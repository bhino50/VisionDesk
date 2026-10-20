import Foundation

/// One compressed H.264 access unit for a single display.
///
/// `payload` is AVCC, not Annex B: a packed run of four-byte big-endian length prefixes, each
/// followed by exactly one NAL unit, with no start codes. Parameter sets travel beside the
/// payload on keyframes so a receiver can build a decoder from any keyframe it happens to see
/// first, and never inside a predicted frame.
///
/// Every bound here is a wire bound. A peer is untrusted input: a receiver validates before it
/// allocates a pixel buffer, not after.
public struct EncodedVideoFrame: Codable, Equatable, Sendable {
    /// Hard payload cap, three mebibytes less wire headroom.
    ///
    /// A `DeskMessage` carries this payload base64-encoded, four bytes out for every three in,
    /// and `FrameCodec` refuses any payload over four mebibytes. The headroom covers that
    /// expansion for the payload and both parameter sets plus the surrounding JSON keys, so a
    /// frame that passes `isValid` is always small enough to actually send.
    public static let maximumPayloadBytes = 3 * 1_024 * 1_024 - 4_096
    public static let maximumParameterSetBytes = 1_024
    /// Matches the client's decoded-bitmap budget.
    public static let maximumPixels = 8_500_000
    public static let minimumDimension = 16
    public static let maximumDimension = 8_192
    /// A pathological payload must not turn validation itself into the denial of service.
    public static let maximumNALUnitCount = 1_024
    /// Sequence numbers stay inside the exactly representable integer range, so no JSON number
    /// path can round one frame's identity into another's.
    public static let maximumSequence: UInt64 = 1 << 53
    /// AVCC length-prefix width. Four is what VideoToolbox emits and all this code accepts.
    public static let lengthPrefixBytes = 4

    static let nalTypeNonIDRSlice: UInt8 = 1
    static let nalTypeIDRSlice: UInt8 = 5
    static let nalTypeSequenceParameterSet: UInt8 = 7
    static let nalTypePictureParameterSet: UInt8 = 8
    /// 0 is unspecified and 24...31 are stream-packetization types that never appear in AVCC.
    private static let allowedNALTypes: ClosedRange<UInt8> = 1...23

    public var width: Int
    public var height: Int
    /// Dense and strictly increasing in emission order for one capture session. A receiver
    /// treats any skip as a lost frame and waits for the next keyframe.
    public var sequence: UInt64
    public var isKeyframe: Bool
    public var payload: Data
    /// Present on keyframes only, as one raw NAL unit each with no start code or length prefix.
    public var sps: Data?
    public var pps: Data?

    public init(width: Int, height: Int, sequence: UInt64, isKeyframe: Bool, payload: Data, sps: Data? = nil, pps: Data? = nil) {
        self.width = width
        self.height = height
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.payload = payload
        self.sps = sps
        self.pps = pps
    }

    public var isValid: Bool {
        guard (Self.minimumDimension...Self.maximumDimension).contains(width),
              (Self.minimumDimension...Self.maximumDimension).contains(height),
              // 4:2:0 chroma siting has no meaning on an odd edge.
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              width * height <= Self.maximumPixels,
              sequence <= Self.maximumSequence,
              (1...Self.maximumPayloadBytes).contains(payload.count),
              let types = Self.nalUnitTypes(in: payload),
              // Parameter sets belong exclusively to the validated side channel. Reject
              // extensions too: native decoding must never replace its admitted geometry.
              types.allSatisfy({ [1, 5, 6, 9, 10, 11, 12].contains($0) }) else { return false }
        guard isKeyframe else {
            // A predicted frame carries no parameter sets and cannot contain an IDR picture;
            // accepting one would let a sender pass off a resynchronization point as a frame
            // that silently depends on a reference the receiver may never have decoded.
            return sps == nil && pps == nil
                && types.contains(Self.nalTypeNonIDRSlice) && !types.contains(Self.nalTypeIDRSlice)
        }
        guard let sps, let pps,
              Self.isParameterSet(sps, type: Self.nalTypeSequenceParameterSet),
              Self.isParameterSet(pps, type: Self.nalTypePictureParameterSet) else { return false }
        // A frame may only claim to be a keyframe if it actually carries an IDR picture.
        return types.contains(Self.nalTypeIDRSlice)
    }

    /// Walks the AVCC length prefixes and returns one NAL unit type per unit, or nil when the
    /// buffer is not an exact, well-formed sequence of length-prefixed NAL units.
    static func nalUnitTypes(in payload: Data) -> [UInt8]? {
        var types: [UInt8] = []
        var index = payload.startIndex
        let end = payload.endIndex
        while index < end {
            guard end - index > Self.lengthPrefixBytes else { return nil }
            var length = 0
            for offset in 0..<Self.lengthPrefixBytes {
                length = (length << 8) | Int(payload[index + offset])
            }
            index += Self.lengthPrefixBytes
            guard length >= 1, end - index >= length else { return nil }
            let header = payload[index]
            // forbidden_zero_bit must be clear in every conforming NAL unit header.
            guard header & 0x80 == 0, Self.allowedNALTypes.contains(header & 0x1F) else { return nil }
            types.append(header & 0x1F)
            guard types.count <= Self.maximumNALUnitCount else { return nil }
            index += length
        }
        return types.isEmpty ? nil : types
    }

    private static func isParameterSet(_ data: Data, type: UInt8) -> Bool {
        guard (2...maximumParameterSetBytes).contains(data.count), let header = data.first else { return false }
        return header & 0x80 == 0 && header & 0x1F == type
    }
}

/// Admission policy for one display's H.264 stream.
///
/// The decoder is a state machine, not an image loader: a predicted frame is meaningless
/// without every frame between it and its keyframe. This type decides, from wire metadata
/// alone, which frames may reach a decoder. It holds no decoder and no pixels, so the policy
/// is testable without any hardware.
public struct VideoStreamSequencer: Equatable, Sendable {
    public enum Admission: Equatable, Sendable {
        /// Feed this frame to the decoder. `resetsPipeline` marks a geometry change, where any
        /// previously decoded picture now describes the wrong screen and must be discarded.
        case decode(resetsPipeline: Bool)
        case rejectMalformed
        /// A duplicate or out-of-order frame. The picture already shown is newer; nothing to do.
        case rejectStale
        /// A frame is missing, so the reference chain is broken. A keyframe is now required.
        case rejectGap
        case rejectAwaitingKeyframe
    }

    public private(set) var isAwaitingKeyframe = true
    public private(set) var lastSequence: UInt64?
    public private(set) var width: Int?
    public private(set) var height: Int?

    public init() {}

    /// Returns to the initial state: nothing decoded, next picture must be a keyframe.
    public mutating func reset() { self = VideoStreamSequencer() }

    /// Forces the next accepted picture to come from a keyframe. Used after a decoder error or
    /// a pipeline teardown, where the decoder no longer holds the reference the stream assumes.
    public mutating func requireKeyframe() { isAwaitingKeyframe = true }

    public mutating func admit(_ frame: EncodedVideoFrame) -> Admission {
        guard frame.isValid else {
            // A malformed unit may still have advanced the sender's reference chain.
            isAwaitingKeyframe = true
            return .rejectMalformed
        }
        // Never rewind the picture, even to a valid keyframe: a late duplicate would replace a
        // newer screen with an older one and refresh its freshness stamp while doing it.
        //
        // This is deliberately terminal for the sequence it rejects, and deliberately silent.
        // It is tempting to read "a sender whose counter restarts below `lastSequence` stalls
        // this display" as a defect in the rule, but relaxing the rule is the wrong repair:
        // the comparison *is* the anti-replay protection, and an exception for keyframes would
        // hand any sender a way to put an old screen back under a live pointer.
        //
        // A restart is a discontinuity in the stream, so it is answered at the stream level
        // instead, by `reset()`. On the sending side a renumbering only ever happens when the
        // capture objects are rebuilt, and that path cancels the channel, so the receiver
        // always sees a disconnect first and a reconnect builds a fresh sequencer. The JPEG
        // fallback is not such a path and deliberately does not reset: it keeps the same
        // capture objects, so their counters keep climbing, and a stream that returns to
        // video resumes above the number recorded here rather than below it. Preserving
        // `lastSequence` across that fallback is the correct behaviour, not an oversight.
        //
        // Nor may this be relaxed after repeated stale frames. Counting insistence and then
        // admitting the frame would hand a replay exactly what this rule denies it: enough
        // retries to put an old picture back on screen and refresh its freshness stamp.
        // Asking the sender for another keyframe would not recover anything either — its next
        // keyframe carries the next number in the same restarted run, and would be just as
        // stale — it would only add a request loop. The condition is already reported where it
        // is actionable: no frame is accepted, so the picture goes stale and the surface says so.
        if let lastSequence, frame.sequence <= lastSequence { return .rejectStale }
        guard frame.isKeyframe else {
            guard !isAwaitingKeyframe else { return .rejectAwaitingKeyframe }
            guard let lastSequence, frame.sequence == lastSequence &+ 1,
                  frame.width == width, frame.height == height else {
                isAwaitingKeyframe = true
                return .rejectGap
            }
            self.lastSequence = frame.sequence
            return .decode(resetsPipeline: false)
        }
        let resetsPipeline = frame.width != width || frame.height != height
        isAwaitingKeyframe = false
        lastSequence = frame.sequence
        width = frame.width
        height = frame.height
        return .decode(resetsPipeline: resetsPipeline)
    }
}
