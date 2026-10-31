import XCTest
@testable import DeskCore

final class DisplayCaptureSizeTests: XCTestCase {
    func testOrdinaryCaptureSizesKeepTheirExistingDimensions() throws {
        let fixtures = [(1920, 1080, 1920, 1080), (3840, 2160, 1920, 1080),
                        (1080, 1920, 1080, 1920), (2160, 3840, 1920, 3412),
                        (1920, 1200, 1920, 1200), (1919, 1079, 1918, 1078)]
        for (width, height, expectedWidth, expectedHeight) in fixtures {
            let result = try size(width, height, format: .h264)
            XCTAssertEqual(result.width, expectedWidth)
            XCTAssertEqual(result.height, expectedHeight)
            assertAdmissible(result, format: .h264)
        }
        let retina = try DisplayCaptureSize(pixelWidth: 2880, aspectWidth: 1440, aspectHeight: 900, format: .h264)
        XCTAssertEqual(retina.width, 1920)
        XCTAssertEqual(retina.height, 1200)
    }

    func testTallSourcesFitBothVideoAndJPEGAllocationBudgets() throws {
        for (width, height) in [(2160, 5120), (2160, 7680), (1080, 16384)] {
            for format in DisplayCaptureSize.Format.allCases {
                let result = try size(width, height, format: format)
                assertAdmissible(result, format: format)
                assertAspect(result, width: width, height: height, format: format)
            }
        }
    }

    func testVideoKeeps4096CodedEdgeAndScalesBeyondIt() throws {
        let boundary = try size(1728, 4096, format: .h264)
        XCTAssertEqual(boundary.width, 1728)
        XCTAssertEqual(boundary.height, 4096)
        assertAdmissible(boundary, format: .h264)

        let above = try size(1728, 4098, format: .h264)
        XCTAssertLessThan(above.width, 1728)
        XCTAssertLessThanOrEqual(above.height, 4096)
        assertAdmissible(above, format: .h264)
        assertAspect(above, width: 1728, height: 4098, format: .h264)

        // The native encoder constraint does not reduce the independent JPEG-only budget.
        let jpeg = try size(1728, 4098, format: .jpeg)
        XCTAssertEqual(jpeg.width, 1728)
        XCTAssertEqual(jpeg.height, 4098)
    }

    func testTallVideoSourcesFitTheConservativeNativeEncoderBudget() throws {
        for (sourceHeight, expectedWidth) in [(5120, 1728), (7680, 1152)] {
            let result = try size(2160, sourceHeight, format: .h264)
            XCTAssertEqual(result.width, expectedWidth)
            XCTAssertEqual(result.height, 4096)
            assertAdmissible(result, format: .h264)
            assertAspect(result, width: 2160, height: sourceHeight, format: .h264)
        }
    }

    func testVideoAccountsForMacroblockPaddingBeyondTheVisiblePixelBudget() throws {
        // The old visible size fits 8.5M pixels, but its 1904×4496 coded surface does not.
        XCTAssertLessThanOrEqual(1892 * 4490, EncodedVideoFrame.maximumPixels)
        XCTAssertGreaterThan(1904 * 4496, EncodedVideoFrame.maximumPixels)
        let result = try size(1892, 4490, format: .h264)
        assertAdmissible(result, format: .h264)
        assertAspect(result, width: 1892, height: 4490, format: .h264)
        XCTAssertTrue(result.width < 1892 || result.height < 4490)
    }

    func testJPEGOnlyKeepsOrdinaryOddEdgesWithoutVideoRounding() throws {
        let result = try size(1919, 1079, format: .jpeg)
        XCTAssertEqual(result.width, 1919)
        XCTAssertEqual(result.height, 1079)
        assertAdmissible(result, format: .jpeg)
        let smallest = try size(1, 1, format: .jpeg)
        XCTAssertEqual(smallest.width, 1)
        XCTAssertEqual(smallest.height, 1)
    }

    func testInvalidSourceGeometryFailsExplicitly() {
        for bad in [0, -1, Int.min] {
            for format in DisplayCaptureSize.Format.allCases {
                for input in [(bad, 1920, 1080), (1920, bad, 1080), (1920, 1920, bad)] {
                    XCTAssertThrowsError(try DisplayCaptureSize(pixelWidth: input.0, aspectWidth: input.1,
                                                               aspectHeight: input.2, format: format)) {
                        XCTAssertEqual($0 as? DisplayCaptureSize.Failure, .invalidSourceGeometry)
                    }
                }
            }
        }
    }

    func testImpossibleAspectAndTooSmallVideoFailInsteadOfStretchingOrOverflowing() {
        for format in DisplayCaptureSize.Format.allCases {
            for (width, height) in [(1, Int.max), (Int.max, 1)] {
                XCTAssertThrowsError(try size(width, height, format: format)) {
                    XCTAssertEqual($0 as? DisplayCaptureSize.Failure, .unrepresentableAspectRatio)
                }
            }
        }
        XCTAssertThrowsError(try size(15, 15, format: .h264))
    }

    func testHugeButProportionalInputsStayBoundedWithoutIntegerOverflow() throws {
        for format in DisplayCaptureSize.Format.allCases {
            let result = try size(Int.max, Int.max, format: format)
            XCTAssertEqual(result.width, 1920)
            XCTAssertEqual(result.height, 1920)
            assertAdmissible(result, format: format)
        }
    }

    func testBoundarySweepPreservesAspectAndAdmissiblePaddedGeometry() throws {
        for width in [16, 17, 255, 1080, 1891, 1892, 1919, 1920, 2160, 8192, 32768] {
            for height in [16, 17, 1080, 1920, 3412, 4490, 5120, 7680, 8192, 16384, 32768] {
                for format in DisplayCaptureSize.Format.allCases {
                    do {
                        let result = try size(width, height, format: format)
                        assertAdmissible(result, format: format)
                        assertAspect(result, width: width, height: height, format: format)
                    } catch {
                        XCTAssertEqual(error as? DisplayCaptureSize.Failure, .unrepresentableAspectRatio)
                    }
                }
            }
        }
    }

    private func size(_ width: Int, _ height: Int, format: DisplayCaptureSize.Format) throws -> DisplayCaptureSize {
        try DisplayCaptureSize(pixelWidth: width, aspectWidth: width, aspectHeight: height, format: format)
    }

    private func assertAdmissible(_ size: DisplayCaptureSize, format: DisplayCaptureSize.Format,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(size.width, 0, file: file, line: line)
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, DisplayCaptureSize.maximumWidth, file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, EncodedVideoFrame.maximumDimension, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width * size.height, EncodedVideoFrame.maximumPixels, file: file, line: line)
        if format == .h264 {
            XCTAssertGreaterThanOrEqual(size.width, EncodedVideoFrame.minimumDimension, file: file, line: line)
            XCTAssertGreaterThanOrEqual(size.height, EncodedVideoFrame.minimumDimension, file: file, line: line)
            XCTAssertTrue(size.width.isMultiple(of: 2) && size.height.isMultiple(of: 2), file: file, line: line)
            let codedWidth = (size.width + 15) / 16 * 16
            let codedHeight = (size.height + 15) / 16 * 16
            XCTAssertLessThanOrEqual(codedWidth, 4096, file: file, line: line)
            XCTAssertLessThanOrEqual(codedHeight, 4096, file: file, line: line)
            XCTAssertLessThanOrEqual(codedWidth * codedHeight, EncodedVideoFrame.maximumPixels, file: file, line: line)
        }
    }

    private func assertAspect(_ size: DisplayCaptureSize, width: Int, height: Int,
                              format: DisplayCaptureSize.Format, file: StaticString = #filePath, line: UInt = #line) {
        let quantum = format == .h264 ? 2.0 : 1.0
        // Both output axes must come from one uniform scale, allowing only integer rounding.
        let minimumScale = max(Double(size.width) / Double(width), Double(size.height) / Double(height))
        let maximumScale = min((Double(size.width) + quantum) / Double(width),
                               (Double(size.height) + quantum) / Double(height))
        XCTAssertLessThanOrEqual(minimumScale, maximumScale + 1e-12, file: file, line: line)
    }
}
