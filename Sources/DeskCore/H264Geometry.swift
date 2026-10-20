import Foundation

/// Allocation geometry read directly from an H.264 sequence parameter set, before a native
/// decoder is allowed to allocate surfaces. Only the 8-bit 4:2:0 profiles this app emits are
/// supported. Parsing is bounded by the parameter-set byte cap and bounded Exp-Golomb values.
public struct H264Geometry: Equatable, Sendable {
    public let codedWidth: Int
    public let codedHeight: Int
    public let visibleWidth: Int
    public let visibleHeight: Int

    public init?(sps: Data) {
        guard (4...EncodedVideoFrame.maximumParameterSetBytes).contains(sps.count),
              let header = sps.first, header & 0x80 == 0, header & 0x1F == 7 else { return nil }
        var bytes: [UInt8] = []
        var zeros = 0
        let source = Array(sps.dropFirst())
        for (index, byte) in source.enumerated() {
            if zeros >= 2 && byte == 3 {
                guard index + 1 < source.count, source[index + 1] <= 3 else { return nil }
                zeros = 0
                continue
            }
            bytes.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        var bits = Bits(bytes: bytes)
        guard let profile = bits.read(8), [66, 77, 88, 100].contains(profile),
              bits.read(8) != nil, bits.read(8) != nil,
              let id = bits.ue(), id <= 31 else { return nil }
        if profile == 100 {
            guard bits.ue() == 1, bits.ue() == 0, bits.ue() == 0,
                  bits.read(1) != nil, let scaling = bits.read(1) else { return nil }
            if scaling == 1 {
                for index in 0..<8 {
                    guard let present = bits.read(1) else { return nil }
                    if present == 1 {
                        var last = 8, next = 8
                        for _ in 0..<(index < 6 ? 16 : 64) {
                            if next != 0 {
                                guard let delta = bits.se(), (-128...127).contains(delta) else { return nil }
                                next = (last + delta + 256) % 256
                            }
                            if next != 0 { last = next }
                        }
                    }
                }
            }
        }
        guard let frameNumber = bits.ue(), frameNumber <= 12,
              let order = bits.ue(), order <= 2 else { return nil }
        if order == 0 {
            guard let value = bits.ue(), value <= 12 else { return nil }
        } else if order == 1 {
            guard bits.read(1) != nil, bits.se() != nil, bits.se() != nil,
                  let cycle = bits.ue(), cycle <= 255 else { return nil }
            for _ in 0..<cycle { guard bits.se() != nil else { return nil } }
        }
        guard let references = bits.ue(), references <= 16, bits.read(1) != nil,
              let widthMB = bits.ue(), widthMB < EncodedVideoFrame.maximumDimension / 16,
              let heightMap = bits.ue(), heightMap < EncodedVideoFrame.maximumDimension / 16,
              let frameOnly = bits.read(1) else { return nil }
        if frameOnly == 0 { guard bits.read(1) != nil else { return nil } }
        guard bits.read(1) != nil, let cropped = bits.read(1) else { return nil }
        let width = (widthMB + 1) * 16
        let height = (heightMap + 1) * 16 * (2 - frameOnly)
        guard height <= EncodedVideoFrame.maximumDimension,
              width * height <= EncodedVideoFrame.maximumPixels else { return nil }
        var left = 0, right = 0, top = 0, bottom = 0
        if cropped == 1 {
            guard let l = bits.ue(), let r = bits.ue(), let t = bits.ue(), let b = bits.ue() else { return nil }
            (left, right, top, bottom) = (l, r, t, b)
        }
        let visibleW = width - (left + right) * 2
        let visibleH = height - (top + bottom) * 2 * (2 - frameOnly)
        guard visibleW >= EncodedVideoFrame.minimumDimension,
              visibleH >= EncodedVideoFrame.minimumDimension else { return nil }
        codedWidth = width; codedHeight = height
        visibleWidth = visibleW; visibleHeight = visibleH
    }

    private struct Bits {
        let bytes: [UInt8]
        var offset = 0
        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, offset + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = read(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                guard zeros <= 16 else { return nil }
            }
            guard let suffix = read(zeros) else { return nil }
            return (1 << zeros) - 1 + suffix
        }
        mutating func se() -> Int? {
            guard let value = ue() else { return nil }
            return value.isMultiple(of: 2) ? -(value / 2) : (value + 1) / 2
        }
    }
}
