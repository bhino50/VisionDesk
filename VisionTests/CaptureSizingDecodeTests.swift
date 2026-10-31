import CoreGraphics
import DeskCore
import XCTest
@testable import VisionDesk

/// Exercise the real JPEG consumer at the computed capture size. Large fixtures are
/// synthetic, processed sequentially, and never taken from a desktop or saved to disk.
@MainActor
final class CaptureSizingDecodeTests: XCTestCase {
    func testTallPortraitVideoFallbackJPEGDecodesAtItsSafeCaptureSize() async throws {
        try await verifyJPEG(sourceWidth: 2160, sourceHeight: 5120, format: .h264)
        try await verifyJPEG(sourceWidth: 2160, sourceHeight: 7680, format: .h264)
    }

    func testTallPortraitJPEGOnlyCaptureDecodesAtItsSafeSize() async throws {
        try await verifyJPEG(sourceWidth: 2160, sourceHeight: 5120, format: .jpeg)
        try await verifyJPEG(sourceWidth: 2160, sourceHeight: 7680, format: .jpeg)
    }

    func testMacroblockBoundaryCaptureStillSupportsJPEGFallback() async throws {
        try await verifyJPEG(sourceWidth: 1892, sourceHeight: 4490, format: .h264)
    }

    func testOrdinaryLandscapeAndPortraitStillDecodeAndMapInput() async throws {
        try await verifyJPEG(sourceWidth: 3840, sourceHeight: 2160, format: .h264)
        try await verifyJPEG(sourceWidth: 1080, sourceHeight: 1920, format: .jpeg)
    }

    func testPreviousOversizedPortraitJPEGRemainsRejectedByTheReceiver() async throws {
        let stream = DisplayStream(info: info(width: 2160, height: 5120))
        defer { stream.clear() }
        // This is the old capture size: a valid compressed JPEG whose decoded allocation
        // exceeds the receiver's existing budget. Fixing the sender must not weaken it.
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg(width: 1920, height: 4550))
        XCTAssertLessThanOrEqual(jpeg.count, DeskMessage.maximumJPEGBytes)
        stream.accept(jpeg: jpeg)
        try await Loopback.waitUntil { stream.decodeWarning != nil }
        XCTAssertNil(stream.image)
        XCTAssertNil(stream.receivedAt)
    }

    private func verifyJPEG(sourceWidth: Int, sourceHeight: Int,
                            format: DisplayCaptureSize.Format) async throws {
        let size = try DisplayCaptureSize(pixelWidth: sourceWidth, aspectWidth: sourceWidth,
                                          aspectHeight: sourceHeight, format: format)
        let stream = DisplayStream(info: info(width: sourceWidth, height: sourceHeight), now: { 100 })
        defer { stream.clear() }
        let jpeg = try XCTUnwrap(DeskFixtures.jpeg(width: size.width, height: size.height))
        XCTAssertLessThanOrEqual(jpeg.count, DeskMessage.maximumJPEGBytes)
        stream.accept(jpeg: jpeg)
        try await Loopback.waitUntil { stream.image != nil || stream.decodeWarning != nil }
        XCTAssertNotNil(stream.image)
        XCTAssertNil(stream.decodeWarning)
        XCTAssertEqual(stream.imageSize, CGSize(width: size.width, height: size.height))
        XCTAssertTrue(stream.isFresh(at: 100))
        XCTAssertEqual(stream.info.width, sourceWidth, "Downscaling must preserve source metadata.")
        XCTAssertEqual(stream.info.height, sourceHeight)

        let container = CGSize(width: 1100, height: 900)
        let visible = try XCTUnwrap(DisplayGeometry.imageRect(in: container, image: stream.imageSize))
        for fraction in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let location = CGPoint(x: visible.minX + visible.width * fraction,
                                   y: visible.minY + visible.height * (1 - fraction))
            let normalized = try XCTUnwrap(DisplayGeometry.normalized(location, in: container,
                                                                       image: stream.imageSize))
            XCTAssertEqual(normalized.x, fraction, accuracy: 1e-9)
            XCTAssertEqual(normalized.y, 1 - fraction, accuracy: 1e-9)
        }
    }

    private func info(width: Int, height: Int) -> DisplayInfo {
        DisplayInfo(id: 1, name: "Synthetic portrait", width: width, height: height,
                    originX: 0, originY: 0, pointWidth: Double(width), pointHeight: Double(height))
    }
}
