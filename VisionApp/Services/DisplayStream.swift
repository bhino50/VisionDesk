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

@MainActor
final class DisplayStream: ObservableObject, Identifiable {
    /// Decoding a backlog only shows the user the past. The queue stays short, and overflowing
    /// it resynchronizes on the next keyframe instead of catching up through stale pictures.
    static let maximumPendingVideoFrames = 4

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
    private var decodeTask: Task<Void, Never>?
    private var epoch = UUID()

    private var pendingVideo: [EncodedVideoFrame] = []
    private var sequencer = VideoStreamSequencer()
    private var decoder: H264Decoder?
    private var videoTask: Task<Void, Never>?

    init(info: DisplayInfo) {
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
        guard decodeTask == nil else { return }
        let currentEpoch = epoch
        decodeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.epoch == currentEpoch,
                      let data = self.latestJPEG else { break }
                self.latestJPEG = nil
                let decoded = await Task.detached(priority: .userInitiated) {
                    DeskFrameDecoder.decode(data)
                }.value
                guard !Task.isCancelled, self.epoch == currentEpoch else { return }
                if let decoded {
                    self.image = UIImage(cgImage: decoded.image)
                    self.receivedAt = ProcessInfo.processInfo.systemUptime
                    self.decodeWarning = nil
                } else {
                    self.decodeWarning = "A frame could not be displayed."
                }
            }
            guard let self, self.epoch == currentEpoch else { return }
            self.decodeTask = nil
        }
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
        guard videoTask == nil else { return }
        let currentEpoch = epoch
        videoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.epoch == currentEpoch, !self.pendingVideo.isEmpty else { break }
                let next = self.pendingVideo.removeFirst()
                let decoder = self.activeDecoder()
                let decoded = await Task.detached(priority: .userInitiated) {
                    decoder.decode(next).map(DecodedDeskFrame.init(image:))
                }.value
                // A stream that was cleared, resized or removed while this frame was decoding
                // must not have its picture resurrected by the result.
                guard !Task.isCancelled, self.epoch == currentEpoch else { return }
                guard let decoded else {
                    // The decoder has lost its reference chain. Retire it, and drop the
                    // picture with it so a stale screen cannot keep control enabled.
                    self.resetPipelines()
                    self.sequencer.requireKeyframe()
                    self.decodeWarning = "A frame could not be displayed."
                    self.requireKeyframe()
                    return
                }
                self.image = UIImage(cgImage: decoded.image)
                self.receivedAt = ProcessInfo.processInfo.systemUptime
                self.decodeWarning = nil
                self.needsKeyframe = self.sequencer.isAwaitingKeyframe
            }
            guard let self, self.epoch == currentEpoch else { return }
            self.videoTask = nil
        }
    }

    private func activeDecoder() -> H264Decoder {
        if let decoder { return decoder }
        let created = H264Decoder()
        decoder = created
        return created
    }

    /// Orphans every decode started before this call and empties both queues.
    ///
    /// The epoch bump is what makes an in-flight result unpublishable, and clearing both task
    /// handles here is what keeps `accept` able to start a new one: an orphaned task returns on
    /// the epoch check without clearing its own handle, so a bump that left a handle set would
    /// make `guard decodeTask == nil` refuse every later frame for the life of the stream.
    /// Those two steps may never be performed apart, which is why they share one function.
    private func invalidateInFlightWork() {
        epoch = UUID()
        decodeTask?.cancel()
        decodeTask = nil
        videoTask?.cancel()
        videoTask = nil
        latestJPEG = nil
        pendingVideo.removeAll()
    }

    private func retireDecoder() {
        let oldDecoder = decoder
        decoder = nil
        if let oldDecoder { Task.detached { oldDecoder.invalidate() } }
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
