import DeskCore
import Foundation
import Network
@testable import DeskTransport
import XCTest

/// Same-network hosting with a remembered key: one advertised listener that stays up across
/// sessions, admits local-link peers only, and lets each source hold one unauthenticated
/// handshake slot. Admission rules are checked as pure values. The listener cases bind real
/// sockets; the Bonjour case advertises a test service on the local link and dials it from this
/// Mac only.
@MainActor
final class PersistentLANListenerTests: XCTestCase {
    private let serviceType = "_visiondesk._tcp"

    // MARK: - Admission rules

    func testACGNATListenerTakesOneHandshakePerPrivatePeerAndNoPublicSources() {
        let admission = HandshakeAdmission(bindHost: "100.64.0.1", loopbackOnly: false)
        XCTAssertTrue(admission.requiresPrivatePeer)
        XCTAssertTrue(admission.limitsPerSource)
        XCTAssertTrue(admission.admits(peerHost: "100.101.102.103", pendingHosts: []))
        XCTAssertTrue(admission.admits(peerHost: "100.101.102.104", pendingHosts: ["100.101.102.103", nil]))
        XCTAssertFalse(admission.admits(peerHost: "100.101.102.103", pendingHosts: ["100.101.102.103"]))
        for peer in ["192.168.1.30", "10.24.0.9", "fd12:3456::9"] {
            XCTAssertTrue(admission.admits(peerHost: peer, pendingHosts: []), "Private ranges may differ across a VPN")
        }
        for peer in ["8.8.8.8", "127.0.0.1", "fe80::1"] {
            XCTAssertFalse(admission.admits(peerHost: peer, pendingHosts: []))
        }
        XCTAssertFalse(admission.admits(peerHost: nil, pendingHosts: []))
    }

    func testAListenerOnThisNetworkLetsEachSourceHoldOneHandshake() {
        for bindHost in [nil, "192.168.1.20"] as [String?] {
            let label = bindHost ?? "advertised"
            let admission = HandshakeAdmission(bindHost: bindHost, loopbackOnly: false)
            XCTAssertTrue(admission.limitsPerSource, label)
            XCTAssertTrue(admission.admits(peerHost: "192.168.1.30", pendingHosts: []), label)
            XCTAssertTrue(admission.admits(peerHost: "192.168.1.31", pendingHosts: ["192.168.1.30"]), label)
            XCTAssertTrue(admission.admits(peerHost: "fd00::30", pendingHosts: ["192.168.1.30"]), label)
            XCTAssertFalse(admission.admits(peerHost: "192.168.1.30", pendingHosts: ["192.168.1.31", "192.168.1.30"]), label)
            XCTAssertFalse(admission.admits(peerHost: nil, pendingHosts: []), "\(label): a source that cannot be named is refused")
        }
    }

    func testPrivateVPNBindingsAdmitPrivatePeersWithoutOpeningPublicSources() {
        for host in ["10.24.0.8", "172.20.0.8", "192.168.40.8", "100.64.0.8", "fd12:3456::8"] {
            let admission = HandshakeAdmission(bindHost: host, loopbackOnly: false)
            XCTAssertTrue(admission.requiresPrivatePeer)
            XCTAssertTrue(admission.limitsPerSource)
            for peer in ["10.24.0.9", "172.20.0.9", "192.168.40.9", "100.64.0.9", "fd12:3456::9"] {
                XCTAssertTrue(admission.admits(peerHost: peer, pendingHosts: []))
                XCTAssertFalse(admission.admits(peerHost: peer, pendingHosts: [peer]))
            }
            for peer in ["8.8.8.8", "127.0.0.1", "169.254.1.8", "fe80::8", "2001:db8::8", "ff02::8"] {
                XCTAssertFalse(admission.admits(peerHost: peer, pendingHosts: []))
            }
            XCTAssertFalse(admission.admits(peerHost: "fd12:3456::9", pendingHosts: ["FD12:3456:0:0:0:0:0:9"]),
                           "Equivalent IPv6 source text shares one handshake slot")
            XCTAssertFalse(admission.admits(peerHost: nil, pendingHosts: []))
        }
    }

    func testLoopbackListenersKeepAdmittingEveryHandshake() {
        let loopback = [HandshakeAdmission(bindHost: nil, loopbackOnly: true)]
            + ["127.0.0.1", "127.0.0.2", "::1", "[::1]", "localhost"].map {
                HandshakeAdmission(bindHost: $0, loopbackOnly: false)
            }
        for admission in loopback {
            XCTAssertFalse(admission.limitsPerSource)
            XCTAssertTrue(admission.admits(peerHost: "127.0.0.1", pendingHosts: ["127.0.0.1", "127.0.0.1"]))
            XCTAssertTrue(admission.admits(peerHost: nil, pendingHosts: []))
        }
        for host in ["128.0.0.1", "192.168.1.20", "::2", "100.64.0.1"] {
            XCTAssertFalse(HandshakeAdmission.isLoopback(host), host)
        }
    }

    func testSourcesAreNamedTheWayPendingHandshakesNameThem() {
        for endpoint in [NWEndpoint.hostPort(host: "192.168.1.30", port: 50_000), .hostPort(host: "fd00::30", port: 50_000)] {
            let pending = DeskConnection(connection: NWConnection(to: endpoint, using: .tcp))
            XCTAssertNotNil(HandshakeAdmission.host(of: endpoint))
            XCTAssertEqual(HandshakeAdmission.host(of: endpoint), pending.endpointHost)
        }
        XCTAssertEqual(HandshakeAdmission.host(of: .hostPort(host: "192.168.1.30", port: 50_000)), "192.168.1.30")
        XCTAssertNil(HandshakeAdmission.host(of: .service(name: "Mac", type: serviceType, domain: "local.", interface: nil)))
    }

    // MARK: - Listeners

    func testAnAddressBoundListenerIsNeverAdvertised() async throws {
        let server = DeskServer()
        defer { server.stop() }
        try server.start(key: PairingKey.generate(), name: "VisionDesk Test \(UUID().uuidString)",
                         allowReconnect: true, bindHost: "127.0.0.1")
        try await waitUntil { server.port != nil }
        XCTAssertNil(server.advertisedServiceName, "A listener bound to one address must not publish the others")
        XCTAssertFalse(server.acceptsLocalLinkOnly)

        try server.startLoopback(key: PairingKey.generate(), allowReconnect: true)
        try await waitUntil { server.port != nil }
        XCTAssertNil(server.advertisedServiceName)
        XCTAssertFalse(server.acceptsLocalLinkOnly)
    }

    /// One device cannot hold every handshake slot of the listener that stays up for the
    /// remembered headset. Raw TCP clients from one source (this Mac, over loopback) never send TLS.
    func testOneSourceCannotHoldMoreThanOneHandshakeSlot() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 5)
        defer { server.stop() }
        var accepted = 0
        server.onConnection = { _ in accepted += 1 }
        try server.start(key: key, name: "VisionDesk Test \(UUID().uuidString)", allowReconnect: true)
        try await waitUntil(timeout: 12) { server.port != nil }
        XCTAssertNotNil(server.advertisedServiceName)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(server.port)))
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        var raw: [NWConnection] = []
        var closed: Set<Int> = []
        defer { raw.forEach { $0.cancel() } }
        func addUnresponsiveClient(_ index: Int) {
            let connection = NWConnection(to: endpoint, using: .tcp)
            raw.append(connection)
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                MainActor.assumeIsolated {
                    if complete || error != nil { closed.insert(index) }
                }
            }
        }
        addUnresponsiveClient(0)
        try await waitUntil { server.pendingHandshakeCount == 1 }
        addUnresponsiveClient(1)
        try await waitUntil { closed.contains(1) }
        XCTAssertEqual(server.pendingHandshakeCount, 1, "A second slot from the same source is refused")
        XCTAssertFalse(closed.contains(0))

        // Once its slot is free, the same source is welcome again.
        raw[0].cancel()
        try await waitUntil { server.pendingHandshakeCount == 0 }
        let headset = DeskConnection(endpoint: endpoint, key: key)
        defer { headset.cancel() }
        headset.start()
        try await waitUntil { accepted == 1 }
    }

    /// The persistent same-network listener end to end: advertised under the Mac's name, local
    /// link only, refusing a second device mid-session, still up after the session ends, and found
    /// again by name with the same key, the way a headset that saved this Mac reconnects.
    func testARememberedListenerOnThisNetworkTakesTheSameHeadsetBackByName() async throws {
        let key = PairingKey.generate()
        // These clients send no heartbeats, so the session gets an idle allowance longer than the
        // test instead of the usual ten seconds.
        let server = DeskServer(handshakeTimeout: 10, idleTimeout: 60)
        defer { server.stop() }
        let name = "VisionDesk Test \(UUID().uuidString)"
        var hosts: [DeskConnection] = []
        var hostsClosed = 0
        var statuses: [String] = []
        server.onConnection = { connection in
            hosts.append(connection)
            connection.onState = { if case .disconnected = $0 { hostsClosed += 1 } }
        }
        server.onStatus = { statuses.append($0) }
        try server.start(key: key, name: name, allowReconnect: true)
        try await waitUntil(timeout: 12) { server.port != nil }
        let boundPort = server.port
        XCTAssertEqual(server.advertisedServiceName, name)
        XCTAssertTrue(server.acceptsLocalLinkOnly, "An advertised listener admits local-link peers only")
        XCTAssertEqual(statuses.last, "Available for the remembered Vision Pro to connect.")

        // Dialled by the saved service name, without browsing first.
        let saved = NWEndpoint.service(name: name, type: serviceType, domain: "local.", interface: nil)
        let first = DeskConnection(endpoint: saved, key: key)
        first.start()
        try await waitUntil(timeout: 12) { hosts.count == 1 }
        XCTAssertEqual(server.port, boundPort, "The session does not consume the listener")
        XCTAssertEqual(server.advertisedServiceName, name, "The Mac stays discoverable during a session")

        // Holding the right key is not enough while a session is active. The intruder gives up
        // after three seconds instead of ten.
        let intruder = DeskConnection(connection: NWConnection(to: saved, using: SecureParameters.make(key: key)),
                                      handshakeTimeout: 3, idleTimeout: nil)
        defer { intruder.cancel() }
        var intruderReady = false
        var intruderClosed = false
        intruder.onState = {
            if case .ready = $0 { intruderReady = true }
            if case .disconnected = $0 { intruderClosed = true }
        }
        intruder.start()
        try await waitUntil(timeout: 8) { intruderClosed }
        XCTAssertFalse(intruderReady)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hostsClosed, 0, "The active session is undisturbed")

        first.cancel()
        try await waitUntil { hostsClosed == 1 }
        XCTAssertTrue(statuses.contains("Disconnected. Waiting for the remembered Vision Pro to reconnect."))
        XCTAssertEqual(server.advertisedServiceName, name)

        let second = DeskConnection(endpoint: saved, key: key)
        defer { second.cancel() }
        second.start()
        try await waitUntil(timeout: 12) { hosts.count == 2 }
        XCTAssertEqual(server.port, boundPort)
        XCTAssertFalse(hosts[1] === hosts[0])
        XCTAssertEqual(hostsClosed, 1)
    }

    private func waitUntil(timeout: TimeInterval = 6, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for a local transport event.", file: file, line: line)
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum WaitError: Error { case timeout }
}
