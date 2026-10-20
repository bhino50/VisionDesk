import Combine
import DeskCore
import Foundation
import ImageIO
import UIKit

private struct DecodedDeskFrame: @unchecked Sendable {
    let image: CGImage
}

private enum DeskFrameDecoder {
    // Limit both the wire payload and decoded pixels before allocating a bitmap.
    static func decode(_ data: Data) -> DecodedDeskFrame? {
        guard !data.isEmpty, data.count <= 4 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue <= 8_192, height.doubleValue <= 8_192,
              width.doubleValue * height.doubleValue <= 8_500_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return DecodedDeskFrame(image: image)
    }
}

/// Process-wide admission, acquired before creating a task. A video decoder retains its
/// lease between frames, so even synchronous destruction cannot escape the native-work cap.
/// There are no suspended waiters or queued acquisition requests: saturation drops work.
private final class NativeDecodeSlot {
    static let capacity = 4
    private static let lock = NSLock()
    private static var count = 0
    var decoder: H264Decoder?

    static func acquire() -> NativeDecodeSlot? {
        lock.lock(); defer { lock.unlock() }
        guard count < capacity else { return nil }
        count += 1
        return NativeDecodeSlot()
    }

    private init() {}

    deinit {
        // Retire before returning capacity, including when an idle stream is removed.
        decoder?.invalidate()
        Self.lock.lock()
        Self.count -= 1
        Self.lock.unlock()
    }
}

@MainActor
final class DisplayStream: ObservableObject, Identifiable {
    /// Decoding a backlog only shows the user the past. The queue stays short, and overflowing
    /// it resynchronizes on the next keyframe instead of catching up through stale pictures.
    static let maximumPendingVideoFrames = 4
    static let maximumNativeWorkers = NativeDecodeSlot.capacity

    let id: UInt32
    @Published private(set) var info: DisplayInfo
    @Published private(set) var image: UIImage?
    @Published private(set) var receivedAt: TimeInterval?
    @Published private(set) var decodeWarning: String?

    /// True while nothing further can be decoded until the Mac emits a keyframe. It starts
    /// true because a stream that has never seen a keyframe has nothing to predict from.
    private(set) var needsKeyframe = true
    /// Set by the client model. Fires whenever the stream newly needs a keyframe; it can fire
    /// repeatedly, so the caller is expected to rate-limit the request it sends.
    var onKeyframeNeeded: (@MainActor () -> Void)?

    /// Which source last published for this display. Readable so a test can state which
    /// pipeline a transition handed the stream to; only `switchSource` changes it.
    private(set) var usesVideo = false
    private var latestJPEG: Data?
    private var workerTask: Task<Void, Never>?
    private var decoderNeedsRetirement = false
    private let beforeNativeWork: @Sendable (String) -> Void
    private var epoch = UUID()

    private var pendingVideo: [EncodedVideoFrame] = []
    private var sequencer = VideoStreamSequencer()
    private var nativeSlot: NativeDecodeSlot?

    init(info: DisplayInfo, beforeNativeWork: @escaping @Sendable (String) -> Void = { _ in }) {
        self.beforeNativeWork = beforeNativeWork
        self.id = info.id
        self.info = info
    }

    var imageSize: CGSize {
        if let image { return image.size }
        return CGSize(width: CGFloat(info.width), height: CGFloat(info.height))
    }

    func update(info: DisplayInfo) {
        // Point size can change without the pixel grid moving, and the cached bitmap is still
        // correct in that case.
        let resized = info.width != self.info.width || info.height != self.info.height
        self.info = info
        guard resized else { return }
        // The cached frame has the old aspect ratio, so `isFresh()` would vouch for an image
        // that maps taps to the wrong place. Drop it and cancel any in-flight decode of a
        // pre-resize frame; the next frame restores the screen.
        clear()
    }

    func isFresh(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard image != nil, let receivedAt, !usesVideo || !sequencer.isAwaitingKeyframe else { return false }
        return uptime - receivedAt < 2.5
    }

    func accept(jpeg: Data) {
        guard !jpeg.isEmpty, jpeg.count <= 4 * 1_024 * 1_024 else {
            // Refused before the source changes: a payload this stream cannot use is not a
            // transition, and tearing a working video pipeline down over it would be worse
            // than the frame being dropped.
            decodeWarning = "The Mac sent an unsupported frame."
            return
        }
        switchSource(toVideo: false)
        // While a frame decodes, keep only the newest replacement for this display.
        latestJPEG = jpeg
        startWorkerIfNeeded()
    }

    /// Admits one compressed access unit. Unlike a JPEG, a predicted frame is meaningless on
    /// its own, so the sequencer decides what may reach the decoder at all and the picture is
    /// only published once a decode actually succeeds.
    func accept(video frame: EncodedVideoFrame) {
        // Validated before the source changes, for the same reason an unusable JPEG is: a
        // payload this stream cannot use is not a transition. Switching first would let a
        // single malformed video message cancel a JPEG decode mid-flight and — because
        // `isFresh()` only consults the sequencer while the stream is on video — revoke a
        // still picture's freshness, disabling control on a screen that images are serving
        // perfectly well.
        guard frame.isValid else {
            decodeWarning = "The Mac sent an unsupported frame."
            // Only a stream already on video has a reference chain to resynchronize. A
            // malformed unit may still have advanced the sender's chain, so that stream has
            // to wait for a keyframe and give up its freshness meanwhile. A stream being
            // served by images has neither a chain nor anything to wait for.
            if usesVideo {
                sequencer.requireKeyframe()
                requireKeyframe()
            }
            return
        }
        switchSource(toVideo: true)
        switch sequencer.admit(frame) {
        case .decode(let resetsPipeline):
            // A geometry change invalidates the decoder, the queued frames behind it and the
            // picture already on screen, all of which describe the previous screen size.
            if resetsPipeline { resetPipelines() }
            enqueue(frame)
        case .rejectMalformed:
            // Unreachable from here now that validity is checked above and `admit` applies
            // the same predicate. Kept so the policy's own answer is still honoured if
            // either check ever moves: keep the last picture for context, and disable
            // control until a valid keyframe restores the reference chain.
            decodeWarning = "The Mac sent an unsupported frame."
            requireKeyframe()
        case .rejectStale:
            return
        case .rejectGap, .rejectAwaitingKeyframe:
            // Frames already queued are still a continuous chain and stay queued; only this
            // one is unusable.
            requireKeyframe()
        }
    }

    func clear() {
        resetPipelines()
        sequencer.reset()
        decodeWarning = nil
        requireKeyframe()
    }

    // MARK: Source transitions

    /// Hands the stream from one source to the other.
    ///
    /// Both directions happen inside one live session. The Mac sends a cached JPEG for every
    /// display the moment a client attaches and only moves to H.264 once it has the client's
    /// codec, and a display whose hardware encoder fails latches back to JPEG for good. So a
    /// decode belonging to the source being retired can still be in flight here, and without
    /// invalidation its older picture would land on top of the newer source's and refresh the
    /// freshness stamp while doing it. Bumping the epoch makes that result unpublishable.
    ///
    /// The picture already on screen stays: it is the newest frame this stream actually
    /// accepted, and blanking it would disable control for a frame on every single connect.
    private func switchSource(toVideo: Bool) {
        guard usesVideo != toVideo else { return }
        usesVideo = toVideo
        invalidateInFlightWork()
        guard !toVideo else { return }
        // Leaving video retires the decoder, so a later return to video cannot predict from
        // state the sender no longer shares. The sequence numbering is deliberately kept: the
        // Mac's fallback disables video on the capture objects it already has rather than
        // rebuilding them, so their counters keep climbing and a return to video resumes
        // above the recorded number. `requireKeyframe` is therefore right where `reset` would
        // be wrong. The requirement is recorded rather than announced, too: a Mac that just
        // gave up on its encoder has no keyframe to send, so asking for one is pure noise.
        retireDecoder()
        sequencer.requireKeyframe()
        needsKeyframe = true
    }

    // MARK: Video pipeline

    private func enqueue(_ frame: EncodedVideoFrame) {
        pendingVideo.append(frame)
        guard pendingVideo.count <= Self.maximumPendingVideoFrames else {
            // The decoder is not keeping up. Shedding the backlog costs one keyframe and
            // returns the user to live, where draining it would only add latency.
            resetPipelines(keepLastPicture: true)
            sequencer.requireKeyframe()
            requireKeyframe()
            return
        }
        startWorkerIfNeeded()
    }

    /// One retained worker owns all native work, including retirement, across every epoch.
    /// Reset clears bounded pending state but cannot abandon a synchronous native operation.
    /// A new source therefore waits for the old operation and its retirement to finish.
    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        if nativeSlot == nil {
            guard let acquired = NativeDecodeSlot.acquire() else {
                latestJPEG = nil
                pendingVideo.removeAll()
                if usesVideo {
                    sequencer.requireKeyframe()
                    requireKeyframe()
                }
                return
            }
            nativeSlot = acquired
        }
        workerTask = Task { @MainActor [weak self] in
            while let self {
                let hook = self.beforeNativeWork
                if self.decoderNeedsRetirement {
                    self.decoderNeedsRetirement = false
                    let old = self.nativeSlot?.decoder
                    self.nativeSlot?.decoder = nil
                    if let old {
                        await Task.detached(priority: .userInitiated) {
                            hook("retire")
                            old.invalidate()
                        }.value
                    }
                    continue
                }
                let currentEpoch = self.epoch
                if let data = self.latestJPEG {
                    self.latestJPEG = nil
                    let decoded = await Task.detached(priority: .userInitiated) {
                        hook("jpeg")
                        return DeskFrameDecoder.decode(data)
                    }.value
                    guard self.epoch == currentEpoch else { continue }
                    self.publish(decoded)
                } else if !self.pendingVideo.isEmpty {
                    let next = self.pendingVideo.removeFirst()
                    let decoder = self.activeDecoder()
                    let decoded = await Task.detached(priority: .userInitiated) {
                        hook("video")
                        return decoder.decode(next).map(DecodedDeskFrame.init(image:))
                    }.value
                    guard self.epoch == currentEpoch else { continue }
                    guard let decoded else {
                        self.resetPipelines()
                        self.sequencer.requireKeyframe()
                        self.decodeWarning = "A frame could not be displayed."
                        self.requireKeyframe()
                        continue
                    }
                    self.publish(decoded)
                    self.needsKeyframe = self.sequencer.isAwaitingKeyframe
                } else {
                    // Keep video reference state under its lease. JPEG-only work has
                    // no native state left, so another display may use the capacity now.
                    if self.nativeSlot?.decoder == nil { self.nativeSlot = nil }
                    self.workerTask = nil
                    return
                }
            }
        }
    }

    private func publish(_ decoded: DecodedDeskFrame?) {
        if let decoded {
            image = UIImage(cgImage: decoded.image)
            receivedAt = ProcessInfo.processInfo.systemUptime
            decodeWarning = nil
        } else {
            decodeWarning = "A frame could not be displayed."
        }
    }

    private func activeDecoder() -> H264Decoder {
        if let decoder = nativeSlot?.decoder { return decoder }
        precondition(nativeSlot != nil, "Native work requires an admitted slot")
        let created = H264Decoder()
        nativeSlot?.decoder = created
        return created
    }

    /// Invalidates results without cancelling the retained worker. Native calls cannot be
    /// cancelled, so resetting its handle would permit another unbounded concurrent decode.
    private func invalidateInFlightWork() {
        epoch = UUID()
        latestJPEG = nil
        pendingVideo.removeAll()
    }

    private func retireDecoder() {
        decoderNeedsRetirement = true
        startWorkerIfNeeded()
    }

    /// Invalidates in-flight results, queued frames and decoder reference state. Overflow
    /// retains the last picture for context; an orphaned decode uses only the retired decoder.
    private func resetPipelines(keepLastPicture: Bool = false) {
        invalidateInFlightWork()
        retireDecoder()
        if !keepLastPicture { image = nil }
        receivedAt = nil
    }

    private func requireKeyframe() {
        receivedAt = nil
        needsKeyframe = true
        onKeyframeNeeded?()
    }
}
