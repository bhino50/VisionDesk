import DeskCore
import Foundation
@testable import DeskTransport
import XCTest

final class FrameCodecTests: XCTestCase {
    func testRoundTripUsesNetworkByteOrderAndPreservesBinaryFrames() throws {
        let message = DeskMessage(kind: "frame", displayID: 4, jpeg: Data((0...255).map { UInt8($0) }))
        let frame = try FrameCodec.encode(message)
        let length = try FrameCodec.payloadLength(from: Data(frame.prefix(4)))
        XCTAssertEqual(length, frame.count - 4)
        XCTAssertEqual(try FrameCodec.decode(Data(frame.dropFirst(4)), expectedLength: length), message)
    }

    func testLargestJPEGWithSlashHeavyBase64FitsFourMiBWireLimit() throws {
        let message = DeskMessage(kind: "frame", displayID: UInt32.max, jpeg: Data(repeating: 255, count: DeskMessage.maximumJPEGBytes))
        let frame = try FrameCodec.encode(message)
        XCTAssertLessThanOrEqual(frame.count - 4, 4 * 1_024 * 1_024)
        XCTAssertEqual(try FrameCodec.decode(Data(frame.dropFirst(4)), expectedLength: frame.count - 4), message)
    }

    func testZeroOversizedOverflowAndTruncatedFramesAreRejected() throws {
        for header in [Data([0, 0, 0, 0]), Data([0, 64, 0, 1]), Data([255, 255, 255, 255])] {
            XCTAssertThrowsError(try FrameCodec.payloadLength(from: header)) { XCTAssertEqual($0 as? FrameError, .invalidLength) }
        }
        XCTAssertEqual(try FrameCodec.payloadLength(from: Data([0, 64, 0, 0])), 4 * 1_024 * 1_024)
        for header in [Data(), Data([0, 0]), Data([0, 0, 0, 1, 2])] {
            XCTAssertThrowsError(try FrameCodec.payloadLength(from: header)) { XCTAssertEqual($0 as? FrameError, .truncated) }
        }
        XCTAssertThrowsError(try FrameCodec.decode(Data("{}".utf8), expectedLength: 3)) { XCTAssertEqual($0 as? FrameError, .truncated) }
    }

    func testMalformedAndSemanticallyInvalidMessagesAreRejected() {
        for json in ["{}", "{\"version\":2,\"kind\":\"heartbeat\"}", "{\"version\":1,\"kind\":\"input\",\"displayID\":1,\"action\":\"move\",\"x\":2,\"y\":0}"] {
            let data = Data(json.utf8)
            XCTAssertThrowsError(try FrameCodec.decode(data, expectedLength: data.count)) { XCTAssertEqual($0 as? FrameError, .invalidMessage) }
        }
        XCTAssertThrowsError(try FrameCodec.encode(DeskMessage(kind: "input", displayID: 1, x: .infinity, y: 0, action: "move")))
        XCTAssertThrowsError(try FrameCodec.encode(DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 0, count: DeskMessage.maximumJPEGBytes + 1))))
    }
}

final class PairingKeyTests: XCTestCase {
    func testGeneratedKeyIs128BitsRoundTripsAndRedactsDiagnostics() throws {
        let key = PairingKey.generate()
        XCTAssertEqual(key.displayValue.filter { $0 != "-" }.count, 32)
        XCTAssertEqual(key.displayValue.split(separator: "-").map(\.count), Array(repeating: 4, count: 8))
        let parsed = try XCTUnwrap(PairingKey(string: "  " + key.displayValue.lowercased().replacingOccurrences(of: "-", with: " ") + "\n"))
        XCTAssertTrue(parsed.displayValue == key.displayValue)
        XCTAssertTrue(PairingKey.generate().displayValue != key.displayValue)
        XCTAssertEqual(String(describing: key), "PairingKey(redacted)")
        XCTAssertEqual(String(reflecting: key), "PairingKey(redacted)")
        XCTAssertTrue(Mirror(reflecting: key).children.isEmpty)
    }

    func testShortOrMalformedKeysAreRejected() {
        for text in ["", "123456", String(repeating: "z", count: 32), String(repeating: "１", count: 32), String(repeating: "a", count: 31), String(repeating: "a", count: 33)] {
            XCTAssertNil(PairingKey(string: text))
        }
    }
}

/// The negotiated binary body. `FrameCodecTests` above keeps the legacy JSON contract; nothing
/// here may change it, and several cases below assert exactly that.
final class BinaryFrameCodecTests: XCTestCase {
    // Header field offsets inside a body, used to corrupt one field at a time.
    private let kindOffset = 4, flagsOffset = 5, reservedOffset = 6, displayOffset = 8
    private let widthOffset = 12, sequenceOffset = 20, payloadLengthOffset = 28, spsLengthOffset = 32

    /// One AVCC access unit: a four-byte big-endian length then `totalBytes - 4` NAL bytes.
    /// 0x65 is an IDR slice, 0x41 a non-IDR slice; both have the forbidden bit clear.
    private func accessUnit(nalHeader: UInt8, totalBytes: Int) -> Data {
        var unit = Data(capacity: totalBytes)
        withUnsafeBytes(of: UInt32(totalBytes - 4).bigEndian) { unit.append(contentsOf: $0) }
        unit.append(nalHeader)
        unit.append(Data(repeating: 0x42, count: totalBytes - 5))
        return unit
    }

    private func keyframe(width: Int = 1_920, height: Int = 1_080, sequence: UInt64 = 1,
                          payloadBytes: Int = 64, parameterSetBytes: Int = 2) -> DeskMessage {
        DeskMessage(kind: "video", displayID: 7, video: EncodedVideoFrame(
            width: width, height: height, sequence: sequence, isKeyframe: true,
            payload: accessUnit(nalHeader: 0x65, totalBytes: payloadBytes),
            sps: Data([0x67]) + Data(repeating: 0x11, count: parameterSetBytes - 1),
            pps: Data([0x68]) + Data(repeating: 0x22, count: parameterSetBytes - 1)))
    }

    private func predicted() -> DeskMessage {
        DeskMessage(kind: "video", displayID: 7, video: EncodedVideoFrame(
            width: 1_920, height: 1_080, sequence: 2, isKeyframe: false,
            payload: accessUnit(nalHeader: 0x41, totalBytes: 48)))
    }

    private func jpegFrame() -> DeskMessage {
        DeskMessage(kind: "frame", displayID: 3, jpeg: Data((0...255).map { UInt8($0) }))
    }

    private func body(of frame: Data) -> Data { Data(frame.dropFirst(FrameCodec.headerLength)) }

    private func decoded(_ body: Data) throws -> DeskMessage {
        try FrameCodec.decode(body, expectedLength: body.count, allowsBinary: true)
    }

    private func rejects(_ body: Data, _ label: String) {
        XCTAssertThrowsError(try decoded(body), label) { XCTAssertEqual($0 as? FrameError, .invalidMessage, label) }
    }

    func testBinaryVideoAndJPEGRoundTripExactlyAtTheDeclaredSize() throws {
        for message in [keyframe(), predicted(), jpegFrame()] {
            let frame = try FrameCodec.encodeBinary(message)
            let header = Data(frame.prefix(FrameCodec.headerLength))
            XCTAssertEqual(try FrameCodec.payloadLength(from: header), frame.count - FrameCodec.headerLength,
                           "the binary body reuses the same four-byte framed length")
            XCTAssertEqual(Data(frame.dropFirst(FrameCodec.headerLength).prefix(4)), FrameCodec.binaryMagic)
            XCTAssertEqual(try decoded(body(of: frame)), message)
        }
        let message = keyframe()
        let video = try XCTUnwrap(message.video)
        let frame = try FrameCodec.encodeBinary(message)
        XCTAssertEqual(frame.count, FrameCodec.headerLength + FrameCodec.binaryHeaderLength
                       + video.payload.count + (video.sps?.count ?? 0) + (video.pps?.count ?? 0),
                       "a body is exactly the header plus the three declared runs")
        XCTAssertLessThan(frame.count, try FrameCodec.encode(message).count,
                          "the point of the binary body is to be smaller than base64 JSON")
    }

    func testMaximumSizedBinaryBodiesStayInsideTheFourMiBWireLimit() throws {
        let largest = [
            DeskMessage(kind: "frame", displayID: .max, jpeg: Data(repeating: 0xFF, count: DeskMessage.maximumJPEGBytes)),
            keyframe(width: 8_192, height: 1_024, sequence: EncodedVideoFrame.maximumSequence,
                     payloadBytes: EncodedVideoFrame.maximumPayloadBytes,
                     parameterSetBytes: EncodedVideoFrame.maximumParameterSetBytes)
        ]
        for message in largest {
            let frame = try FrameCodec.encodeBinary(message)
            XCTAssertLessThanOrEqual(frame.count - FrameCodec.headerLength, FrameCodec.maximumPayloadLength)
            XCTAssertEqual(try decoded(body(of: frame)), message)
        }
    }

    func testBinaryBodiesAreRejectedUntilThisSideHasAdvertisedTheFormat() throws {
        let body = body(of: try FrameCodec.encodeBinary(keyframe()))
        XCTAssertThrowsError(try FrameCodec.decode(body, expectedLength: body.count)) {
            XCTAssertEqual($0 as? FrameError, .invalidMessage, "refusing binary must be the default")
        }
        XCTAssertThrowsError(try FrameCodec.decode(body, expectedLength: body.count, allowsBinary: false)) {
            XCTAssertEqual($0 as? FrameError, .invalidMessage)
        }
        XCTAssertNoThrow(try FrameCodec.decode(body, expectedLength: body.count, allowsBinary: true))
    }

    func testMalformedBinaryHeadersFlagsAndLengthsAreRejected() throws {
        let valid = body(of: try FrameCodec.encodeBinary(keyframe()))
        let jpeg = body(of: try FrameCodec.encodeBinary(jpegFrame()))
        func mutating(_ source: Data, _ transform: (inout Data) -> Void) -> Data {
            var copy = source
            transform(&copy)
            return copy
        }
        func replacing(_ source: Data, at offset: Int, with bytes: [UInt8]) -> Data {
            mutating(source) { $0.replaceSubrange($0.startIndex + offset..<$0.startIndex + offset + bytes.count, with: bytes) }
        }
        var cases: [String: Data] = [
            "unknown body kind": mutating(valid) { $0[kindOffset] = 3 },
            "zero body kind": mutating(valid) { $0[kindOffset] = 0 },
            "undefined flag bit": mutating(valid) { $0[flagsOffset] = 0x03 },
            "non-zero reserved": mutating(valid) { $0[reservedOffset] = 1 },
            "trailing byte": valid + Data([0]),
            "one byte short": Data(valid.dropLast()),
            "header with no payload": Data(valid.prefix(FrameCodec.binaryHeaderLength)),
            "magic with no header": FrameCodec.binaryMagic,
            "payload length past the body": replacing(valid, at: payloadLengthOffset, with: [0xFF, 0xFF, 0xFF, 0xFF]),
            "zero display": replacing(valid, at: displayOffset, with: [0, 0, 0, 0]),
            "odd width": replacing(valid, at: widthOffset, with: [0, 0, 0x07, 0x81]),
            "jpeg body carrying a width": replacing(jpeg, at: widthOffset, with: [0, 0, 0x02, 0x80]),
            "jpeg body flagged as a keyframe": mutating(jpeg) { $0[flagsOffset] = 0x01 },
            "jpeg body carrying a sequence": mutating(jpeg) { $0[sequenceOffset + 7] = 1 }
        ]
        // A predicted frame that actually carries a parameter set: the lengths add up, so only the
        // post-decode message validation can catch it.
        cases["parameter set on a predicted frame"] = mutating(body(of: try FrameCodec.encodeBinary(predicted()))) {
            $0.replaceSubrange($0.startIndex + spsLengthOffset..<$0.startIndex + spsLengthOffset + 2, with: [0, 2])
            $0.append(Data([0x67, 0x11]))
        }
        for (label, body) in cases { rejects(body, label) }
    }

    func testBinaryDecodeStillAppliesEveryMessageBound() throws {
        // A structurally perfect body whose payload is not a well-formed AVCC run.
        var garbage = body(of: try FrameCodec.encodeBinary(keyframe(payloadBytes: 8)))
        let payloadStart = garbage.startIndex + FrameCodec.binaryHeaderLength
        garbage.replaceSubrange(payloadStart..<payloadStart + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        rejects(garbage, "payload that is not length-prefixed NAL units")
        // An IDR picture sent with the keyframe flag clear would pass a resynchronization point off
        // as a frame depending on a reference the receiver may never have decoded.
        var mislabelled = body(of: try FrameCodec.encodeBinary(predicted()))
        mislabelled[mislabelled.startIndex + FrameCodec.binaryHeaderLength + 4] = 0x65
        rejects(mislabelled, "IDR slice flagged as a predicted frame")
    }

    func testOnlyLosslesslyRepresentableScreenContentGetsABinaryBody() throws {
        XCTAssertTrue(FrameCodec.supportsBinaryBody(keyframe()))
        XCTAssertTrue(FrameCodec.supportsBinaryBody(jpegFrame()))
        let withoutBinaryBody = [
            DeskMessage(kind: "heartbeat"),
            DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec, wireFormat: DeskMessage.binaryWireFormat),
            DeskMessage(kind: "input", displayID: 1, x: 0.5, y: 0.5, action: "move"),
            DeskMessage(kind: "status", status: "ok", controlEnabled: true),
            // Screen content the fixed header cannot represent exactly. JSON keeps the extra field
            // instead of the transport canonicalizing it away once negotiation succeeds.
            DeskMessage(kind: "frame", displayID: 1, jpeg: Data([1]), status: "attached"),
            DeskMessage(kind: "frame", displayID: 1, jpeg: Data([1]), controlEnabled: true),
            DeskMessage(kind: "frame", displayID: 1, jpeg: Data([1]), x: 0.25, y: 0.75),
            DeskMessage(kind: "video", displayID: 7, text: "note", video: try XCTUnwrap(keyframe().video))
        ]
        for message in withoutBinaryBody {
            XCTAssertTrue(message.isValid, message.kind)
            XCTAssertFalse(FrameCodec.supportsBinaryBody(message), message.kind)
            XCTAssertThrowsError(try FrameCodec.encodeBinary(message), message.kind) {
                XCTAssertEqual($0 as? FrameError, .unsupportedBinaryKind, message.kind)
            }
            XCTAssertEqual(try decoded(body(of: try FrameCodec.encode(message))), message,
                           "whatever the binary body refuses, JSON still carries without loss")
        }
    }

    func testLegacyJSONBodiesAndOlderPeerCapabilitiesSurviveNegotiation() throws {
        for message in [DeskMessage(kind: "heartbeat"), jpegFrame(), keyframe()] {
            let body = body(of: try FrameCodec.encode(message))
            XCTAssertEqual(body.first, UInt8(ascii: "{"), "JSON must stay distinguishable from the binary magic")
            XCTAssertEqual(try FrameCodec.decode(body, expectedLength: body.count), message)
            XCTAssertEqual(try decoded(body), message, "allowing binary must not disturb the JSON path")
        }
        // A peer that predates the capability sends no such field at all.
        let legacy = Data("{\"version\":1,\"kind\":\"capabilities\",\"videoCodec\":\"h264\"}".utf8)
        XCTAssertNil(try FrameCodec.decode(legacy, expectedLength: legacy.count).wireFormat)
    }

    func testWireFormatCapabilityIsOptionalBoundedAndCapabilitiesOnly() {
        func capabilities(_ wireFormat: String?) -> DeskMessage {
            DeskMessage(kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec, wireFormat: wireFormat)
        }
        XCTAssertTrue(capabilities(nil).isValid)
        XCTAssertTrue(capabilities(DeskMessage.binaryWireFormat).isValid)
        // An unrecognized format stays valid and simply never enables the binary body.
        XCTAssertTrue(capabilities("binary-v2").isValid)
        XCTAssertNotEqual("binary-v2", DeskMessage.binaryWireFormat)
        XCTAssertTrue(capabilities(String(repeating: "x", count: DeskMessage.maximumWireFormatBytes)).isValid)
        XCTAssertFalse(capabilities(String(repeating: "x", count: DeskMessage.maximumWireFormatBytes + 1)).isValid)
        for kind in ["heartbeat", "stop", "requestControl", "keyframe", "status"] {
            XCTAssertFalse(DeskMessage(kind: kind, displayID: 1, status: "ok", wireFormat: DeskMessage.binaryWireFormat).isValid, kind)
        }
    }
}
