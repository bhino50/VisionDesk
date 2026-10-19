import Network
import XCTest
@testable import VisionDesk

/// The nearby list shows each Mac once, in a stable order, and keeps the Mac the wearer chose
/// while discovery stops and restarts around an attempt.
@MainActor
final class NearbyMacListTests: XCTestCase {
    private let serviceType = "_visiondesk._tcp"

    /// One Mac seen on two interfaces is one entry, under an ID the interface is not part of, and
    /// the endpoint kept for dialling is the one bound to no interface, whichever arrived first.
    func testAMacFoundOnSeveralInterfacesIsListedOnce() async throws {
        guard let interface = try await Loopback.anyInterface() else {
            throw XCTSkip("The system reported no network interface to find a service on.")
        }
        let bound = NWEndpoint.service(name: "Studio", type: serviceType, domain: "local.", interface: interface)
        let unbound = NWEndpoint.service(name: "Studio", type: serviceType, domain: "local.", interface: nil)
        for endpoints in [[bound, unbound], [unbound, bound]] {
            let peers = NearbyMacList.peers(from: endpoints)
            XCTAssertEqual(peers.map(\.name), ["Studio"])
            XCTAssertNil(try boundInterface(peers.first), "The endpoint bound to no interface is kept.")
        }
        XCTAssertEqual(NearbyMacList.peers(from: [bound]).first?.id, NearbyMacList.peers(from: [unbound]).first?.id,
                       "The interface a Mac was found on is not part of its ID.")
    }

    /// Different services are different Macs, listed by name as Finder would sort them, and an
    /// endpoint that is not a service names no Mac to pair with.
    func testDifferentMacsAreListedByNameAndOnlyServicesAreListed() {
        let peers = NearbyMacList.peers(from: [
            .service(name: "Studio 10", type: serviceType, domain: "local.", interface: nil),
            .service(name: "Studio 2", type: serviceType, domain: "local.", interface: nil),
            .service(name: "air", type: serviceType, domain: "local.", interface: nil),
            .service(name: "Studio 2", type: serviceType, domain: "example.com.", interface: nil),
            .hostPort(host: "127.0.0.1", port: 4_242)
        ])
        XCTAssertEqual(peers.map(\.name), ["air", "Studio 2", "Studio 2", "Studio 10"])
        XCTAssertEqual(Set(peers.map(\.id)).count, 4, "A service in another domain is another Mac.")
        XCTAssertEqual(NearbyMacList.peers(from: peers.reversed().map(\.endpoint)).map(\.id), peers.map(\.id),
                       "The order does not depend on the order discovery reported them in.")
    }

    /// Discovery stops while a Mac is dialled and restarts after a failure. Neither is the wearer
    /// choosing again, so the chosen Mac stays chosen while it is listed and while the list is
    /// empty; only a Mac that is gone gives way to the first one listed.
    func testTheChosenMacStaysChosenAcrossARestartedSearch() throws {
        let peers = NearbyMacList.peers(from: [
            .service(name: "Air", type: serviceType, domain: "local.", interface: nil),
            .service(name: "Studio", type: serviceType, domain: "local.", interface: nil)
        ])
        let studio = try XCTUnwrap(peers.first { $0.name == "Studio" }).id
        XCTAssertEqual(NearbyMacList.selection(keeping: studio, in: peers), studio)
        XCTAssertEqual(NearbyMacList.selection(keeping: studio, in: []), studio)
        XCTAssertEqual(NearbyMacList.selection(keeping: "gone", in: peers), peers.first?.id)
        XCTAssertEqual(NearbyMacList.selection(keeping: nil, in: peers), peers.first?.id)
        XCTAssertNil(NearbyMacList.selection(keeping: nil, in: []))
    }

    /// The interface an entry's endpoint is bound to; nil for one bound to none.
    private func boundInterface(_ mac: NearbyMac?) throws -> NWInterface? {
        let mac = try XCTUnwrap(mac)
        guard case let .service(_, _, _, interface) = mac.endpoint else {
            XCTFail("A nearby Mac is always a service.")
            return nil
        }
        return interface
    }
}
