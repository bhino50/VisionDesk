import XCTest
@testable import DeskCore

final class H264GeometryTests: XCTestCase {
    /// Encodes just the bounded SPS prefix that determines allocation and crop geometry.
    private func sps(widthMB: Int, heightMB: Int, profile: Int = 66, bottomCrop: Int = 0) -> Data {
        var bits = ""
        func fixed(_ n: Int, _ count: Int) { bits += String(repeating: "0", count: max(0, count - String(n, radix: 2).count)) + String(n, radix: 2) }
        func ue(_ n: Int) { let word = String(n + 1, radix: 2); bits += String(repeating: "0", count: word.count - 1) + word }
        fixed(profile, 8); fixed(0, 8); fixed(40, 8); ue(0)
        if profile == 100 { ue(1); ue(0); ue(0); fixed(0, 1); fixed(0, 1) }
        ue(0); ue(0); ue(0); ue(1); fixed(0, 1)
        ue(widthMB - 1); ue(heightMB - 1); fixed(1, 1); fixed(1, 1)
        fixed(bottomCrop == 0 ? 0 : 1, 1)
        if bottomCrop > 0 { ue(0); ue(0); ue(0); ue(bottomCrop) }
        bits += "1"
        while !bits.count.isMultiple(of: 8) { bits += "0" }
        let chars = Array(bits)
        var result = Data([0x67]), zeroCount = 0
        for index in stride(from: 0, to: chars.count, by: 8) {
            let byte = UInt8(String(chars[index..<index + 8]), radix: 2)!
            if zeroCount >= 2 && byte <= 3 { result.append(3); zeroCount = 0 }
            result.append(byte); zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return result
    }

    func testBaselineMainAndHighAllowPadded1080Geometry() throws {
        for profile in [66, 77, 100] {
            let value = try XCTUnwrap(H264Geometry(sps: sps(widthMB: 120, heightMB: 68, profile: profile, bottomCrop: 4)))
            XCTAssertEqual(value.codedWidth, 1920); XCTAssertEqual(value.codedHeight, 1088)
            XCTAssertEqual(value.visibleWidth, 1920); XCTAssertEqual(value.visibleHeight, 1080)
        }
    }

    func testCodedAllocationIsBoundedEvenWhenCropWouldFit() {
        XCTAssertNil(H264Geometry(sps: sps(widthMB: 512, heightMB: 512, bottomCrop: 4000)))
        XCTAssertNil(H264Geometry(sps: sps(widthMB: 513, heightMB: 4)))
        XCTAssertNil(H264Geometry(sps: sps(widthMB: 4, heightMB: 4, bottomCrop: 32)))
    }

    func testRealHardwareHighProfileSPS() throws {
        let value = try XCTUnwrap(H264Geometry(sps: XCTUnwrap(Data(base64Encoded: "J2QAFKxWgw3gQYRQ"))))
        XCTAssertEqual(value.visibleWidth, 64); XCTAssertEqual(value.visibleHeight, 64)
    }

    func testTruncationAndOverlongExpGolombFailClosed() {
        let valid = sps(widthMB: 120, heightMB: 68)
        for end in 0..<4 { XCTAssertNil(H264Geometry(sps: valid.prefix(end))) }
        XCTAssertNil(H264Geometry(sps: Data([0x67, 66, 0, 40]) + Data(repeating: 0, count: 1000)))
        XCTAssertNil(H264Geometry(sps: Data(repeating: 0, count: 1025)))
    }

    func testInlineParameterSetsCannotOverrideTheAdmittedSets() {
        for type: UInt8 in [7, 8, 13, 15, 19, 20, 21] {
            let frame = EncodedVideoFrame(width: 64, height: 64, sequence: 1, isKeyframe: false,
                payload: Data([0, 0, 0, 1, 1, 0, 0, 0, 1, type]))
            XCTAssertFalse(frame.isValid, "NAL type \(type) must not reach a decoder")
        }
    }
}
