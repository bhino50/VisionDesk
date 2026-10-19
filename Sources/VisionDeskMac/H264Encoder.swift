import CoreMedia
import CoreVideo
import DeskCore
import Foundation
import VideoToolbox

/// A hardware H.264 compression session for exactly one display, configured for interactive
/// remote control rather than for recording: real time, no frame reordering, no B-frames, a
/// keyframe at least every second, and a hard data-rate ceiling so a scene change cannot burst
/// a slow WAN link into a multi-second backlog.
///
/// The session is driven from the capture queue and torn down from the main actor, so every
/// piece of mutable state is behind one lock. Nothing is ever emitted after `invalidate()`.
final class H264Encoder: @unchecked Sendable {
    /// One compressed access unit, before the caller stamps it with a wire sequence number.
    struct EncodedUnit: Sendable {
        let payload: Data
        let sps: Data?
        let pps: Data?
        let isKeyframe: Bool
        let width: Int
        let height: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case sessionCreation(OSStatus)
        case property(String, OSStatus)
        case preparation(OSStatus)

        var description: String {
            switch self {
            case .sessionCreation(let status):
                return "no hardware H.264 encoder is available (status \(status))"
            case .property(let name, let status):
                return "the hardware H.264 encoder rejected \(name) (status \(status))"
            case .preparation(let status):
                return "the hardware H.264 encoder failed to start (status \(status))"
            }
        }
    }

    static let frameRate = 30
    /// At most one second between keyframes, so a receiver that loses the reference chain
    /// recovers without waiting on a round trip.
    static let keyframeIntervalSeconds = 1.0
    static let maximumBitRate = 6_000_000
    static let minimumBitRate = 1_500_000
    /// 1920x1080 at 30fps lands just under the 6 Mbit/s ceiling; smaller screens scale down.
    static let bitsPerPixelPerFrame = 0.095
    /// Hard burst ceiling as a multiple of the average rate, over a one-second window.
    static let burstAllowance = 1.5
    /// Submitting past this many unreturned frames would only build latency the user feels as
    /// lag. Dropping at the source is always better than queueing at the source.
    static let maximumInFlightFrames = 2
    private static let presentationTimescale: CMTimeScale = 600
    /// NAL unit header: forbidden_zero_bit, nal_ref_idc, then five bits of type.
    private static let nalTypeMask: UInt8 = 0x1F
    private static let nalTypeSequenceParameterSet: UInt8 = 7
    private static let nalTypePictureParameterSet: UInt8 = 8
    /// Upper bound on how many parameter sets one descriptor is scanned for.
    private static let maximumParameterSetScan = 8

    let width: Int
    let height: Int
    let bitRate: Int

    private let session: VTCompressionSession
    private let onEncoded: @Sendable (EncodedUnit) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let frameDuration: CMTime
    private let lock = NSLock()
    private var inFlight = 0
    private var isInvalidated = false
    /// The first frame of any session has to be a keyframe for a receiver to start at all.
    private var wantsKeyframe = true
    private var lastPresentation: CMTime?

    static func bitRate(width: Int, height: Int) -> Int {
        let target = Double(width * height) * bitsPerPixelPerFrame * Double(frameRate)
        return min(maximumBitRate, max(minimumBitRate, Int(target)))
    }

    init(width: Int, height: Int, onEncoded: @escaping @Sendable (EncodedUnit) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.width = width
        self.height = height
        self.bitRate = Self.bitRate(width: width, height: height)
        self.onEncoded = onEncoded
        self.onFailure = onFailure
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))

        // Requiring hardware acceleration is deliberate. A software fallback would silently
        // spend the companion's CPU on four displays and still miss 30fps, so an unavailable
        // hardware encoder has to surface as a failure rather than as a slow success.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            // Null, because every frame carries its own output handler block. That keeps the
            // callback's lifetime tied to the block instead of to an unmanaged refcon pointer
            // that would have to outlive an asynchronous teardown.
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { throw Failure.sessionCreation(status) }
        self.session = session

        do {
            try Self.require(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "real-time mode")
            // No reordering means no B-frames, which means an access unit is displayable the
            // moment it arrives. Reordering would add a frame of latency for nothing here.
            try Self.require(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "low-latency frame order")
            try Self.require(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel, "H.264 High profile")
            try Self.require(session, kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber, "average bit rate")
            try Self.require(session, kVTCompressionPropertyKey_ExpectedFrameRate, Self.frameRate as CFNumber, "expected frame rate")
            try Self.require(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, Self.frameRate as CFNumber, "keyframe interval")
            try Self.require(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Self.keyframeIntervalSeconds as CFNumber, "keyframe interval duration")

            // Best effort. These sharpen latency and bandwidth behavior but no encoder is
            // required to support them, and none of them changes whether the output decodes.
            let bytesPerWindow = Double(bitRate) / 8 * Self.burstAllowance
            Self.prefer(session, kVTCompressionPropertyKey_DataRateLimits, [bytesPerWindow, 1.0] as CFArray)
            Self.prefer(session, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
            Self.prefer(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            Self.prefer(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)

            let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
            guard prepared == noErr else { throw Failure.preparation(prepared) }
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
    }

    deinit { invalidate() }

    /// Thread-safe. The next submitted frame is encoded as an IDR picture carrying fresh
    /// parameter sets, which is what lets a receiver resynchronize after a loss.
    func requestKeyframe() {
        lock.lock()
        wantsKeyframe = true
        lock.unlock()
    }

    /// Submits one captured frame. Returns false when the frame was refused, which happens when
    /// the encoder is already saturated or has been torn down. A refusal consumes no sequence
    /// number and leaves no gap on the wire.
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, at uptime: TimeInterval) -> Bool {
        lock.lock()
        guard !isInvalidated, inFlight < Self.maximumInFlightFrames else {
            lock.unlock()
            return false
        }
        let presentation = nextPresentationTimeLocked(uptime)
        let forceKeyframe = wantsKeyframe
        wantsKeyframe = false
        inFlight += 1
        lock.unlock()

        let properties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentation, duration: frameDuration,
            frameProperties: properties, infoFlagsOut: &flags,
            outputHandler: { [weak self] status, infoFlags, sampleBuffer in
                self?.handleOutput(status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
            }
        )
        guard status == noErr else {
            // VideoToolbox does not call the handler when the submission itself fails, so the
            // in-flight count has to be released here or the encoder would wedge shut.
            lock.lock()
            inFlight = max(0, inFlight - 1)
            // The reference chain is now in doubt; the next frame out has to be a keyframe.
            wantsKeyframe = true
            let reportable = !isInvalidated
            lock.unlock()
            if reportable { onFailure("The hardware H.264 encoder rejected a frame (status \(status)).") }
            return false
        }
        return true
    }

    /// Drops every pending frame and tears the session down. Safe to call more than once, and
    /// safe to call while a frame is in flight: nothing is emitted afterwards.
    func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        lock.unlock()
        // Completion runs the pending handlers, which now see `isInvalidated` and emit nothing.
        // The lock must be released first, because those handlers take it.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func handleOutput(status: OSStatus, infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        let stopped = isInvalidated
        lock.unlock()
        guard !stopped else { return }

        guard status == noErr, !infoFlags.contains(.frameDropped), let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            // A dropped or failed frame breaks the chain the next predicted frame assumes.
            requestKeyframe()
            return
        }
        guard let unit = Self.unit(from: sampleBuffer) else {
            requestKeyframe()
            return
        }
        onEncoded(unit)
    }

    private static func unit(from sampleBuffer: CMSampleBuffer) -> EncodedUnit? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let isKeyframe = Self.isKeyframe(sampleBuffer)
        var sps: Data?
        var pps: Data?
        if isKeyframe {
            guard let sets = Self.parameterSets(from: format) else { return nil }
            (sps, pps) = sets
        }
        return EncodedUnit(
            payload: payload, sps: sps, pps: pps, isKeyframe: isKeyframe,
            width: Int(dimensions.width), height: Int(dimensions.height)
        )
    }

    /// A sample is a sync sample unless it is explicitly marked otherwise, which is how
    /// VideoToolbox reports a predicted frame.
    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else { return true }
        return !notSync
    }

    /// Reads the sequence and picture parameter sets out of a format description.
    ///
    /// The sets are identified by their NAL unit type rather than by their index. VideoToolbox
    /// emits SPS at 0 and PPS at 1 in practice, but the index is not a documented guarantee, and
    /// a descriptor carrying a third set — or the two in the other order — would otherwise be
    /// read as a reversed pair the receiver rejects on every keyframe. Each candidate is held to
    /// the same bounds `EncodedVideoFrame.isValid` applies, so an unusable set is refused here,
    /// where it is attributable, rather than downstream as an unexplained invalid frame.
    private static func parameterSets(from format: CMFormatDescription) -> (Data, Data)? {
        var count = 0
        var nalLengthSize: Int32 = 0
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize
        )
        // Everything downstream parses four-byte AVCC length prefixes; a different width would
        // be silently misread as corrupt NAL units.
        guard probe == noErr, count >= 2, Int(nalLengthSize) == EncodedVideoFrame.lengthPrefixBytes else { return nil }

        var candidates: [Data] = []
        // A conforming descriptor carries two or three sets. The scan is bounded regardless, so
        // a malformed count cannot turn one keyframe into unbounded work on the callback thread.
        for index in 0..<min(count, maximumParameterSetScan) {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else { return nil }
            // Bounded before the copy, not after: a set the wire cannot carry is unusable
            // either way, and there is no reason to allocate it to find that out.
            guard size <= EncodedVideoFrame.maximumParameterSetBytes else { continue }
            candidates.append(Data(bytes: pointer, count: size))
        }
        return parameterSets(among: candidates)
    }

    /// Picks the first usable SPS and PPS out of the candidates a descriptor offered.
    ///
    /// Split out from the CoreMedia plumbing so the selection rule can be exercised directly:
    /// a reversed pair, a leading unrelated unit, a set with `forbidden_zero_bit` set, and a set
    /// too long for the wire all have to be handled here, and none of them needs hardware to
    /// reproduce. Returns nil unless both sets were found, because a keyframe without them is
    /// not decodable by a receiver that just joined.
    static func parameterSets(among candidates: [Data]) -> (Data, Data)? {
        var sps: Data?
        var pps: Data?
        for set in candidates {
            // A cleared forbidden_zero_bit and a length the wire can carry are exactly what
            // `EncodedVideoFrame.isValid` demands; anything else is skipped rather than
            // claimed, so a stray unit cannot be mistaken for a parameter set.
            guard (2...EncodedVideoFrame.maximumParameterSetBytes).contains(set.count),
                  let header = set.first, header & 0x80 == 0 else { continue }
            switch header & nalTypeMask {
            case nalTypeSequenceParameterSet where sps == nil: sps = set
            case nalTypePictureParameterSet where pps == nil: pps = set
            default: continue
            }
            if let sps, let pps { return (sps, pps) }
        }
        return nil
    }

    /// Presentation stamps must be strictly increasing for rate control to behave, and the
    /// idle repeat path can re-submit within the same tick of the clock.
    private func nextPresentationTimeLocked(_ uptime: TimeInterval) -> CMTime {
        let scale = Self.presentationTimescale
        var time = CMTime(value: Int64((uptime * Double(scale)).rounded()), timescale: scale)
        if let lastPresentation, time <= lastPresentation {
            time = CMTime(value: lastPresentation.value + 1, timescale: scale)
        }
        lastPresentation = time
        return time
    }

    private static func require(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef, _ name: String) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw Failure.property(name, status) }
    }

    private static func prefer(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef) {
        _ = VTSessionSetProperty(session, key: key, value: value)
    }
}
