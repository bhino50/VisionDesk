import CoreGraphics
import Foundation
import XCTest
@testable import VisionDesk

/// Unit tests for the client's input coalescing rules.
///
/// `InputCoalescer` takes a monotonic timestamp as a parameter and returns what to do, so
/// every rule here is exercised with explicit times and no sleeping, no clock and no
/// connection. Nothing in this file is timing-dependent, which is the point: the wire-level
/// consequences are proven separately against a real TLS session in `DeskClientModelTests`.
final class InputCoalescerTests: XCTestCase {
    private let display: UInt32 = 1
    /// One coalescing window, named so the arithmetic below reads as intent.
    private var window: TimeInterval { InputCoalescer.interval }

    // MARK: Pointer movement

    func testFirstMovementIsImmediateAndTheNextOneInsideTheWindowIsHeld() {
        var coalescer = InputCoalescer()
        XCTAssertEqual(coalescer.offer(move: point(0.1), displayID: display, now: 100), .now,
                       "Starting to point may never be delayed by coalescing.")
        let first = coalescer.flush(now: 100)
        XCTAssertEqual(first.move?.point, point(0.1))
        XCTAssertEqual(first.next, .idle, "One flushed position leaves nothing scheduled.")

        let held = coalescer.offer(move: point(0.2), displayID: display, now: 100 + window / 2)
        guard case .after(let wait) = held else {
            return XCTFail("A second position inside the window has to be held back.")
        }
        XCTAssertEqual(wait, window / 2, accuracy: 1e-9, "The wait is only what is left of the window.")
    }

    func testMovementPastTheWindowGoesStraightOut() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.1), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        XCTAssertEqual(coalescer.offer(move: point(0.2), displayID: display, now: 100 + window),
                       .now, "Once the window has elapsed there is nothing to hold back.")
    }

    func testOnlyTheLatestHeldPositionSurvives() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.1), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        for (index, x) in [0.2, 0.3, 0.4, 0.5].enumerated() {
            _ = coalescer.offer(move: point(x), displayID: display, now: 100 + Double(index) * 0.001)
        }
        let batch = coalescer.flush(now: 100 + window)
        XCTAssertEqual(batch.move?.point, point(0.5),
                       "A pointer's intermediate positions are not information anyone can act on.")
        XCTAssertFalse(coalescer.hasPendingInput, "One slot, so one flush drains it.")
    }

    func testARepeatedPositionIsNotSentTwice() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.4), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        XCTAssertEqual(coalescer.offer(move: point(0.4), displayID: display, now: 100 + window),
                       .idle, "A hand held still reports the same place; re-sending it is pure cost.")
        XCTAssertFalse(coalescer.hasPendingInput)
    }

    func testMovingAwayAndBackInsideOneWindowStillEndsWhereTheHandIs() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.4), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        _ = coalescer.offer(move: point(0.6), displayID: display, now: 100.001)
        _ = coalescer.offer(move: point(0.4), displayID: display, now: 100.002)
        XCTAssertEqual(coalescer.flush(now: 100 + window).move?.point, point(0.4),
                       "The latest offered position wins, repeat or not.")
    }

    // MARK: Scroll

    func testScrollAccumulatesRatherThanReplacing() throws {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(scrollX: 0, scrollY: -7, displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        for step in 1...5 {
            _ = coalescer.offer(scrollX: -1, scrollY: -7, displayID: display,
                                now: 100 + Double(step) * 0.001)
        }
        let scroll = try XCTUnwrap(coalescer.flush(now: 100 + window).scroll)
        XCTAssertEqual(scroll.deltaY, -35, accuracy: 1e-9,
                       "A dropped scroll delta is distance the user cannot ask for again.")
        XCTAssertEqual(scroll.deltaX, -5, accuracy: 1e-9)
    }

    func testASubThresholdScrollIsRetainedUntilItAddsUp() throws {
        var coalescer = InputCoalescer()
        // Each of these alone is numerically meaningless and must not go out as a no-op.
        for step in 1...2 {
            let now = 100 + Double(step) * window
            XCTAssertEqual(coalescer.offer(scrollX: 0, scrollY: -0.004, displayID: display, now: now),
                           .now, "Nothing has been sent, so nothing is being waited on.")
            XCTAssertFalse(coalescer.hasPendingInput,
                           "A retained fraction is not work, or a flush would reschedule forever.")
            XCTAssertNil(coalescer.flush(now: now).scroll)
        }
        // The third retained fraction exceeds the threshold together with the first two.
        _ = coalescer.offer(scrollX: 0, scrollY: -0.004, displayID: display, now: 200)
        let scroll = try XCTUnwrap(coalescer.flush(now: 200).scroll)
        XCTAssertEqual(scroll.deltaY, -0.012, accuracy: 1e-9,
                       "The fractions were kept, not rounded away one at a time.")
    }

    func testOneMessageIsBoundedAndTheRemainderStaysOwed() throws {
        var coalescer = InputCoalescer()
        for step in 1...4 {
            _ = coalescer.offer(scrollX: 0, scrollY: -400, displayID: display,
                                now: 100 + Double(step) * 0.001)
        }
        let first = coalescer.flush(now: 100)
        XCTAssertEqual(try XCTUnwrap(first.scroll).deltaY, -InputCoalescer.scrollLimit,
                       "One message carries no more than the protocol's own bound.")
        XCTAssertEqual(first.next, .after(window), "What the bound could not carry still needs a flush.")

        XCTAssertEqual(try XCTUnwrap(coalescer.flush(now: 100 + window).scroll).deltaY,
                       -InputCoalescer.scrollLimit)
        XCTAssertEqual(try XCTUnwrap(coalescer.flush(now: 100 + 2 * window).scroll).deltaY,
                       -InputCoalescer.scrollLimit)
        let last = coalescer.flush(now: 100 + 3 * window)
        XCTAssertEqual(try XCTUnwrap(last.scroll).deltaY, -100, accuracy: 1e-9,
                       "A flick scrolls the same distance as the same motion made slowly.")
        XCTAssertEqual(last.next, .idle)
        XCTAssertFalse(coalescer.hasPendingInput)
    }

    func testAccumulationIsCappedAtTheDocumentedBudget() {
        var coalescer = InputCoalescer()
        // Far more hand travel than the budget, all offered inside a single window.
        for step in 1...200 {
            _ = coalescer.offer(scrollX: 0, scrollY: -500, displayID: display,
                                now: 100 + Double(step) * 0.00001)
        }
        var owed = 0.0
        var flushes = 0
        var batch = coalescer.flush(now: 100)
        while let scroll = batch.scroll {
            owed += scroll.deltaY
            flushes += 1
            XCTAssertLessThanOrEqual(flushes, 8, "A bounded budget has to drain in bounded time.")
            batch = coalescer.flush(now: 100 + Double(flushes) * window)
        }
        XCTAssertEqual(owed, -InputCoalescer.scrollBudget, accuracy: 1e-9,
                       "Summing finite deltas without a cap is how an owed total runs away.")
        XCTAssertEqual(flushes, 4, "The budget drains in four messages, about 67 ms.")
        XCTAssertFalse(coalescer.hasPendingInput)
    }

    /// The model drains this budget at a gesture end and before every discrete action, and it
    /// sizes that drain from these two constants: the budget divided by one message's bound,
    /// rounded up. Two properties of that arithmetic are load-bearing and neither is implied
    /// by any other test here — it has to allow at least one batch, or a drain would discard
    /// everything it was supposed to deliver, and the batches it allows have to be able to
    /// carry the whole budget, or an end would silently drop the remainder.
    func testTheDrainBoundIsAtLeastOneBatchAndCoversTheWholeBudget() {
        let batches = Int((InputCoalescer.scrollBudget / InputCoalescer.scrollLimit).rounded(.up))
        XCTAssertGreaterThanOrEqual(batches, 1, "A drain allowing no batches discards everything.")
        XCTAssertGreaterThanOrEqual(
            Double(batches) * InputCoalescer.scrollLimit, InputCoalescer.scrollBudget,
            "The allowed batches have to be able to carry a full budget."
        )

        var coalescer = InputCoalescer()
        for step in 1...200 {
            _ = coalescer.offer(scrollX: 0, scrollY: -InputCoalescer.scrollLimit,
                                displayID: display, now: 100 + Double(step) * 0.00001)
        }
        var owed = 0.0
        for index in 0..<batches {
            owed += coalescer.flush(now: 100 + Double(index) * window).scroll?.deltaY ?? 0
        }
        XCTAssertEqual(owed, -InputCoalescer.scrollBudget, accuracy: 1e-9,
                       "A full budget has to empty inside the drain's own bound.")
        XCTAssertFalse(coalescer.hasPendingInput)
    }

    func testAnEnormousSingleDeltaCannotOutrunOneMessage() throws {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(scrollX: 0, scrollY: -1e9, displayID: display, now: 100)
        XCTAssertEqual(try XCTUnwrap(coalescer.flush(now: 100).scroll).deltaY,
                       -InputCoalescer.scrollLimit,
                       "One frame of travel cannot by itself fill the budget.")
        XCTAssertFalse(coalescer.hasPendingInput)
    }

    func testNonFiniteOrEmptyInputIsRefusedOutright() {
        var coalescer = InputCoalescer()
        XCTAssertEqual(coalescer.offer(scrollX: .infinity, scrollY: .nan, displayID: display, now: 100),
                       .idle)
        XCTAssertEqual(coalescer.offer(scrollX: 0, scrollY: 0, displayID: display, now: 100), .idle)
        XCTAssertFalse(coalescer.hasPendingInput, "Nothing usable was offered, so nothing is owed.")
    }

    func testScrollOwedToOneDisplayIsNotDeliveredToAnother() throws {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(scrollX: 0, scrollY: -40, displayID: 1, now: 100)
        _ = coalescer.offer(scrollX: 0, scrollY: -40, displayID: 2, now: 100.001)
        let scroll = try XCTUnwrap(coalescer.flush(now: 100).scroll)
        XCTAssertEqual(scroll.displayID, 2)
        XCTAssertEqual(scroll.deltaY, -40, accuracy: 1e-9, "Display 1's distance is not carried across.")
    }

    // MARK: Ordering and lifecycle

    func testAFlushOrdersThePointerAheadOfScroll() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.3), displayID: display, now: 100)
        _ = coalescer.offer(scrollX: 0, scrollY: -20, displayID: display, now: 100)
        let batch = coalescer.flush(now: 100)
        XCTAssertEqual(batch.move?.point, point(0.3), "Scroll lands where the pointer already is.")
        XCTAssertNotNil(batch.scroll)
    }

    func testDiscardDropsHeldInputWithoutSendingIt() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.1), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)
        _ = coalescer.offer(move: point(0.9), displayID: display, now: 100.001)
        _ = coalescer.offer(scrollX: 0, scrollY: -90, displayID: display, now: 100.001)
        XCTAssertTrue(coalescer.hasPendingInput)

        coalescer.discard()
        XCTAssertFalse(coalescer.hasPendingInput)
        let batch = coalescer.flush(now: 100 + window)
        XCTAssertNil(batch.move, "A position recorded before a cancel must never arrive after it.")
        XCTAssertNil(batch.scroll, "Neither may the scroll it was holding.")
    }

    func testResetMakesTheNextGesturesFirstMovementImmediateAgain() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.5), displayID: display, now: 100)
        _ = coalescer.flush(now: 100)

        coalescer.reset()
        // The same position, at the same instant, and still immediate: a new gesture has no
        // history to be deduplicated or rate-limited against.
        XCTAssertEqual(coalescer.offer(move: point(0.5), displayID: display, now: 100), .now)
        XCTAssertEqual(coalescer.flush(now: 100).move?.point, point(0.5))
    }

    func testAClockThatStopsOrGoesBackwardsNeverStrandsHeldInput() {
        var coalescer = InputCoalescer()
        _ = coalescer.offer(move: point(0.2), displayID: display, now: 500)
        _ = coalescer.flush(now: 500)
        XCTAssertEqual(coalescer.offer(move: point(0.3), displayID: display, now: 100), .now,
                       "A timestamp before the last send is unusable, not a reason to wait.")
        _ = coalescer.flush(now: 100)
        XCTAssertEqual(coalescer.offer(move: point(0.4), displayID: display, now: .nan), .now)
    }

    func testTheSendRateStaysInsideSixtyHertzAcrossASecondOfNinetyHertzInput() {
        var coalescer = InputCoalescer()
        var sends = 0
        var due: TimeInterval?
        // One second of reports at 90 Hz, each a new position, flushed exactly when the
        // schedule said to — which is what the model's single flush task does.
        for frame in 0..<90 {
            let now = Double(frame) / 90
            if let due, now >= due {
                if coalescer.flush(now: due).move != nil { sends += 1 }
            }
            if let pending = due, now >= pending { due = nil }
            switch coalescer.offer(move: point(Double(frame) / 90), displayID: display, now: now) {
            case .now:
                if coalescer.flush(now: now).move != nil { sends += 1 }
            case .after(let wait):
                if due == nil { due = now + wait }
            case .idle:
                break
            }
        }
        XCTAssertLessThanOrEqual(sends, 61, "A second of pointing may not put more than 60 Hz on the wire.")
        XCTAssertGreaterThan(sends, 30, "Coalescing has to pass movement through, not swallow it.")
    }

    private func point(_ x: Double) -> CGPoint { CGPoint(x: x, y: 0.5) }
}
