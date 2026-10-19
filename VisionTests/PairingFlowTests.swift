import DeskCore
import Foundation
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// The way in and the control card, driven through the production model. Sessions are the real
/// PSK-TLS loopback against the mock Mac; nothing here dials a real address or a discovered Mac.
@MainActor
final class PairingFlowTests: XCTestCase {
    /// Connect waits for a whole key, so it is never offered for one that could only be refused.
    /// Submitting an incomplete one from the field says why nothing happened and opens nothing.
    func testConnectWaitsForAWholePairingKey() {
        let model = Loopback.model()
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil) }
        model.updateScene(scene, phase: .active)
        model.directAddress = "100.64.0.42"
        let compact = PairingKey.generate().displayValue.replacingOccurrences(of: "-", with: "")
        let incomplete = [("empty", ""), ("short", String(compact.prefix(31))), ("long", compact + "0"),
                          ("not hexadecimal", String(compact.prefix(31)) + "G")]
        for (name, text) in incomplete {
            model.pairingCode = text
            XCTAssertNotEqual(model.keyEntry, .complete, name)
            XCTAssertFalse(model.canConnectDirectly, name)
            XCTAssertFalse(model.canConnect, name)
        }

        model.pairingCode = String(compact.prefix(31))
        model.connectDirectly()
        XCTAssertFalse(model.isConnecting, "An incomplete key opens no connection.")
        XCTAssertEqual(model.connectionMessage, SessionCopy.incompleteKeyMessage)

        // Case, dashes and spaces do not matter. Connecting is not attempted: the address is real.
        model.pairingCode = " " + compact.lowercased() + " "
        XCTAssertEqual(model.keyEntry, .complete)
        XCTAssertTrue(model.canConnectDirectly)
    }

    /// A discovered Mac's session is never dialled again, so when it drops the wearer is told how
    /// to start a new one, in plain words, and offered no reconnection the model cannot make.
    func testALostNearbySessionSaysHowToConnectAgain() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        session.mac.dropConnection()
        try await Loopback.waitUntil { !session.model.isLinked }

        let message = try XCTUnwrap(session.model.connectionMessage)
        let expected = ["The other device disconnected.", "The secure connection was interrupted.",
                        "Truncated frame.", "The connection to your Mac was interrupted."]
            .map { SessionCopy.connectionEnded(with: "Loopback Mac", reason: $0) }
        XCTAssertTrue(expected.contains(message), message)
        XCTAssertFalse(session.model.canReconnectNow)
        XCTAssertFalse(session.model.isReconnecting)
    }

    /// The overview's control card follows the Mac's grant, the wearer's Stop and the Mac's answer,
    /// and always offers the one action the model would carry out: Stop while there is a grant,
    /// nothing while the Stop is unanswered — even when a grant arrives first — and a request
    /// once the Mac has answered.
    func testTheControlCardFollowsTheGrantTheStopAndTheAnswer() async throws {
        let session = try await Loopback.directSession()
        defer { session.close() }
        let model = session.model
        let mac = session.mac
        XCTAssertEqual(model.controlSummary.title, "Viewing only")
        XCTAssertEqual(model.controlSummary.action, .requestControl)

        try await session.grantControl()
        XCTAssertEqual(model.controlSummary.title, "You're in control")
        XCTAssertEqual(model.controlSummary.action, .stopControl)

        model.stopControl()
        XCTAssertTrue(model.isStopPending)
        XCTAssertFalse(model.isMacControlEnabled, "Nothing is left for the toolbar's Stop to stop.")
        XCTAssertEqual(model.controlSummary.title, "Control stopped")
        XCTAssertEqual(model.controlSummary.action, .none)
        try await Loopback.waitUntil { mac.received(inSession: 1).contains { $0.kind == "stop" } }

        XCTAssertTrue(mac.publishStatus("stale grant", controlEnabled: true))
        try await Loopback.waitUntil { model.statusText == "stale grant" }
        XCTAssertEqual(model.controlSummary.title, "Control stopped", "A grant before the answer is not believed.")
        XCTAssertEqual(model.controlSummary.action, .none)

        XCTAssertTrue(mac.publishStatus("Input stopped from Vision Pro.", controlEnabled: false))
        try await Loopback.waitUntil { !model.isStopPending }
        XCTAssertEqual(model.controlSummary.title, "Viewing only")
        XCTAssertEqual(model.controlSummary.detail, "Input stopped from Vision Pro.")
        XCTAssertEqual(model.controlSummary.action, .requestControl)
        XCTAssertTrue(model.canResumeControl)

        model.resumeControl()
        try await Loopback.waitUntil { mac.received(inSession: 1).contains { $0.kind == "requestControl" } }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
        XCTAssertEqual(model.controlSummary.action, .stopControl)
    }
}
