import DeskCore
import Foundation
import XCTest

final class DeskMessageTests: XCTestCase {
    private func display(_ id: UInt32 = 1) -> DisplayInfo {
        DisplayInfo(id: id, name: "Display \(id)", width: 3_840, height: 2_160, originX: -1_920, originY: -200, pointWidth: 1_920, pointHeight: 1_080)
    }

    func testCoordinateMappingHonorsNegativeOriginsRetinaScaleAndEdges() throws {
        let info = display()
        XCTAssertEqual(try XCTUnwrap(info.point(x: 0, y: 0)), CGPoint(x: -1_920, y: -200))
        XCTAssertEqual(try XCTUnwrap(info.point(x: 1, y: 1)), CGPoint(x: -1, y: 879))
        XCTAssertEqual(try XCTUnwrap(info.point(x: 0.5, y: 0.5)), CGPoint(x: -960.5, y: 339.5))
    }

    func testInvalidCoordinatesAndGeometryCannotProducePointerPositions() {
        for coordinate in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            XCTAssertNil(display().point(x: coordinate, y: 0.5))
            XCTAssertNil(display().point(x: 0.5, y: coordinate))
        }
        var info = display()
        info.pointWidth = 0
        XCTAssertFalse(info.isValid)
        XCTAssertNil(info.point(x: 0.5, y: 0.5))
        info = display()
        info.originY = .nan
        XCTAssertFalse(info.isValid)
    }

    func testDisplayListAllowsAtMostFourUniquePhysicalDisplays() {
        XCTAssertTrue(DeskMessage(kind: "displays", displays: (1...4).map { display(UInt32($0)) }).isValid)
        XCTAssertTrue(DeskMessage(kind: "displays", displays: []).isValid)
        XCTAssertFalse(DeskMessage(kind: "displays", displays: (1...5).map { display(UInt32($0)) }).isValid)
        XCTAssertFalse(DeskMessage(kind: "displays", displays: [display(), display()]).isValid)
        XCTAssertFalse(DeskMessage(kind: "displays").isValid)
    }

    func testInputRequiresTargetAndKnownActionWithValidPayload() {
        for action in ["move", "leftDown", "leftUp", "rightClick", "doubleClick"] {
            XCTAssertTrue(DeskMessage(kind: "input", displayID: 1, x: 0, y: 1, action: action).isValid)
            XCTAssertFalse(DeskMessage(kind: "input", x: 0, y: 1, action: action).isValid)
            XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, x: 0, action: action).isValid)
        }
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, x: 0, y: 0, action: "execute").isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, x: .infinity, y: 0, action: "move").isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 0, x: 0, y: 0, action: "move").isValid)
    }

    func testScrollTextAndKeysRequireDisplayAndBoundedPayloads() {
        XCTAssertTrue(DeskMessage(kind: "input", displayID: 1, action: "scroll", deltaX: -2_000, deltaY: 2_000).isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, action: "scroll", deltaX: .nan, deltaY: 0).isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, action: "scroll", deltaX: 0, deltaY: 2_001).isValid)
        XCTAssertTrue(DeskMessage(kind: "input", displayID: 1, action: "text", text: String(repeating: "é", count: 2_048)).isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, action: "text", text: String(repeating: "é", count: 2_049)).isValid)
        XCTAssertFalse(DeskMessage(kind: "input", action: "text", text: "hello").isValid)
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, x: -1, action: "text", text: "hello").isValid)
        for key in DeskMessage.supportedKeys {
            XCTAssertTrue(DeskMessage(kind: "input", displayID: 1, action: "key", text: key).isValid)
        }
        XCTAssertFalse(DeskMessage(kind: "input", displayID: 1, action: "key", text: "cmd+q").isValid)
    }

    func testVersionKindsAndBinaryAttachmentsAreValidated() {
        XCTAssertFalse(DeskMessage(version: 2, kind: "heartbeat").isValid)
        XCTAssertFalse(DeskMessage(kind: "unknown").isValid)
        XCTAssertFalse(DeskMessage(kind: "heartbeat", jpeg: Data([1])).isValid)
        XCTAssertFalse(DeskMessage(kind: "frame", displayID: 1, jpeg: Data()).isValid)
        XCTAssertFalse(DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 0, count: DeskMessage.maximumJPEGBytes + 1)).isValid)
        XCTAssertTrue(DeskMessage(kind: "status", controlEnabled: false).isValid)
        XCTAssertFalse(DeskMessage(kind: "status").isValid)
    }

    func testCodableRoundTripPreservesDisplayMetadataAndControlState() throws {
        let messages = [DeskMessage(kind: "displays", displays: [display()]), DeskMessage(kind: "status", status: "Ready", controlEnabled: true)]
        for message in messages {
            XCTAssertEqual(try JSONDecoder().decode(DeskMessage.self, from: JSONEncoder().encode(message)), message)
        }
    }
}
