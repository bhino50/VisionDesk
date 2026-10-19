import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// A Stop the Mac never read is not lost with the session that carried it.
///
/// Each scenario here loses the wearer's Stop for real — on a path from the headset that has
/// failed while the connection stays open, or in a send the channel refuses from inside
/// `stopControl` — and then reconnects through the production model, automatically or by the
/// wearer's hand. Where it matters, the mock Mac applies the companion's own consent rules: a
/// Mac that never read the Stop re-arms control on attach and enables it on the first
/// heartbeat. So "control stayed off" below is the Mac's state, not only the headset's belief.
@MainActor
final class StopReplayTests: XCTestCase {
    // MARK: Lost on a dead path

    /// The reviewer's scenario: the link dies both ways, the headset reports it, the wearer
    /// presses Stop into the dead path, and the session recovers on its own. The new session
    /// repeats the Stop before its first heartbeat, so the Mac that re-armed control on attach
    /// pauses it instead of enabling it.
    func testAStopLostOnADeadPathIsRepeatedFirstWhenTheSessionRecoversOnItsOwn() async throws {
        let mac = MockMac()
        mac.emulatesConsent = true
        let session = try await Loopback.directSession(linkPolicy: Loopback.fastPolicy, mac: mac)
        defer { session.close() }
        let model = session.model
        try await controlEnabledByTheMac(session)

        mac.stopHearingCurrentSession()
        try await Loopback.waitUntil { !model.isMacResponsive }
        XCTAssertTrue(model.willRecoverAutomatically)
        model.stopControl()
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.statusText, SessionCopy.controlStoppedStatus)
        XCTAssertFalse(model.canResumeControl, "Nothing may follow a Stop the Mac has not answered.")

        try await Loopback.waitUntil(timeout: 20) { mac.sessionCount >= 2 }
        try await Loopback.waitUntil { self.heartbeats(mac, session: 2) >= 2 }
        XCTAssertFalse(mac.received(inSession: 1).contains { $0.kind == "stop" },
                       "The Stop pressed into the dead path was never read.")
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertTrue(mac.pausedByHeadset)
        XCTAssertFalse(mac.controlEnabled, "The Mac read the Stop before the heartbeat that would have enabled control.")
        try await Loopback.pause(0.3)
        XCTAssertFalse(model.isMacControlEnabled)
        XCTAssertFalse(model.canControl)
    }

    /// The same lost Stop, recovered by the wearer's Reconnect instead of the schedule. Once the
    /// Mac has answered, Resume is new consent: it is granted, it ends the Stop, and the next
    /// reconnection is Stop-free and gets the Mac's re-armed grant back.
    func testAStopLostOnADeadPathIsRepeatedFirstWhenTheWearerReconnects() async throws {
        let mac = MockMac()
        mac.emulatesConsent = true
        let session = try await Loopback.directSession(linkPolicy: Loopback.reportOnlyPolicy, mac: mac)
        defer { session.close() }
        let model = session.model
        try await controlEnabledByTheMac(session)

        mac.stopHearingCurrentSession()
        try await Loopback.waitUntil { !model.isMacResponsive }
        model.stopControl()
        XCTAssertTrue(model.canReconnectNow)
        model.reconnectNow()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { self.heartbeats(mac, session: 2) >= 2 }
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertTrue(mac.pausedByHeadset)
        XCTAssertFalse(mac.controlEnabled)
        try await Loopback.pause(0.3)
        XCTAssertFalse(model.isMacControlEnabled)

        try await Loopback.waitUntil { model.canResumeControl }
        model.resumeControl()
        try await Loopback.waitUntil { model.isMacControlEnabled && mac.controlEnabled }

        model.reconnectNow()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 3 && model.isLinked }
        try await Loopback.waitUntil { model.isMacControlEnabled && mac.controlEnabled }
        XCTAssertFalse(mac.received(inSession: 3).contains { $0.kind == "stop" },
                       "Control granted again ends the Stop: this reconnection is Stop-free.")
    }

    // MARK: Grants while the Stop is unanswered

    /// A grant that reaches the headset before the Mac's answer to the repeated Stop cannot be
    /// told apart from one the Mac sent before reading it, so every grant is refused until the
    /// answer — and the answer itself grants nothing. Only a grant after it is believed.
    func testARepeatedStopRefusesEveryGrantUntilTheMacAnswersIt() async throws {
        let session = try await Loopback.directSession(linkPolicy: Loopback.reportOnlyPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()

        mac.stopHearingCurrentSession()
        model.stopControl()
        model.reconnectNow()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { mac.received(inSession: 2).contains { $0.kind == "stop" } }
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertEqual(model.statusText, SessionCopy.controlStoppedStatus)

        XCTAssertTrue(mac.publishStatus("stale grant", controlEnabled: true))
        try await Loopback.waitUntil { model.statusText == "stale grant" }
        XCTAssertFalse(model.isMacControlEnabled)
        XCTAssertFalse(model.canResumeControl)
        model.resumeControl()
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await Loopback.waitUntil { model.display(id: 1) != nil }
        XCTAssertTrue(mac.sendFrame(session.frame))
        try await Loopback.waitUntil { model.display(id: 1)?.isFresh() == true }
        XCTAssertFalse(model.canControl(displayID: 1), "A fresh picture grants nothing while the Stop is unanswered.")

        XCTAssertTrue(mac.publishStatus("Input stopped from Vision Pro.", controlEnabled: false))
        try await Loopback.waitUntil { model.canResumeControl }
        XCTAssertFalse(model.canControl, "An answer is not a grant.")
        XCTAssertFalse(mac.received(inSession: 2).contains { $0.kind == "requestControl" },
                       "The Resume refused before the answer sent nothing.")

        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.canControl(displayID: 1) }

        mac.dropConnection()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 3 && model.isLinked }
        try await Loopback.waitUntil { self.heartbeats(mac, session: 3) >= 1 }
        XCTAssertFalse(mac.received(inSession: 3).contains { $0.kind == "stop" },
                       "A grant believed after the answer ends the Stop.")
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
    }

    // MARK: Refused from inside Stop

    /// The channel refuses the Stop itself and ends the session from inside `stopControl`. The
    /// intent was recorded first, so the drop it caused — one drop, one attempt — reconnects
    /// into a session that repeats the Stop before the Mac's re-armed grant can take effect.
    func testAStopTheChannelRefusesIsRepeatedFirstAfterTheDropItCaused() async throws {
        let log = ChannelLog()
        let mac = MockMac()
        mac.emulatesConsent = true
        let session = try await Loopback.directSession(
            makeConnection: Loopback.recordingFactory(log, maximumPendingBytes: Loopback.constrainedQueueBytes),
            mac: mac
        )
        defer { session.close() }
        let model = session.model
        try await Loopback.waitUntil { model.isMacControlEnabled && mac.controlEnabled }
        let channel = try XCTUnwrap(log.channels.last, "the model has to use the channel it was given")

        // No suspension from here on, so nothing drains the queue before the Stop.
        let stopBytes = try FrameCodec.encode(DeskMessage(kind: "stop")).count
        try Loopback.fillSendQueue(channel, leaving: stopBytes - 1)
        XCTAssertEqual(channel.pendingBytes, Loopback.constrainedQueueBytes - (stopBytes - 1))
        XCTAssertTrue(model.isLinked, "filling the queue may not itself end the session")

        model.stopControl()

        XCTAssertFalse(model.isLinked, "the refused Stop fails the channel closed")
        XCTAssertEqual(model.reconnectAttempt, 1, "One refused send is one drop and one attempt.")
        XCTAssertTrue(model.isReconnecting)
        XCTAssertEqual(model.connectionMessage,
                       "Lost the connection to 127.0.0.1. Trying again in 1s (attempt 1 of 5).")

        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { self.heartbeats(mac, session: 2) >= 2 }
        XCTAssertFalse(mac.received(inSession: 1).contains { $0.kind == "stop" })
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertTrue(mac.pausedByHeadset)
        XCTAssertFalse(mac.controlEnabled)
        try await Loopback.pause(0.3)
        XCTAssertFalse(model.isMacControlEnabled)
    }

    /// Stop lifts a held button first, and the channel refuses that release: the session ends
    /// inside the release, before the Stop can be sent at all. That is still one drop and one
    /// attempt, the Mac's own disconnect releases the button, and the Stop that never left the
    /// headset opens the reconnection.
    func testAHeldReleaseRefusedWhileStoppingSpendsOneAttemptAndTheStopIsStillRepeated() async throws {
        let log = ChannelLog()
        let session = try await Loopback.directSession(
            makeConnection: Loopback.recordingFactory(log, maximumPendingBytes: Loopback.constrainedQueueBytes)
        )
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let pressed = CGPoint(x: 0.3, y: 0.7)
        model.updateGesture(token: UUID(), displayID: 1, mode: .interact,
                            start: pressed, point: pressed, translation: .zero)
        try await Loopback.waitUntil { mac.buttonHeld }
        let channel = try XCTUnwrap(log.channels.last, "the model has to use the channel it was given")

        // No suspension from here on, so nothing drains the queue before the release.
        let release = DeskMessage(kind: "input", displayID: 1,
                                  x: Double(pressed.x), y: Double(pressed.y), action: "leftUp")
        let releaseBytes = try FrameCodec.encode(release).count
        try Loopback.fillSendQueue(channel, leaving: releaseBytes - 1)
        XCTAssertEqual(channel.pendingBytes, Loopback.constrainedQueueBytes - (releaseBytes - 1),
                       "the queue has to end up exactly one byte short of carrying the release")

        model.stopControl()

        XCTAssertFalse(model.isLinked, "the refused release ends the session before the Stop is sent")
        XCTAssertEqual(model.reconnectAttempt, 1, "A release refused inside Stop is one drop and one attempt.")
        XCTAssertEqual(model.connectionMessage,
                       "Lost the connection to 127.0.0.1. Trying again in 1s (attempt 1 of 5).")
        try await Loopback.waitUntil { !mac.isConnected }
        XCTAssertFalse(mac.buttonHeld, "Losing the connection releases what the Mac could not be told to.")

        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { self.heartbeats(mac, session: 2) >= 1 }
        XCTAssertEqual(model.reconnectAttempt, 0)
        XCTAssertFalse(mac.received(inSession: 1).contains { $0.kind == "stop" })
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertTrue(mac.publishStatus("stale grant", controlEnabled: true))
        try await Loopback.waitUntil { model.statusText == "stale grant" }
        XCTAssertFalse(model.isMacControlEnabled)
    }

    // MARK: A deliberate connection

    /// Disconnect ends automatic reconnection, not the wearer's Stop. A Mac found by discovery
    /// is never redialled on its own, but connecting to it again by hand, the same way, still
    /// opens with the Stop it never read.
    func testConnectingAgainAfterDisconnectStillRepeatsAStopTheMacNeverRead() async throws {
        let mac = MockMac()
        let model = Loopback.model(linkPolicy: Loopback.reportOnlyPolicy)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
        let endpoint = try XCTUnwrap(mac.endpoint)
        model.connect(to: endpoint, key: mac.key, name: "Loopback Mac")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }

        mac.stopHearingCurrentSession()
        model.stopControl()
        model.disconnect()
        XCTAssertFalse(model.canReconnectNow)
        try await Loopback.waitUntil { !mac.isConnected }

        model.connect(to: endpoint, key: mac.key, name: "Loopback Mac")
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { mac.received(inSession: 2).contains { $0.kind == "stop" } }
        assertOpensWithTheRepeatedStop(mac, session: 2)
        XCTAssertTrue(mac.publishStatus("stale grant", controlEnabled: true))
        try await Loopback.waitUntil { model.statusText == "stale grant" }
        XCTAssertFalse(model.isMacControlEnabled)
    }

    /// A Stop pending on one Mac is still pending after sessions with another, even one the wearer
    /// also stopped, and a Mac with nothing pending opens Stop-free.
    func testAStopPendingOnOneMacSurvivesSessionsWithAnother() async throws {
        let first = MockMac(), second = MockMac()
        let model = Loopback.model(linkPolicy: Loopback.reportOnlyPolicy)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); first.stop(); second.stop() }
        model.updateScene(scene, phase: .active)
        try first.start(allowReconnect: true)
        try second.start(allowReconnect: true)
        try await Loopback.waitUntil { first.endpoint != nil && second.endpoint != nil }
        let firstEndpoint = try XCTUnwrap(first.endpoint), secondEndpoint = try XCTUnwrap(second.endpoint)

        model.connect(to: firstEndpoint, key: first.key, name: "First Mac")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && first.isConnected }
        first.stopHearingCurrentSession()
        model.stopControl()
        model.disconnect()
        try await Loopback.waitUntil { !first.isConnected }

        model.connect(to: secondEndpoint, key: second.key, name: "Second Mac")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && second.isConnected }
        try await Loopback.waitUntil { self.heartbeats(second, session: 1) >= 1 }
        XCTAssertFalse(second.received(inSession: 1).contains { $0.kind == "stop" },
                       "Only the Mac the wearer stopped is sent the Stop.")
        XCTAssertTrue(second.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
        model.stopControl()
        try await Loopback.waitUntil { second.received(inSession: 1).contains { $0.kind == "stop" } }
        model.disconnect()
        try await Loopback.waitUntil { !second.isConnected }

        model.connect(to: firstEndpoint, key: first.key, name: "First Mac")
        try await Loopback.waitUntil(timeout: 15) { first.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { first.received(inSession: 2).contains { $0.kind == "stop" } }
        assertOpensWithTheRepeatedStop(first, session: 2)
    }

    // MARK: Helpers

    /// Waits for the emulated Mac to enable control on the first heartbeat, then gives the
    /// session a display with a fresh picture, so every display accepts input.
    private func controlEnabledByTheMac(_ session: LoopbackSession) async throws {
        let model = session.model, mac = session.mac
        try await Loopback.waitUntil { model.isMacControlEnabled && mac.controlEnabled }
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await Loopback.waitUntil { model.display(id: 1) != nil }
        XCTAssertTrue(mac.sendFrame(session.frame))
        try await Loopback.waitUntil { model.canControl(displayID: 1) }
    }

    private func heartbeats(_ mac: MockMac, session: Int) -> Int {
        mac.received(inSession: session).filter { $0.kind == "heartbeat" }.count
    }

    /// A reconnection's opening: its capabilities, then the repeated Stop, with nothing — no
    /// heartbeat, no input, no Resume request — ahead of the Stop, and the Stop sent once.
    private func assertOpensWithTheRepeatedStop(_ mac: MockMac, session: Int,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let kinds = mac.received(inSession: session).map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(2)), ["capabilities", "stop"],
                       "session \(session) opened with \(Array(kinds.prefix(6)))", file: file, line: line)
        XCTAssertEqual(kinds.filter { $0 == "stop" }.count, 1, "repeated once per session", file: file, line: line)
    }
}
