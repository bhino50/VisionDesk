import XCTest
@testable import VisionDesk

/// The inbound-silence rules, checked without a clock or a network. The integration of these
/// rules with a live session is in `ClientRecoveryTests`.
final class LinkMonitorTests: XCTestCase {
    private let policy = LinkMonitor.Policy(quietAfter: 4, recoverAfter: 15, maximumAutomaticRecoveries: 2)

    /// The standard thresholds are what make the behaviour safe, so their relationships are
    /// pinned: quiet only after longer than one paused screen's 2.5-second freshness window,
    /// and recycled only after the Mac's own ten-second limit, so a Mac that already gave up
    /// on a dead path has released its single session slot before the reconnection arrives.
    func testTheStandardPolicyWaitsOutAPausedScreenAndTheMacsOwnLimit() {
        let standard = LinkMonitor.Policy.standard
        XCTAssertGreaterThan(standard.quietAfter, 2.5)
        XCTAssertGreaterThan(standard.recoverAfter, 10)
        XCTAssertLessThan(standard.quietAfter, standard.recoverAfter)
        XCTAssertGreaterThan(standard.maximumAutomaticRecoveries, 0)
    }

    func testWithoutASessionNothingIsEverSilent() {
        var monitor = LinkMonitor(policy: policy)
        monitor.received(at: 1)
        XCTAssertNil(monitor.lastInbound, "Arrivals outside a session are not evidence about one.")
        XCTAssertNil(monitor.silence(at: 1_000))
        XCTAssertEqual(monitor.assess(at: 1_000, canRecover: true), .responsive)
        XCTAssertEqual(monitor.automaticRecoveries, 0)
    }

    func testAuthenticatingCountsAsHearingFromTheMac() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 10)
        XCTAssertEqual(try XCTUnwrap(monitor.silence(at: 13.5)), 3.5, accuracy: 1e-9)
        XCTAssertEqual(monitor.assess(at: 13.9, canRecover: true), .responsive)
        XCTAssertEqual(monitor.assess(at: 14, canRecover: true), .quiet)
    }

    func testArrivalsKeepTheLinkResponsive() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 0)
        for second in stride(from: 1.0, through: 60, by: 1) {
            monitor.received(at: second)
            XCTAssertEqual(monitor.assess(at: second + 0.5, canRecover: true), .responsive, "\(second)")
        }
        XCTAssertEqual(monitor.automaticRecoveries, 0)
    }

    /// A session that cannot come back by itself — a discovered Mac's, or one with no window
    /// in front — is only ever told about, however long the silence lasts.
    func testSilenceIsOnlyReportedForASessionThatCannotRecover() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 0)
        XCTAssertEqual(monitor.assess(at: 5, canRecover: false), .quiet)
        XCTAssertEqual(monitor.assess(at: 3_600, canRecover: false), .quiet)
        XCTAssertEqual(monitor.automaticRecoveries, 0, "Nothing was spent on a session that could not recover.")
    }

    func testARecoverableSessionIsRecycledOnlyAfterTheLongerWait() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 0)
        XCTAssertEqual(monitor.assess(at: 14.9, canRecover: true), .quiet)
        XCTAssertEqual(monitor.assess(at: 15, canRecover: true), .recover)
        XCTAssertEqual(monitor.automaticRecoveries, 1)
    }

    /// The cap is what stops a live Mac whose screens are genuinely idle from being redialled
    /// forever. Traffic during the burst every Mac sends on attach does not earn the allowance
    /// back; traffic once a session has outlived the recycle wait does.
    func testRecyclesStopAtTheAllowanceUntilAHealthySessionEarnsItBack() {
        var monitor = LinkMonitor(policy: policy)
        for cycle in 0..<2 {
            let start = Double(cycle) * 100
            monitor.linked(at: start)
            XCTAssertEqual(monitor.assess(at: start + 15, canRecover: true), .recover, "cycle \(cycle)")
            monitor.unlinked()
        }
        XCTAssertFalse(monitor.allowsAutomaticRecovery)
        monitor.linked(at: 300)
        XCTAssertEqual(monitor.assess(at: 400, canRecover: true), .quiet, "The allowance is spent.")
        monitor.unlinked()

        monitor.linked(at: 500)
        monitor.received(at: 501)
        XCTAssertEqual(monitor.assess(at: 502, canRecover: true), .responsive)
        XCTAssertFalse(monitor.allowsAutomaticRecovery, "The attach burst proves nothing yet.")

        monitor.received(at: 516)
        XCTAssertEqual(monitor.assess(at: 516, canRecover: true), .responsive)
        XCTAssertTrue(monitor.allowsAutomaticRecovery, "A session that kept talking has recovered.")
        XCTAssertEqual(monitor.automaticRecoveries, 0)
    }

    func testADeliberateAttemptRestoresTheAllowance() {
        var monitor = LinkMonitor(policy: policy)
        for cycle in 0..<2 {
            monitor.linked(at: Double(cycle) * 100)
            _ = monitor.assess(at: Double(cycle) * 100 + 20, canRecover: true)
            monitor.unlinked()
        }
        XCTAssertFalse(monitor.allowsAutomaticRecovery)
        monitor.resetAutomaticRecoveries()
        XCTAssertTrue(monitor.allowsAutomaticRecovery)
        monitor.linked(at: 1_000)
        XCTAssertEqual(monitor.assess(at: 1_015, canRecover: true), .recover)
    }

    /// Recycles are counted across the recycle itself: unlinking forgets the session, never
    /// the allowance it spent, or every recycle would arrive with a fresh one.
    func testUnlinkingForgetsTheSessionButNotTheSpentAllowance() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 0)
        _ = monitor.assess(at: 15, canRecover: true)
        monitor.unlinked()
        XCTAssertNil(monitor.linkedAt)
        XCTAssertNil(monitor.silence(at: 30))
        XCTAssertEqual(monitor.automaticRecoveries, 1)
    }

    /// Reordered or nonsensical times must never manufacture silence, because silence is what
    /// recycles a session: every doubt resolves towards "responsive".
    func testTimeNeverRunsBackwardsIntoSilence() {
        var monitor = LinkMonitor(policy: policy)
        monitor.linked(at: 100)
        monitor.received(at: 110)
        monitor.received(at: 105)
        XCTAssertEqual(monitor.lastInbound, 110, "A reordered arrival does not move the last one back.")
        XCTAssertEqual(monitor.silence(at: 90), 0)
        XCTAssertEqual(monitor.assess(at: 90, canRecover: true), .responsive)

        monitor.received(at: .nan)
        monitor.received(at: .infinity)
        monitor.received(at: -.infinity)
        XCTAssertEqual(monitor.lastInbound, 110)
        XCTAssertNil(monitor.silence(at: .nan))
        XCTAssertEqual(monitor.assess(at: .nan, canRecover: true), .responsive)
        XCTAssertEqual(monitor.assess(at: .infinity, canRecover: true), .responsive)
        XCTAssertEqual(monitor.automaticRecoveries, 0)
    }
}
