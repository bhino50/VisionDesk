import DeskCore
import Foundation
import Network
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// The saved Mac's first attempt joins the bounded reconnection schedule.
///
/// Its key is written only after a TLS handshake with it succeeded, so a first attempt that
/// finds nothing listening is most likely a Mac still waking, restarting its sharing or waiting
/// for its VPN — not a code typed wrong. A typed or discovered code that never authenticated is
/// still reported once and not retried; `ClientRecoveryTests` covers that side.
@MainActor
final class SavedMacRetryTests: XCTestCase {
    /// A relaunched app taps the saved Mac before the Mac is listening. The refusal is retried on
    /// the schedule, says the Mac has not been reached yet rather than that a link was lost,
    /// pauses while no window is in front and resumes where it left off, and connects once the
    /// Mac starts — with the stored key, rewriting nothing.
    func testASavedMacThatIsNotListeningYetIsRetriedUntilItStarts() async throws {
        let keychain = MemoryKeychain(), preferences = MemoryRememberedMacStore()
        let key = PairingKey.generate()
        let port = try await saveMac(key: key, keychain: keychain, preferences: preferences)
        let writes = keychain.writeCount
        XCTAssertEqual(writes, 1, "The key was stored once, after TLS authenticated.")

        let log = ChannelLog()
        let model = Loopback.model(keychain: keychain, preferences: preferences,
                                   makeConnection: Loopback.recordingFactory(log))
        let mac = MockMac(key: key)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        XCTAssertTrue(model.canConnectRemembered)
        model.connectRemembered()
        XCTAssertTrue(model.isConnecting)

        // Nothing listens yet, so the transport's handshake deadline ends the first attempt.
        try await Loopback.waitUntil(timeout: 20) { model.reconnectAttempt == 1 && !model.isConnecting }
        XCTAssertEqual(log.channels.count, 1)
        XCTAssertFalse(model.isLinked)
        XCTAssertTrue(model.isReconnecting)
        XCTAssertEqual(model.connectionMessage, "Couldn't reach 127.0.0.1 yet. Trying again in 1s (attempt 1 of 5).")
        XCTAssertTrue(model.canReconnectNow, "Reconnect offers what the schedule is already doing.")
        XCTAssertNotNil(model.rememberedMac, "A failed attempt forgets nothing.")

        model.updateScene(scene, phase: .inactive)
        XCTAssertFalse(model.isReconnecting)
        try await Loopback.pause(1.5)
        XCTAssertEqual(log.channels.count, 1, "Nothing is dialled while no window is in front.")
        model.updateScene(scene, phase: .active)
        XCTAssertTrue(model.isReconnecting, "Coming back resumes the same schedule.")
        XCTAssertEqual(model.reconnectAttempt, 2)
        XCTAssertEqual(model.connectionMessage, "Couldn't reach 127.0.0.1 yet. Trying again in 2s (attempt 2 of 5).")

        try mac.start(allowReconnect: true, port: port)
        try await Loopback.waitUntil { mac.endpoint != nil }
        try await Loopback.waitUntil(timeout: 20) { model.isLinked && mac.isConnected }
        XCTAssertEqual(log.channels.count, 2)
        XCTAssertEqual(mac.sessionCount, 1)
        XCTAssertEqual(model.reconnectAttempt, 0)
        XCTAssertFalse(model.isReconnecting)
        XCTAssertEqual(keychain.writeCount, writes, "Connecting with the stored key rewrites nothing.")
    }

    func testOtherWindowsCannotRestartAnExhaustedRetryBudget() async throws {
        let keychain = MemoryKeychain(), preferences = MemoryRememberedMacStore()
        let key = PairingKey.generate()
        _ = try await saveMac(key: key, keychain: keychain, preferences: preferences)
        let log = ChannelLog()
        let model = DeskClientModel(keys: Loopback.store(keychain), preferences: preferences,
                                    retryDelays: [0, 0, 0, 0, 0],
                                    makeConnection: { endpoint, key in
                                        let channel = DeskConnection(
                                            connection: NWConnection(to: endpoint, using: SecureParameters.make(key: key)),
                                            handshakeTimeout: 0.1, idleTimeout: nil)
                                        log.channels.append(channel)
                                        return channel
                                    })
        let scene = UUID(), other = UUID()
        defer { model.updateScene(other, phase: nil); model.updateScene(scene, phase: nil) }
        model.updateScene(scene, phase: .active)
        model.connectRemembered()
        try await Loopback.waitUntil(timeout: 30) { model.retryExhausted }
        XCTAssertEqual(log.channels.count, 6)
        XCTAssertEqual(model.reconnectAttempt, 5)
        let gaveUp = model.connectionMessage
        model.updateScene(other, phase: .active)
        model.updateScene(other, phase: .inactive)
        model.updateScene(other, phase: nil)
        try await Loopback.pause(0.2)
        XCTAssertEqual(log.channels.count, 6)
        XCTAssertTrue(model.retryExhausted)
        XCTAssertEqual(model.connectionMessage, gaveUp)

        model.updateScene(scene, phase: .inactive)
        model.updateScene(scene, phase: .active)
        XCTAssertFalse(model.retryExhausted)
        try await Loopback.waitUntil { log.channels.count > 6 }
        model.disconnect()
        XCTAssertFalse(model.retryExhausted)
    }

    // MARK: Helpers

    /// Saves a Mac the way the app does — a typed address and code, remembered only once TLS
    /// has authenticated — then closes that session and that listener. Returns the port.
    private func saveMac(key: PairingKey, keychain: MemoryKeychain,
                         preferences: MemoryRememberedMacStore) async throws -> UInt16 {
        let mac = MockMac(key: key)
        let model = Loopback.model(keychain: keychain, preferences: preferences)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
        let address = try Loopback.address(for: mac)
        model.directAddress = address
        model.pairingCode = key.displayValue
        model.remembersThisMac = true
        model.connectDirectly()
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.rememberedMac != nil }
        return try XCTUnwrap(RemoteMacAddress(string: address)?.port)
    }
}
