import Foundation
import XCTest
import DeskCore

final class DockAppMessageTests: XCTestCase {
    func testCatalogIsBoundedUniqueAndRoundTrips() throws {
        let apps = (0..<64).map { DockAppInfo(id: "opaque-\($0)", name: "App \($0)") }
        let message = DeskMessage(kind: "apps", dockApps: apps)
        XCTAssertTrue(message.isValid)
        XCTAssertEqual(try JSONDecoder().decode(DeskMessage.self, from: JSONEncoder().encode(message)), message)
        XCTAssertFalse(DeskMessage(kind: "apps", dockApps: apps + [DockAppInfo(id: "65", name: "extra")]).isValid)
        XCTAssertFalse(DeskMessage(kind: "apps", dockApps: [apps[0], apps[0]]).isValid)
        XCTAssertTrue(DeskMessage(kind: "apps", dockApps: []).isValid)
        XCTAssertTrue(DeskMessage(kind: "apps", dockApps: [], appPlacement: true).isValid)
        XCTAssertFalse(DeskMessage(kind: "heartbeat", appPlacement: true).isValid)
        XCTAssertFalse(DeskMessage(kind: "capabilities", videoCodec: "h264", appPlacement: true).isValid)
        let placementCatalog = DeskMessage(kind: "apps", dockApps: apps, appPlacement: true)
        XCTAssertEqual(try JSONDecoder().decode(DeskMessage.self, from: JSONEncoder().encode(placementCatalog)), placementCatalog)
        XCTAssertFalse(DockAppInfo(id: "", name: "App").isValid)
        XCTAssertFalse(DockAppInfo(id: "id", name: String(repeating: "é", count: 129)).isValid)
        XCTAssertFalse(DockAppInfo(id: "id", name: "App", iconPNG: Data(repeating: 1, count: 16385)).isValid)
    }

    func testLaunchRequiresMatchedBoundedIdentifiersAndResult() {
        let request = UUID().uuidString
        XCTAssertTrue(DeskMessage(kind: "launchApp", appID: "opaque", appRequestID: request).isValid)
        XCTAssertFalse(DeskMessage(kind: "launchApp", appID: "opaque").isValid)
        XCTAssertFalse(DeskMessage(kind: "launchApp", appID: "opaque", appRequestID: "not-a-uuid").isValid)
        XCTAssertFalse(DeskMessage(kind: "launchApp", appID: String(repeating: "x", count: 129), appRequestID: request).isValid)
        XCTAssertTrue(DeskMessage(kind: "appLaunchResult", status: "Opened", appID: "opaque", appRequestID: request, appLaunchSucceeded: true).isValid)
        XCTAssertFalse(DeskMessage(kind: "appLaunchResult", status: "Opened", appID: "opaque", appRequestID: request).isValid)
        XCTAssertFalse(DeskMessage(kind: "heartbeat", appID: "opaque").isValid)
        XCTAssertFalse(DeskMessage(kind: "requestApps", dockLauncher: true).isValid)
        XCTAssertTrue(DeskMessage(kind: "capabilities", videoCodec: "h264", dockLauncher: true).isValid)
    }
}
