import Foundation
import XCTest
@testable import VisionDesk

@MainActor
final class SceneHandoffTests: XCTestCase {
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
