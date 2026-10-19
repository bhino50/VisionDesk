import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import DeskCore

final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Paces genuine idle callbacks; their actual cadence still depends on ScreenCaptureKit.
    static let idleRepeatInterval: TimeInterval = 0.8
    /// While the headset is not watching the JPEG — H.264 carries the screen, or no headset is
    /// attached at all — the JPEG is only the companion's own preview and the copy sent on the
    /// next attach, so it is capped at two per second instead of running at the capture rate.
    static let previewOnlyInterval: TimeInterval = 0.5
    static let jpegQuality = 0.76
    static let videoFrameRate = 30
    static let legacyFrameRate = 12
    static let maximumWidth = 1_920
    /// Holding one buffer back for the idle repeat has to leave the stream room to keep
    /// filling, so the video path asks for a deeper queue than the JPEG-only path. The JPEG
    /// output holds at most one frame, and only while pacing has one pending.
    static let videoQueueDepth = 6
    static let legacyQueueDepth = 3
    /// How many consecutive unusable access units are tolerated before video is given up on.
    ///
    /// Every unusable unit costs a forced keyframe, which is the most expensive output the
    /// encoder produces. If the defect belongs to the session rather than to one frame, that
    /// retry never succeeds, so an unbounded count would spend the whole capture budget emitting
    /// IDRs that are discarded — while the display stays blank. At 30fps this ceiling spends
    /// roughly a quarter second on recovery before falling back to JPEG.
    static let maximumConsecutiveInvalidUnits = 8

    let id: UInt32
    private let queue = DispatchQueue(label: "VisionDesk.capture", qos: .userInteractive)
    /// The JPEG output: pacing, the newest frame it held back, and the idle repeat. Touched only
    /// from the serial capture queue.
    private let preview: PreviewPipeline
    private let onEncodedFrame: (@Sendable (UInt32, EncodedVideoFrame) -> Void)?
    private let onFailure: @Sendable (CaptureFailure) -> Void
    /// Reports that H.264 is no longer available for this display while capture itself is still
    /// healthy. A caller that supplies this degrades to JPEG instead of restarting capture;
    /// without it the failure is reported through `onFailure` exactly as before.
    private let onVideoUnavailable: (@Sendable (String) -> Void)?
    private var stream: SCStream?

    // Touched only from the serial capture queue. Monotonic: a backward wall-clock step must not
    // stall idle repeats for a static screen.
    private var lastVideoSubmission = -Double.infinity

    // Shared between the capture queue, the encoder's output handler and the main actor.
    private let lock = NSLock()
    private var encoder: H264Encoder?
    private var encoderFailed = false
    /// Latched once no further video may be produced or rebuilt for this display, by its own
    /// encoder failing or by the session giving up on video globally. Checked in `emit` so an
    /// access unit already in the encoder's pipeline at that moment is discarded rather than
    /// arriving after the client has been told to expect images.
    private var videoDisabled = false
    /// Whether the session is actually putting this display's H.264 on the wire. A live encoder
    /// is not the same thing: during negotiation every encoder runs while the peer is still
    /// being served JPEG, and throttling on encoder existence would cut the picture the headset
    /// is really watching to two frames a second for the whole of that window.
    private var isDeliveringVideo = false
    /// Whether any headset session is attached. With none, nobody but this companion sees the
    /// JPEG, so it is paced as a preview even though no video is being delivered either.
    private var isHeadsetAttached = false
    private var isStopped = false
    private var sequence: UInt64 = 0
    private var invalidOutput = InvalidOutputBudget()
    /// The most recent genuinely captured frame, re-encoded as H.264 while the desktop sits idle.
    /// It is never synthesized: without a live idle callback there is nothing here to repeat.
    /// Kept only while video can still use it; the JPEG output holds its own pending frame.
    private var latestPixelBuffer: CVPixelBuffer?

    /// True only while a hardware H.264 session is actually running. Nothing may advertise the
    /// codec on the strength of the callback alone.
    var isEncodingVideo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return encoder != nil
    }

    init(display: SCDisplay, onFrame: @escaping @Sendable (UInt32, Data) -> Void, onEncodedFrame: (@Sendable (UInt32, EncodedVideoFrame) -> Void)? = nil, onVideoUnavailable: (@Sendable (String) -> Void)? = nil, onFailure: @escaping @Sendable (CaptureFailure) -> Void) {
        self.id = display.displayID
        self.preview = PreviewPipeline(id: display.displayID, deliver: onFrame)
        self.onEncodedFrame = onEncodedFrame
        self.onVideoUnavailable = onVideoUnavailable
        self.onFailure = onFailure
        super.init()
        let config = SCStreamConfiguration()
        var width = min(Self.maximumWidth, CGDisplayPixelsWide(display.displayID))
        var height = max(2, Int(Double(width) * Double(display.height) / Double(display.width)))
        if onEncodedFrame != nil {
            // 4:2:0 has no odd edge. Rounding here, and only here, keeps the JPEG-only path
            // byte-for-byte what it was.
            width = max(EncodedVideoFrame.minimumDimension, width - width % 2)
            height = max(EncodedVideoFrame.minimumDimension, height - height % 2)
        }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(onEncodedFrame == nil ? Self.legacyFrameRate : Self.videoFrameRate))
        config.queueDepth = onEncodedFrame == nil ? Self.legacyQueueDepth : Self.videoQueueDepth
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: self)
    }

    func start() async throws {
        guard let stream else { return }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    /// Stops capture and tears down the encoder. After this returns, no further encoded frame
    /// can be produced for this display, including from a late ScreenCaptureKit callback.
    func stop() async {
        guard !latchStop() else { return }
        try? await stream?.stopCapture()
    }

    /// Latches the stop and tears the encoder down synchronously, so no lock is ever held
    /// across a suspension point. Returns true when an earlier call already stopped capture.
    private func latchStop() -> Bool {
        lock.lock()
        let alreadyStopped = isStopped
        isStopped = true
        let stale = encoder
        encoder = nil
        latestPixelBuffer = nil
        lock.unlock()
        stale?.invalidate()
        // A frame held back by pacing goes back to ScreenCaptureKit's pool. This runs after any
        // callback already in flight, and every later callback sees the stop latch.
        queue.async { [preview] in preview.discardPending() }
        return alreadyStopped
    }

    /// Thread-safe. Asks the encoder to emit the next frame as a keyframe so a client that has
    /// just attached, or has just lost the reference chain, can resynchronize.
    func requestKeyframe() {
        lock.lock()
        let encoder = self.encoder
        lock.unlock()
        // With no session yet, the first frame of the next session is a keyframe anyway.
        encoder?.requestKeyframe()
    }

    /// Thread-safe. Records whether the session is currently sending this display's compressed
    /// video to the peer, which is what decides the JPEG cadence. Called from the main actor as
    /// the session negotiates, promotes to video, or falls back to images.
    func setDeliveringVideo(_ delivering: Bool) {
        lock.lock()
        isDeliveringVideo = delivering && !videoDisabled
        lock.unlock()
    }

    /// Thread-safe. Records whether a headset session is attached at all, which decides whether
    /// the JPEG is anyone's picture or only the companion's preview. Called from the main actor.
    func setHeadsetAttached(_ attached: Bool) {
        lock.lock()
        isHeadsetAttached = attached
        lock.unlock()
    }

    /// Gives up on H.264 for this display without reporting anything.
    ///
    /// Used when the session falls back to images because *another* display's encoder failed. A
    /// healthy capture left encoding would keep throttling its JPEG to the two-per-second
    /// preview cadence while that JPEG is the only picture the headset still receives, so every
    /// capture has to be latched off together. Silent by design: the caller already knows why,
    /// and notifying back would let one failure fan out into another round of fallbacks.
    func disableVideo() {
        lock.lock()
        guard !videoDisabled else {
            lock.unlock()
            return
        }
        videoDisabled = true
        isDeliveringVideo = false
        let stale = encoder
        encoder = nil
        latestPixelBuffer = nil
        lock.unlock()
        // Tearing a session down runs its pending output handlers, so it never happens inline:
        // this can be called from the main actor while a VideoToolbox callback is in flight.
        queue.async { stale?.invalidate() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(CaptureFailure(error))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        lock.lock()
        let stopped = isStopped
        lock.unlock()
        guard !stopped else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let frameStatus = SCFrameStatus(rawValue: raw)
        // An idle callback means capture is alive but the desktop has not changed. Repeating
        // the last real frame keeps the client's freshness window satisfied; `.blank`,
        // `.suspended` and `.stopped` deliberately fall through and produce nothing at all.
        if frameStatus == .idle {
            repeatIdleFrame(at: now)
            return
        }
        guard frameStatus == .complete || frameStatus == .started,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        retainForIdleRepeat(pixelBuffer)
        submitVideo(pixelBuffer, at: now)
        preview.frame(pixelBuffer, at: now, interval: currentPreviewInterval())
    }

    // MARK: Video

    private func submitVideo(_ pixelBuffer: CVPixelBuffer, at uptime: TimeInterval) {
        guard onEncodedFrame != nil,
              let encoder = activeEncoder(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) else { return }
        if encoder.encode(pixelBuffer, at: uptime) { lastVideoSubmission = uptime }
    }

    /// Returns the session for these dimensions, building one if the geometry changed. Called
    /// only from the serial capture queue, so creation never races with itself; the lock is
    /// there for `stop()` and `requestKeyframe()`.
    private func activeEncoder(width: Int, height: Int) -> H264Encoder? {
        lock.lock()
        if isStopped || encoderFailed || videoDisabled {
            lock.unlock()
            return nil
        }
        if let encoder, encoder.width == width, encoder.height == height {
            lock.unlock()
            return encoder
        }
        let stale = encoder
        encoder = nil
        lock.unlock()

        // Never hold the lock across these: tearing a session down runs its pending output
        // handlers, and those take the same lock.
        stale?.invalidate()
        do {
            let created = try H264Encoder(
                width: width, height: height,
                onEncoded: { [weak self] unit in self?.emit(unit) },
                onFailure: { [weak self] reason in self?.reportEncoderFailure(reason) }
            )
            lock.lock()
            guard !isStopped else {
                lock.unlock()
                created.invalidate()
                return nil
            }
            encoder = created
            lock.unlock()
            return created
        } catch {
            reportEncoderFailure("Hardware H.264 encoding is unavailable: \(error).")
            return nil
        }
    }

    /// Called from the encoder's output handler, so this runs on a VideoToolbox callback thread
    /// and must never re-enter VideoToolbox. A unit that cannot be represented on the wire is
    /// answered with a keyframe request, but only while the run of failures stays bounded: past
    /// the ceiling the session is given up on so the JPEG path can take the display back.
    private func emit(_ unit: H264Encoder.EncodedUnit) {
        guard let onEncodedFrame else { return }
        lock.lock()
        guard !isStopped, !videoDisabled else {
            lock.unlock()
            return
        }
        let candidate = EncodedVideoFrame(
            width: unit.width, height: unit.height, sequence: sequence &+ 1,
            isKeyframe: unit.isKeyframe, payload: unit.payload, sps: unit.sps, pps: unit.pps
        )
        guard candidate.isValid else {
            let response = invalidOutput.recordInvalid(limit: Self.maximumConsecutiveInvalidUnits)
            // Read under the lock: another callback thread may record a failure the moment
            // this one releases it, and the message must name the run that actually tripped.
            let count = invalidOutput.consecutive
            lock.unlock()
            switch response {
            case .requestKeyframe:
                // Dropping an access unit breaks the chain the next predicted frame assumes,
                // and consuming no sequence number keeps the wire dense for whatever follows.
                requestKeyframe()
            case .giveUpOnVideo:
                // Asking for yet another keyframe would only buy another unusable unit.
                reportEncoderFailure("The hardware H.264 encoder produced \(count) unusable frames in a row. Falling back to image updates for this display.")
            }
            return
        }
        invalidOutput.recordValid()
        sequence = candidate.sequence
        lock.unlock()
        onEncodedFrame(id, candidate)
    }

    /// Latches the failure so the companion stops paying for retries, and lets the JPEG path
    /// return to full rate rather than leaving the client on a two-frame-per-second preview.
    ///
    /// Safe to call from any thread, including a VideoToolbox output handler: the state is
    /// latched synchronously, so no further frame is submitted, but tearing the session down
    /// runs its pending handlers and is therefore deferred to the capture queue rather than
    /// re-entering VideoToolbox from inside its own callback.
    private func reportEncoderFailure(_ reason: String) {
        lock.lock()
        let alreadyFailed = encoderFailed
        encoderFailed = true
        videoDisabled = true
        let stale = encoder
        encoder = nil
        // No H.264 idle repeat can use it any more, so its surface goes back to the pool.
        latestPixelBuffer = nil
        let stopped = isStopped
        lock.unlock()
        guard !alreadyFailed, !stopped else {
            queue.async { stale?.invalidate() }
            return
        }
        let degrade = onVideoUnavailable
        let fail = onFailure
        queue.async {
            stale?.invalidate()
            if let degrade { degrade(reason) } else { fail(CaptureFailure(retryable: reason)) }
        }
    }

    /// Keeps the newest frame for the H.264 idle repeat, and only while video can still use it.
    /// Once video is given up — this display's encoder failed, or the session fell back for every
    /// display — a buffer kept here would only pin a ScreenCaptureKit surface. The JPEG output
    /// keeps its own pending frame (`PreviewPipeline`), so JPEG-only captures are covered too.
    private func retainForIdleRepeat(_ pixelBuffer: CVPixelBuffer) {
        guard onEncodedFrame != nil else { return }
        lock.lock()
        if !isStopped && !videoDisabled { latestPixelBuffer = pixelBuffer }
        lock.unlock()
    }

    private func repeatIdleFrame(at uptime: TimeInterval) {
        preview.idle(at: uptime, interval: currentPreviewInterval())
        guard onEncodedFrame != nil, uptime - lastVideoSubmission >= Self.idleRepeatInterval else { return }
        lock.lock()
        let buffer = isStopped ? nil : latestPixelBuffer
        lock.unlock()
        guard let buffer else { return }
        submitVideo(buffer, at: uptime)
    }

    // MARK: JPEG preview

    /// The minimum spacing between JPEG frames.
    ///
    /// The deciding fact is whether the headset is actually watching the JPEG. With no headset
    /// attached nobody is: the JPEG only refreshes the companion's own thumbnail and the copy
    /// sent on the next attach, so it is paced as a preview. That is the state an unattended
    /// host spends most of its time in, and pacing it as the headset's picture cost four
    /// displays 48 full-size JPEG encodes a second for an audience of none.
    ///
    /// With a headset attached, the deciding fact is whether compressed video is actually
    /// reaching it, not whether an encoder exists. Those differ for the whole negotiation
    /// window — every encoder is live while the session is still serving JPEG — and they differ
    /// again when one display's encoder fails and the session falls back for all of them.
    ///
    /// While video is being delivered the JPEG is only the companion's own preview and is cut to
    /// two per second. Otherwise it is the picture the headset sees and has to run at a usable
    /// rate — but not the capture rate: a video-configured stream delivers 30fps, which across
    /// four displays would be 120 JPEG encodes per second, far more CPU and bandwidth than the
    /// legacy path ever spent for a picture no better than 12fps.
    ///
    /// A capture that was never configured for video is already paced at `legacyFrameRate` by
    /// ScreenCaptureKit itself, so while a headset watches it keeps its unthrottled behavior
    /// exactly: imposing the same interval on a 12fps stream would drop frames on float-boundary
    /// jitter and halve the rate.
    static func previewInterval(isDeliveringVideo: Bool, isHeadsetAttached: Bool, isVideoCapture: Bool) -> TimeInterval {
        guard isHeadsetAttached else { return previewOnlyInterval }
        guard isVideoCapture else { return 0 }
        return isDeliveringVideo ? previewOnlyInterval : 1.0 / Double(legacyFrameRate)
    }

    /// The JPEG every image path sends, or nil when it cannot be encoded or would not fit on the
    /// wire. Static so its cost can be measured on a synthetic frame without capturing a screen.
    static func encodeJPEG(_ pixelBuffer: CVPixelBuffer, context: CIContext) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        // `DeskMessage.isValid` refuses anything larger. A frame past it would be cached, then
        // fail on every send and on every idle repeat, so it is refused here instead.
        guard CGImageDestinationFinalize(destination), data.length <= DeskMessage.maximumJPEGBytes else { return nil }
        return data as Data
    }

    /// This display's JPEG spacing right now; see `previewInterval`.
    private func currentPreviewInterval() -> TimeInterval {
        lock.lock()
        let delivering = isDeliveringVideo
        let attached = isHeadsetAttached
        lock.unlock()
        return Self.previewInterval(isDeliveringVideo: delivering, isHeadsetAttached: attached,
                                    isVideoCapture: onEncodedFrame != nil)
    }
}

/// A display's JPEG output: pacing, the newest frame pacing held back, and the idle repeat.
///
/// Pacing used to drop every frame inside its interval for good, and an idle callback only
/// re-sent the last JPEG. So a change that came less than an interval after the previous image —
/// a keystroke, the cursor coming to rest, a clock tick — and was followed by a still screen was
/// never encoded: the companion's thumbnail, the copy sent on the next attach and a headset
/// watching images all kept the older picture until the screen changed again. Now the newest
/// held-back frame is kept and encoded at the first idle callback after the interval, in place
/// of the repeat. That holds on every path that carries JPEG: no headset attached, a JPEG-only
/// headset, a session that fell back from video, and a capture never configured for video.
///
/// A frame that fails to encode is not retried, so a screen that cannot be encoded costs one
/// attempt rather than one per idle callback. At most one frame is held, only while it is
/// pending, and it is released once it is encoded, superseded or discarded.
///
/// Confined to its capture's serial queue. Nothing here touches ScreenCaptureKit, so the
/// behavior harness drives exactly this code with synthetic frames and explicit times.
final class PreviewPipeline: @unchecked Sendable {
    let id: UInt32
    private let encode: (CVPixelBuffer) -> Data?
    private let deliver: @Sendable (UInt32, Data) -> Void
    /// The last JPEG handed on, repeated while the desktop sits idle.
    private(set) var latestJPEG: Data?
    /// When the last JPEG was handed on, fresh or repeated. Monotonic uptime: a backward
    /// wall-clock step must not stall idle repeats for a static screen.
    private var lastDelivery = -Double.infinity
    /// The newest captured frame the interval held back, not yet encoded.
    private var pending: CVPixelBuffer?

    var hasPendingFrame: Bool { pending != nil }

    init(id: UInt32, encode: @escaping (CVPixelBuffer) -> Data? = PreviewPipeline.productionEncoder(),
         deliver: @escaping @Sendable (UInt32, Data) -> Void) {
        self.id = id
        self.encode = encode
        self.deliver = deliver
    }

    /// The production JPEG settings on a Core Image context of the pipeline's own.
    static func productionEncoder() -> (CVPixelBuffer) -> Data? {
        let context = CIContext(options: [.cacheIntermediates: false])
        return { DisplayCapture.encodeJPEG($0, context: context) }
    }

    /// A captured frame: encoded now once `interval` has passed since the last image, otherwise
    /// held back in place of any older pending frame.
    func frame(_ buffer: CVPixelBuffer, at uptime: TimeInterval, interval: TimeInterval) {
        guard uptime - lastDelivery >= interval else {
            pending = buffer
            return
        }
        // Newer than anything held back, whether or not it encodes.
        pending = nil
        send(buffer, at: uptime)
    }

    /// An idle callback: capture is alive and the desktop has not changed since the last frame.
    /// A held-back frame is encoded once the interval allows; otherwise the last JPEG is repeated
    /// on the idle cadence, which keeps the headset's freshness window satisfied.
    func idle(at uptime: TimeInterval, interval: TimeInterval) {
        if let held = pending {
            guard uptime - lastDelivery >= interval else { return }
            pending = nil
            send(held, at: uptime)
        } else if let latestJPEG, uptime - lastDelivery >= DisplayCapture.idleRepeatInterval {
            lastDelivery = uptime
            deliver(id, latestJPEG)
        }
    }

    /// Releases a held-back frame, returning its surface to ScreenCaptureKit's pool.
    func discardPending() { pending = nil }

    private func send(_ buffer: CVPixelBuffer, at uptime: TimeInterval) {
        guard let jpeg = encode(buffer) else { return }
        latestJPEG = jpeg
        lastDelivery = uptime
        deliver(id, jpeg)
    }
}

/// More displays are connected than one session carries. No start can succeed until the
/// arrangement changes, so this is never retried.
struct DisplayLimitExceeded: LocalizedError, Equatable {
    let count: Int

    var errorDescription: String? {
        "This prototype supports up to four displays. Disconnect extra displays before sharing."
    }

    /// What an unattended remote host reports while it waits for a shareable arrangement.
    static let remoteStatus = "This prototype supports up to four displays. Disconnect extra displays; remote sharing resumes on its own once four or fewer are connected."
}

/// Why capture ended, and whether the companion may start it again on its own.
///
/// An unattended host used to retry every capture stop. Three outcomes are not worth retrying.
/// A stop from the macOS screen-sharing controls is the owner's own choice, and restarting
/// capture seconds later would override it. A refused recording permission or missing
/// entitlement cannot succeed until the owner changes System Settings, so retrying only repeats
/// the refusal every 30 seconds indefinitely. More displays than a session carries cannot be
/// shared until one is disconnected; retrying that held the Mac awake indefinitely while nothing
/// was shared. ScreenCaptureKit codes are matched together with their domain, and every other
/// error keeps the previous retry behavior.
struct CaptureFailure: Equatable, Sendable {
    enum Disposition: Equatable, Sendable {
        /// An interruption that can clear up: a display going away, the system stopping the
        /// stream, a dropped connection to the capture service, an encoder failure.
        case retry
        /// Someone stopped sharing from the macOS screen-sharing controls (`userStopped`).
        case stoppedByOwner
        /// macOS refused capture (`userDeclined`) or this build lacks the entitlement.
        case notPermitted
        /// More displays are connected than a session carries (`DisplayLimitExceeded`).
        case unsupportedArrangement
    }

    let disposition: Disposition
    let reason: String

    init(_ error: Error) {
        let nsError = error as NSError
        disposition = error is DisplayLimitExceeded
            ? .unsupportedArrangement
            : Self.disposition(domain: nsError.domain, code: nsError.code)
        reason = nsError.localizedDescription
    }

    init(retryable reason: String) {
        disposition = .retry
        self.reason = reason
    }

    static func disposition(domain: String, code: Int) -> Disposition {
        guard domain == SCStreamErrorDomain else { return .retry }
        switch code {
        case SCStreamError.Code.userStopped.rawValue:
            return .stoppedByOwner
        case SCStreamError.Code.userDeclined.rawValue, SCStreamError.Code.missingEntitlements.rawValue:
            return .notPermitted
        default:
            return .retry
        }
    }
}

/// Bounded recovery from encoder output that cannot be put on the wire.
///
/// A single unusable access unit is ordinary — the reference chain broke, and a fresh keyframe
/// repairs it. An unbroken run of them is not: it means the defect belongs to the session, and
/// each retry produces another equally expensive IDR that is also discarded. Counting only
/// consecutive failures is what separates the two, so intermittent corruption never accumulates
/// into a false give-up.
struct InvalidOutputBudget {
    enum Response: Equatable {
        case requestKeyframe
        case giveUpOnVideo
    }

    private(set) var consecutive = 0

    mutating func recordValid() { consecutive = 0 }

    mutating func recordInvalid(limit: Int) -> Response {
        consecutive += 1
        return consecutive >= limit ? .giveUpOnVideo : .requestKeyframe
    }
}

/// One queued delivery and one latest image per capture, regardless of main-thread load.
final class LatestFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (UInt32, Data)?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (UInt32, Data) -> Void

    init(deliver: @escaping @MainActor @Sendable (UInt32, Data) -> Void) { self.deliver = deliver }

    func submit(id: UInt32, jpeg: Data) {
        lock.lock()
        latest = (id, jpeg)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            Task { @MainActor [self] in
                if let value = take() { deliver(value.0, value.1) }
            }
        }
    }

    private func take() -> (UInt32, Data)? {
        lock.lock(); defer { lock.unlock() }
        let value = latest
        latest = nil; scheduled = false
        return value
    }
}
