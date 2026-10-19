import DeskCore
import Combine
import Foundation
import Network
@testable import DeskTransport
import XCTest

@MainActor
final class DeskConnectionTests: XCTestCase {
    func testFourDisplaysEachHaveCapacityForASimultaneousLargeFrame() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var displays: [UInt32] = []
        host.onMessage = { if let id = $0.displayID { displays.append(id) } }
        for id in UInt32(1)...4 {
            XCTAssertTrue(client.send(DeskMessage(kind: "frame", displayID: id,
                                                  jpeg: Data(repeating: UInt8(id), count: 160_000))),
                          "One display cannot consume another display's frame budget.")
        }
        XCTAssertEqual(client.droppedFrameCount, 0)
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")))
        try await waitUntil { displays.count == 4 && client.pendingBytes == 0 }
        XCTAssertEqual(displays, [1, 2, 3, 4])
    }

    func testBonjourDiscoveryPublishesConnectableEndpointAndStopsCleanly() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        let browser = DeskBrowser()
        defer { browser.stop(); server.stop() }
        let name = "VisionDesk Test \(UUID().uuidString)"
        var accepted = false
        server.onConnection = { _ in accepted = true }
        try server.start(key: key, name: name)
        browser.start()
        func matchingResult() -> NWBrowser.Result? {
            browser.results.first {
                if case let .service(found, _, _, _) = $0.endpoint { return found == name }
                return false
            }
        }
        try await waitUntil(timeout: 12) { matchingResult() != nil }
        let result = try XCTUnwrap(matchingResult())
        let client = DeskConnection(endpoint: result.endpoint, key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil { accepted }
        var publications = 0
        let observation = browser.$results.sink { _ in publications += 1 }
        defer { observation.cancel() }
        browser.stop()
        XCTAssertTrue(browser.results.isEmpty)
        let afterStop = publications
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(publications, afterStop)
        XCTAssertEqual(browser.status, "Discovery stopped.")
    }

    func testEncryptedLoopbackPreservesFourDisplayFramesAndControlOrder() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var hostMessages: [DeskMessage] = []
        var clientMessages: [DeskMessage] = []
        host.onMessage = { [weak host] message in
            hostMessages.append(message)
            host?.send(DeskMessage(kind: "status", status: message.text, controlEnabled: true))
        }
        client.onMessage = { clientMessages.append($0) }
        XCTAssertNil(server.port, "Authenticated sessions stop discovery and further admission.")
        for index in 0..<20 {
            XCTAssertTrue(client.send(DeskMessage(kind: "input", displayID: UInt32(index % 4 + 1), action: "text", text: "event-\(index)")))
        }
        try await waitUntil { clientMessages.count == 20 }
        XCTAssertEqual(hostMessages.compactMap(\.text), (0..<20).map { "event-\($0)" })
        XCTAssertEqual(clientMessages.compactMap(\.status), (0..<20).map { "event-\($0)" })
        for id in UInt32(1)...4 {
            XCTAssertTrue(host.send(DeskMessage(kind: "frame", displayID: id, jpeg: Data(repeating: UInt8(id), count: 131_072))))
            // This is an ordering test, not a burst/backpressure test. Drain each display.
            try await waitUntil { clientMessages.count == 20 + Int(id) }
        }
        try await waitUntil { clientMessages.count == 24 }
        let frames = Array(clientMessages.suffix(4))
        XCTAssertEqual(frames.compactMap(\.displayID), [1, 2, 3, 4])
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.jpeg, Data(repeating: UInt8(index + 1), count: 131_072))
        }
        var disconnects = 0
        var hostDisconnected = false
        client.onState = { if case .disconnected = $0 { disconnects += 1 } }
        host.onState = { if case .disconnected = $0 { hostDisconnected = true } }
        client.cancel()
        client.cancel()
        try await waitUntil { hostDisconnected }
        XCTAssertEqual(disconnects, 1)
        XCTAssertFalse(client.send(DeskMessage(kind: "heartbeat")))
    }

    func testWrongKeyCannotAuthenticateOrConsumeThePairingSession() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var accepted = 0
        server.onConnection = { _ in accepted += 1 }
        try server.startLoopback(key: key)
        let endpoint = try await endpoint(for: server)
        let wrong = DeskConnection(endpoint: endpoint, key: PairingKey.generate())
        defer { wrong.cancel() }
        var wrongReady = false
        var wrongClosed = false
        wrong.onState = { state in
            if case .ready = state { wrongReady = true }
            if case .disconnected = state { wrongClosed = true }
        }
        wrong.start()
        try await waitUntil(timeout: 12) { wrongClosed }
        XCTAssertFalse(wrongReady)
        XCTAssertEqual(accepted, 0)
        XCTAssertNotNil(server.port)
        let right = DeskConnection(endpoint: endpoint, key: key)
        defer { right.cancel() }
        right.start()
        try await waitUntil { accepted == 1 }
        XCTAssertNil(server.port)
    }

    func testVideoBackpressureDropsOnlyVideoAndResumesAfterDrain() async throws {
        let cap = 128 * 1_024
        let (server, client, host) = try await connectedPair(clientPendingLimit: cap)
        defer { client.cancel(); server.stop() }
        var messages: [DeskMessage] = []
        var disconnected = false
        host.onMessage = { messages.append($0) }
        client.onState = { if case .disconnected = $0 { disconnected = true } }
        let frame = DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 15, count: 40_000))
        XCTAssertTrue(client.send(frame))
        // Main-actor serialization keeps send completions from draining this burst.
        XCTAssertFalse(client.send(frame))
        XCTAssertEqual(client.droppedFrameCount, 1)
        XCTAssertTrue(client.send(DeskMessage(kind: "status", status: "Control still fits", controlEnabled: false)))
        XCTAssertLessThanOrEqual(client.pendingBytes, cap)
        XCTAssertFalse(disconnected)
        try await waitUntil { messages.count == 2 && client.pendingBytes == 0 }
        XCTAssertEqual(messages.map(\.kind), ["frame", "status"])
        XCTAssertTrue(client.send(frame))
        try await waitUntil { messages.count == 3 }
        XCTAssertFalse(disconnected)
    }

    func testDefaultScreenQueueDropsEarlyButAllowsOneLargeFrameAndControl() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var received: [DeskMessage] = []
        host.onMessage = { received.append($0) }
        let frame = DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 15, count: 160_000))
        XCTAssertTrue(client.send(frame))
        XCTAssertTrue(client.send(frame))
        XCTAssertFalse(client.send(frame), "screen content must drop before building a multi-megabyte backlog")
        XCTAssertLessThanOrEqual(client.pendingBytes, 512 * 1_024)
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")), "control retains its reserved capacity")
        try await waitUntil { received.count == 3 && client.pendingBytes == 0 }
        XCTAssertEqual(received.map(\.kind), ["frame", "frame", "heartbeat"])

        let large = DeskMessage(kind: "frame", displayID: 1, jpeg: Data(repeating: 31, count: 1_024 * 1_024))
        XCTAssertTrue(client.send(large), "one large independently decodable frame may use an empty queue")
        XCTAssertFalse(client.send(frame), "a large frame must not authorize a backlog behind it")
        XCTAssertTrue(client.send(DeskMessage(kind: "stop")))
        try await waitUntil { received.count == 5 && client.pendingBytes == 0 }
        XCTAssertEqual(received.suffix(2).map(\.kind), ["frame", "stop"])
        XCTAssertTrue(client.send(frame), "screen content resumes after the queue drains")
        try await waitUntil { received.count == 6 }
    }

    func testControlRoundTripsStayResponsiveDuringFourDisplayVideoTraffic() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var sentAt: [String: TimeInterval] = [:]
        var receiptDelays: [Double] = []
        var roundTrips: [Double] = []
        var receivedVideoFrames = 0
        var attemptedVideoFrames = 0
        var deliveredInputs: [String] = []
        host.onMessage = { message in
            guard message.kind == "input", let label = message.text, let start = sentAt[label] else { return }
            deliveredInputs.append(label)
            receiptDelays.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            host.send(DeskMessage(kind: "status", status: label))
        }
        client.onMessage = { message in
            if message.kind == "frame" { receivedVideoFrames += 1 }
            if let label = message.status, let start = sentAt[label] {
                roundTrips.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
        }
        // Synthetic payloads exercise TLS/framing load, not screen capture or bitmap decoding.
        let frames = (UInt32(1)...4).map {
            DeskMessage(kind: "frame", displayID: $0, jpeg: Data(repeating: UInt8($0), count: 24_000))
        }
        let video = Task { @MainActor in
            for _ in 0..<60 {
                if Task.isCancelled { return }
                for frame in frames { attemptedVideoFrames += 1; host.send(frame) }
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
        defer { video.cancel() }
        for index in 0..<120 {
            let label = "probe-\(index)"
            sentAt[label] = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(client.send(DeskMessage(kind: "input", displayID: UInt32(index % 4 + 1), action: "text", text: label)))
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        await video.value
        try await waitUntil { roundTrips.count == 120 }
        guard receiptDelays.count == 120, roundTrips.count == 120 else {
            XCTFail("Every probe must have both a host receipt and a round trip before reporting percentiles")
            return
        }
        XCTAssertEqual(deliveredInputs, (0..<120).map { "probe-\($0)" })
        XCTAssertGreaterThan(receivedVideoFrames, 120, "all four streams must produce sustained traffic during the probes")
        let sorted = roundTrips.sorted()
        XCTAssertLessThan(sorted[114], 500, "a gross control stall must not hide inside a successful delivery count")
        if let path = ProcessInfo.processInfo.environment["VISION_DESK_LATENCY_REPORT_PATH"] {
            let receipts = receiptDelays.sorted()
            let report: [String: Any] = [
                "scope": "TLS loopback, shared main actor, four synthetic video streams; no Quartz input or bitmap decode",
                "inputProbes": roundTrips.count, "attemptedVideoFrames": attemptedVideoFrames,
                "receivedVideoFrames": receivedVideoFrames,
                "receiptMedianMilliseconds": receipts[60], "receiptP95Milliseconds": receipts[114],
                "roundTripMedianMilliseconds": sorted[60], "roundTripP95Milliseconds": sorted[114],
                "physicalHeadsetLatencyMeasured": false
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testExhaustingControlReserveClosesOnceAndReleasesPendingMemory() async throws {
        let cap = 128 * 1_024
        let (server, client, _) = try await connectedPair(clientPendingLimit: cap)
        defer { client.cancel(); server.stop() }
        var disconnects = 0
        client.onState = { if case .disconnected = $0 { disconnects += 1 } }
        let status = DeskMessage(kind: "status", status: String(repeating: "a", count: 1_024))
        var accepted = 0
        while accepted < 200, client.send(status) { accepted += 1 }
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertLessThan(accepted, 200)
        XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(client.pendingBytes, 0)
        XCTAssertFalse(client.send(DeskMessage(kind: "heartbeat")))
        client.cancel()
        XCTAssertEqual(disconnects, 1)
    }

    func testInvalidLocalMessageReturnsFalseWithoutDisconnecting() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var received = false
        host.onMessage = { _ in received = true }
        XCTAssertFalse(client.send(DeskMessage(kind: "input", displayID: 1, x: 2, y: 0, action: "move")))
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")))
        try await waitUntil { received }
    }

    func testFragmentedHeadersAndCoalescedFramesPreserveBoundaries() async throws {
        let (server, raw, host) = try await connectedRawPair()
        defer { raw.cancel(); server.stop() }
        var received: [DeskMessage] = []
        host.onMessage = { received.append($0) }
        let first = try FrameCodec.encode(DeskMessage(kind: "frame", displayID: 1, jpeg: Data([1, 2, 3])))
        let second = try FrameCodec.encode(DeskMessage(kind: "frame", displayID: 4, jpeg: Data([4, 5, 6])))
        raw.send(content: Data(first.prefix(2)), completion: .contentProcessed { _ in })
        var remainder = Data(first.dropFirst(2))
        remainder.append(second)
        raw.send(content: remainder, completion: .contentProcessed { _ in })
        try await waitUntil { received.count == 2 }
        XCTAssertEqual(received.compactMap(\.displayID), [1, 4])
        XCTAssertEqual(received.compactMap(\.jpeg), [Data([1, 2, 3]), Data([4, 5, 6])])
    }

    func testInvalidLengthAndCrossFrameAbuseNeverReachApplication() async throws {
        for header in [Data([0, 0, 0, 0]), Data([0, 64, 0, 1]), Data([255, 255, 255, 255])] {
            let reason = try await rejectionReason(for: header)
            XCTAssertEqual(reason, "Invalid message length.")
        }
        let valid = try FrameCodec.encode(DeskMessage(kind: "heartbeat"))
        // A malformed first frame cannot be bypassed by appending a valid second one.
        var invalid = Data([0, 0, 0, 2, 123, 125])
        invalid.append(valid)
        let reason = try await rejectionReason(for: invalid)
        XCTAssertEqual(reason, "Invalid message.")
    }

    func testTruncatedAndStalledFramesCloseAuthenticatedConnection() async throws {
        for frame in [Data([0, 0]), Data([0, 0, 0, 20, 123, 125])] {
            let reason = try await rejectionReason(for: frame, complete: true)
            XCTAssertEqual(reason, "Truncated frame.")
        }
        let reason = try await rejectionReason(for: Data([0, 0]), frameTimeout: 0.15)
        XCTAssertEqual(reason, "Truncated frame.")
    }

    func testCompletedFrameCancelsDeadlineAndAllowsIdleConnection() async throws {
        let (server, raw, host) = try await connectedRawPair(frameTimeout: 0.1)
        defer { raw.cancel(); server.stop() }
        var received = false
        var disconnected = false
        host.onMessage = { _ in received = true }
        host.onState = { if case .disconnected = $0 { disconnected = true } }
        raw.send(content: try FrameCodec.encode(DeskMessage(kind: "heartbeat")), completion: .contentProcessed { _ in })
        try await waitUntil { received }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(disconnected)
    }

    func testFourPendingHandshakesLimitAndTimeoutLeaveSessionAvailable() async throws {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 0.8)
        defer { server.stop() }
        var accepted = 0
        server.onConnection = { _ in accepted += 1 }
        try server.startLoopback(key: key)
        let endpoint = try await endpoint(for: server)
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
        XCTAssertEqual(server.pendingHandshakeCount, 4)
        XCTAssertTrue(closed.isDisjoint(with: Set(0..<4)))
        try await waitUntil { closed.count == 5 && server.pendingHandshakeCount == 0 }
        XCTAssertEqual(accepted, 0)
        XCTAssertNotNil(server.port)
        let right = DeskConnection(endpoint: endpoint, key: key)
        defer { right.cancel() }
        right.start()
        try await waitUntil { accepted == 1 }
    }

    func testOutgoingHandshakeDeadlineCoversServerThatNeverNegotiatesTLS() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        var rawServer: NWConnection?
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                rawServer = connection
                connection.start(queue: .main)
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); rawServer?.cancel() }
        try await waitUntil { listener.port != nil }
        let port = try XCTUnwrap(listener.port)
        let rawClient = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: SecureParameters.make(key: PairingKey.generate()))
        let client = DeskConnection(connection: rawClient, handshakeTimeout: 0.15)
        defer { client.cancel() }
        var ready = false
        var reason: String?
        client.onState = {
            if case .ready = $0 { ready = true }
            if case let .disconnected(value) = $0 { reason = value }
        }
        client.start()
        try await waitUntil { reason != nil }
        XCTAssertFalse(ready)
        XCTAssertTrue(reason?.contains("timed out") == true)
    }

    func testStoppingFromAuthenticationStatusCannotDeliverObsoleteConnection() async throws {
        let key = PairingKey.generate()
        let server = DeskServer()
        defer { server.stop() }
        var accepted = 0
        var stopped = false
        server.onConnection = { _ in accepted += 1 }
        server.onStatus = { status in
            if status == "Secure connection established." {
                stopped = true
                server.stop()
            }
        }
        try server.startLoopback(key: key)
        let client = DeskConnection(endpoint: try await endpoint(for: server), key: key)
        defer { client.cancel() }
        client.start()
        try await waitUntil { stopped }
        XCTAssertEqual(accepted, 0)
        XCTAssertNil(server.port)
    }

    // MARK: Per-display screen capacity

    /// A keyframe large enough to exceed one display's 512 KiB reservation once JSON base64 has
    /// inflated it by a third. `payloadBytes` is the compressed access unit, not the wire size.
    private func keyframe(_ displayID: UInt32, payloadBytes: Int, sequence: UInt64 = 1) -> DeskMessage {
        // One AVCC unit: a four-byte big-endian length, then an IDR slice header (type 5).
        let nalLength = payloadBytes - EncodedVideoFrame.lengthPrefixBytes
        var payload = Data([UInt8(nalLength >> 24 & 0xFF), UInt8(nalLength >> 16 & 0xFF),
                            UInt8(nalLength >> 8 & 0xFF), UInt8(nalLength & 0xFF), 0x65])
        payload.append(Data(repeating: UInt8(displayID), count: nalLength - 1))
        let frame = EncodedVideoFrame(width: 1_920, height: 1_080, sequence: sequence, isKeyframe: true,
                                      payload: payload, sps: Data([0x67, 0x42, 0x00, 0x1F]), pps: Data([0x68, 0xCE, 0x3C, 0x80]))
        XCTAssertTrue(frame.isValid, "the fixture itself must satisfy every wire bound")
        return DeskMessage(kind: "video", displayID: displayID, video: frame)
    }

    private func jpeg(_ displayID: UInt32, bytes: Int) -> DeskMessage {
        DeskMessage(kind: "frame", displayID: displayID, jpeg: Data(repeating: UInt8(displayID), count: bytes))
    }

    /// Every display must be able to place one oversize keyframe in the same main-actor turn.
    ///
    /// Four displays emit an IDR together whenever a client attaches or renegotiates. Sharing a
    /// single 512 KiB exception meant only the first was admitted; each drop then provoked
    /// another equally large keyframe, so the losing displays never painted at all.
    func testSimultaneousOversizeKeyframesReachEveryDisplay() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var arrived: [UInt32] = []
        host.onMessage = { if $0.kind == "video", let id = $0.displayID { arrived.append(id) } }
        // 700 KB compressed becomes ~933 KB of base64, well past one display's reservation.
        for id in UInt32(1)...4 {
            XCTAssertTrue(client.send(keyframe(id, payloadBytes: 700_000)),
                          "display \(id) must keep its own oversize allowance during a keyframe storm")
        }
        XCTAssertEqual(client.droppedFrameCount, 0)
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")), "the control reserve survives four oversize keyframes")
        try await waitUntil { arrived.count == 4 && client.pendingBytes == 0 }
        XCTAssertEqual(arrived, [1, 2, 3, 4])
    }

    /// A recovery keyframe must not wait for unrelated displays to drain.
    ///
    /// The previous rule granted the oversize exception only when the whole screen queue was
    /// empty, so a display recovering from a loss was refused for as long as any other display
    /// had bytes in flight — exactly when recovery matters.
    func testRecoveryKeyframeEntersWhileOtherDisplaysStillHaveNormalFramesPending() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var arrived: [UInt32] = []
        host.onMessage = { if let id = $0.displayID { arrived.append(id) } }
        for id in UInt32(2)...4 {
            XCTAssertTrue(client.send(jpeg(id, bytes: 300_000)), "ordinary frames occupy three displays")
        }
        XCTAssertGreaterThan(client.pendingBytes, 0, "the other displays must still be in flight")
        XCTAssertTrue(client.send(keyframe(1, payloadBytes: 700_000)),
                      "a recovery keyframe may use the shared surplus while other displays are busy")
        XCTAssertEqual(client.droppedFrameCount, 0)
        try await waitUntil { arrived.count == 4 && client.pendingBytes == 0 }
        XCTAssertEqual(arrived.sorted(), [1, 2, 3, 4])
    }

    /// Borrowing the surplus is bounded in both directions: the borrower cannot queue behind its
    /// own oversize frame, and it cannot spend capacity the other three displays are entitled to.
    func testOversizeFrameNeitherQueuesBehindItselfNorConsumesAnotherDisplaysReservation() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var arrived: [UInt32] = []
        host.onMessage = { if let id = $0.displayID { arrived.append(id) } }
        // 3 MB of JPEG is 4 MB on the wire: far past a reservation, and most of the surplus.
        XCTAssertTrue(client.send(jpeg(1, bytes: 3_000_000)), "an empty display may borrow the surplus")
        XCTAssertFalse(client.send(jpeg(1, bytes: 300_000)),
                       "a borrowed frame must not authorize a backlog queued behind it")
        XCTAssertEqual(client.droppedFrameCount, 1)
        for id in UInt32(2)...4 {
            XCTAssertTrue(client.send(jpeg(id, bytes: 375_000)),
                          "display \(id) keeps its full reservation while display 1 holds the surplus")
        }
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")), "control is never reachable from screen content")
        XCTAssertLessThanOrEqual(client.pendingBytes, 8 * 1_024 * 1_024)
        try await waitUntil { arrived.count == 4 && client.pendingBytes == 0 }
        XCTAssertEqual(arrived, [1, 2, 3, 4])
    }

    /// Pins the worst case the admission policy can reach, so a later change to one bound cannot
    /// quietly widen the queue. These are byte ceilings computed from the policy's own constants,
    /// not a throughput or latency measurement of any network.
    func testWorstCaseScreenBacklogStaysInsideTheCeilingAndSparesTheControlReserve() async throws {
        let totalLimit = 8 * 1_024 * 1_024
        let controlReserve = 65_536
        let reservation = 512 * 1_024
        let screenCeiling = totalLimit - controlReserve
        let surplus = screenCeiling - reservation * DeskConnection.maximumSharedDisplays
        // One display borrowing the whole surplus, plus a full reservation for each of the
        // others, is exactly the ceiling: the policy can never exceed it, and never erodes
        // the control reserve to reach it.
        let worstCase = (reservation + surplus) + reservation * (DeskConnection.maximumSharedDisplays - 1)
        XCTAssertEqual(worstCase, screenCeiling)
        XCTAssertEqual(totalLimit - worstCase, controlReserve)

        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var arrived = 0
        host.onMessage = { _ in arrived += 1 }
        for id in UInt32(1)...4 { XCTAssertTrue(client.send(jpeg(id, bytes: 375_000))) }
        XCTAssertLessThanOrEqual(client.pendingBytes, screenCeiling)
        XCTAssertTrue(client.send(DeskMessage(kind: "heartbeat")))
        try await waitUntil { arrived == 5 && client.pendingBytes == 0 }
        XCTAssertEqual(client.droppedFrameCount, 0)
    }

    /// A refused frame must leave the accounting exactly where it found it, and a drained queue
    /// must return to zero on every display rather than leaking a residue that narrows the next
    /// frame's budget.
    func testScreenAccountingReturnsToZeroAfterRefusalsAndDrains() async throws {
        let (server, client, host) = try await connectedPair()
        defer { client.cancel(); server.stop() }
        var arrived = 0
        host.onMessage = { _ in arrived += 1 }
        for round in 0..<3 {
            for id in UInt32(1)...4 { XCTAssertTrue(client.send(jpeg(id, bytes: 200_000)), "round \(round)") }
            XCTAssertFalse(client.send(jpeg(1, bytes: 300_000)), "display 1 is over its reservation in round \(round)")
            try await waitUntil { client.pendingBytes == 0 }
        }
        XCTAssertEqual(client.droppedFrameCount, 3)
        try await waitUntil { arrived == 12 }
        // A full-size frame on every display still fits, which it would not if any counter had
        // drifted upward across the refusals.
        for id in UInt32(1)...4 { XCTAssertTrue(client.send(jpeg(id, bytes: 375_000))) }
        try await waitUntil { arrived == 16 && client.pendingBytes == 0 }
    }

    private func connectedPair(clientPendingLimit: Int = 8 * 1_024 * 1_024) async throws -> (DeskServer, DeskConnection, DeskConnection) {
        let key = PairingKey.generate()
        let server = DeskServer()
        var host: DeskConnection?
        server.onConnection = { host = $0 }
        try server.startLoopback(key: key)
        let raw = NWConnection(to: try await endpoint(for: server), using: SecureParameters.make(key: key))
        let client = DeskConnection(connection: raw, maximumPendingBytes: clientPendingLimit)
        var ready = false
        client.onState = { if case .ready = $0 { ready = true } }
        client.start()
        do {
            try await waitUntil { ready && host != nil }
            return (server, client, try XCTUnwrap(host))
        } catch {
            client.cancel()
            server.stop()
            throw error
        }
    }

    private func connectedRawPair(frameTimeout: TimeInterval = 10) async throws -> (DeskServer, NWConnection, DeskConnection) {
        let key = PairingKey.generate()
        let server = DeskServer(handshakeTimeout: 10, frameTimeout: frameTimeout)
        var host: DeskConnection?
        server.onConnection = { host = $0 }
        try server.startLoopback(key: key)
        let raw = NWConnection(to: try await endpoint(for: server), using: SecureParameters.make(key: key))
        var ready = false
        raw.stateUpdateHandler = { state in MainActor.assumeIsolated { if case .ready = state { ready = true } } }
        raw.start(queue: .main)
        do {
            try await waitUntil { ready && host != nil }
            XCTAssertTrue(SecureParameters.isAuthenticated(raw))
            return (server, raw, try XCTUnwrap(host))
        } catch {
            raw.cancel()
            server.stop()
            throw error
        }
    }

    private func rejectionReason(for data: Data, complete: Bool = false, frameTimeout: TimeInterval = 10) async throws -> String {
        let (server, raw, host) = try await connectedRawPair(frameTimeout: frameTimeout)
        defer { raw.cancel(); server.stop() }
        var reason: String?
        var messages = 0
        host.onMessage = { _ in messages += 1 }
        host.onState = { if case let .disconnected(value) = $0 { reason = value } }
        raw.send(content: data, completion: .contentProcessed { _ in
            // Closing after the bytes are processed produces an actual truncated TLS stream.
            // A finalMessage context alone may leave the connection open until its deadline.
            if complete { raw.cancel() }
        })
        try await waitUntil { reason != nil }
        XCTAssertEqual(messages, 0)
        return try XCTUnwrap(reason)
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

    func testNegotiationUpgradesScreenContentToBinaryAndAcknowledgesExactlyOnce() async throws {
        let (server, raw, host) = try await connectedRawPair()
        defer { raw.cancel(); server.stop() }
        let collector = BodyCollector()
        collect(from: raw, into: collector)
        let video = DeskMessage(kind: "video", displayID: 1, video: EncodedVideoFrame(
            width: 640, height: 480, sequence: 1, isKeyframe: true,
            payload: Data([0, 0, 0, 1, 0x65]), sps: Data([0x67, 0x64]), pps: Data([0x68, 0xEE])))

        // Until the peer advertises the format, even video goes out as JSON.
        XCTAssertFalse(host.isUsingBinaryWireFormat)
        XCTAssertTrue(host.send(video))
        try await waitUntil { collector.bodies.count == 1 }
        XCTAssertEqual(collector.bodies[0].first, UInt8(ascii: "{"))

        // The client advertises exactly as the app does. DeskConnection attaches the wire format.
        let advertisement = try FrameCodec.encode(DeskMessage(
            kind: "capabilities", videoCodec: DeskMessage.supportedVideoCodec,
            wireFormat: DeskMessage.binaryWireFormat))
        raw.send(content: advertisement, completion: .contentProcessed { _ in })
        try await waitUntil { host.isUsingBinaryWireFormat && collector.bodies.count == 2 }
        let ack = try FrameCodec.decode(collector.bodies[1], expectedLength: collector.bodies[1].count)
        XCTAssertEqual(ack.kind, "capabilities")
        XCTAssertEqual(ack.videoCodec, DeskMessage.supportedVideoCodec)
        XCTAssertEqual(ack.wireFormat, DeskMessage.binaryWireFormat, "the acknowledgement is decorated too")

        // Screen content is now binary on the wire and still arrives as the identical message.
        XCTAssertTrue(host.send(video))
        try await waitUntil { collector.bodies.count == 3 }
        let binary = collector.bodies[2]
        XCTAssertEqual(Data(binary.prefix(4)), FrameCodec.binaryMagic)
        XCTAssertEqual(try FrameCodec.decode(binary, expectedLength: binary.count, allowsBinary: true), video)

        // Control keeps its JSON body after negotiation, so no command depends on the upgrade.
        XCTAssertTrue(host.send(DeskMessage(kind: "status", status: "still json", controlEnabled: true)))
        try await waitUntil { collector.bodies.count == 4 }
        XCTAssertEqual(collector.bodies[3].first, UInt8(ascii: "{"))

        // A repeated advertisement draws no second acknowledgement: one per side, so no ping-pong.
        raw.send(content: advertisement, completion: .contentProcessed { _ in })
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(collector.bodies.count, 4)
        XCTAssertTrue(host.isUsingBinaryWireFormat)
    }

    func testBinaryScreenContentBeforeNegotiationClosesTheConnection() async throws {
        let video = DeskMessage(kind: "video", displayID: 1, video: EncodedVideoFrame(
            width: 640, height: 480, sequence: 1, isKeyframe: true,
            payload: Data([0, 0, 0, 1, 0x65]), sps: Data([0x67, 0x64]), pps: Data([0x68, 0xEE])))
        let reason = try await rejectionReason(for: try FrameCodec.encodeBinary(video))
        XCTAssertEqual(reason, "Invalid message.", "a body in a format this side never offered is not a message")
    }

    /// Reassembles length-prefixed bodies from the raw peer so a test can inspect the actual wire
    /// rather than only the decoded message.
    @MainActor
    private final class BodyCollector {
        private var buffer = Data()
        private(set) var bodies: [Data] = []

        func append(_ data: Data) {
            buffer.append(data)
            while buffer.count >= FrameCodec.headerLength {
                let length = Int(buffer.prefix(FrameCodec.headerLength).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard buffer.count >= FrameCodec.headerLength + length else { return }
                let start = buffer.startIndex + FrameCodec.headerLength
                bodies.append(Data(buffer[start..<(start + length)]))
                buffer = Data(buffer.dropFirst(FrameCodec.headerLength + length))
            }
        }
    }

    private func collect(from raw: NWConnection, into collector: BodyCollector) {
        raw.receive(minimumIncompleteLength: 1, maximumLength: FrameCodec.maximumPayloadLength) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                if let data, !data.isEmpty { collector.append(data) }
                guard error == nil, !complete else { return }
                self?.collect(from: raw, into: collector)
            }
        }
    }

    private enum WaitError: Error { case timeout }
}
