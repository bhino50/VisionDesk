import CoreGraphics
import DeskCore
import Foundation
import XCTest
@testable import DeskTransport
@testable import VisionDesk

/// A Stop the Mac never read outlives the app process.
///
/// The production preference store, over a suite of its own, is shared by one model and a
/// second model built after the first is gone — the relaunch. Everything in between is the real
/// path: a saved Mac reached over PSK-TLS loopback, a Stop pressed into a dead path, and a
/// reconnection by the saved card with the key from the Keychain fake.
@MainActor
final class StopPersistenceTests: XCTestCase {
    func testAStopLostBeforeTheAppClosedIsRepeatedFirstAfterARelaunch() async throws {
        let suite = try Loopback.throwawayDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let other = MacRoute.service(name: "Other Mac", type: "_visiondesk._tcp", domain: "local.")
        UserDefaultsRememberedMacStore(defaults: suite.defaults).saveStoppedRoutes([other])
        let keychain = MemoryKeychain()
        let mac = MockMac()
        defer { mac.stop() }
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
        let address = try Loopback.address(for: mac)
        let route = MacRoute(try XCTUnwrap(RemoteMacAddress(string: address)))

        // First launch: the Mac is saved and grants control, then the path from the headset dies,
        // the wearer presses Stop into it, and the app is closed before any reconnection.
        let first = Loopback.model(keychain: keychain, preferences: UserDefaultsRememberedMacStore(defaults: suite.defaults),
                                   linkPolicy: Loopback.reportOnlyPolicy)
        let firstScene = UUID()
        first.updateScene(firstScene, phase: .active)
        first.directAddress = address
        first.pairingCode = mac.key.displayValue
        first.remembersThisMac = true
        first.connectDirectly()
        try await Loopback.waitUntil(timeout: 15) { first.isLinked && mac.isConnected && first.rememberedMac != nil }
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { first.isMacControlEnabled }
        mac.stopHearingCurrentSession()
        first.stopControl()
        XCTAssertEqual(storedRoutes(suite.defaults), [route, other], "The Stop is in preferences as soon as it is pressed.")
        first.updateScene(firstScene, phase: nil)
        try await Loopback.waitUntil { !mac.isConnected }
        XCTAssertFalse(mac.received(inSession: 1).contains { $0.kind == "stop" }, "The Mac never read a Stop.")

        // Relaunch: a new model over the same preferences, connected by the saved card.
        let second = Loopback.model(keychain: keychain, preferences: UserDefaultsRememberedMacStore(defaults: suite.defaults),
                                    linkPolicy: Loopback.reportOnlyPolicy)
        let secondScene = UUID()
        defer { second.updateScene(secondScene, phase: nil) }
        second.updateScene(secondScene, phase: .active)
        XCTAssertTrue(second.canConnectRemembered)
        second.connectRemembered()
        try await Loopback.waitUntil(timeout: 15) { mac.sessionCount == 2 && second.isLinked }
        try await Loopback.waitUntil { mac.received(inSession: 2).contains { $0.kind == "heartbeat" } }
        let kinds = mac.received(inSession: 2).map(\.kind)
        XCTAssertEqual(Array(kinds.prefix(2)), ["capabilities", "stop"], "session 2 opened with \(Array(kinds.prefix(6)))")

        // Input stays gated: a grant before the Mac's answer is not believed, a fresh picture
        // grants nothing, and no input or Resume request leaves the headset.
        let frame = try XCTUnwrap(DeskFixtures.jpeg(), "The platform could not encode a JPEG fixture.")
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await Loopback.waitUntil { second.display(id: 1) != nil }
        XCTAssertTrue(mac.publishStatus("stale grant", controlEnabled: true))
        XCTAssertTrue(mac.sendFrame(frame))
        try await Loopback.waitUntil { second.statusText == "stale grant" && second.display(id: 1)?.isFresh() == true }
        XCTAssertFalse(second.isMacControlEnabled)
        XCTAssertFalse(second.canControl(displayID: 1))
        second.placePointer(displayID: 1, at: CGPoint(x: 0.5, y: 0.5))
        second.sendKey("space", displayID: 1)
        second.resumeControl()
        try await Loopback.pause(0.3)
        XCTAssertFalse(mac.received(inSession: 2).contains { $0.kind == "input" || $0.kind == "requestControl" })

        // The answer alone keeps the Stop. A grant after it clears this route, and only this one.
        XCTAssertTrue(mac.publishStatus("Input stopped from Vision Pro.", controlEnabled: false))
        try await Loopback.waitUntil { second.canResumeControl }
        XCTAssertEqual(storedRoutes(suite.defaults), [route, other])
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { second.canControl(displayID: 1) }
        XCTAssertEqual(storedRoutes(suite.defaults), [other],
                       "An accepted grant clears its own route; another Mac's pending Stop remains.")
        assertNothingSecret(about: mac.key, in: suite)
    }

    // MARK: Helpers

    /// What a fresh store reads from these preferences, as a newly launched app would.
    private func storedRoutes(_ defaults: UserDefaults) -> Set<MacRoute> {
        UserDefaultsRememberedMacStore(defaults: defaults).loadStoppedRoutes()
    }

    /// No form of the pairing key appears in anything the suite holds. Compared without printing
    /// either value, so a failure can never write a key into a log.
    private func assertNothingSecret(about key: PairingKey, in suite: (defaults: UserDefaults, name: String),
                                     file: StaticString = #filePath, line: UInt = #line) {
        let values = suite.defaults.persistentDomain(forName: suite.name) ?? [:]
        XCTAssertFalse(values.isEmpty, "the suite should hold the saved Mac and a pending Stop", file: file, line: line)
        let text = values.values.map { value -> String in
            (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }.joined(separator: "\n").lowercased()
        let display = key.displayValue.lowercased()
        let compact = display.replacingOccurrences(of: "-", with: "")
        XCTAssertTrue(!text.contains(display) && !text.contains(compact),
                      "a pairing key was written to preferences", file: file, line: line)
    }
}
