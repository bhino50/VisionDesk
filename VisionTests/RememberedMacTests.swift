import DeskCore
import Foundation
import Network
import XCTest
@testable import VisionDesk

/// What the headset keeps about its saved Mac: a name and a route, in a form an earlier build still
/// reads, and nothing secret. These are the stored form and what the saved card dials.
@MainActor
final class RememberedMacTests: XCTestCase {
    private let serviceType = "_visiondesk._tcp"
    private var studioService: RememberedMac {
        RememberedMac(name: "Studio", route: .service(name: "Studio", type: serviceType, domain: "local."))
    }

    // MARK: Stored form

    func testBothKindsOfSavedMacReadBackAsWritten() throws {
        for mac in [RememberedMac(address: "100.64.0.42:58271", name: "Studio"), studioService] {
            let data = try JSONEncoder().encode(mac)
            XCTAssertEqual(try JSONDecoder().decode(RememberedMac.self, from: data), mac)
        }
    }

    /// A Mac saved by address also carries the address on its own, which is all an earlier build
    /// reads. A Mac saved by its service has no address to give.
    func testAnAddressStaysReadableByAnEarlierBuild() throws {
        let byAddress = try fields(of: RememberedMac(address: "100.64.0.42:58271", name: "Studio"))
        XCTAssertEqual(byAddress["address"] as? String, "100.64.0.42:58271")
        XCTAssertEqual(byAddress["name"] as? String, "Studio")
        XCTAssertNotNil(byAddress["route"])
        let byService = try fields(of: studioService)
        XCTAssertNil(byService["address"])
        XCTAssertEqual(byService["name"] as? String, "Studio")
        XCTAssertNotNil(byService["route"])
    }

    /// A record from before routes existed reads as a Mac saved by address. A route the model could
    /// not have made is not trusted: the address beside it is used if there is one, and otherwise
    /// the record does not read at all.
    func testEarlierAndDamagedRecordsReadSafely() throws {
        let legacy = Data(#"{"address":"100.64.0.42:58271","name":"Studio"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RememberedMac.self, from: legacy),
                       RememberedMac(address: "100.64.0.42:58271", name: "Studio"))
        let damagedWithAddress = Data(#"""
            {"name":"Studio","route":{"service":{"name":"","type":"","domain":"local."}},"address":"100.64.0.42:58271"}
            """#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RememberedMac.self, from: damagedWithAddress),
                       RememberedMac(address: "100.64.0.42:58271", name: "Studio"))
        let damagedAlone = Data(#"{"name":"Studio","route":{"address":{"_0":"Not An Address"}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RememberedMac.self, from: damagedAlone))
    }

    /// The production store over a suite of its own. A saved service reads back through a new
    /// store, as after a relaunch, and data that cannot be read is no saved Mac rather than a crash.
    func testThePreferenceStoreKeepsASavedServiceAcrossLaunches() throws {
        let suite = try Loopback.throwawayDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        UserDefaultsRememberedMacStore(defaults: suite.defaults).save(studioService)
        XCTAssertEqual(UserDefaultsRememberedMacStore(defaults: suite.defaults).load(), studioService)

        let key = UserDefaultsRememberedMacStore.rememberedMacKey
        suite.defaults.set(Data(#"{"name":"Studio","route":{"address":{"_0":"Not An Address"}}}"#.utf8), forKey: key)
        XCTAssertNil(UserDefaultsRememberedMacStore(defaults: suite.defaults).load())
        suite.defaults.set("not data", forKey: key)
        XCTAssertNil(UserDefaultsRememberedMacStore(defaults: suite.defaults).load())
    }

    // MARK: What the saved card dials and says

    /// An address is dialled at its host and port. A service is dialled bound to no interface, so
    /// the system finds it on whichever interface reaches it.
    func testASavedRouteDialsWhatItNames() {
        XCTAssertEqual(MacRoute.address("100.64.0.42:58271").endpoint, .hostPort(host: "100.64.0.42", port: 58_271))
        XCTAssertEqual(MacRoute.address("mac-studio.local:4242").endpoint, .hostPort(host: "mac-studio.local", port: 4_242))
        XCTAssertEqual(studioService.route.endpoint,
                       .service(name: "Studio", type: serviceType, domain: "local.", interface: nil))
        XCTAssertNil(MacRoute.address("Not An Address").endpoint)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 4_242)
        XCTAssertEqual(MacRoute(endpoint)?.endpoint, endpoint)
    }

    func testTheSavedCardSaysWhereTheMacIsReached() {
        XCTAssertEqual(SessionCopy.savedMacDetail(RememberedMac(address: "100.64.0.42:58271", name: "Studio")),
                       "100.64.0.42:58271")
        XCTAssertEqual(SessionCopy.savedMacDetail(studioService), "On this network")
    }

    /// A saved record that cannot be dialled — only damaged data could make one — says how to
    /// recover, and nothing is dialled.
    func testASavedMacThatCannotBeDialledSaysSoAndDialsNothing() {
        let log = ChannelLog()
        let preferences = MemoryRememberedMacStore(stored: RememberedMac(address: "Not An Address", name: "Studio"))
        let model = Loopback.model(preferences: preferences, makeConnection: Loopback.recordingFactory(log))
        let scene = UUID()
        defer { model.updateScene(scene, phase: nil) }
        model.updateScene(scene, phase: .active)
        XCTAssertTrue(model.canConnectRemembered)
        model.connectRemembered()
        XCTAssertFalse(model.isConnecting)
        XCTAssertTrue(log.channels.isEmpty)
        XCTAssertEqual(model.connectionMessage,
                       "The saved connection to Studio is no longer usable. \(SessionCopy.forgetSavedMacAdvice)")
        XCTAssertEqual(SessionCopy.forgetSavedMacAdvice, "Choose More, then Forget This Mac, and pair with it again.",
                       "The advice names the menu and the item the saved card shows.")
    }

    // MARK: Helpers

    private func fields(of mac: RememberedMac) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(mac))
        return try XCTUnwrap(object as? [String: Any])
    }
}
