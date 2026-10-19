import Foundation
import CoreVideo
import CoreGraphics
import DeskCore

/// Synthetic moving color fields exercise four real hardware encoders and the production
/// decoder without capturing the user's desktop or posting input. No pixels are saved.
final class StreamResult: @unchecked Sendable {
    private let lock = NSLock()
    private let decoder = H264Decoder()
    private var encoded = 0, decoded = 0, invalid = 0, bytes = 0
    private var failures: [String] = []
    func accept(_ unit: H264Encoder.EncodedUnit) {
        lock.lock(); defer { lock.unlock() }
        let frame = EncodedVideoFrame(width: unit.width, height: unit.height, sequence: UInt64(encoded), isKeyframe: unit.isKeyframe, payload: unit.payload, sps: unit.sps, pps: unit.pps)
        encoded += 1; bytes += unit.payload.count
        if !frame.isValid { invalid += 1; return }
        if decoder.decode(frame) != nil { decoded += 1 }
    }
    func fail(_ reason: String) { lock.lock(); failures.append(reason); lock.unlock() }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["encoded": encoded, "decoded": decoded, "invalid": invalid, "bytes": bytes, "failures": failures,
                "success": decoded >= 90 && decoded == encoded && invalid == 0 && failures.isEmpty]
    }
}

@main struct HardwareVideoChecks {
    static func main() async throws {
        let sizes = [(1920,1080), (1080,1920), (1920,1080), (1080,1920)]
        let results = sizes.map { _ in StreamResult() }
        var encoders: [H264Encoder] = []
        var buffers: [CVPixelBuffer] = []
        for (index, size) in sizes.enumerated() {
            let result = results[index]
            encoders.append(try H264Encoder(width: size.0, height: size.1, onEncoded: { result.accept($0) }, onFailure: { result.fail($0) }))
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, size.0, size.1, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw NSError(domain: "HardwareVideoChecks", code: Int(status)) }
            buffers.append(buffer)
        }
        for tick in 0..<150 {
            for index in buffers.indices {
                let buffer = buffers[index]
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    memset(base, Int32((tick + index * 31) % 255), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                _ = encoders[index].encode(buffer, at: ProcessInfo.processInfo.systemUptime)
                if tick == 75 { encoders[index].requestKeyframe() }
            }
            try await Task.sleep(nanoseconds: 33_333_333)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        encoders.forEach { $0.invalidate() }
        let rows = results.map { $0.report() }
        let success = rows.allSatisfy { $0["success"] as? Bool == true }
        let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "synthetic": true,
            "physicalHeadsetVerified": false, "streamCount": rows.count, "success": success, "streams": rows]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        exit(success ? 0 : 1)
    }
}
