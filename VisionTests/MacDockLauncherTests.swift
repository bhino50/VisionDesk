import DeskCore
import Foundation
import UIKit
import XCTest
@testable import VisionDesk

@MainActor
final class MacDockLauncherTests: XCTestCase {
    private let finder = DockAppInfo(id: "finder", name: "Finder")
    private let notes = DockAppInfo(id: "notes", name: "Notes")

    func testCatalogNegotiationRefreshAndLegacyHostStayInTheAuthenticatedSession() async throws {
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "capabilities" } }
        XCTAssertTrue(mac.received.contains { $0.kind == "capabilities" && $0.dockLauncher == true })
        XCTAssertFalse(model.dockLauncher.isAvailable, "An older companion sends no catalog; no false empty Dock appears.")
        XCTAssertTrue(mac.send(DeskMessage(kind: "apps", dockApps: [finder, notes])))
        try await Loopback.waitUntil { model.dockApps.count == 2 }
        XCTAssertTrue(model.dockLauncher.isAvailable)
        XCTAssertFalse(model.canLaunchDockApps, "A catalog is not a control grant.")
        model.refreshDockApps()
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "requestApps" } }
        model.launchDockApp(id: finder.id)
        try await Loopback.pause(0.1)
        XCTAssertFalse(mac.received.contains { $0.kind == "launchApp" })
        model.disconnect()
        XCTAssertFalse(model.dockLauncher.isAvailable)
        XCTAssertTrue(model.dockApps.isEmpty)
        model.receive(DeskMessage(kind: "apps", dockApps: [finder]))
        XCTAssertTrue(model.dockApps.isEmpty, "An unlinked model cannot accept a catalog.")
    }

    func testLaunchAcknowledgmentMatchesBothRequestAndAppAndReportsMacFailure() async throws {
        let session = try await preparedSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        model.launchDockApp(id: "not-in-dock")
        XCTAssertFalse(model.dockLauncher.isLaunching)
        model.launchDockApp(id: finder.id)
        model.launchDockApp(id: notes.id)
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "launchApp" } }
        let request = try XCTUnwrap(mac.received.first { $0.kind == "launchApp" })
        XCTAssertEqual(request.appID, finder.id)
        XCTAssertNil(request.displayID, "Current location preserves the app’s existing screen.")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request.appRequestID)))
        XCTAssertEqual(mac.received.filter { $0.kind == "launchApp" }.count, 1)
        XCTAssertTrue(mac.send(result(for: request, appID: notes.id, succeeded: true, status: "Wrong app")))
        XCTAssertTrue(mac.send(result(for: request, requestID: UUID().uuidString, succeeded: true, status: "Wrong request")))
        try await Loopback.pause(0.1)
        XCTAssertTrue(model.dockLauncher.isLaunching)
        XCTAssertTrue(mac.send(result(for: request, succeeded: true, status: "Finder opened on your Mac.")))
        try await Loopback.waitUntil { model.dockLauncher.launchSucceeded == true }
        XCTAssertEqual(model.dockLauncher.launchStatus, "Finder opened on your Mac.")
        XCTAssertTrue(model.canLaunchDockApps)
        model.launchDockApp(id: notes.id)
        try await Loopback.waitUntil { mac.received.filter { $0.kind == "launchApp" }.count == 2 }
        let second = try XCTUnwrap(mac.received.last { $0.kind == "launchApp" })
        XCTAssertTrue(mac.send(result(for: second, succeeded: false, status: "Notes is no longer in the Dock.")))
        try await Loopback.waitUntil { model.dockLauncher.launchSucceeded == false }
        XCTAssertEqual(model.dockLauncher.launchStatus, "Notes is no longer in the Dock.")
    }

    func testStopAndFocusLossCancelWaitingWithoutBelievingLateAcknowledgment() async throws {
        let session = try await preparedSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        model.launchDockApp(id: finder.id)
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "launchApp" } }
        let request = try XCTUnwrap(mac.received.first { $0.kind == "launchApp" })
        model.stopControl()
        XCTAssertFalse(model.dockLauncher.isLaunching)
        XCTAssertFalse(model.canLaunchDockApps)
        let paused = model.dockLauncher.launchStatus
        XCTAssertTrue(mac.send(result(for: request, succeeded: true, status: "Late success")))
        try await Loopback.pause(0.1)
        XCTAssertEqual(model.dockLauncher.launchStatus, paused)
        XCTAssertTrue(mac.publishStatus("Stopped", controlEnabled: false))
        try await Loopback.waitUntil { model.canResumeControl }
        XCTAssertTrue(mac.publishStatus("Granted again", controlEnabled: true))
        try await Loopback.waitUntil { model.canLaunchDockApps }
        model.launchDockApp(id: notes.id)
        XCTAssertTrue(model.dockLauncher.isLaunching)
        model.updateScene(session.scene, phase: .inactive)
        XCTAssertFalse(model.dockLauncher.isLaunching)
        XCTAssertFalse(model.canLaunchDockApps)
    }

    func testRevocationAndUnresponsiveMacDisableLaunches() async throws {
        let session = try await preparedSession(linkPolicy: Loopback.reportOnlyPolicy)
        defer { session.close() }
        let model = session.model, mac = session.mac
        model.launchDockApp(id: finder.id)
        XCTAssertTrue(mac.publishStatus("Control revoked", controlEnabled: false))
        try await Loopback.waitUntil { !model.isMacControlEnabled }
        XCTAssertFalse(model.dockLauncher.isLaunching)
        XCTAssertFalse(model.canLaunchDockApps)
        XCTAssertTrue(mac.publishStatus("Control granted", controlEnabled: true))
        try await Loopback.waitUntil { model.canLaunchDockApps }
        mac.stopHearingCurrentSession()
        try await Loopback.waitUntil { !model.isMacResponsive }
        let count = mac.received.filter { $0.kind == "launchApp" }.count
        model.launchDockApp(id: notes.id)
        XCTAssertFalse(model.dockLauncher.isLaunching)
        XCTAssertEqual(mac.received.filter { $0.kind == "launchApp" }.count, count)
    }

    func testTimeoutDoesNotRetryAndLateSuccessCannotReplaceIt() async throws {
        let model = DeskClientModel(keys: Loopback.store(MemoryKeychain()),
                                    preferences: MemoryRememberedMacStore(),
                                    dockLaunchTimeoutNanoseconds: 100_000_000)
        let mac = MockMac(), scene = UUID()
        defer { model.updateScene(scene, phase: nil); mac.stop() }
        model.updateScene(scene, phase: .active)
        try mac.start()
        try await Loopback.waitUntil { mac.endpoint != nil }
        model.connect(to: try XCTUnwrap(mac.endpoint), key: mac.key, name: "Dock timeout Mac")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
        XCTAssertTrue(mac.send(DeskMessage(kind: "apps", dockApps: [finder])))
        XCTAssertTrue(mac.publishStatus("Control granted", controlEnabled: true))
        try await Loopback.waitUntil { model.canLaunchDockApps }
        model.launchDockApp(id: finder.id)
        try await Loopback.waitUntil { model.dockLauncher.launchSucceeded == false }
        let timeout = model.dockLauncher.launchStatus
        XCTAssertTrue(timeout?.contains("Check your Mac") == true)
        let request = try XCTUnwrap(mac.received.first { $0.kind == "launchApp" })
        XCTAssertTrue(mac.send(result(for: request, succeeded: true, status: "Late success")))
        try await Loopback.pause(0.1)
        XCTAssertEqual(model.dockLauncher.launchStatus, timeout)
        XCTAssertEqual(mac.received.filter { $0.kind == "launchApp" }.count, 1)
    }

    func testReconnectForgetsCatalogAndRejectsPreviousSessionResult() async throws {
        let mac = MockMac()
        mac.keepsPairing = true
        let session = try await Loopback.discoveredSession(mac: mac)
        defer { session.close() }
        let model = session.model
        XCTAssertTrue(mac.send(DeskMessage(kind: "apps", dockApps: [finder])))
        XCTAssertTrue(mac.publishStatus("Control granted", controlEnabled: true))
        try await Loopback.waitUntil { model.canLaunchDockApps }
        model.launchDockApp(id: finder.id)
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "launchApp" } }
        let old = try XCTUnwrap(mac.received.first { $0.kind == "launchApp" })
        model.disconnect()
        XCTAssertTrue(model.dockApps.isEmpty)
        XCTAssertNil(model.dockLauncher.launchStatus)
        // A fresh real handshake and catalog make the new session independent of the old one.
        try mac.start(allowReconnect: true)
        try await Loopback.waitUntil { mac.endpoint != nil }
        model.connect(to: try XCTUnwrap(mac.endpoint), key: mac.key, name: "Reconnected Mac")
        try await Loopback.waitUntil(timeout: 15) { model.isLinked && mac.isConnected }
        XCTAssertFalse(model.dockLauncher.isAvailable)
        XCTAssertTrue(mac.send(DeskMessage(kind: "apps", dockApps: [finder])))
        XCTAssertTrue(mac.publishStatus("Control granted", controlEnabled: true))
        try await Loopback.waitUntil { model.canLaunchDockApps }
        model.launchDockApp(id: finder.id)
        try await Loopback.waitUntil { mac.received.filter { $0.kind == "launchApp" }.count == 2 }
        let current = try XCTUnwrap(mac.received.last { $0.kind == "launchApp" })
        XCTAssertNotEqual(current.appRequestID, old.appRequestID)
        XCTAssertTrue(mac.send(result(for: old, succeeded: true, status: "Old session success")))
        try await Loopback.pause(0.1)
        XCTAssertTrue(model.dockLauncher.isLaunching)
        XCTAssertTrue(mac.send(result(for: current, succeeded: true, status: "New session success")))
        try await Loopback.waitUntil { model.dockLauncher.launchSucceeded == true }
        XCTAssertEqual(model.dockLauncher.launchStatus, "New session success")
    }

    func testIconsArePNGOnlyBoundedDownsampledAndCachedWithCatalog() async throws {
        let good = try png(size: 256)
        let image = try XCTUnwrap(MacDockLauncherModel.decodeIcon(good))
        XCTAssertLessThanOrEqual(image.size.width, 96)
        XCTAssertNil(MacDockLauncherModel.decodeIcon(try png(size: 512)))
        XCTAssertNil(MacDockLauncherModel.decodeIcon(try XCTUnwrap(DeskFixtures.jpeg())))
        XCTAssertNil(MacDockLauncherModel.decodeIcon(Data("/Applications/Example.app".utf8)))
        let session = try await Loopback.discoveredSession()
        defer { session.close() }
        let app = DockAppInfo(id: "icon-app", name: "Icon App", iconPNG: good)
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "apps", dockApps: [app])))
        try await Loopback.waitUntil { session.model.dockLauncher.icons[app.id] != nil }
        let cached = try XCTUnwrap(session.model.dockLauncher.icons[app.id])
        XCTAssertTrue(session.mac.publishStatus("Unrelated grant update", controlEnabled: true))
        try await Loopback.waitUntil { session.model.isMacControlEnabled }
        XCTAssertTrue(session.model.dockLauncher.icons[app.id] === cached)
    }

    func testExplicitDestinationIsSentAndRemovedScreenNeverFallsBackSilently() async throws {
        let session = try await preparedSession(supportsPlacement: true)
        defer { session.close() }
        let model = session.model, mac = session.mac
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await Loopback.waitUntil { model.display(id: DeskFixtures.display.id) != nil }
        model.launchDockApp(id: finder.id, displayID: 99)
        XCTAssertFalse(model.dockLauncher.isLaunching)
        model.launchDockApp(id: finder.id, displayID: DeskFixtures.display.id)
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "launchApp" } }
        let request = try XCTUnwrap(mac.received.first { $0.kind == "launchApp" })
        XCTAssertEqual(request.displayID, DeskFixtures.display.id)
        XCTAssertTrue(mac.send(result(for: request, succeeded: true, status: "Opened on selected screen.")))
        try await Loopback.waitUntil { !model.dockLauncher.isLaunching }
        XCTAssertTrue(mac.publish(displays: []))
        try await Loopback.waitUntil { model.displays.isEmpty }
        model.launchDockApp(id: notes.id, displayID: DeskFixtures.display.id)
        try await Loopback.pause(0.1)
        XCTAssertEqual(mac.received.filter { $0.kind == "launchApp" }.count, 1,
                       "A missing destination must not silently launch on some other screen.")
    }

    func testLegacyCatalogCannotClaimPlacementAndKeepsCurrentLocationLaunchesWorking() async throws {
        let session = try await preparedSession()
        defer { session.close() }
        let model = session.model, mac = session.mac
        XCTAssertFalse(model.dockLauncher.supportsPlacement)
        XCTAssertTrue(mac.publish(displays: [DeskFixtures.display]))
        try await Loopback.waitUntil { model.display(id: DeskFixtures.display.id) != nil }
        model.launchDockApp(id: finder.id, displayID: DeskFixtures.display.id)
        try await Loopback.pause(0.1)
        XCTAssertFalse(model.dockLauncher.isLaunching)
        XCTAssertFalse(mac.received.contains { $0.kind == "launchApp" })
        model.launchDockApp(id: finder.id)
        try await Loopback.waitUntil { mac.received.contains { $0.kind == "launchApp" } }
        XCTAssertNil(mac.received.first { $0.kind == "launchApp" }?.displayID)
        model.disconnect()
        XCTAssertFalse(model.dockLauncher.supportsPlacement)
    }

    private func preparedSession(linkPolicy: LinkMonitor.Policy = .standard,
                                 supportsPlacement: Bool = false) async throws -> LoopbackSession {
        let session = try await Loopback.discoveredSession(linkPolicy: linkPolicy)
        XCTAssertTrue(session.mac.send(DeskMessage(kind: "apps", dockApps: [finder, notes],
                                                  appPlacement: supportsPlacement ? true : nil)))
        XCTAssertTrue(session.mac.publishStatus("Control granted", controlEnabled: true))
        try await Loopback.waitUntil { session.model.canLaunchDockApps }
        return session
    }

    private func result(for request: DeskMessage, appID: String? = nil, requestID: String? = nil,
                        succeeded: Bool, status: String) -> DeskMessage {
        DeskMessage(kind: "appLaunchResult", status: status, appID: appID ?? request.appID,
                    appRequestID: requestID ?? request.appRequestID, appLaunchSucceeded: succeeded)
    }

    private func png(size: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return try XCTUnwrap(renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }.pngData())
    }
}
