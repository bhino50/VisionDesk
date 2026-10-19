import Foundation
import CoreVideo
import DeskCore

final class FixtureResult: @unchecked Sendable {
    let lock = NSLock()
    var frames: [EncodedVideoFrame] = []
    func add(_ unit: H264Encoder.EncodedUnit) {
        lock.lock(); defer { lock.unlock() }
        frames.append(EncodedVideoFrame(width: unit.width, height: unit.height, sequence: UInt64(frames.count), isKeyframe: unit.isKeyframe, payload: unit.payload, sps: unit.sps, pps: unit.pps))
    }
}
@main struct MakeFixture {
    static func main() async throws {
        let result = FixtureResult()
        let encoder = try H264Encoder(width: 64, height: 64, onEncoded: { result.add($0) }, onFailure: { _ in })
        var raw: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &raw) == kCVReturnSuccess,
              let buffer = raw else { exit(1) }
        for index in 0..<4 {
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(80 + index * 15), CVPixelBufferGetBytesPerRow(buffer) * 64)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if index == 3 { encoder.requestKeyframe() }
            _ = encoder.encode(buffer, at: ProcessInfo.processInfo.systemUptime)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        encoder.invalidate()
        guard result.frames.count == 4, result.frames.allSatisfy(\.isValid) else { exit(1) }
        let decoder = H264Decoder()
        guard result.frames.allSatisfy({ decoder.decode($0) != nil }) else { exit(1) }
        print(String(data: try JSONEncoder().encode(result.frames), encoding: .utf8)!)
    }
}
