import Network
@testable import DeskTransport
import XCTest

final class ConnectionProblemTests: XCTestCase {
    func testNetworkFailuresHaveDistinctActionableCauses() {
        XCTAssertEqual(ConnectionProblem(.dns(-65538)), .nameResolution)
        XCTAssertEqual(ConnectionProblem(.posix(.ECONNREFUSED)), .refused)
        for code: POSIXErrorCode in [.ENETDOWN, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .ENETRESET] {
            XCTAssertEqual(ConnectionProblem(.posix(code)), .networkUnavailable)
        }
        XCTAssertEqual(ConnectionProblem(.posix(.ETIMEDOUT)), .timedOut)
        XCTAssertTrue(ConnectionProblem(.posix(.ECONNREFUSED)).message.contains("start sharing"))
        XCTAssertTrue(ConnectionProblem(.posix(.ENETUNREACH)).message.contains("private VPN"))
    }

    func testPolicyDenialIsNotMisreportedAsAnIncorrectKey() {
        XCTAssertEqual(ConnectionProblem(.dns(ListenerProblem.dnsPolicyDenied)), .localNetworkDenied)
        for code: POSIXErrorCode in [.EACCES, .EPERM] {
            XCTAssertEqual(ConnectionProblem(.posix(code)), .notPermitted)
            XCTAssertTrue(ConnectionProblem(.posix(code)).message.contains("policy"))
            XCTAssertFalse(ConnectionProblem(.posix(code)).message.contains("pairing"))
        }
        XCTAssertTrue(ConnectionProblem(.dns(ListenerProblem.dnsPolicyDenied)).message.contains("Local Network"))
    }

    func testTLSFailureDoesNotClaimTheKeyWasRejectedOrExposeSystemDetails() {
        let first = ConnectionProblem(.tls(-9800)).message
        XCTAssertEqual(ConnectionProblem(.tls(-9800)), .secureHandshake)
        XCTAssertEqual(first, ConnectionProblem(.tls(-9847)).message)
        XCTAssertFalse(first.contains("rejected"))
        XCTAssertFalse(first.contains("wrong"))
        XCTAssertFalse(first.contains("9800"))
        XCTAssertTrue(first.contains("both apps"))
    }

    func testUnrecognizedErrorsUseOneFixedFallback() {
        XCTAssertEqual(ConnectionProblem(.posix(.EMFILE)), .other)
        XCTAssertEqual(ConnectionProblem(.posix(.EINVAL)), .other)
        XCTAssertEqual(ConnectionProblem(.posix(.EMFILE)).message,
                       ConnectionProblem(.posix(.EINVAL)).message)
        XCTAssertEqual(ConnectionProblem(.posix(.EMFILE)).message,
                       "The connection failed. Check that the Mac is awake and sharing and that both devices can reach each other, then try again.")
    }
}
