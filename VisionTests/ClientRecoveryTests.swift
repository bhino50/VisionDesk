import DeskCore
import Foundation
import Network
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// What the production `DeskClientModel` does when a session goes wrong, over a real
/// authenticated loopback session: a Mac that stops answering without closing the connection,
/// a first attempt that never authenticates, a dropped link with a button held, and a control
/// send the channel refuses in the middle of a display update.
@MainActor
final class ClientRecoveryTests: XCTestCase {
    // MARK: A Mac that stops answering

    /// The Mac goes silent — no picture, no status — while the connection stays open, which is
    /// what a hard sleep or a dead VPN path looks like from the headset: TCP never notices,
    /// because only the headset ever sends. A session that can come back by itself is reported
    /// first, then recycled through the ordinary reconnection schedule without telling the Mac
    /// to stop, and comes back. After the allowance it is only reported, so a live Mac whose
    /// screens are genuinely idle is not redialled forever; anything that arrives clears it.
    func testASilentDirectSessionIsReportedThenRecycledWithoutAStopAndCapped() async throws {
        let session = try await Loopback.directSession(linkPolicy: Loopback.fastPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac

        try await Loopback.waitUntil { !model.isMacResponsive }
        XCTAssertTrue(model.isLinked, "Silence is reported before anything is closed.")
        XCTAssertEqual(model.connectionLabel, "Not responding")
        XCTAssertTrue(model.willRecoverAutomatically)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.macSilence()), Loopback.fastPolicy.quietAfter)

        // Each recycle is a real new handshake on the same listener.
        try await Loopback.waitUntil(timeout: 20) { mac.sessionCount == 3 && model.isLinked }
        XCTAssertEqual(model.reconnectAttempt, 0, "Each recycle came back on its first scheduled try.")
        XCTAssertFalse(mac.received.contains { $0.kind == "stop" },
                       "A recycle is not a hang-up, so the Mac's control grant is never paused by one.")

        try await Loopback.waitUntil { !model.isMacResponsive }
        XCTAssertFalse(model.willRecoverAutomatically, "The allowance is spent.")
        XCTAssertTrue(model.canReconnectNow, "The wearer can still choose to dial again.")
        try await Loopback.pause(Loopback.fastPolicy.recoverAfter + 1.5)
        XCTAssertEqual(mac.sessionCount, 3, "After the allowance, silence is only reported.")
        XCTAssertTrue(model.isLinked)
        XCTAssertEqual(model.connectionLabel, "Not responding")

        XCTAssertTrue(mac.publishStatus("Still here", controlEnabled: false))
        try await Loopback.waitUntil { model.isMacResponsive }
        XCTAssertEqual(model.connectionLabel, "Viewing only")
    }

    /// A fresh manual pairing must not inherit the recovery allowance spent by an earlier
    /// session, even when the wearer returns through the nearby route instead of its address.
    func testDeliberateNearbyPairingRestoresSpentAutomaticRecoveryAllowance() async throws {
        let session = try await Loopback.directSession(linkPolicy: Loopback.fastPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac

        try await Loopback.waitUntil(timeout: 20) {
            mac.sessionCount == 3 && model.isLinked && !model.isMacResponsive
        }
        XCTAssertFalse(model.willRecoverAutomatically, "The earlier session spent both recoveries.")
        model.disconnect()
        try await Loopback.waitUntil { !mac.isConnected }

        // The same listener is handed to the production nearby-pairing entry point. It now
        // advertises persistent pairing, just as the shipping companion does after attach.
        mac.keepsPairing = true
        model.connect(to: try XCTUnwrap(mac.endpoint), key: mac.key, name: "Nearby Mac")
        try await Loopback.waitUntil(timeout: 15) {
            mac.sessionCount == 4 && model.isLinked && model.canReconnectNow
        }
        XCTAssertTrue(model.willRecoverAutomatically,
                      "A deliberate nearby pairing gets its own recovery allowance.")
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 5 && model.isLinked }
    }

    /// A Mac found by discovery stops sharing as soon as its session closes, so closing a silent
    /// session would end the very sharing the wearer is waiting for. It is reported, never
    /// closed, never offered a reconnection it could not deliver, and its silence explains
    /// the screen rather than its grant until a picture arrives.
    func testASilentDiscoveredSessionIsReportedButNeverClosed() async throws {
        let session = try await Loopback.discoveredSession(linkPolicy: Loopback.fastPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        XCTAssertEqual(model.connectionLabel, "Control enabled")

        try await Loopback.waitUntil { !model.isMacResponsive }
        XCTAssertEqual(model.connectionLabel, "Not responding",
                       "Control that cannot reach the Mac is not shown as control.")
        XCTAssertFalse(model.canReconnectNow)
        XCTAssertFalse(model.willRecoverAutomatically)
        try await Loopback.pause(Loopback.fastPolicy.recoverAfter + 1.5)
        XCTAssertTrue(model.isLinked)
        XCTAssertTrue(mac.isConnected)
        XCTAssertEqual(mac.sessionCount, 1)
        model.reconnectNow()
        XCTAssertTrue(model.isLinked, "Reconnect is refused for a session that cannot be dialled again.")
        XCTAssertFalse(mac.received.contains { $0.kind == "stop" })

        XCTAssertTrue(mac.sendFrame(session.frame))
        try await Loopback.waitUntil { model.isMacResponsive && model.canControl(displayID: 1) }
        XCTAssertEqual(model.connectionLabel, "Control enabled")
    }

    /// The wearer does not have to wait out the silence: Reconnect recycles a session that has
    /// reached its Mac at once, reports itself as a reconnection across the attempt, sends no
    /// Stop, and the new session is a real second handshake.
    func testReconnectNowRedialsASilentSessionAtOnce() async throws {
        let session = try await Loopback.directSession(linkPolicy: Loopback.reportOnlyPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await Loopback.waitUntil { !model.isMacResponsive }
        XCTAssertTrue(model.canReconnectNow)

        model.reconnectNow()
        XCTAssertFalse(model.isLinked)
        XCTAssertTrue(model.isConnecting)
        XCTAssertTrue(model.isReconnecting)
        XCTAssertEqual(model.connectionMessage, "Reconnecting to 127.0.0.1.")
        XCTAssertFalse(model.canReconnectNow, "One attempt at a time.")
        model.reconnectNow()

        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        XCTAssertFalse(model.isReconnecting)
        XCTAssertEqual(model.reconnectAttempt, 0)
        XCTAssertFalse(mac.received.contains { $0.kind == "stop" })
        try await Loopback.pause(0.3)
        XCTAssertEqual(mac.sessionCount, 2, "A second request during the attempt dialled nothing.")
    }

    // MARK: A first attempt that never authenticates

    /// An attempt that never completed its handshake was never connected, so there is no link
    /// to lose. Retrying it would repeat the same refusal — with a mistyped code, the same wrong
    /// key five more times — under a "lost the connection" message that is not true. It is
    /// reported once, says what to do, and leaves the typed code in place to correct. Both
    /// ways in run side by side, because each waits out the transport's handshake deadline.
    func testAFirstAttemptThatNeverAuthenticatesIsReportedOnceAndKeepsTheTypedCode() async throws {
        let wrongCode = PairingKey.generate().displayValue
        let addressLog = ChannelLog(), nearbyLog = ChannelLog()
        let addressMac = MockMac(), nearbyMac = MockMac()
        let addressModel = Loopback.model(makeConnection: Loopback.recordingFactory(addressLog))
        let nearbyModel = Loopback.model(makeConnection: Loopback.recordingFactory(nearbyLog))
        let scene = UUID()
        defer {
            addressModel.updateScene(scene, phase: nil)
            nearbyModel.updateScene(scene, phase: nil)
            addressMac.stop()
            nearbyMac.stop()
        }
        addressModel.updateScene(scene, phase: .active)
        nearbyModel.updateScene(scene, phase: .active)
        try addressMac.start(allowReconnect: true)
        try nearbyMac.start()
        try await Loopback.waitUntil { addressMac.endpoint != nil && nearbyMac.endpoint != nil }

        addressModel.directAddress = try Loopback.address(for: addressMac)
        addressModel.pairingCode = wrongCode
        addressModel.connectDirectly()
        nearbyModel.pairingCode = wrongCode
        nearbyModel.connect(to: try XCTUnwrap(nearbyMac.endpoint),
                            key: try XCTUnwrap(PairingKey(string: wrongCode)), name: "Loopback Mac")
        try await Loopback.waitUntil(timeout: 20) {
            !addressModel.isConnecting && !nearbyModel.isConnecting
                && addressModel.connectionMessage != nil && nearbyModel.connectionMessage != nil
        }
        // Longer than the first backoff step plus a handshake, so a retry would have dialled.
        try await Loopback.pause(2.5)

        for (name, model, log, mac) in [("address", addressModel, addressLog, addressMac),
                                        ("nearby", nearbyModel, nearbyLog, nearbyMac)] {
            XCTAssertEqual(log.channels.count, 1, "\(name): a refused first attempt is not retried.")
            XCTAssertEqual(mac.sessionCount, 0, name)
            XCTAssertFalse(model.isLinked, name)
            XCTAssertFalse(model.isReconnecting, name)
            XCTAssertEqual(model.reconnectAttempt, 0, name)
            XCTAssertFalse(model.canReconnectNow, "\(name): nothing was reached, so nothing can be redialled.")
            // Compared without printing either value: a failure must never write a pairing code
            // into a log, even this throwaway one.
            XCTAssertTrue(model.pairingCode == wrongCode, "\(name): the typed code stays to be corrected.")
        }
        // A wrong key ends the handshake one of these two ways, and the message says what that
        // means in the headset's words — never the transport's — with advice for the route taken.
        // Matching the real reasons exactly is also what notices the transport rewording them.
        let secureFailure = "The secure connection could not be established. Check that both apps are up to date and use the same pairing key, then try again."
        let wrongKeyReasons = ["Pairing timed out. Check the key and local network.",
                               secureFailure, "Connection attempt timed out. \(secureFailure)"]
        let addressMessage = try XCTUnwrap(addressModel.connectionMessage)
        XCTAssertTrue(wrongKeyReasons.map { SessionCopy.couldNotConnect(to: "127.0.0.1", reason: $0, route: .address) }
            .contains(addressMessage), addressMessage)
        let nearbyMessage = try XCTUnwrap(nearbyModel.connectionMessage)
        XCTAssertTrue(wrongKeyReasons.map { SessionCopy.couldNotConnect(to: "Loopback Mac", reason: $0, route: .nearby) }
            .contains(nearbyMessage), nearbyMessage)
    }

    // MARK: One drop

    /// One dropped link is one reconnection attempt. A drop with a button held makes the
    /// teardown send a release over the channel that just died, and that refused send used to be
    /// handled as a second drop from inside the first: a second attempt spent, the first wait
    /// doubled, and the first handling's message overwritten.
    func testOneDropWithAHeldButtonSpendsOneReconnectAttempt() async throws {
        let session = try await Loopback.directSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        let point = CGPoint(x: 0.4, y: 0.6)
        model.updateGesture(token: UUID(), displayID: 1, mode: .interact,
                            start: point, point: point, translation: .zero)
        try await Loopback.waitUntil { mac.buttonHeld }
        XCTAssertEqual(model.pointedDisplayIDs, [1])

        mac.dropConnection()
        try await Loopback.waitUntil { !model.isLinked }
        XCTAssertEqual(model.reconnectAttempt, 1, "One drop, one attempt.")
        XCTAssertTrue(model.isReconnecting)
        XCTAssertEqual(model.connectionMessage,
                       "Lost the connection to 127.0.0.1. Trying again in 1s (attempt 1 of 5).")
        XCTAssertTrue(model.pointedDisplayIDs.isEmpty, "A lost session forgets where its pointers were.")
        XCTAssertTrue(model.canReconnectNow, "The wait is optional for a Mac this session reached.")

        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && model.isLinked }
        XCTAssertFalse(mac.received.contains { $0.kind == "stop" })
        XCTAssertFalse(mac.buttonHeld)
    }

    // MARK: A refused send inside a display update

    /// A resized display drops its picture and asks for a keyframe, and that request is a
    /// control send that can fail and end the session from inside the display update. The new
    /// list is installed before anything can send, so the teardown empties the list that is
    /// actually installed; it used to be assigned afterwards, putting live-looking streams back
    /// onto a session that no longer existed.
    func testAKeyframeRequestRefusedDuringAResizeLeavesNoDisplaysBehind() async throws {
        let log = ChannelLog()
        let session = try await Loopback.discoveredSession(
            makeConnection: Loopback.recordingFactory(log, maximumPendingBytes: Loopback.constrainedQueueBytes)
        )
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await session.grantControl()
        // Outside the per-display keyframe rate limit, so the resize really asks.
        try await Loopback.pause(0.6)
        let channel = try XCTUnwrap(log.channels.last, "the model has to use the channel it was given")

        // No suspension from here on, so nothing drains the queue before the request.
        let keyframeBytes = try FrameCodec.encode(DeskMessage(kind: "keyframe", displayID: 1)).count
        try Loopback.fillSendQueue(channel, leaving: keyframeBytes - 1)
        XCTAssertEqual(channel.pendingBytes, Loopback.constrainedQueueBytes - (keyframeBytes - 1))
        XCTAssertTrue(model.isLinked, "filling the queue may not itself end the session")

        model.receive(DeskMessage(kind: "displays", displays: [DeskFixtures.resizedDisplay]))

        XCTAssertFalse(model.isLinked, "the refused keyframe request fails the channel closed")
        XCTAssertTrue(model.displays.isEmpty, "a teardown during the update may not leave streams behind")
        XCTAssertNil(model.display(id: 1))
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(model.connectionMessage, "the drop has to be reported, not silent")
        try await Loopback.waitUntil { !mac.isConnected }
    }
}
