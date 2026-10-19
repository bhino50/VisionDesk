import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

/// Every click lands where the Mac's pointer already is. These check the other half of that
/// rule: a display whose pointer has not been placed has nowhere to click without moving it,
/// so every click is refused there until something places it, and a placement is forgotten
/// whenever the remembered position would land somewhere else on the Mac.
@MainActor
final class PointerPlacementTests: XCTestCase {
    /// Before anything has pointed at a display, a Pointer tap, the toolbar's three clicks and
    /// the assistive primary action all send nothing. Each used to fall back to the centre of
    /// the screen, which moved the Mac's pointer there and clicked: exactly the click that moves
    /// the cursor, and after every reconnection the first tap did it again.
    func testEveryClickIsRefusedUntilThePointerHasBeenPlaced() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        XCTAssertTrue(model.canControl(displayID: 1))
        XCTAssertFalse(model.hasPointerPosition(displayID: 1))
        XCTAssertFalse(model.canClick(displayID: 1), "The toolbar's click buttons start disabled.")
        XCTAssertTrue(model.pointedDisplayIDs.isEmpty)

        model.tapClick(displayID: 1, at: CGPoint(x: 0.05, y: 0.9))
        model.clickAtLastPointer(displayID: 1)
        model.click(displayID: 1, action: "rightClick")
        model.click(displayID: 1, action: "doubleClick")
        try await Loopback.pause(0.4)
        XCTAssertTrue(mac.actions.isEmpty, "An unplaced pointer has nowhere to click without moving it.")
        XCTAssertTrue(model.isLinked)
        XCTAssertTrue(model.canControl(displayID: 1), "A refused click costs nothing else.")
    }

    /// Placement by name is the assistive way in: one move to where it was asked and no press.
    /// Every click that follows lands exactly there, whatever the tap's own location.
    func testPlacingThePointerByNameMovesItOnceAndClicksThenLandThere() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let centre = CGPoint(x: 0.5, y: 0.5)

        model.placePointer(displayID: 1, at: centre)
        try await Loopback.waitUntil { mac.actions == ["move"] }
        XCTAssertEqual(model.pointedDisplayIDs, [1])
        XCTAssertTrue(model.canClick(displayID: 1))
        XCTAssertFalse(mac.buttonHeld, "Placing presses nothing.")

        model.clickAtLastPointer(displayID: 1)
        model.click(displayID: 1, action: "rightClick")
        model.tapClick(displayID: 1, at: CGPoint(x: 0.9, y: 0.1))
        try await Loopback.waitUntil { mac.actions.count == 9 }
        try await Loopback.pause(0.4)
        XCTAssertEqual(mac.actions, ["move", "move", "leftDown", "leftUp", "move", "rightClick",
                                     "move", "leftDown", "leftUp"])
        for message in mac.received.filter({ $0.kind == "input" }) {
            XCTAssertEqual(try XCTUnwrap(message.x), centre.x, accuracy: 1e-9, message.action ?? "")
            XCTAssertEqual(try XCTUnwrap(message.y), centre.y, accuracy: 1e-9, message.action ?? "")
        }
        XCTAssertFalse(mac.buttonHeld)
    }

    /// Placement is refused exactly where a click would be: while a gesture owns the pointer,
    /// for a coordinate off the picture, and for a display that is not controllable.
    func testPlacementIsRefusedWhereverAClickWouldBe() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let drag = UUID(), start = CGPoint(x: 0.2, y: 0.2)
        model.updateGesture(token: drag, displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await Loopback.waitUntil { mac.buttonHeld }
        let held = mac.actions.count
        model.placePointer(displayID: 1, at: CGPoint(x: 0.8, y: 0.8))
        model.endGesture(token: drag)
        try await Loopback.waitUntil { !mac.buttonHeld }
        XCTAssertEqual(mac.actions.count, held + 1, "Only the Drag's own release followed its press.")

        let ended = mac.actions.count
        for point in [CGPoint(x: .nan, y: 0.5), CGPoint(x: 1.5, y: 0.5), CGPoint(x: 0.5, y: -0.1)] {
            model.placePointer(displayID: 1, at: point)
        }
        model.placePointer(displayID: 99, at: CGPoint(x: 0.5, y: 0.5))
        model.stopControl()
        model.placePointer(displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        try await Loopback.pause(0.4)
        XCTAssertEqual(mac.actions.count, ended)
        for message in mac.received.filter({ $0.kind == "input" }) {
            XCTAssertEqual(try XCTUnwrap(message.x), start.x, accuracy: 1e-9, message.action ?? "")
        }
    }

    /// The Mac maps a normalized position through the display's point geometry, so a scaling
    /// change moves where the remembered position lands and the placement is forgotten. A pure
    /// pixel change maps every position to the same place, so the placement is kept.
    func testAPointGeometryChangeForgetsThePlacementButAPixelChangeKeepsIt() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let pointed = CGPoint(x: 0.3, y: 0.7)
        model.placePointer(displayID: 1, at: pointed)
        try await Loopback.waitUntil { model.pointedDisplayIDs == [1] }

        let doubledPixels = DisplayInfo(id: 1, name: "Loopback Display", width: 3_840, height: 2_160,
                                        originX: 0, originY: 0, pointWidth: 1_920, pointHeight: 1_080)
        XCTAssertTrue(mac.publish(displays: [doubledPixels]))
        try await Loopback.waitUntil { model.display(id: 1)?.info.width == 3_840 }
        XCTAssertEqual(model.pointedDisplayIDs, [1], "A pixel-only change keeps the placement.")

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.rescaledDisplay]))
        try await Loopback.waitUntil { model.display(id: 1)?.info.pointWidth == 960 }
        XCTAssertTrue(model.pointedDisplayIDs.isEmpty, "A scaling change forgets it.")
        XCTAssertTrue(mac.sendFrame(session.frame))
        try await Loopback.waitUntil { model.canControl(displayID: 1) }
        XCTAssertFalse(model.canClick(displayID: 1))

        let before = mac.actions.count
        model.clickAtLastPointer(displayID: 1)
        model.tapClick(displayID: 1, at: pointed)
        try await Loopback.pause(0.4)
        XCTAssertEqual(mac.actions.count, before, "No click may land where the Mac now maps the old position.")
    }

    /// A Drag holding the button when the geometry changes is released first, where it pressed.
    /// The Mac posts a release wherever the message says, so a release sent after the position
    /// had been forgotten would fall back to a guess and move the pointer as it let go.
    func testAGeometryChangeReleasesAHeldDragWhereItPressed() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let start = CGPoint(x: 0.25, y: 0.4)
        model.updateGesture(token: UUID(), displayID: 1, mode: .interact,
                            start: start, point: start, translation: .zero)
        try await Loopback.waitUntil { mac.buttonHeld }

        XCTAssertTrue(mac.publish(displays: [DeskFixtures.rescaledDisplay]))
        try await Loopback.waitUntil { !mac.buttonHeld }
        let release = try XCTUnwrap(mac.received.last { $0.action == "leftUp" })
        XCTAssertEqual(try XCTUnwrap(release.x), start.x, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(release.y), start.y, accuracy: 1e-9)
        XCTAssertTrue(model.pointedDisplayIDs.isEmpty)
        XCTAssertTrue(model.isLinked, "A scaling change ends the gesture, not the session.")
    }

    /// A new session starts with no placement. The Mac's pointer may have moved while the link
    /// was down, so a position from the old session is no longer where it is, and the first tap
    /// after an automatic reconnection must not click at it — or at the centre.
    func testAReconnectionStartsWithNoPlacedPointer() async throws {
        let session = try await Loopback.directSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let pointed = CGPoint(x: 0.6, y: 0.4)
        model.placePointer(displayID: 1, at: pointed)
        try await Loopback.waitUntil { model.pointedDisplayIDs == [1] }

        mac.dropConnection()
        try await Loopback.waitUntil { !model.isLinked }
        XCTAssertTrue(model.pointedDisplayIDs.isEmpty)
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await session.grantControl()

        let before = mac.actions.count
        model.clickAtLastPointer(displayID: 1)
        model.tapClick(displayID: 1, at: pointed)
        model.click(displayID: 1, action: "doubleClick")
        try await Loopback.pause(0.4)
        XCTAssertEqual(mac.actions.count, before)
        XCTAssertFalse(model.canClick(displayID: 1))
    }
}
