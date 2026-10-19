import DeskCore
import Foundation
import XCTest
@testable import DeskTransport

final class WirePerformanceTests: XCTestCase {
    func testScreenCodecBenchmarkPreservesPayloadAndReportsProcessingCost() throws {
        let message = DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 0xA5, count: 150_000))
        let iterations = 100
        func measure(binary: Bool) throws -> (seconds: Double, bytes: Int) {
            let start = ProcessInfo.processInfo.systemUptime
            var bytes = 0
            for _ in 0..<iterations {
                let frame = try binary ? FrameCodec.encodeBinary(message) : FrameCodec.encode(message)
                let length = try FrameCodec.payloadLength(from: frame.prefix(4))
                let decoded = try FrameCodec.decode(Data(frame.dropFirst(4)), expectedLength: length, allowsBinary: binary)
                XCTAssertEqual(decoded, message)
                bytes = frame.count
            }
            return (ProcessInfo.processInfo.systemUptime - start, bytes)
        }
        let legacy = try measure(binary: false)
        let binary = try measure(binary: true)
        XCTAssertLessThan(binary.bytes, legacy.bytes)
        let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "iterations": iterations, "screenPayloadBytes": 150_000,
            "jsonFrameBytes": legacy.bytes, "binaryFrameBytes": binary.bytes,
            "jsonEncodeDecodeTotalMilliseconds": legacy.seconds * 1_000,
            "binaryEncodeDecodeTotalMilliseconds": binary.seconds * 1_000,
            "scope": "same 150 KB synthetic JPEG payload, production framing encode/decode; no image decoding or network",
            "physicalHeadsetMeasured": false]
        if let path = ProcessInfo.processInfo.environment["VISION_DESK_WIRE_REPORT_PATH"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("WIRE BENCHMARK JSON \(legacy.seconds * 1_000)ms; binary \(binary.seconds * 1_000)ms; bytes \(legacy.bytes) -> \(binary.bytes)")
        // Timing is evidence rather than a load-sensitive CI pass condition.
    }
}
