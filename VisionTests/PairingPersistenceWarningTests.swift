import DeskCore
import Foundation
import Security
import XCTest
@testable import VisionDesk

@MainActor
final class PairingPersistenceWarningTests: XCTestCase {
    func testFailedSaveStaysVisibleAcrossHostStatusAndDisconnectThenSuccessfulPairingClearsIt() async throws {
        let keychain = MemoryKeychain()
        keychain.forcedStatus = errSecInteractionNotAllowed
        let preferences = MemoryRememberedMacStore()
        let mac = MockMac()
        let model = Loopback.model(keychain: keychain, preferences: preferences)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
        model.updateScene(scene, phase: .active)
        model.directAddress = try Loopback.address(for: mac)
        model.pairingCode = mac.key.displayValue
        model.connectDirectly()
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.pairingPersistenceWarning != nil }

        let warning = try XCTUnwrap(model.pairingPersistenceWarning)
        XCTAssertTrue(warning.contains("need its pairing key next time"))
        XCTAssertNil(model.rememberedMac)
        XCTAssertNil(preferences.stored)
        XCTAssertTrue(keychain.items.isEmpty)
        XCTAssertTrue(mac.publishStatus("Mac control enabled", controlEnabled: true))
        try await Loopback.waitUntil { model.isMacControlEnabled }
        XCTAssertEqual(model.pairingPersistenceWarning, warning)
        model.disconnect(message: "Connect again when ready.")
        XCTAssertFalse(model.isLinked)
        XCTAssertEqual(model.pairingPersistenceWarning, warning)
        XCTAssertEqual(model.connectionMessage, "Connect again when ready.")
        try await Loopback.waitUntil { !mac.isConnected }

        keychain.forcedStatus = nil
        model.pairingCode = mac.key.displayValue
        model.connectDirectly()
        XCTAssertNil(model.pairingPersistenceWarning, "Deliberate new pairing clears the previous attempt's warning.")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.rememberedMac != nil }
        XCTAssertNil(model.pairingPersistenceWarning)
        XCTAssertEqual(preferences.stored, model.rememberedMac)
        XCTAssertEqual(keychain.writeCount, 1)
    }

    func testSuccessfulForgetClearsSaveWarningWithoutEndingViewing() async throws {
        let keychain = MemoryKeychain()
        keychain.forcedStatus = errSecInteractionNotAllowed
        let mac = MockMac()
        let model = Loopback.model(keychain: keychain)
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        try mac.start()
        try await Loopback.waitUntil { mac.endpoint != nil }
        model.updateScene(scene, phase: .active)
        model.directAddress = try Loopback.address(for: mac)
        model.pairingCode = mac.key.displayValue
        model.connectDirectly()
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && model.pairingPersistenceWarning != nil }
        keychain.forcedStatus = nil
        model.forgetRememberedMac()
        XCTAssertNil(model.pairingPersistenceWarning)
        XCTAssertTrue(model.isLinked)
    }
}
