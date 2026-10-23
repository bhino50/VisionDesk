import DeskCore
import Foundation
import XCTest
@testable import VisionDesk

@MainActor
final class SceneHandoffTests: XCTestCase {
    func testClosingBackgroundScenePreservesAnotherScenesKeyboardDelivery() async throws {
        let session = try await Loopback.discoveredSession()
        let background = UUID()
        defer {
            session.model.updateScene(background, phase: nil)
            session.close()
        }
        try await session.grantControl()
        try await Loopback.waitUntil { session.model.keyboard.isSupported }
        session.model.updateScene(background, phase: .background)
        session.mac.keyboardAcknowledgements = false
        XCTAssertTrue(session.model.sendText("first\nsecond", displayID: 1))
        try await Loopback.waitUntil { session.mac.received.contains { $0.keyboardRequestID != nil } }
        let request = try XCTUnwrap(session.mac.received.first { $0.keyboardRequestID != nil })
        XCTAssertEqual(session.model.keyboardPendingCount, 3)

        session.model.updateScene(background, phase: nil)

        XCTAssertTrue(session.model.canControl(displayID: 1))
        XCTAssertEqual(session.model.keyboardPendingCount, 3,
                       "Closing an unrelated background screen must not discard accepted text")
        session.mac.keyboardAcknowledgements = true
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "keyboardResult",
                                                   keyboardRequestID: request.keyboardRequestID,
                                                   keyboardResult: "posted")))
        try await Loopback.waitUntil { session.model.keyboardPendingCount == 0 }
        let input = session.mac.received.filter { $0.keyboardRequestID != nil }
        XCTAssertEqual(input.filter { $0.action == "text" }.compactMap(\.text), ["first", "second"])
        XCTAssertEqual(input.filter { $0.action == "key" }.compactMap(\.text), ["return"])
        XCTAssertNil(session.model.keyboardNotice)
    }

    func testLosingLastActiveSceneStillCancelsKeyboardDeliveryImmediately() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        try await session.grantControl()
        try await Loopback.waitUntil { session.model.keyboard.isSupported }
        session.mac.keyboardAcknowledgements = false
        XCTAssertTrue(session.model.sendText("first\nsecond", displayID: 1))
        XCTAssertEqual(session.model.keyboardPendingCount, 3)

        session.model.updateScene(session.scene, phase: .inactive)

        XCTAssertFalse(session.model.canControl)
        XCTAssertEqual(session.model.keyboardPendingCount, 0)
        XCTAssertTrue(session.model.keyboardNotice?.contains("stopped") == true)
    }

    func testWindowReplacementKeepsSessionButImmediatelyBlocksInputDuringGap() async throws {
        let session = try await Loopback.discoveredSession()
        let replacement = UUID()
        defer {
            session.model.updateScene(replacement, phase: nil)
            session.model.disconnect()
            session.close()
        }
        let model = session.model, mac = session.mac
        XCTAssertTrue(mac.publishStatus("Control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.canControl }
        model.updateScene(session.scene, phase: nil)
        XCTAssertTrue(model.isLinked, "Removal can be followed by replacement in another scene event.")
        XCTAssertFalse(model.canControl, "A handoff never keeps input enabled with no active window.")
        try await Loopback.pause(0.1)
        model.updateScene(replacement, phase: .active)
        try await Loopback.pause(1.1)
        XCTAssertTrue(model.isLinked)
        XCTAssertEqual(mac.sessionCount, 1)
        XCTAssertTrue(model.canControl)
    }

    func testRealBackgroundStillDisconnectsAfterGraceWithoutAutoReopening() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        session.model.updateScene(session.scene, phase: .background)
        XCTAssertTrue(session.model.isLinked)
        XCTAssertFalse(session.model.canControl)
        try await Loopback.waitUntil { !session.model.isLinked }
        XCTAssertFalse(session.model.isReconnecting)
        XCTAssertTrue(session.model.displays.isEmpty)
    }
}
