import DeskCore
import Foundation
import Network
@testable import DeskTransport
import XCTest

/// Listener failures and waits, explained for the person at the Mac. The mapping is pure, so each
/// branch is checked without binding a socket; one loopback case confirms that Network.framework
/// really reports a taken port as `EADDRINUSE` and that the server passes that error on.
@MainActor
final class ListenerProblemTests: XCTestCase {
    private let tailnetHost = "100.64.0.1"
    private let port = RemoteMacAddress.defaultPort

    /// Errors other than `EADDRINUSE`, covering every other cause and an unrecognized one.
    private let errorsOtherThanAddressInUse: [NWError?] = [
        nil, .posix(.EADDRNOTAVAIL), .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH),
        .posix(.EACCES), .posix(.EPERM), .posix(.EMFILE),
        .dns(ListenerProblem.dnsPolicyDenied), .dns(-65537), .tls(-9800)
    ]

    private func reason(_ code: POSIXErrorCode) -> String { String(cString: strerror(code.rawValue)) }

    func testEachCauseFollowsTheErrorNetworkFrameworkReports() {
        XCTAssertEqual(ListenerProblem(.posix(.EADDRINUSE)), .portInUse)
        XCTAssertEqual(ListenerProblem(.posix(.EADDRNOTAVAIL)), .addressUnavailable)
        for code in [POSIXErrorCode.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH] {
            XCTAssertEqual(ListenerProblem(.posix(code)), .networkDown, "\(code)")
        }
        XCTAssertEqual(ListenerProblem(.posix(.EACCES)), .notPermitted)
        XCTAssertEqual(ListenerProblem(.posix(.EPERM)), .notPermitted)
        XCTAssertEqual(ListenerProblem(.dns(ListenerProblem.dnsPolicyDenied)), .localNetworkDenied)
        XCTAssertEqual(ListenerProblem(.dns(-65537)), .other)
        XCTAssertEqual(ListenerProblem(.tls(-9800)), .other)
        XCTAssertEqual(ListenerProblem(.posix(.EMFILE)), .other)
        XCTAssertEqual(ListenerProblem(nil), .other)
    }

    func testPortInUseAdviceIsReservedForAddressInUse() {
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRINUSE), port: port, bindHost: tailnetHost),
                       "Could not listen on 100.64.0.1:58271: another app on this Mac is already using that port "
                       + "(\(reason(.EADDRINUSE))). Quit that app to free the port.")
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRINUSE), port: port, bindHost: nil),
                       "Could not listen on port 58271: another app on this Mac is already using that port "
                       + "(\(reason(.EADDRINUSE))). Quit that app to free the port.")

        for error in errorsOtherThanAddressInUse {
            for host in [tailnetHost, "192.168.1.20", nil] as [String?] {
                for message in [ListenerProblem.failureStatus(error, port: port, bindHost: host),
                                ListenerProblem.waitingStatus(error, port: port, bindHost: host)] {
                    XCTAssertFalse(message.contains("another app"), message)
                    XCTAssertFalse(message.contains("different port"), message)
                    XCTAssertFalse(message.contains("leave it blank"), message)
                }
            }
        }
        // With no pinned port there is no port to blame, so even EADDRINUSE names none.
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRINUSE), port: nil, bindHost: nil),
                       "Could not listen on the local network (\(reason(.EADDRINUSE))). Check this Mac's network connection.")
    }

    func testALostTailscaleAddressIsNamedWithTheSystemReason() {
        let advice = "Check that Tailscale is connected on this Mac and that 100.64.0.1 is this Mac's Tailscale address."
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRNOTAVAIL), port: port, bindHost: tailnetHost),
                       "Could not listen on 100.64.0.1:58271: that address is not on this Mac right now "
                       + "(\(reason(.EADDRNOTAVAIL))). \(advice)")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.EADDRNOTAVAIL), port: port, bindHost: tailnetHost),
                       "Waiting for 100.64.0.1 to be available on this Mac (\(reason(.EADDRNOTAVAIL))). \(advice)")
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.ENETDOWN), port: port, bindHost: tailnetHost),
                       "Could not listen on 100.64.0.1:58271: its network is unavailable (\(reason(.ENETDOWN))). \(advice)")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.ENETUNREACH), port: port, bindHost: tailnetHost),
                       "Waiting for 100.64.0.1 to be available on this Mac (\(reason(.ENETUNREACH))). \(advice)")
    }

    func testAnAddressOutsideTheTailnetGetsNetworkAdviceInstead() {
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRNOTAVAIL), port: port, bindHost: "192.168.1.20"),
                       "Could not listen on 192.168.1.20:58271: that address is not on this Mac right now "
                       + "(\(reason(.EADDRNOTAVAIL))). Check that 192.168.1.20 is this Mac's address and that its network is connected.")
        let ipv6 = ListenerProblem.failureStatus(.posix(.EADDRNOTAVAIL), port: port, bindHost: "FD7A:115C:A1E0::1")
        XCTAssertTrue(ipv6.hasPrefix("Could not listen on [fd7a:115c:a1e0::1]:58271: "), ipv6)
        XCTAssertFalse(ipv6.contains("Tailscale"), "Only a tailnet IPv4 address gets Tailscale advice: \(ipv6)")
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EADDRNOTAVAIL), port: nil, bindHost: nil),
                       "Could not listen on the local network: this Mac has no usable network address "
                       + "(\(reason(.EADDRNOTAVAIL))). Check this Mac's network connection.")
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.ENETDOWN), port: nil, bindHost: nil),
                       "Could not listen on the local network: the network is unavailable "
                       + "(\(reason(.ENETDOWN))). Check this Mac's network connection.")
    }

    func testWaitingStaysAWaitAndSaysWhatToDo() {
        let localNetwork = "Allow VisionDeskMac in System Settings → Privacy & Security → Local Network."
        XCTAssertEqual(ListenerProblem.waitingStatus(.dns(ListenerProblem.dnsPolicyDenied), port: nil, bindHost: nil),
                       "Waiting for access to the local network (DNS service error -65570). \(localNetwork)")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.EPERM), port: port, bindHost: nil),
                       "Waiting for access to the local network (\(reason(.EPERM))). \(localNetwork)")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.ENETDOWN), port: nil, bindHost: nil),
                       "Waiting for a network connection (\(reason(.ENETDOWN))).")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.EADDRINUSE), port: port, bindHost: tailnetHost),
                       "Waiting for 100.64.0.1:58271: another app on this Mac is using that port "
                       + "(\(reason(.EADDRINUSE))). Quit that app to free the port.")
        XCTAssertEqual(ListenerProblem.waitingStatus(.posix(.EMFILE), port: port, bindHost: nil),
                       "Waiting to listen on port 58271 (\(reason(.EMFILE))).")
        XCTAssertEqual(ListenerProblem.waitingStatus(nil, port: port, bindHost: tailnetHost),
                       "Waiting for the network to become available.")

        for error in errorsOtherThanAddressInUse + [.posix(.EADDRINUSE)] {
            for host in [tailnetHost, nil] as [String?] {
                let message = ListenerProblem.waitingStatus(error, port: port, bindHost: host)
                XCTAssertTrue(message.hasPrefix("Waiting"), "A wait must not read as a failure: \(message)")
                XCTAssertFalse(message.contains("Could not"), message)
            }
        }
    }

    func testDeniedAccessNamesTheLocalNetworkSetting() {
        let localNetwork = "Allow VisionDeskMac in System Settings → Privacy & Security → Local Network."
        XCTAssertEqual(ListenerProblem.failureStatus(.dns(ListenerProblem.dnsPolicyDenied), port: nil, bindHost: nil),
                       "Could not listen on the local network: VisionDesk is not allowed to use the local network "
                       + "(DNS service error -65570). \(localNetwork)")
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EACCES), port: port, bindHost: nil),
                       "Could not listen on port 58271: macOS did not allow it (\(reason(.EACCES))). \(localNetwork)")
    }

    func testAnUnrecognizedErrorCarriesTheSystemsOwnReason() {
        XCTAssertEqual(ListenerProblem.failureStatus(.posix(.EMFILE), port: port, bindHost: nil),
                       "Could not listen on port 58271 (\(reason(.EMFILE))). Check this Mac's network connection.")
        XCTAssertEqual(ListenerProblem.failureStatus(.tls(-9800), port: nil, bindHost: nil),
                       "Could not listen on the local network (TLS error -9800). Check this Mac's network connection.")
        XCTAssertEqual(ListenerProblem.failureStatus(.dns(-65537), port: port, bindHost: tailnetHost),
                       "Could not listen on 100.64.0.1:58271 (DNS service error -65537). Check this Mac's network connection.")
        XCTAssertEqual(ListenerProblem.failureStatus(nil, port: port, bindHost: nil),
                       "Could not listen on port 58271. Check this Mac's network connection.")
    }

    /// A real bind, on loopback only: a second listener pinned to a port the first one holds.
    func testATakenLoopbackPortIsReportedAsInUseThroughTheServer() async throws {
        let holder = DeskServer()
        defer { holder.stop() }
        try holder.startLoopback(key: PairingKey.generate())
        try await waitUntil { holder.port != nil }
        let taken = try XCTUnwrap(holder.port)

        let server = DeskServer()
        defer { server.stop() }
        var statuses: [String] = []
        var failure: String?
        server.onStatus = { statuses.append($0) }
        server.onStopped = { failure = $0 }
        try server.start(key: PairingKey.generate(), name: "VisionDesk Test", port: taken, allowReconnect: true, bindHost: "127.0.0.1")
        try await waitUntil(timeout: 10) {
            failure != nil || statuses.contains { $0.contains("another app on this Mac") }
        }

        let reported = try XCTUnwrap(failure ?? statuses.last { $0.contains("another app on this Mac") })
        XCTAssertTrue(reported.contains("127.0.0.1:\(taken)"), reported)
        XCTAssertTrue(reported.contains("another app on this Mac"), reported)
        XCTAssertTrue(reported.contains(reason(.EADDRINUSE)), "The system's own reason is reported: \(reported)")
        XCTAssertNil(server.port, "The second listener never bound")
        XCTAssertEqual(holder.port, taken, "The listener that holds the port is undisturbed")
        print("      taken loopback port reported via \(failure != nil ? "failed (onStopped)" : "waiting (onStatus)"): \(reported)")
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
