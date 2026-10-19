import DeskCore
import Foundation
import Network
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// A Mac found on this network is saved only when it says, inside the authenticated session, that
/// its pairing outlives the session. Then it is saved by its Bonjour service, comes back by itself
/// after a drop, and connects from the saved card after a relaunch without anyone typing a key.
///
/// The mock Mac listens on loopback rather than advertising on the real network. The model is
/// handed a Bonjour service endpoint, as the nearby list hands it one, and the factory below dials
/// the mock Mac's loopback listener whenever the model asks for a service. The handshake is the
/// production PSK-TLS either way, and the factory records every endpoint the model asked for, so
/// each test proves which route was dialled.
@MainActor
final class SavedNearbyMacTests: XCTestCase {
    private static let studio = NWEndpoint.service(name: "Studio", type: SecureParameters.serviceType,
                                                   domain: "local.", interface: nil)
    private static let studioRoute = MacRoute.service(name: "Studio", type: SecureParameters.serviceType,
                                                      domain: "local.")

    /// A Mac that never says its pairing lasts is the one-time session it always was. Nothing is
    /// saved, a status saying the pairing does not last changes nothing, and after a drop nothing
    /// is dialled again, although this listener would still answer.
    func testANearbyMacThatDoesNotKeepItsPairingIsNeitherSavedNorDialledAgain() async throws {
        let keychain = MemoryKeychain(), preferences = MemoryRememberedMacStore(), log = EndpointLog()
        let mac = MockMac()
        let model = Loopback.model(keychain: keychain, preferences: preferences,
                                   makeConnection: Self.serviceRedirect(to: mac, log: log))
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        try await Self.startListening(mac)
        model.updateScene(scene, phase: .active)
        model.connect(to: Self.studio, key: mac.key, name: "Studio")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && mac.isConnected }

        XCTAssertTrue(mac.send(DeskMessage(kind: "status", status: "Temporary pairing", keepsPairing: false)))
        try await Loopback.waitUntil { model.statusText == "Temporary pairing" }
        XCTAssertNil(model.rememberedMac)
        XCTAssertNil(preferences.stored)
        XCTAssertEqual(keychain.writeCount, 0, "A one-time key is never stored.")
        XCTAssertFalse(model.canReconnectNow)

        mac.dropConnection()
        try await Loopback.waitUntil { !model.isLinked }
        XCTAssertFalse(model.isReconnecting)
        try await Loopback.pause(1.5)
        XCTAssertEqual(log.requested, [Self.studio], "Nothing is dialled again after a one-time session.")
        XCTAssertEqual(mac.sessionCount, 1)
    }

    /// The Mac says its pairing lasts. The session is saved at once — the key once in the
    /// Keychain, the name and service in preferences — and is worth dialling again: when its link
    /// drops with a Stop the Mac never read, the model dials the same service by itself, and the
    /// new session opens by repeating that Stop.
    func testANearbyMacThatKeepsItsPairingIsSavedByItsServiceAndComesBack() async throws {
        let keychain = MemoryKeychain(), preferences = MemoryRememberedMacStore(), log = EndpointLog()
        let mac = MockMac()
        mac.keepsPairing = true
        let model = Loopback.model(keychain: keychain, preferences: preferences, linkPolicy: Loopback.reportOnlyPolicy,
                                   makeConnection: Self.serviceRedirect(to: mac, log: log))
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        try await Self.startListening(mac)
        model.updateScene(scene, phase: .active)
        model.connect(to: Self.studio, key: mac.key, name: "Studio")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.rememberedMac != nil }

        let saved = RememberedMac(name: "Studio", route: Self.studioRoute)
        XCTAssertEqual(model.rememberedMac, saved)
        XCTAssertEqual(preferences.stored, saved)
        XCTAssertEqual(keychain.writeCount, 1, "The key is stored once, after TLS authenticated and the Mac said it lasts.")
        XCTAssertTrue(model.canReconnectNow)
        let record = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).lowercased()
        let compact = mac.key.displayValue.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertFalse(record.contains(compact), "The saved record holds no key.")

        // Every later status repeats the flag, and nothing is written again.
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
        XCTAssertEqual(keychain.writeCount, 1)

        // The path dies, the wearer stops control into it, then the link drops.
        mac.stopHearingCurrentSession()
        model.stopControl()
        mac.dropConnection()
        try await Loopback.waitUntil(timeout: 20) { mac.sessionCount == 2 && model.isLinked }
        try await Loopback.waitUntil { mac.received(inSession: 2).contains { $0.kind == "heartbeat" } }
        let kinds = mac.received(inSession: 2).map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(2)), ["capabilities", "stop"], "session 2 opened with \(Array(kinds.prefix(6)))")
        XCTAssertFalse(mac.received(inSession: 1).contains { $0.kind == "stop" }, "The first Stop was never read.")
        XCTAssertEqual(log.requested, [Self.studio, Self.studio], "The same service is dialled again, by itself.")
        XCTAssertEqual(keychain.writeCount, 1, "Coming back rewrites nothing.")
    }

    /// After a relaunch the saved card reaches the same Mac by its service, with the key from the
    /// Keychain and none typed, and a Stop the Mac never read is repeated first. Preferences hold
    /// the name and the service, never the key.
    func testASavedNearbyMacConnectsAfterARelaunchWithoutAKey() async throws {
        let suite = try Loopback.throwawayDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let keychain = MemoryKeychain(), log = EndpointLog()
        let mac = MockMac()
        mac.keepsPairing = true
        defer { mac.stop() }
        try await Self.startListening(mac)

        // First launch: paired from the nearby list and granted control, then a Stop pressed into
        // a dead path, and the app closes before any reconnection.
        let first = Loopback.model(keychain: keychain, preferences: UserDefaultsRememberedMacStore(defaults: suite.defaults),
                                   linkPolicy: Loopback.reportOnlyPolicy,
                                   makeConnection: Self.serviceRedirect(to: mac, log: log))
        let firstScene = UUID()
        first.updateScene(firstScene, phase: .active)
        first.connect(to: Self.studio, key: mac.key, name: "Studio")
        try await Loopback.waitUntil(timeout: 15) { first.isLinked && first.rememberedMac != nil }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { first.isMacControlEnabled }
        mac.stopHearingCurrentSession()
        first.stopControl()
        first.updateScene(firstScene, phase: nil)
        try await Loopback.waitUntil { !mac.isConnected }

        // Relaunch: a new model over the same preferences and Keychain.
        let second = Loopback.model(keychain: keychain, preferences: UserDefaultsRememberedMacStore(defaults: suite.defaults),
                                    linkPolicy: Loopback.reportOnlyPolicy,
                                    makeConnection: Self.serviceRedirect(to: mac, log: log))
        let secondScene = UUID()
        defer { second.updateScene(secondScene, phase: nil) }
        second.updateScene(secondScene, phase: .active)
        XCTAssertEqual(second.rememberedMac, RememberedMac(name: "Studio", route: Self.studioRoute))
        XCTAssertTrue(second.pairingCode.isEmpty)
        XCTAssertTrue(second.canConnectRemembered)
        second.connectRemembered()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && second.isLinked }
        try await Loopback.waitUntil { mac.received(inSession: 2).contains { $0.kind == "heartbeat" } }
        let kinds = mac.received(inSession: 2).map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(2)), ["capabilities", "stop"], "session 2 opened with \(Array(kinds.prefix(6)))")
        XCTAssertEqual(log.requested, [Self.studio, Self.studio])
        XCTAssertEqual(keychain.writeCount, 1, "The saved key is used as stored.")
        assertNoKey(mac.key, in: suite)
    }

    /// The flag changes only a session started from the nearby list. A model with no session
    /// ignores it, a typed address keeps the choice it was started with, and with saving turned
    /// off a nearby session comes back by itself but is not saved.
    func testTheFlagChangesOnlyANearbySession() async throws {
        let idle = Loopback.model()
        idle.macKeepsPairing()
        XCTAssertNil(idle.rememberedMac)
        XCTAssertFalse(idle.canReconnectNow)

        let typedMac = MockMac()
        typedMac.keepsPairing = true
        let typed = try await Loopback.directSession(mac: typedMac)
        defer { typed.close() }
        try await Loopback.waitUntil { typed.model.statusText == MockMac.attachStatus }
        XCTAssertNil(typed.model.rememberedMac, "A typed address is saved by the choice it was started with.")

        let keychain = MemoryKeychain(), preferences = MemoryRememberedMacStore(), log = EndpointLog()
        let mac = MockMac()
        mac.keepsPairing = true
        let model = Loopback.model(keychain: keychain, preferences: preferences,
                                   makeConnection: Self.serviceRedirect(to: mac, log: log))
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        try await Self.startListening(mac)
        model.updateScene(scene, phase: .active)
        model.remembersThisMac = false
        model.connect(to: Self.studio, key: mac.key, name: "Studio")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.statusText == MockMac.attachStatus }
        XCTAssertTrue(model.canReconnectNow, "A Mac that keeps its pairing is worth dialling again.")
        XCTAssertNil(model.rememberedMac)
        XCTAssertNil(preferences.stored)
        XCTAssertEqual(keychain.writeCount, 0)
    }

    // MARK: Helpers

    /// The listener outlives a session either way, so a model that does not dial again is shown
    /// not to, rather than unable to.
    private static func startListening(_ mac: MockMac) async throws {
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
    }

    /// The production channel, except that a service is dialled at the mock Mac's loopback
    /// listener. Every endpoint the model asks for is recorded first.
    private static func serviceRedirect(to mac: MockMac, log: EndpointLog) -> Loopback.ConnectionFactory {
        { endpoint, key in
            log.requested.append(endpoint)
            guard case .service = endpoint, let loopback = mac.endpoint else {
                return DeskConnection(endpoint: endpoint, key: key)
            }
            return DeskConnection(endpoint: loopback, key: key)
        }
    }

    /// No form of the pairing key is in anything the suite holds. Compared without printing either
    /// value, so a failure never writes a key into a log.
    private func assertNoKey(_ key: PairingKey, in suite: (defaults: UserDefaults, name: String),
                             file: StaticString = #filePath, line: UInt = #line) {
        let values = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
        XCTAssertFalse(values.isEmpty, "the suite should hold the saved Mac", file: file, line: line)
        let text = values.values.map { value -> String in
            (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }.joined(separator: "\n").lowercased()
        let display = key.displayValue.lowercased()
        let compact = display.replacingOccurrences(of: "-", with: "")
        XCTAssertTrue(!text.contains(display) && !text.contains(compact),
                      "a pairing key was written to preferences", file: file, line: line)
    }
}

/// Every endpoint a factory was asked for, in order.
@MainActor
private final class EndpointLog {
    var requested: [NWEndpoint] = []
}
