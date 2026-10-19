import Foundation
import Network
@testable import DeskTransport
import XCTest

/// Discovery after `NWBrowser` fails: a bounded, cancellable restart. A fake browser and a manual
/// clock drive every step, so none of this touches the network or waits in real time, except the
/// one case that checks a real sleep is cancelled.
@MainActor
final class DeskBrowserRecoveryTests: XCTestCase {
    private let searching = "Looking for Macs ready to pair."
    private let restarting = "Discovery was interrupted. Searching again shortly."
    private let failed = "Could not discover Macs. Check Local Network access and try again."
    /// `kDNSServiceErr_ServiceNotRunning`: the Bonjour daemon went away under the browser.
    private let daemonGone = NWBrowser.State.failed(.dns(-65563))

    func testTheStatusesTheHeadsetMatchesAreUnchanged() {
        // The headset app switches on these exact strings (`SessionCopy.discoveryGuidance`).
        XCTAssertEqual(DeskBrowser.stoppedStatus, "Discovery stopped.")
        XCTAssertEqual(DeskBrowser.searchingStatus, searching)
        XCTAssertEqual(DeskBrowser.waitingStatus, "Waiting for access to the local network.")
        XCTAssertEqual(DeskBrowser.failedStatus, failed)
        XCTAssertEqual(DeskBrowser.unsupportedStatus, "Discovery entered an unsupported state.")
        XCTAssertEqual(DeskBrowser.restartingStatus, restarting)
        XCTAssertEqual(DeskBrowser().status, "Discovery stopped.")
    }

    func testAFailureRestartsDiscoveryAfterAShortWait() async throws {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        XCTAssertEqual(fakes.made.count, 1)
        XCTAssertEqual(browser.status, searching)
        fakes.made[0].report(.ready)

        fakes.made[0].report(daemonGone)
        XCTAssertEqual(browser.status, restarting)
        XCTAssertTrue(fakes.made[0].isCancelled, "A failed browser is released, not reused")
        XCTAssertTrue(browser.results.isEmpty)
        try await waitUntil { clock.waiting == 1 }
        XCTAssertEqual(clock.requested, [1])
        XCTAssertEqual(fakes.made.count, 1, "Nothing restarts before the wait ends")

        clock.elapse()
        try await waitUntil { fakes.made.count == 2 }
        XCTAssertEqual(browser.status, searching)
        XCTAssertFalse(fakes.made[1].isCancelled)
        fakes.made[1].report(.ready)
        XCTAssertEqual(browser.status, searching)

        // A late callback from the failed browser is ignored.
        fakes.made[0].report(.waiting(.dns(-65570)))
        fakes.made[0].report(daemonGone)
        XCTAssertEqual(browser.status, searching)
        XCTAssertEqual(clock.requested, [1])
    }

    func testRestartsBackOffAndSettleOnTheFailureAfterFive() async throws {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        try await failAndRestart(times: 5, fakes: fakes, clock: clock, browser: browser)
        XCTAssertEqual(clock.requested, DeskBrowser.restartDelays)
        XCTAssertEqual(clock.requested, [1, 2, 4, 8, 16])

        fakes.made[5].report(daemonGone)
        XCTAssertEqual(browser.status, failed, "The budget is spent, so the failure is reported as before")
        XCTAssertTrue(fakes.made[5].isCancelled)
        try await settle()
        XCTAssertEqual(clock.requested.count, 5, "No sixth restart is scheduled")
        XCTAssertEqual(clock.waiting, 0)
        XCTAssertEqual(fakes.made.count, 6)
        XCTAssertEqual(browser.status, failed)
    }

    func testStartingAgainGivesAFreshBudget() async throws {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        try await failAndRestart(times: 5, fakes: fakes, clock: clock, browser: browser)
        fakes.made[5].report(daemonGone)
        XCTAssertEqual(browser.status, failed)

        browser.start()
        XCTAssertEqual(fakes.made.count, 7)
        XCTAssertEqual(browser.status, searching)
        fakes.made[6].report(daemonGone)
        XCTAssertEqual(browser.status, restarting)
        try await waitUntil { clock.requested.count == 6 }
        XCTAssertEqual(clock.requested.last, 1, "A new start begins the schedule again")
        browser.stop()
        clock.elapse()
    }

    func testAWaitIsNotAFailureAndSpendsNoRestart() {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        fakes.made[0].report(.waiting(.dns(-65570)))
        XCTAssertEqual(browser.status, "Waiting for access to the local network.")
        XCTAssertFalse(fakes.made[0].isCancelled, "The system resumes a waiting browser by itself")
        XCTAssertTrue(clock.requested.isEmpty)
        fakes.made[0].report(.ready)
        XCTAssertEqual(browser.status, searching)
        XCTAssertEqual(fakes.made.count, 1)
    }

    func testStopDuringTheWaitCancelsTheRestart() async throws {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        fakes.made[0].report(daemonGone)
        try await waitUntil { clock.waiting == 1 }

        browser.stop()
        XCTAssertEqual(browser.status, "Discovery stopped.")
        // Even if the wait ends anyway, the cancelled restart does nothing.
        clock.elapse()
        try await settle()
        XCTAssertEqual(fakes.made.count, 1)
        XCTAssertEqual(browser.status, "Discovery stopped.")
    }

    func testStartDuringTheWaitReplacesThePendingRestart() async throws {
        let (browser, fakes, clock) = makeSubject()
        browser.start()
        fakes.made[0].report(daemonGone)
        try await waitUntil { clock.waiting == 1 }

        browser.start()
        XCTAssertEqual(fakes.made.count, 2)
        XCTAssertEqual(browser.status, searching)
        clock.elapse()
        try await settle()
        XCTAssertEqual(fakes.made.count, 2, "The replaced restart must not start a second browser")
        XCTAssertFalse(fakes.made[1].isCancelled)
        XCTAssertEqual(browser.status, searching)
    }

    /// With the production sleep, `stop()` ends the pending wait at once instead of leaving it to run out.
    func testStopCancelsARealPendingWait() async throws {
        let fakes = FakeBrowsers()
        let probe = SleepProbe()
        let browser = DeskBrowser(makeBrowser: { fakes.make() }, sleep: { _ in
            await probe.began()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                await probe.cancelled()
                throw error
            }
        })
        browser.start()
        fakes.made[0].report(daemonGone)
        try await waitUntil { probe.started == 1 }

        let stoppedAt = ContinuousClock.now
        browser.stop()
        try await waitUntil { probe.cancellations == 1 }
        XCTAssertLessThan(ContinuousClock.now - stoppedAt, .seconds(5), "The wait ended with the stop, not after a minute")
        XCTAssertEqual(fakes.made.count, 1)
        XCTAssertEqual(browser.status, "Discovery stopped.")
    }

    // MARK: - Helpers

    private func makeSubject() -> (DeskBrowser, FakeBrowsers, ManualClock) {
        let fakes = FakeBrowsers()
        let clock = ManualClock()
        let browser = DeskBrowser(makeBrowser: { fakes.make() }, sleep: { await clock.sleep($0) })
        return (browser, fakes, clock)
    }

    /// Fails the newest browser and lets each wait run out, `times` times.
    private func failAndRestart(times: Int, fakes: FakeBrowsers, clock: ManualClock, browser: DeskBrowser) async throws {
        for attempt in 0..<times {
            fakes.made[attempt].report(daemonGone)
            XCTAssertEqual(browser.status, restarting)
            try await waitUntil { clock.waiting == 1 }
            XCTAssertEqual(clock.requested.last, DeskBrowser.restartDelays[attempt])
            clock.elapse()
            try await waitUntil { fakes.made.count == attempt + 2 }
            XCTAssertEqual(browser.status, searching)
        }
    }

    /// Long enough for a resumed restart task to run on the main actor, if it were going to.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1_000))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for discovery to change.")
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum WaitError: Error { case timeout }
}

/// Stands in for `NWBrowser`. It reports whatever the test says, even after it is cancelled, so
/// ignoring a late callback stays `DeskBrowser`'s job.
@MainActor
private final class FakeBrowser: BonjourBrowsing {
    private var onState: (@Sendable (NWBrowser.State) -> Void)?
    private(set) var isCancelled = false

    func start(onState: @escaping @Sendable (NWBrowser.State) -> Void,
               onResults: @escaping @Sendable (Set<NWBrowser.Result>) -> Void) {
        self.onState = onState
    }

    func cancel() { isCancelled = true }

    func report(_ state: NWBrowser.State) { onState?(state) }
}

@MainActor
private final class FakeBrowsers {
    private(set) var made: [FakeBrowser] = []

    func make() -> any BonjourBrowsing {
        let browser = FakeBrowser()
        made.append(browser)
        return browser
    }
}

/// Waits that end only when the test says their time has passed.
@MainActor
private final class ManualClock {
    private(set) var requested: [UInt64] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { pending.count }

    func sleep(_ seconds: UInt64) async {
        requested.append(seconds)
        await withCheckedContinuation { pending.append($0) }
    }

    /// Ends the oldest wait.
    func elapse() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }
}

@MainActor
private final class SleepProbe {
    private(set) var started = 0
    private(set) var cancellations = 0

    func began() { started += 1 }
    func cancelled() { cancellations += 1 }
}
