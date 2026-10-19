import DeskCore
import Foundation

enum FrameError: Error, Equatable {
    case invalidLength
    case truncated
    case invalidMessage
    /// Only screen content has a binary body. Control messages stay JSON.
    case unsupportedBinaryKind
}

/// A four-byte unsigned big-endian length and one bounded body.
///
/// A body is either JSON — the only format a peer may send before negotiation — or, once both
/// peers have advertised `DeskMessage.binaryWireFormat`, a fixed binary header followed by the
/// raw payload and parameter sets. The binary body exists to keep base64 and JSON off the hot
/// path: screen content is the only large message, and its bytes are already compressed.
///
/// The two body formats can never be confused. A JSON `DeskMessage` always begins with `{`, and
/// the binary magic begins with a NUL byte, which is neither JSON whitespace nor the start of any
/// JSON value. A receiver that has not advertised the binary format refuses a binary body
/// outright instead of guessing at an unnegotiated encoding.
enum FrameCodec {
    static let maximumPayloadLength = 4 * 1_024 * 1_024
    static let headerLength = 4
    /// "\0VD1". The leading NUL is what makes a body unambiguous against JSON.
    static let binaryMagic = Data([0x00, 0x56, 0x44, 0x31])
    /// magic(4) kind(1) flags(1) reserved(2) displayID(4) width(4) height(4) sequence(8)
    /// payloadLength(4) spsLength(2) ppsLength(2). Every field is big-endian, like the frame
    /// length, and every field a body kind does not use is required to be zero.
    static let binaryHeaderLength = 36

    private enum BodyKind: UInt8 {
        case jpegFrame = 1
        case videoFrame = 2
    }

    private static let keyframeFlag: UInt8 = 0x01

    /// The messages a binary body can carry without losing anything.
    ///
    /// Screen content is the only candidate, but `DeskMessage.isValid` also permits a frame to
    /// carry control fields beside its payload, and the header has no room for them. Such a
    /// message falls back to JSON instead of being canonicalized, so a binary body is always an
    /// exact representation of the message it encodes: `decode` of `encodeBinary` is the identity,
    /// and a field never disappears merely because negotiation happened to succeed. Capture output
    /// sets none of these, so real screen content always takes the fast path.
    static func supportsBinaryBody(_ message: DeskMessage) -> Bool {
        guard message.kind == "frame" || message.kind == "video" else { return false }
        return message.version == 1
            && message.displays == nil && message.videoCodec == nil && message.wireFormat == nil
            && message.x == nil && message.y == nil && message.action == nil && message.text == nil
            && message.deltaX == nil && message.deltaY == nil
            && message.status == nil && message.controlEnabled == nil
    }

    static func encode(_ message: DeskMessage) throws -> Data {
        guard message.isValid else { throw FrameError.invalidMessage }
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            body = try encoder.encode(message)
        } catch {
            throw FrameError.invalidMessage
        }
        return try framed(body)
    }

    /// Encodes screen content without base64 or JSON. Throws for anything else, so control can
    /// never reach a peer in a format the protocol does not require it to understand.
    static func encodeBinary(_ message: DeskMessage) throws -> Data {
        guard supportsBinaryBody(message) else { throw FrameError.unsupportedBinaryKind }
        guard message.isValid, let displayID = message.displayID else { throw FrameError.invalidMessage }
        let body: Data
        if message.kind == "frame" {
            guard let jpeg = message.jpeg else { throw FrameError.invalidMessage }
            body = try binaryBody(kind: .jpegFrame, displayID: displayID, width: 0, height: 0,
                                  sequence: 0, isKeyframe: false, payload: jpeg, sps: nil, pps: nil)
        } else {
            guard let video = message.video,
                  let width = UInt32(exactly: video.width),
                  let height = UInt32(exactly: video.height) else { throw FrameError.invalidMessage }
            body = try binaryBody(kind: .videoFrame, displayID: displayID, width: width, height: height,
                                  sequence: video.sequence, isKeyframe: video.isKeyframe,
                                  payload: video.payload, sps: video.sps, pps: video.pps)
        }
        return try framed(body)
    }

    static func payloadLength(from header: Data) throws -> Int {
        guard header.count == headerLength else { throw FrameError.truncated }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...UInt32(maximumPayloadLength)).contains(length) else { throw FrameError.invalidLength }
        return Int(length)
    }

    /// Decodes one body. `allowsBinary` is true only when this side has itself advertised
    /// `DeskMessage.binaryWireFormat`, which mirrors the rule a sender follows.
    static func decode(_ body: Data, expectedLength: Int, allowsBinary: Bool = false) throws -> DeskMessage {
        guard (1...maximumPayloadLength).contains(expectedLength) else { throw FrameError.invalidLength }
        guard body.count == expectedLength else { throw FrameError.truncated }
        if isBinaryBody(body) {
            guard allowsBinary else { throw FrameError.invalidMessage }
            return try decodeBinary(body)
        }
        do {
            let message = try JSONDecoder().decode(DeskMessage.self, from: body)
            guard message.isValid else { throw FrameError.invalidMessage }
            return message
        } catch {
            throw FrameError.invalidMessage
        }
    }

    private static func isBinaryBody(_ body: Data) -> Bool {
        body.count >= binaryMagic.count && body.prefix(binaryMagic.count).elementsEqual(binaryMagic)
    }

    private static func framed(_ body: Data) throws -> Data {
        guard (1...maximumPayloadLength).contains(body.count) else { throw FrameError.invalidLength }
        var frame = Data(capacity: headerLength + body.count)
        append(UInt32(body.count), to: &frame)
        frame.append(body)
        return frame
    }

    private static func binaryBody(kind: BodyKind, displayID: UInt32, width: UInt32, height: UInt32,
                                   sequence: UInt64, isKeyframe: Bool, payload: Data,
                                   sps: Data?, pps: Data?) throws -> Data {
        guard let payloadLength = UInt32(exactly: payload.count),
              let spsLength = UInt16(exactly: sps?.count ?? 0),
              let ppsLength = UInt16(exactly: pps?.count ?? 0) else { throw FrameError.invalidLength }
        var body = Data(capacity: binaryHeaderLength + payload.count + Int(spsLength) + Int(ppsLength))
        body.append(binaryMagic)
        body.append(kind.rawValue)
        body.append(isKeyframe ? keyframeFlag : 0)
        append(UInt16.zero, to: &body)
        append(displayID, to: &body)
        append(width, to: &body)
        append(height, to: &body)
        append(sequence, to: &body)
        append(payloadLength, to: &body)
        append(spsLength, to: &body)
        append(ppsLength, to: &body)
        body.append(payload)
        if let sps { body.append(sps) }
        if let pps { body.append(pps) }
        return body
    }

    private static func decodeBinary(_ body: Data) throws -> DeskMessage {
        guard body.count >= binaryHeaderLength else { throw FrameError.invalidMessage }
        var reader = BodyReader(body, skipping: binaryMagic.count)
        let rawKind = reader.next(UInt8.self)
        let flags = reader.next(UInt8.self)
        let reserved = reader.next(UInt16.self)
        let displayID = reader.next(UInt32.self)
        let width = reader.next(UInt32.self)
        let height = reader.next(UInt32.self)
        let sequence = reader.next(UInt64.self)
        let payloadLength = reader.next(UInt32.self)
        let spsLength = reader.next(UInt16.self)
        let ppsLength = reader.next(UInt16.self)
        // Reserved bits and unknown flags are rejected rather than ignored, so a later version
        // cannot smuggle meaning past this one and one frame has exactly one encoding. The
        // consumed check pins `binaryHeaderLength` to the field list actually read above.
        guard reader.consumed == binaryHeaderLength,
              let kind = BodyKind(rawValue: rawKind),
              reserved == 0,
              flags & ~keyframeFlag == 0,
              payloadLength <= UInt32(maximumPayloadLength),
              // The body is exactly the header plus the three declared runs: no trailing bytes,
              // no overlap, and no declared length reaching past what actually arrived.
              binaryHeaderLength + Int(payloadLength) + Int(spsLength) + Int(ppsLength) == body.count
        else { throw FrameError.invalidMessage }
        let payloadStart = body.startIndex + binaryHeaderLength
        let spsStart = payloadStart + Int(payloadLength)
        let ppsStart = spsStart + Int(spsLength)
        let payload = Data(body[payloadStart..<spsStart])
        let sps = spsLength == 0 ? nil : Data(body[spsStart..<ppsStart])
        let pps = ppsLength == 0 ? nil : Data(body[ppsStart..<body.endIndex])
        let message: DeskMessage
        switch kind {
        case .jpegFrame:
            // A JPEG body has no video metadata. A sender that fills any of it is malformed.
            guard flags == 0, width == 0, height == 0, sequence == 0,
                  sps == nil, pps == nil else { throw FrameError.invalidMessage }
            message = DeskMessage(kind: "frame", displayID: displayID, jpeg: payload)
        case .videoFrame:
            let video = EncodedVideoFrame(width: Int(width), height: Int(height), sequence: sequence,
                                          isKeyframe: flags & keyframeFlag != 0,
                                          payload: payload, sps: sps, pps: pps)
            message = DeskMessage(kind: "video", displayID: displayID, video: video)
        }
        // The binary header is only a transport. The message still has to satisfy every bound the
        // JSON path enforces, including the AVCC walk over an untrusted payload.
        guard message.isValid else { throw FrameError.invalidMessage }
        return message
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Sequential big-endian reads over a body the caller has already bounds-checked. Mirroring
    /// the append order in `binaryBody` keeps the two from drifting apart over hand-written
    /// offsets.
    private struct BodyReader {
        private let body: Data
        private(set) var consumed: Int

        init(_ body: Data, skipping prefix: Int) {
            self.body = body
            self.consumed = prefix
        }

        mutating func next<Value: FixedWidthInteger>(_ type: Value.Type) -> Value {
            var value = Value.zero
            for _ in 0..<MemoryLayout<Value>.size {
                value = (value << 8) | Value(body[body.startIndex + consumed])
                consumed += 1
            }
            return value
        }
    }
}
