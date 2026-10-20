import XCTest
@testable import VisionDesk

final class ConnectionDiagnosticsTests: XCTestCase {
    func testFrameAgeHandlesMissingNonfiniteFutureAndVeryOldClocks() {
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: nil, now: 10), "No decoded frame yet")
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: .nan, now: 10), "No decoded frame yet")
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: 5, now: .infinity), "No decoded frame yet")
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: 11, now: 10), "Less than 1 second ago")
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: 8, now: 10), "2 seconds ago")
        XCTAssertEqual(ConnectionDiagnostics.frameAge(receivedAt: 0, now: .greatestFiniteMagnitude), "Over an hour ago")
    }

    func testRecoveryAdvicePrioritizesSilentMacThenMissingScreens() {
        let silent = ConnectionDiagnostics.recoveryAdvice(isLinked: true, isResponsive: false,
            hasDisplays: false, retryExhausted: true, isRetrying: false)
        XCTAssertTrue(silent.contains("awake and on the network"))
        XCTAssertFalse(silent.contains("Screen Recording"))
        let missing = ConnectionDiagnostics.recoveryAdvice(isLinked: true, isResponsive: true,
            hasDisplays: false, retryExhausted: false, isRetrying: false)
        XCTAssertTrue(missing.contains("Screen Recording"))
        let exhausted = ConnectionDiagnostics.recoveryAdvice(isLinked: false, isResponsive: true,
            hasDisplays: false, retryExhausted: true, isRetrying: false)
        XCTAssertTrue(exhausted.contains("Automatic attempts have finished"))
        let viewing = ConnectionDiagnostics.recoveryAdvice(isLinked: true, isResponsive: true,
            hasDisplays: true, retryExhausted: false, isRetrying: false)
        XCTAssertTrue(viewing.contains("When control is enabled"))
        XCTAssertTrue(viewing.contains("For viewing only, choose Request Control"))
    }
}
