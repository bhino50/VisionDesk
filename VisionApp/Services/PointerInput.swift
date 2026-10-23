import CoreGraphics
import DeskCore
import Foundation

/// Turns gestures, clicks and typing on the session's displays into input messages.
///
/// This is the half of the client that decides what reaches the Mac's pointer and keyboard:
/// one gesture owns the pointer at a time, held-back movement is coalesced and drained in
/// order, every press is matched by a release on every end path, and direct clicks aim at the selected target while trackpad clicks use
/// the previously placed pointer. It owns no connection. `DeskClientModel` supplies the gates and the
/// one send path. A send that fails may end the session — and re-enter this object through
/// `releaseGesture` and `forgetAllPositions` — before the call that made it returns, which is
/// why gesture state is re-read after every send rather than assumed.
@MainActor
final class PointerInput {
    /// Whether ordinary input may reach this display now: control granted, a window active and
    /// a fresh frame. A release is deliberately gated only by `isLinked`.
    var canControl: @MainActor (UInt32) -> Bool = { _ in false }
    /// Whether the session is linked, which is the only gate a release needs.
    var isLinked: @MainActor () -> Bool = { false }
    /// Queues one message for the Mac. False when it was not queued, and the failure may
    /// already have ended the session.
    var send: @MainActor (DeskMessage) -> Bool = { _ in false }
    /// Called when the set of displays with a placed pointer changes, and only then.
    var onPointedDisplaysChanged: @MainActor (Set<UInt32>) -> Void = { _ in }

    /// Points of Mac scroll per point of hand travel.
    private static let scrollScale = 1.4

    private struct ActiveGesture {
        let token: UUID
        let displayID: UInt32
        let mode: ScreenInteractionMode
        let start: CGPoint
        let pointerOrigin: CGPoint
        var lastTranslation: CGSize
        var buttonHeld: Bool
    }

    /// Where each display's pointer was last sent: the place every click and release lands.
    private var lastPoints: [UInt32: CGPoint] = [:]
    private var activeGesture: ActiveGesture?
    // Retire completed/cancelled recognizers so a late callback cannot press again. The
    // surface assigns a new UUID to every pinch; retaining the last 64 keeps this bounded.
    private var retiredGestureTokens: [UUID] = []
    /// Holds back pointer movement and scroll so a gesture cannot queue one framed
    /// message per reported frame. Decision-making only; the sends stay here.
    private var coalescer = InputCoalescer()
    /// The single flush in flight, or nil. There is never a second, and there is
    /// never one at all while nothing is held back.
    private var flushTask: Task<Void, Never>?
    /// A recognizer reset waiting to find out whether a completion follows it. Nil whenever
    /// no reset is outstanding; see `gestureStateDidReset`.
    private var settleTask: Task<Void, Never>?

    /// The display the active gesture belongs to, if one owns the pointer.
    var activeDisplayID: UInt32? { activeGesture?.displayID }
    var canPerformDiscreteAction: Bool { activeGesture == nil }

    func hasPosition(displayID: UInt32) -> Bool {
        lastPoints[displayID] != nil
    }

    /// Forgets one display's pointer, for a display that went away or whose geometry changed.
    /// The caller releases a gesture on that display first, while its position still exists.
    func forgetPosition(displayID: UInt32) {
        guard lastPoints.removeValue(forKey: displayID) != nil else { return }
        onPointedDisplaysChanged(Set(lastPoints.keys))
    }

    func forgetAllPositions() {
        guard !lastPoints.isEmpty else { return }
        lastPoints = [:]
        onPointedDisplaysChanged([])
    }

    // MARK: Clicks

    /// A primary click where this display's pointer already is: the toolbar's Left click, the
    /// surface's assistive action and, through `tapClick`, the Pointer tap.
    ///
    /// None of them aims. The pointer is wherever it was last actually sent to the Mac — the
    /// same position the right- and double-click actions beside it use. Until something has
    /// placed it on this display there is no such position, and the click is refused rather
    /// than aimed at a guess: the old centre fallback moved the Mac's pointer to the middle of
    /// the screen and clicked there, which is the click-that-moves-the-cursor this exists to
    /// prevent, and every reconnection reset each display to that guess without the wearer
    /// necessarily noticing. It is refused while any gesture owns the pointer, too, so it can
    /// never interleave with one.
    func clickAtLastPointer(displayID: UInt32) {
        guard activeGesture == nil, canControl(displayID),
              let point = lastPoints[displayID] else { return }
        leftClick(displayID: displayID, at: point)
    }

    /// Pointer mode's click: the surface's native tap, pressed where the pointer already is.
    ///
    /// The tapped location is validated as proof of a tap on the picture and never used to aim.
    /// In a headset it is wherever the wearer happened to look, so clicking there would move the
    /// pointer first. The surface tries this tap before the Pointer pan, and the pan recognizes
    /// only after real travel, so one pinch is a click or a pan and its jitter moves nothing.
    ///
    /// Should a same-display Pointer pan still own the pointer when a tap arrives, the tap
    /// cancels it rather than finishing it: movement the pan held back never reached the Mac and
    /// is discarded, because draining it ahead of the press is exactly a click that moves the
    /// pointer. The pan holds no button, so cancelling it sends nothing, and its retired token
    /// leaves a late change, completion or reset nothing to act on.
    ///
    /// Anything else that owns the pointer — a Drag holding the button, a Scroll, a gesture on
    /// another display — keeps it, and the tap is refused rather than interleaved.
    /// A direct spatial tap aims and clicks in one action, including on a fresh display.
    /// An existing gesture keeps ownership, even on this display; the surface arbitrates a
    /// tap against a drag with an exclusive recognizer rather than interrupting a held button.
    func directTapClick(displayID: UInt32, at point: CGPoint) {
        guard activeGesture == nil, canControl(displayID), valid(point) else { return }
        leftClick(displayID: displayID, at: point)
    }

    func tapClick(displayID: UInt32, at point: CGPoint) {
        guard canControl(displayID), valid(point) else { return }
        if let active = activeGesture {
            guard active.mode == .pointer, active.displayID == displayID else { return }
            cancelGesture(token: active.token)
        }
        clickAtLastPointer(displayID: displayID)
    }

    func click(displayID: UInt32, action: String) {
        // Refused before anything drains or releases: a click this display cannot place must
        // not end another display's gesture on its way to being refused.
        guard activeGesture == nil, canControl(displayID), lastPoints[displayID] != nil,
              ["rightClick", "doubleClick"].contains(action) else { return }
        // Discrete buttons cannot interrupt a gesture. Any remaining queued input must
        // succeed before the click, and the position is read again after that send.
        guard flushPendingInput(drain: true) else { return }
        releaseGesture()
        guard let point = lastPoints[displayID] else { return }
        move(displayID: displayID, point: point)
        input(displayID: displayID, action: action, point: point)
    }

    /// Moves this display's pointer and presses nothing: placement asked for by name. An
    /// assistive activation carries no hand position, so a wearer who cannot pinch and move
    /// would otherwise have no way to give a click somewhere to land now that clicks never
    /// guess. The move is the request itself, never a side effect of a click, and like every
    /// click it is refused while any gesture owns the pointer.
    func placePointer(displayID: UInt32, at point: CGPoint) {
        guard activeGesture == nil, canControl(displayID), valid(point) else { return }
        move(displayID: displayID, point: point)
    }

    /// One press and its release, driven through the ordinary gesture lifecycle rather than as a
    /// loose pair, so it inherits every rule a pinch already has: the recognizer is recorded
    /// before any pointer event leaves, a failed send releases it on the way out, the token is
    /// retired afterwards, and the drain still orders held-back movement ahead of the click. A
    /// raw down/up pair would be an unrecorded gesture, and a send that failed between the two
    /// would leave the Mac's button down with nothing able to lift it. Nothing new reaches the
    /// Mac: this is the sequence a Drag pinch already sends. Callers decide whether a click may
    /// happen at all; `updateGesture` still re-checks control and the coordinate.
    private func leftClick(displayID: UInt32, at point: CGPoint) {
        let token = UUID()
        updateGesture(token: token, displayID: displayID, mode: .interact,
                      start: point, point: point, translation: .zero)
        finishGesture(token: token, displayID: displayID, mode: .interact,
                      start: point, point: point, translation: .zero)
    }

    // MARK: Typing

    /// Finish owed pointer input before a keyboard queue takes over the focused app.
    func prepareKeyboardInput(displayID: UInt32) -> Bool {
        guard canControl(displayID), flushPendingInput(drain: true) else { return false }
        releaseGesture()
        return canControl(displayID)
    }

    func sendText(_ text: String, displayID: UInt32) -> Bool {
        guard canControl(displayID), !text.isEmpty, text.utf8.count <= 4_096 else { return false }
        // Held-back movement is ordered ahead of the text, and a flush that failed has
        // already dropped the session, so there is nothing left to type into.
        guard prepareKeyboardInput(displayID: displayID) else { return false }
        return send(DeskMessage(kind: "input", displayID: displayID, action: "text", text: text))
    }

    func sendKey(_ key: String, displayID: UInt32) {
        guard canControl(displayID), DeskMessage.supportedKeys.contains(key) else { return }
        guard prepareKeyboardInput(displayID: displayID) else { return }
        _ = send(DeskMessage(kind: "input", displayID: displayID, action: "key", text: key))
    }

    // MARK: Gesture lifecycle

    func updateGesture(
        token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
        start: CGPoint, point: CGPoint, translation: CGSize
    ) {
        guard !retiredGestureTokens.contains(token) else { return }
        guard canControl(displayID), valid(start),
              point.x.isFinite, point.y.isFinite, mode == .pointer || valid(point),
              translation.width.isFinite, translation.height.isFinite else {
            cancelGesture(token: token)
            return
        }
        // One Mac pointer cannot be in two drags at once, so the first gesture keeps it until
        // it ends, is cancelled, or loses control. A second window's drag is ignored rather
        // than interleaved as a leftUp/leftDown storm across two displays.
        if let active = activeGesture,
           active.token != token || active.displayID != displayID || active.mode != mode { return }
        if activeGesture == nil {
            // Record the gesture before any pointer event leaves, so every failure path below
            // still has releasable state. A leftUp with no leftDown is the safe direction; a
            // leftDown with no recorded gesture holds the Mac's button down with nothing able
            // to lift it.
            activeGesture = ActiveGesture(
                token: token, displayID: displayID, mode: mode,
                start: start, pointerOrigin: mode == .pointer ? (lastPoints[displayID] ?? start) : start,
                lastTranslation: .zero, buttonHeld: false
            )
            // A fresh budget, so this first position goes out with no added wait. Starting
            // to point is the moment coalescing may not be felt in.
            cancelPendingInput()
            coalescer.reset()
            offerMove(displayID: displayID, point: activeGesture?.pointerOrigin ?? start)
            if mode == .interact || mode == .direct {
                // A failed send disconnects, which has already released this gesture; a
                // revoked gate drops the press. Either way nothing is held on the Mac.
                guard activeGesture?.token == token,
                      input(displayID: displayID, action: "leftDown", point: start) else {
                    releaseGesture()
                    return
                }
                activeGesture?.buttonHeld = true
            }
        }
        guard var gesture = activeGesture, gesture.token == token else { return }
        if gesture.mode == .pointer {
            // Repositioning the hand starts a fresh relative stroke, not a jump to
            // the new gaze target. Direct interaction remains absolute.
            let relative = CGPoint(
                x: min(1, max(0, gesture.pointerOrigin.x + (point.x - gesture.start.x))),
                y: min(1, max(0, gesture.pointerOrigin.y + (point.y - gesture.start.y)))
            )
            offerMove(displayID: displayID, point: relative)
        } else if gesture.mode != .scroll {
            offerMove(displayID: displayID, point: point)
        } else {
            // Per-callback deltas, so coalescing them by addition is exactly the distance
            // between the first and last translation: no scroll is invented or lost.
            offerScroll(
                displayID: displayID,
                deltaX: -Double(translation.width - gesture.lastTranslation.width) * Self.scrollScale,
                deltaY: -Double(translation.height - gesture.lastTranslation.height) * Self.scrollScale
            )
        }
        gesture.lastTranslation = translation
        // A failed send disconnects and releases. Never write a released gesture back.
        if activeGesture?.token == token { activeGesture = gesture }
    }

    /// A finished gesture. The hand's last position is what decides where a click lands, so
    /// anything held back reaches the Mac before the button comes up.
    ///
    /// The flush sends synchronously and can fail, and a failed send is a drop: it tears the
    /// session down, which releases this gesture and lifts the button on its way out. So the
    /// token is re-checked afterwards rather than assumed, and `releaseGesture` is reached
    /// only while this gesture is still the active one. Calling it twice would be harmless —
    /// it is nil-guarded — but relying on that would hide the reentrancy.
    func endGesture(token: UUID) {
        guard activeGesture?.token == token else { return }
        flushPendingInput(drain: true)
        guard activeGesture?.token == token else { return }
        // A Pointer pan ends with movement only, however little the hand moved: it never
        // presses. Its click is the surface's native tap, which reaches `tapClick` on its own.
        releaseGesture()
    }

    /// A final callback may follow cancellation. It can update an existing drag, but must
    /// never create a new mouse-down after that drag has already ended. A completion that
    /// arrives with no changed callback is ignored for the same reason; in Pointer mode that
    /// loses nothing, because Pointer clicks come from the native tap rather than from here.
    func finishGesture(token: UUID, displayID: UInt32, mode: ScreenInteractionMode,
                       start: CGPoint, point: CGPoint, translation: CGSize) {
        guard activeGesture?.token == token else { return }
        updateGesture(token: token, displayID: displayID, mode: mode,
                      start: start, point: point, translation: translation)
        endGesture(token: token)
    }

    /// A cancelled gesture, which is not the same thing. SwiftUI cancels for a lost window or
    /// an interrupted hand, and a position recorded before that would land as a pointer jump
    /// nobody asked for, so it is dropped. The held button is still lifted.
    ///
    /// Token-scoped on purpose: a second hand's cancel may not discard the winning gesture's
    /// movement any more than it may release its button.
    func cancelGesture(token: UUID) {
        guard activeGesture?.token == token else { return }
        releaseGesture()
    }

    /// SwiftUI has reset this gesture's recognizer state, which it does for a completed drag
    /// and a cancelled one alike — and the surface can observe that reset either before or
    /// after the completion callback. Deciding which it was at the call site would make the
    /// drain depend on an order SwiftUI does not document: observed first, it would discard
    /// the movement and scroll a finished gesture still owes the Mac, which is exactly the
    /// loss `endGesture`'s drain exists to prevent.
    ///
    /// So a reset claims nothing. It schedules a settlement for the next turn of this actor,
    /// and whichever signal arrives first decides:
    ///
    /// - completion first: `endGesture` drains, releases, and cancels the settlement;
    /// - reset first: the settlement is still pending, so `endGesture` still finds this
    ///   gesture active and still drains;
    /// - a real cancellation: no completion ever arrives, so the settlement cancels.
    ///
    /// Both orders therefore produce the same wire traffic. The button is never left down by
    /// this deferral — every other release path (focus loss, revoked grant, heartbeat,
    /// teardown) still fires on its own and still reaches `releaseGesture`.
    func gestureStateDidReset(token: UUID) {
        guard activeGesture?.token == token else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.settleTask = nil
            // Still the active gesture means no completion arrived: a genuine cancellation.
            self.cancelGesture(token: token)
        }
    }

    /// Drops whatever was held back, then lifts the button if one is down. Every path that
    /// ends a gesture the user did not finish arrives here — a cancel, a glance away, a
    /// revoked grant, a removed display, a teardown — so discarding is the default and only
    /// `endGesture` flushes first. Nothing recorded before the release can land after it.
    func releaseGesture() {
        // Every end path arrives here, so this is where an outstanding recognizer reset stops
        // being able to cancel a gesture that something else has already settled.
        settleTask?.cancel()
        settleTask = nil
        cancelPendingInput()
        guard let gesture = activeGesture else { return }
        retiredGestureTokens.append(gesture.token)
        if retiredGestureTokens.count > 64 { retiredGestureTokens.removeFirst() }
        activeGesture = nil
        if gesture.buttonHeld, isLinked() {
            // Releases remain allowed after local control state has been revoked. A held button
            // always has a sent position, because its press followed one; the fallback is only
            // defensive, and the Mac posts the release wherever this says.
            let point = lastPoints[gesture.displayID] ?? CGPoint(x: 0.5, y: 0.5)
            input(displayID: gesture.displayID, action: "leftUp", point: point)
        }
    }

    // MARK: Coalescing

    private func offerMove(displayID: UInt32, point: CGPoint) {
        act(on: coalescer.offer(move: point, displayID: displayID, now: Self.now()))
    }

    private func offerScroll(displayID: UInt32, deltaX: Double, deltaY: Double) {
        act(on: coalescer.offer(scrollX: deltaX, scrollY: deltaY, displayID: displayID, now: Self.now()))
    }

    private func act(on schedule: InputCoalescer.Schedule) {
        switch schedule {
        case .now: flushPendingInput()
        case .after(let seconds): scheduleFlush(after: seconds)
        case .idle: break
        }
    }

    /// Sends what was held back, pointer before scroll, and reschedules only when the
    /// protocol's own scroll bound could not carry the whole accumulation at once.
    @discardableResult
    private func flushPendingInput(drain: Bool = false) -> Bool {
        if drain {
            flushTask?.cancel()
            flushTask = nil
        }
        // A completed gesture or discrete action is an ordering barrier. Drain the
        // bounded scroll budget now; releaseGesture would otherwise discard all
        // but its first 500-pixel chunk. Ordinary movement keeps the 60 Hz cadence.
        let maximumBatches = drain ? Int((InputCoalescer.scrollBudget / InputCoalescer.scrollLimit).rounded(.up)) : 1
        for _ in 0..<maximumBatches {
            guard coalescer.hasPendingInput else { return true }
            let batch = coalescer.flush(now: Self.now())
            if let pointer = batch.move {
                guard move(displayID: pointer.displayID, point: pointer.point) else { return false }
            }
            if let scroll = batch.scroll {
                // A delayed scroll is gated the same as a live one, so a flush cannot deliver
                // distance to a display whose grant or frame went away while it waited.
                guard canControl(scroll.displayID),
                      send(DeskMessage(
                          kind: "input", displayID: scroll.displayID, action: "scroll",
                          deltaX: scroll.deltaX, deltaY: scroll.deltaY
                      )) else { return false }
            }
            if !drain, case .after(let seconds) = batch.next { scheduleFlush(after: seconds) }
        }
        return true
    }

    /// One flush, and only while something is actually held back. A repeating timer would
    /// wake this app sixty times a second to discover that a still hand has nothing to send.
    private func scheduleFlush(after seconds: TimeInterval) {
        guard flushTask == nil, coalescer.hasPendingInput else { return }
        // Clamped to the coalescing window, so no clock reading can stretch the wait.
        let wait = min(max(0, seconds), InputCoalescer.interval)
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPendingInput()
        }
    }

    private func cancelPendingInput() {
        flushTask?.cancel()
        flushTask = nil
        coalescer.discard()
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Sending

    /// Records the position only once it was queued for the Mac, so `lastPoints` is always where
    /// the Mac's pointer was last sent: the place every cursor click and release lands. A move a
    /// gate refused moved nothing, and a failed send has already cleared the session.
    @discardableResult
    private func move(displayID: UInt32, point: CGPoint) -> Bool {
        guard input(displayID: displayID, action: "move", point: point) else { return false }
        let isNewlyPlaced = lastPoints.updateValue(point, forKey: displayID) == nil
        if isNewlyPlaced { onPointedDisplaysChanged(Set(lastPoints.keys)) }
        return true
    }

    /// Reports whether the event was queued, so a gesture never assumes a button is down
    /// after a control gate flipped or a send failed. Transport receipt is asynchronous.
    @discardableResult
    private func input(displayID: UInt32, action: String, point: CGPoint) -> Bool {
        // A release must survive freshness expiry between a tap's down and up events.
        // The linked transport and coordinate validation still apply to every release.
        guard valid(point), action == "leftUp" ? isLinked() : canControl(displayID) else { return false }
        return send(DeskMessage(
            kind: "input", displayID: displayID,
            x: Double(point.x), y: Double(point.y), action: action
        ))
    }

    private func valid(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}
