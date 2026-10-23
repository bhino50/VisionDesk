import CoreGraphics
import XCTest
@testable import VisionDesk

final class DisplayWindowGeometryTests: XCTestCase {
    func testOverviewPreviewFillsPortraitAndLandscapeCardsWithoutLetterboxing() throws {
        for image in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080),
                      CGSize(width: 5120, height: 1440)] {
            let ratio = DisplayGeometry.previewAspectRatio(image: image)
            let card = CGSize(width: 320, height: 320 / ratio)
            let rect = try XCTUnwrap(DisplayGeometry.imageRect(in: card, image: image))
            XCTAssertEqual(rect.width, card.width, accuracy: 0.0001)
            XCTAssertEqual(rect.height, card.height, accuracy: 0.0001)
        }
        XCTAssertLessThan(DisplayGeometry.previewAspectRatio(image: CGSize(width: 1080, height: 1920)), 1)
    }

    func testInvalidPreviewDimensionsUseASafeFallback() {
        for image in [CGSize.zero, CGSize(width: -1, height: 100),
                      CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan)] {
            XCTAssertEqual(DisplayGeometry.previewAspectRatio(image: image), 1.6)
        }
    }

    func testPortraitLandscapeAndUltrawidePreserveTheirAspect() throws {
        for image in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080),
                      CGSize(width: 5120, height: 1440), CGSize(width: 1920, height: 1920)] {
            let sizing = try XCTUnwrap(DisplayGeometry.windowSizing(image: image))
            XCTAssertEqual(sizing.preferred.width / sizing.preferred.height, image.width / image.height, accuracy: 0.0001)
            XCTAssertEqual(sizing.minimum.width / sizing.minimum.height, image.width / image.height, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(sizing.preferred.width, 1120 + 1e-6)
            XCTAssertLessThanOrEqual(sizing.preferred.height, 1000 + 1e-6)
            XCTAssertLessThanOrEqual(sizing.minimum.width, sizing.preferred.width)
            XCTAssertLessThanOrEqual(sizing.minimum.height, sizing.preferred.height)
            let rect = try XCTUnwrap(DisplayGeometry.imageRect(in: sizing.preferred, image: image))
            XCTAssertEqual(rect.minX, 0, accuracy: 0.0001)
            XCTAssertEqual(rect.minY, 0, accuracy: 0.0001)
            XCTAssertEqual(rect.width, sizing.preferred.width, accuracy: 0.0001)
            XCTAssertEqual(rect.height, sizing.preferred.height, accuracy: 0.0001)
        }
    }

    func testPortraitDoesNotInheritLandscapeMinimumWidth() throws {
        let size = try XCTUnwrap(DisplayGeometry.windowSizing(image: CGSize(width: 1080, height: 1920)))
        XCTAssertEqual(size.preferred.width, 562.5, accuracy: 1e-6)
        XCTAssertEqual(size.preferred.height, 1000, accuracy: 1e-6)
        XCTAssertEqual(size.minimum.width, 320)
        XCTAssertGreaterThan(size.minimum.height, size.minimum.width)
    }

    func testInvalidDimensionsHaveNoWindowRequest() {
        for image in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: 100, height: 0),
                      CGSize(width: CGFloat.infinity, height: 100), CGSize(width: 100, height: CGFloat.nan)] {
            XCTAssertNil(DisplayGeometry.windowSizing(image: image))
        }
    }
}
