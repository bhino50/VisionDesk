import DeskCore
import Foundation
import Network
@testable import DeskTransport
import XCTest

/// Reconnect-mode behavior for an unattended Mac.
///
/// The requirement these cover is narrow and worth stating: a listener that
/// outlives one authenticated session, so a headset this Mac already remembers
/// can come back on its own, over whatever network path the owner already has.
/// Nothing here opens a relay, forwards a port, or touches a VPN, and none of it
/// changes how a peer is authenticated — the same PSK TLS handshake is still the
/// only way in, which the wrong-key case below asserts directly.
@MainActor
final class DeskReconnectTests: XCTestCase {
    func testClientSurvivesSilentMacWhileItKeepsSendingHeartbeats() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 1, idleTimeout: 1)
        defer { server.stop() }
        var host: DeskConnection?
        server.onConnection = { host = $0 }
        try server.startLoopback(key: key, allowReconnect: true)
        let client = DeskConnection(endpoint: try await endpoint(for: server), key: key)
        defer { client.cancel() }
        var closed = false
        client.onState = { if case .disconnected = $0 { closed = true } }
        client.start()
        try await waitUntil { host != nil }
        // Longer than the old symmetric 10-second deadline. No video or status
        // leaves the host; only the client's production-direction heartbeat runs.
        for _ in 0..<36 {
            XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")))
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTAssertFalse(closed, "A paused screen must not drop a healthy client connection.")
    }

    func testAuthenticatedSilentPeerExpiresAndTheRememberedHeadsetCanReconnect() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 1, idleTimeout: 0.2)
        defer { server.stop() }
        var hosts: [DeskConnection] = []
        server.onConnection = { hosts.append($0) }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)
        let first = DeskConnection(endpoint: endpoint, key: key)
        defer { first.cancel() }
        var closed = false
        first.onState = { if case .disconnected = $0 { closed = true } }
        first.start()
        try await waitUntil { hosts.count == 1 }
        try await waitUntil { closed }
        XCTAssertNotNil(server.port, "The listener survives an idle session.")
        let second = DeskConnection(endpoint: endpoint, key: key)
        defer { second.cancel() }
        second.start()
        try await waitUntil { hosts.count == 2 }
    }

    func testCompletedHeartbeatsResetTheIdleDeadline() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 1, idleTimeout: 0.2)
        defer { server.stop() }
        var host: DeskConnection?
        var messages = 0, closed = false
        server.onConnection = { channel in
            host = channel
            channel.onMessage = { _ in messages += 1 }
            channel.onState = { if case .disconnected = $0 { closed = true } }
        }
        try server.startLoopback(key: key, allowReconnect: true)
        let client = DeskConnection(endpoint: try await endpoint(for: server), key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil { host != nil }
        for _ in 0..<8 {
            XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(messages, 8)
        XCTAssertFalse(closed, "Active heartbeats keep a session alive past the idle interval.")
        try await waitUntil { closed }
    }

    func testReconnectModeKeepsItsPortBoundAcrossSessions() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var hosts: [DeskConnection] = []
        var statuses: [String] = []
        server.onConnection = { hosts.append($0) }
        server.onStatus = { statuses.append($0) }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)
        let boundPort = try XCTUnwrap(server.port)

        let first = DeskConnection(endpoint: endpoint, key: key)
        first.start()
        try await waitUntil { hosts.count == 1 }
        XCTAssertEqual(server.port, boundPort, "A remembered session must not consume its listener.")

        var firstClosed = false
        hosts[0].onState = { if case .disconnected = $0 { firstClosed = true } }
        first.cancel()
        try await waitUntil { firstClosed }
        XCTAssertEqual(server.port, boundPort, "The same port must still be listening after a session ends.")
        XCTAssertTrue(statuses.contains("Disconnected. Waiting for the remembered Vision Pro to reconnect."))

        let second = DeskConnection(endpoint: endpoint, key: key)
        defer { second.cancel() }
        second.start()
        try await waitUntil { hosts.count == 2 }
        XCTAssertEqual(server.port, boundPort)
        XCTAssertFalse(hosts[1] === hosts[0])
    }

    func testReconnectModeRefusesASecondDeviceWhileOneIsActive() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var accepted = 0
        var host: DeskConnection?
        var hostClosed = false
        server.onConnection = { connection in
            accepted += 1
            host = connection
            connection.onState = { if case .disconnected = $0 { hostClosed = true } }
        }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)

        let first = DeskConnection(endpoint: endpoint, key: key)
        first.start()
        try await waitUntil { accepted == 1 }
        XCTAssertNotNil(host)

        // Holding the right key is not enough while a session is already up.
        let second = DeskConnection(endpoint: endpoint, key: key)
        defer { second.cancel() }
        var secondReady = false
        var secondClosed = false
        second.onState = {
            if case .ready = $0 { secondReady = true }
            if case .disconnected = $0 { secondClosed = true }
        }
        second.start()
        try await waitUntil(timeout: 12) { secondClosed }
        XCTAssertFalse(secondReady)
        XCTAssertEqual(accepted, 1)
        XCTAssertNotNil(server.port)

        first.cancel()
        try await waitUntil { hostClosed }
        let returning = DeskConnection(endpoint: endpoint, key: key)
        defer { returning.cancel() }
        returning.start()
        try await waitUntil { accepted == 2 }
    }

    func testReconnectModeRejectsTheWrongKeyAndStaysAvailable() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var accepted = 0
        server.onConnection = { _ in accepted += 1 }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)
        let boundPort = try XCTUnwrap(server.port)

        let wrong = DeskConnection(endpoint: endpoint, key: PairingKey.generate())
        defer { wrong.cancel() }
        var wrongReady = false
        var wrongClosed = false
        wrong.onState = {
            if case .ready = $0 { wrongReady = true }
            if case .disconnected = $0 { wrongClosed = true }
        }
        wrong.start()
        try await waitUntil(timeout: 12) { wrongClosed }
        XCTAssertFalse(wrongReady)
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(server.port, boundPort, "A refused handshake must not cost the listener.")

        let right = DeskConnection(endpoint: endpoint, key: key)
        defer { right.cancel() }
        right.start()
        try await waitUntil { accepted == 1 }
        XCTAssertEqual(server.port, boundPort)
    }

    func testReconnectModeStillBoundsPendingHandshakesAndRecoversAfterTimeout() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 0.8)
        defer { server.stop() }
        var accepted = 0
        server.onConnection = { _ in accepted += 1 }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)
        let boundPort = try XCTUnwrap(server.port)
        var rawClients: [NWConnection] = []
        var closed: Set<Int> = []
        defer { rawClients.forEach { $0.cancel() } }
        func addUnresponsiveClient(_ index: Int) {
            let raw = NWConnection(to: endpoint, using: .tcp)
            rawClients.append(raw)
            raw.start(queue: .main)
            raw.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                MainActor.assumeIsolated {
                    if complete || error != nil { closed.insert(index) }
                }
            }
        }
        for index in 0..<4 { addUnresponsiveClient(index) }
        try await waitUntil { server.pendingHandshakeCount == 4 }
        addUnresponsiveClient(4)
        try await waitUntil { closed.contains(4) }
        XCTAssertEqual(server.pendingHandshakeCount, 4, "The four-handshake cap still applies in reconnect mode.")
        XCTAssertTrue(closed.isDisjoint(with: Set(0..<4)))
        try await waitUntil { closed.count == 5 && server.pendingHandshakeCount == 0 }
        XCTAssertEqual(accepted, 0)
        XCTAssertEqual(server.port, boundPort)

        let right = DeskConnection(endpoint: endpoint, key: key)
        defer { right.cancel() }
        right.start()
        try await waitUntil { accepted == 1 }
        XCTAssertEqual(server.port, boundPort)
    }

    func testDefaultModeStillConsumesItsListenerAfterAuthentication() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var host: DeskConnection?
        var statuses: [String] = []
        server.onConnection = { host = $0 }
        server.onStatus = { statuses.append($0) }
        try server.startLoopback(key: key)
        let endpoint = try await endpoint(for: server)
        let client = DeskConnection(endpoint: endpoint, key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil { host != nil }
        XCTAssertNil(server.port, "One-session pairing keeps its current ephemeral behavior.")

        var closed = false
        host?.onState = { if case .disconnected = $0 { closed = true } }
        client.cancel()
        try await waitUntil { closed }
        XCTAssertNil(server.port)
        XCTAssertTrue(statuses.contains("Disconnected. Start pairing to reconnect."))
        XCTAssertFalse(statuses.contains("Available for the remembered Vision Pro to connect."))
    }

    func testStopCancelsTheSessionAndInvalidatesCallbacks() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        var host: DeskConnection?
        var statuses: [String] = []
        server.onConnection = { host = $0 }
        server.onStatus = { statuses.append($0) }
        server.onStopped = { _ in XCTFail("A deliberate stop is not a listener failure.") }
        try server.startLoopback(key: key, allowReconnect: true)
        let endpoint = try await endpoint(for: server)
        let client = DeskConnection(endpoint: endpoint, key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil { host != nil }

        var hostClosed = false
        host?.onState = { if case .disconnected = $0 { hostClosed = true } }
        server.stop()
        try await waitUntil { hostClosed }
        XCTAssertNil(server.port)
        XCTAssertEqual(statuses.last, "Stopped.")
        XCTAssertNil(server.onConnection)
        XCTAssertNil(server.onStatus)
        XCTAssertNil(server.onStopped)

        let delivered = statuses.count
        server.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(statuses.count, delivered, "A stopped server cannot deliver anything more.")
    }

    /// The only case here that leaves loopback, because pinning a port is exactly
    /// what a remote headset needs in order to dial this Mac at all.
    func testPinnedPortIsHonoredAndPortZeroIsRejected() async throws {
        let server = DeskServer()
        defer { server.stop() }
        var accepted = false
        var failure: String?
        server.onConnection = { _ in accepted = true }
        server.onStopped = { failure = $0 }

        XCTAssertThrowsError(try server.start(key: PairingKey.generate(), name: "VisionDesk Test", port: 0)) { error in
            XCTAssertEqual(error as? DeskServerError, .invalidPort)
            XCTAssertNotNil((error as? DeskServerError)?.errorDescription)
        }
        XCTAssertNil(server.port, "A rejected argument must not start anything.")
        XCTAssertNotNil(server.onConnection, "A rejected argument must not tear the server down either.")

        // Borrow a free port from the system, release it, then pin it.
        let probe = try NWListener(using: .tcp, on: .any)
        probe.newConnectionHandler = { $0.cancel() }
        probe.start(queue: .main)
        try await waitUntil { (probe.port?.rawValue ?? 0) > 0 }
        let pinned = try XCTUnwrap(probe.port?.rawValue)
        probe.cancel()

        let key = PairingKey.generate()
        try server.start(key: key, name: "VisionDesk Test \(UUID().uuidString)", port: pinned, allowReconnect: true, bindHost: "127.0.0.1")
        try await waitUntil(timeout: 12) { server.port != nil || failure != nil }
        XCTAssertNil(failure)
        XCTAssertEqual(server.port, pinned, "A pinned port is the address a remote headset dials.")

        let client = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: pinned))), key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil(timeout: 12) { accepted }
        XCTAssertEqual(server.port, pinned)
    }

    private func endpoint(for server: DeskServer) async throws -> NWEndpoint {
        try await waitUntil { server.port != nil }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: XCTUnwrap(server.port)))
        return .hostPort(host: "127.0.0.1", port: port)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for a local transport event.")
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum WaitError: Error { case timeout }
}
