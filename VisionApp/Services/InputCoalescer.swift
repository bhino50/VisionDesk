import CoreGraphics
import Foundation

/// Decides which pointer movement and scroll distance actually reaches the Mac,
/// and when.
///
/// A visionOS drag reports a new hand location on every frame, and each report
/// used to become its own framed message. Past whatever the link can carry, that
/// queue only grows: every event lands later than the one before it, and the
/// whole gesture feels like it is trailing the hand. Coalescing keeps at most one
/// pending item of each kind. A pointer position is *replaced*, because the
/// positions a cursor passed through are not information anyone can act on. Scroll
/// distance is *accumulated*, because a dropped delta is distance the user asked
/// for and cannot ask for again.
///
/// This type sends nothing and owns no task. It is handed a monotonic timestamp
/// and answers with what to do, which is what lets every rule below be tested
/// without sleeping, without a clock and without a live connection.
struct InputCoalescer {
    /// Minimum spacing between sends once a gesture is under way: 60 Hz. The first
    /// send of a gesture is exempt, so beginning to point is never delayed.
    static let interval: TimeInterval = 1.0 / 60.0
    /// The bound one scroll message carries, matched to what the model has always
    /// put on the wire so coalescing cannot widen it.
    static let scrollLimit: Double = 500
    /// The most owed scroll distance held at once, per axis. Accumulation has to be
    /// bounded or it is not coalescing: finite per-frame deltas still sum without
    /// limit, and a long flick would otherwise either overflow to infinity or leave
    /// the Mac draining a backlog of scroll for whole seconds after the hand
    /// stopped. At `scrollLimit` per message and one message per `interval`, this
    /// budget drains in four flushes — about 67 ms — so what is owed is always
    /// something the user can still recognize as the gesture they just made.
    static let scrollBudget: Double = 2_000
    /// Under this, an accumulated scroll is numerically meaningless. It stays
    /// accumulated rather than going out as a no-op, which is what lets a slow
    /// drag still scroll instead of being rounded away a fraction at a time.
    static let scrollThreshold: Double = 0.01

    /// One pointer position, for one display.
    struct Move: Equatable {
        let displayID: UInt32
        let point: CGPoint
    }

    /// Scroll distance owed to one display, in the units the protocol carries.
    struct Scroll: Equatable {
        let displayID: UInt32
        var deltaX: Double
        var deltaY: Double
    }

    /// What the caller has to do about the input it just offered.
    enum Schedule: Equatable {
        /// Flush now. Nothing is being held back.
        case now
        /// Something is held back. Flush this many seconds from now, unless a
        /// flush is already scheduled to run sooner.
        case after(TimeInterval)
        /// Nothing to send and nothing to schedule.
        case idle
    }

    /// Everything one flush releases, in the order it has to reach the Mac.
    struct Batch: Equatable {
        var move: Move?
        var scroll: Scroll?
        /// `.after` only when real work remains — which is to say when the scroll
        /// bound could not carry the whole accumulation in one message.
        var next: Schedule
    }

    private var pendingMove: Move?
    private var pendingScroll: Scroll?
    /// Nil until something has gone out for the current gesture. That is the whole
    /// mechanism behind the first movement being immediate.
    private var lastSend: TimeInterval?
    /// The last position actually released. A repeat of it carries no information,
    /// and a hand held still does keep reporting the same location.
    private var lastReleased: Move?

    /// Whether a flush would produce an actual message. A retained sub-threshold
    /// scroll fraction is deliberately not "work": counting it would let a flush
    /// reschedule itself forever against a hand that has stopped moving.
    var hasPendingInput: Bool {
        if pendingMove != nil { return true }
        guard let pendingScroll else { return false }
        return abs(pendingScroll.deltaX) >= Self.scrollThreshold
            || abs(pendingScroll.deltaY) >= Self.scrollThreshold
    }

    /// Begins a new gesture with no history, so its first movement goes out
    /// untouched no matter what the previous gesture was doing.
    mutating func reset() {
        pendingMove = nil
        pendingScroll = nil
        lastSend = nil
        lastReleased = nil
    }

    /// Drops held-back input without sending it, for every path that ends a
    /// gesture the user did not finish. A position recorded before a cancel, a
    /// lost window or a revoked grant must never arrive after it.
    mutating func discard() {
        pendingMove = nil
        pendingScroll = nil
    }

    mutating func offer(move point: CGPoint, displayID: UInt32, now: TimeInterval) -> Schedule {
        let move = Move(displayID: displayID, point: point)
        if move == lastReleased, pendingMove == nil { return .idle }
        // Latest-only: one slot, overwritten.
        pendingMove = move
        return schedule(at: now)
    }

    mutating func offer(
        scrollX deltaX: Double, scrollY deltaY: Double, displayID: UInt32, now: TimeInterval
    ) -> Schedule {
        // One frame of hand travel cannot owe more than one message carries, so a
        // single absurd report cannot by itself fill the budget below.
        let offeredX = Self.bounded(deltaX, to: Self.scrollLimit)
        let offeredY = Self.bounded(deltaY, to: Self.scrollLimit)
        guard offeredX != 0 || offeredY != 0 else {
            return hasPendingInput ? schedule(at: now) : .idle
        }
        if var pending = pendingScroll, pending.displayID == displayID {
            // Bounded accumulation. Summing finite deltas without a cap is how an
            // owed total reaches infinity, or a length of time the user would feel
            // as the Mac scrolling on its own after the hand stopped.
            pending.deltaX = Self.bounded(pending.deltaX + offeredX, to: Self.scrollBudget)
            pending.deltaY = Self.bounded(pending.deltaY + offeredY, to: Self.scrollBudget)
            pendingScroll = pending
        } else {
            // A different display means the distance owed belongs to a screen
            // this gesture is not scrolling, so it is not carried across.
            pendingScroll = Scroll(displayID: displayID, deltaX: offeredX, deltaY: offeredY)
        }
        return schedule(at: now)
    }

    /// Releases what was held back and records that it went out at `now`.
    mutating func flush(now: TimeInterval) -> Batch {
        let move = pendingMove
        pendingMove = nil
        var scroll: Scroll?
        if var pending = pendingScroll {
            let deltaX = Self.bounded(pending.deltaX, to: Self.scrollLimit)
            let deltaY = Self.bounded(pending.deltaY, to: Self.scrollLimit)
            if abs(deltaX) >= Self.scrollThreshold || abs(deltaY) >= Self.scrollThreshold {
                scroll = Scroll(displayID: pending.displayID, deltaX: deltaX, deltaY: deltaY)
                // Whatever the bound could not carry stays owed, so a flick
                // scrolls the same distance as the same motion made slowly.
                pending.deltaX -= deltaX
                pending.deltaY -= deltaY
                pendingScroll = (pending.deltaX != 0 || pending.deltaY != 0) ? pending : nil
            }
            // Under the threshold nothing is sent and nothing is subtracted: the
            // fraction keeps accumulating instead of being discarded.
        }
        if let move { lastReleased = move }
        // An unusable timestamp leaves the budget as it was rather than poisoning
        // it: comparing against an older send only makes the next offer sooner,
        // which is the safe direction.
        if move != nil || scroll != nil, now.isFinite { lastSend = now }
        return Batch(move: move, scroll: scroll, next: hasPendingInput ? .after(Self.interval) : .idle)
    }

    /// `.now` while the 60 Hz budget allows another send — including the first
    /// send of a gesture — and otherwise the wait still owed.
    private func schedule(at now: TimeInterval) -> Schedule {
        guard let lastSend, now.isFinite else { return .now }
        let elapsed = now - lastSend
        // A clock that appears to move backwards must not strand pending input.
        // Subtracting two large uptimes can leave a tiny rounding residue exactly at the
        // boundary. A sub-nanosecond task adds no useful pacing and needlessly wakes the UI.
        guard elapsed >= 0, elapsed < Self.interval - 1e-9 else { return .now }
        return .after(Self.interval - elapsed)
    }

    private static func bounded(_ delta: Double, to limit: Double) -> Double {
        guard delta.isFinite else { return 0 }
        return max(-limit, min(limit, delta))
    }
}
