import CoreMedia
import CoreVideo
import DeskCore
import Foundation
import VideoToolbox

/// Hardware H.264 decoding for one display.
///
/// The session is rebuilt whenever a keyframe brings parameter sets that differ from the ones
/// it was built with, which is how a resolution change or an encoder restart is absorbed. A
/// decode failure retires the session outright: a decoder that has lost its reference frames
/// would otherwise keep emitting pictures built on state the sender no longer shares.
///
/// Decoding is synchronous on whichever thread calls `decode`, so output order is exactly
/// submission order. The caller is responsible for keeping that off the main actor.
final class H264Decoder: @unchecked Sendable {
    /// Lets the synchronous output handler hand its picture back without mutating a captured
    /// variable from a `@Sendable` block.
    private final class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var isInvalidated = false
    private var geometry: H264Geometry?
    private let beforeSessionCreation: () -> Void

    init(beforeSessionCreation: @escaping () -> Void = {}) {
        self.beforeSessionCreation = beforeSessionCreation
    }

    deinit { invalidate() }

    /// Decodes one access unit, or returns nil when it cannot be turned into a picture. A nil
    /// result always means the caller must wait for a keyframe before showing anything again.
    func decode(_ frame: EncodedVideoFrame) -> CGImage? {
        // Re-validated here rather than trusted: this is the last gate before VideoToolbox
        // parses attacker-reachable bytes.
        guard frame.isValid else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else { return nil }

        if frame.isKeyframe {
            guard let sps = frame.sps, let pps = frame.pps,
                  let geometry = H264Geometry(sps: sps),
                  geometry.visibleWidth == frame.width, geometry.visibleHeight == frame.height,
                  prepareLocked(sps: sps, pps: pps, geometry: geometry) else {
                tearDownLocked()
                return nil
            }
        }
        // A predicted frame that arrives before any usable keyframe has nothing to predict
        // from. There is no fallback that could make it an image.
        guard let geometry, geometry.visibleWidth == frame.width, geometry.visibleHeight == frame.height,
              let session, let formatDescription,
              let sampleBuffer = Self.makeSampleBuffer(payload: frame.payload, format: formatDescription) else { return nil }

        let box = ImageBox()
        var infoFlags = VTDecodeInfoFlags()
        // No asynchronous flag: the handler runs before this call returns.
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: &infoFlags,
            outputHandler: { status, infoFlags, imageBuffer, _, _ in
                guard status == noErr, !infoFlags.contains(.frameDropped), let imageBuffer else { return }
                var created: CGImage?
                guard VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &created) == noErr else { return }
                box.image = created
            }
        )
        guard status == noErr, let image = box.image else {
            tearDownLocked()
            return nil
        }
        // A sender that lies about its geometry must not get a picture mapped to the wrong grid.
        guard image.width == frame.width, image.height == frame.height else {
            tearDownLocked()
            return nil
        }
        return image
    }

    /// Discards the session without retiring the decoder. The next keyframe rebuilds it.
    func reset() {
        lock.lock()
        tearDownLocked()
        lock.unlock()
    }

    /// Retires the decoder for good. Any later `decode` returns nil.
    func invalidate() {
        lock.lock()
        isInvalidated = true
        tearDownLocked()
        lock.unlock()
    }

    private func prepareLocked(sps: Data, pps: Data, geometry: H264Geometry) -> Bool {
        if session != nil, self.sps == sps, self.pps == pps { return true }
        tearDownLocked()
        guard let format = Self.makeFormatDescription(sps: sps, pps: pps) else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let nativeSize = (Int(dimensions.width), Int(dimensions.height))
        guard nativeSize == (geometry.codedWidth, geometry.codedHeight)
                || nativeSize == (geometry.visibleWidth, geometry.visibleHeight) else { return false }
        beforeSessionCreation()
        guard let created = Self.makeSession(format: format) else { return false }
        self.geometry = geometry
        session = created
        formatDescription = format
        self.sps = sps
        self.pps = pps
        return true
    }

    private func tearDownLocked() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        geometry = nil
        sps = Data()
        pps = Data()
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer -> OSStatus in
                    sizes.withUnsafeBufferPointer { sizeBuffer -> OSStatus in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else { return -1 }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: Int32(EncodedVideoFrame.lengthPrefixBytes),
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }
        guard status == noErr else { return nil }
        return format
    }

    private static func makeSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        // Asking for BGRA on an IOSurface keeps the picture one conversion away from a
        // CGImage instead of two, and keeps the decode itself zero-copy.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            // Null, because each frame carries its own output handler block, so no refcon has
            // to outlive an asynchronous teardown.
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { return nil }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return created
    }

    private static func makeSampleBuffer(payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
        )
        guard allocated == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let created = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        )
        guard created == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}
