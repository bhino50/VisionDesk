import DeskCore
import Foundation
import Network
import XCTest
@testable import VisionDesk

/// A pending Stop finds its Mac again by route, and the route is all the preference store keeps
/// about it. These are the identity rules and the stored form, without a session.
@MainActor
final class MacRouteTests: XCTestCase {
    private let serviceType = "_visiondesk._tcp"

    // MARK: Identity

    /// A typed address, the same address as saved, and a host-and-port endpoint for it are one
    /// route. A different port is a different Mac.
    func testEveryWayOfWritingOneAddressIsOneRoute() throws {
        let typed = try XCTUnwrap(RemoteMacAddress(string: "Mac-Studio.Local"))
        let saved = try XCTUnwrap(RemoteMacAddress(string: typed.formatted))
        XCTAssertEqual(MacRoute(typed), MacRoute(saved))
        XCTAssertEqual(MacRoute(typed), .address("mac-studio.local:58271"))

        let loopback = try XCTUnwrap(RemoteMacAddress(string: "127.0.0.1:4242"))
        XCTAssertEqual(MacRoute(NWEndpoint.hostPort(host: "127.0.0.1", port: 4_242)), MacRoute(loopback))
        XCTAssertNotEqual(MacRoute(try XCTUnwrap(RemoteMacAddress(string: "127.0.0.1:4243"))), MacRoute(loopback))
    }

    /// A nearby Mac is its Bonjour service. The interface it was found on is not part of the
    /// route, and a service is never the same route as an address.
    func testANearbyMacIsOneRouteOnEveryInterfaceAndNeverAnAddress() async throws {
        let route = try XCTUnwrap(MacRoute(.service(name: "Studio", type: serviceType, domain: "local.", interface: nil)))
        XCTAssertEqual(route, .service(name: "Studio", type: serviceType, domain: "local."))
        XCTAssertNotEqual(route, MacRoute(.service(name: "Studio (2)", type: serviceType, domain: "local.", interface: nil)))
        XCTAssertNotEqual(route, .address("studio.local:58271"))

        guard let interface = try await Loopback.anyInterface() else {
            throw XCTSkip("The system reported no network interface to find a service on.")
        }
        XCTAssertEqual(MacRoute(.service(name: "Studio", type: serviceType, domain: "local.", interface: interface)),
                       route, "The interface a service was found on is not part of its route.")
    }

    // MARK: Stored form

    func testRoutesReadBackExactlyAsWritten() throws {
        let routes: Set<MacRoute> = [
            .address("100.64.0.42:58271"), .address("[fd7a:115c:a1e0::1]:58271"),
            .service(name: "Studio", type: serviceType, domain: "local.")
        ]
        let data = try XCTUnwrap(PendingStopsCodec.encode(routes))
        XCTAssertEqual(PendingStopsCodec.decode(data), routes)
        XCTAssertEqual(PendingStopsCodec.encode(routes), data, "The same routes are always written as the same bytes.")
    }

    /// Invalid JSON and entries are ignored; oversized records conservatively preserve Stop.
    func testUnreadableStoredRoutesNeverStopTheApp() throws {
        XCTAssertEqual(PendingStopsCodec.decode(nil), [])
        for corrupt in [Data(), Data("not json".utf8), Data("[".utf8), Data(repeating: 0xFF, count: 64),
                        Data("{\"address\":{\"_0\":\"127.0.0.1:4242\"}}".utf8)] {
            XCTAssertEqual(PendingStopsCodec.decode(corrupt), [])
        }
        XCTAssertEqual(PendingStopsCodec.decode(Data(repeating: 0x20, count: PendingStopsCodec.maximumBytes + 1)), [PendingStopsCodec.overflowStop])

        let good = MacRoute.address("127.0.0.1:4242")
        let goodEntry = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        let mixed = """
            [\(goodEntry), 17, null, {"unknown": {}}, {"address": {"_0": "Not An Address"}},
             {"address": {"_0": "127.0.0.1"}}, {"service": {"name": "", "type": "\(serviceType)", "domain": "local."}}]
            """
        XCTAssertEqual(PendingStopsCodec.decode(Data(mixed.utf8)), [good], "Only the valid, canonical entry is kept.")

        let many = (1...(PendingStopsCodec.maximumRoutes + 10)).map { MacRoute.address("127.0.0.1:\($0)") }
        XCTAssertEqual(PendingStopsCodec.decode(try JSONEncoder().encode(many)), [PendingStopsCodec.overflowStop])
    }

    func testOverflowPersistsAStopForEveryRouteAcrossRelaunch() throws {
        let routes = Set((1...65).map { MacRoute.address("127.0.0.1:\($0)") })
        let encoded = try XCTUnwrap(PendingStopsCodec.encode(routes))
        XCTAssertLessThanOrEqual(encoded.count, PendingStopsCodec.maximumBytes)
        let restored = PendingStopsCodec.decode(encoded)
        XCTAssertEqual(restored, [PendingStopsCodec.overflowStop])
        for route in routes {
            XCTAssertTrue(PendingStopsCodec.requiresStop(for: route, in: restored))
        }
        XCTAssertTrue(PendingStopsCodec.requiresStop(for: .address("new-mac.local:58271"), in: restored))
        XCTAssertEqual(PendingStopsCodec.decode(PendingStopsCodec.encode(restored)), restored)
    }

    func testByteOverflowFailsClosedAndLegacyRoutesStillRoundTrip() throws {
        // JSON escaping makes these valid bounded fields exceed the byte limit below 64 routes.
        let field = String(repeating: "\\", count: 250)
        let routes = Set((1...60).map {
            MacRoute.service(name: "\($0)" + field, type: field, domain: field)
        })
        XCTAssertTrue(routes.allSatisfy(\.isValid))
        let legacy = try JSONEncoder().encode(Array(routes))
        XCTAssertGreaterThan(legacy.count, PendingStopsCodec.maximumBytes)
        XCTAssertEqual(PendingStopsCodec.decode(legacy), [PendingStopsCodec.overflowStop])
        XCTAssertEqual(PendingStopsCodec.decode(PendingStopsCodec.encode(routes)), [PendingStopsCodec.overflowStop])
        let single: Set<MacRoute> = [.address("studio.local:58271")]
        XCTAssertEqual(PendingStopsCodec.decode(PendingStopsCodec.encode(single)), single)
    }

    /// The production store over a suite of its own: routes are kept apart from the saved Mac,
    /// Forget does not clear them, an empty set removes the record, and a value of the wrong type
    /// or unreadable bytes read as no routes.
    func testThePreferenceStoreKeepsPendingStopsApartFromTheSavedMac() throws {
        let suite = try Loopback.throwawayDefaults()
        defer { suite.defaults.removePersistentDomain(forName: suite.name) }
        let store = UserDefaultsRememberedMacStore(defaults: suite.defaults)
        let key = UserDefaultsRememberedMacStore.stoppedRoutesKey
        let routes: Set<MacRoute> = [.address("127.0.0.1:4242"),
                                     .service(name: "Studio", type: serviceType, domain: "local.")]

        store.save(RememberedMac(address: "127.0.0.1:4242", name: "Studio"))
        store.saveStoppedRoutes(routes)
        XCTAssertEqual(UserDefaultsRememberedMacStore(defaults: suite.defaults).loadStoppedRoutes(), routes)
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertEqual(store.loadStoppedRoutes(), routes, "Forgetting the saved Mac does not forget a pending Stop.")

        store.saveStoppedRoutes([])
        XCTAssertNil(suite.defaults.object(forKey: key), "No pending Stop leaves no record.")
        suite.defaults.set("not data", forKey: key)
        XCTAssertEqual(store.loadStoppedRoutes(), [])
        suite.defaults.set(Data("garbage".utf8), forKey: key)
        XCTAssertEqual(store.loadStoppedRoutes(), [])
    }
}
