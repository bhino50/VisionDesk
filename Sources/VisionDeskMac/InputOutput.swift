import AppKit
import ApplicationServices
import DeskCore

/// Answers "may this process post input events right now", caching only the expensive half.
///
/// Measured on this Mac (`evidence/input-preflight-latency-2026-10-04.txt`),
/// `CGPreflightPostEventAccess()` costs about 7.41ms at the median and 9.41ms at the 95th
/// percentile, while a warm `AXIsProcessTrusted()` costs about 0.00033ms. Every input event
/// asks for permission twice, once in `CompanionModel.receive` before the event is counted and
/// again in `InputOutput.apply` before it is posted, so the preflight alone spent roughly 15ms
/// of main-actor time per event, against a rate limit that admits 240 events a second.
///
/// So a preflight answer is reused for at most `maximumAge`. That collapses the duplicate pair
/// into one call and bounds a burst to one preflight per window. Quartz stays authoritative:
/// nothing here grants anything, the window is short, Accessibility trust is read on every
/// call, and a cached answer is dropped the moment that trust is gone.
struct InputPermissionCache {
    /// Longest a preflight answer may be reused. Deliberately short, because this is also the
    /// window in which a change only the preflight can report may still be served stale.
    static let maximumAge: TimeInterval = 0.25

    private let isTrusted: () -> Bool
    private let canPostEvents: () -> Bool
    private let now: () -> TimeInterval
    private var cached: (isAllowed: Bool, at: TimeInterval)?

    /// Defaults to the two live Quartz probes and the monotonic clock the rest of this file
    /// already uses. Checks inject fakes, so none of this depends on the running Mac's grants.
    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         canPostEvents: @escaping () -> Bool = { CGPreflightPostEventAccess() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isTrusted = isTrusted
        self.canPostEvents = canPostEvents
        self.now = now
    }

    /// Reads Accessibility trust every time and the event-post preflight at most once per
    /// `maximumAge`. A denial is cached like a grant, so a run without permission does not pay
    /// the preflight per event either; `InputOutput.requestPermission()` invalidates around the
    /// prompt so a grant the person just gave is never hidden behind a cached denial.
    mutating func isAllowed() -> Bool {
        // Cheap, and the one answer that must never be stale: losing Accessibility has to fail
        // the very next event rather than whenever the window happens to end.
        guard isTrusted() else {
            cached = nil
            return false
        }
        let stamp = now()
        if let entry = cached {
            // Zero age is the duplicate pair this exists for. A clock that read backwards
            // expires the entry instead of extending it.
            let age = stamp - entry.at
            if age >= 0, age < Self.maximumAge { return entry.isAllowed }
        }
        let isAllowed = canPostEvents()
        cached = (isAllowed: isAllowed, at: stamp)
        return isAllowed
    }

    /// Drops any cached preflight, so the next `isAllowed()` asks Quartz again.
    mutating func invalidate() { cached = nil }
}

/// Preserve small continuous scroll deltas across packets instead of rounding each away.
/// The remainder stays below half a pixel, so this never becomes an input backlog.
struct ScrollRemainder {
    private var x: Double = 0
    private var y: Double = 0
    mutating func take(x deltaX: Double?, y deltaY: Double?) -> (x: Int32, y: Int32) {
        func step(_ delta: Double?, remainder: inout Double) -> Int32 {
            guard let delta, delta.isFinite else { return 0 }
            let sum = min(2_000, max(-2_000, delta)) + remainder
            let rounded = min(2_000, max(-2_000, sum.rounded()))
            remainder = sum - rounded
            // Saturation must not leave a large stored delta to leak into a later gesture.
            remainder = min(0.5, max(-0.5, remainder))
            return Int32(rounded)
        }
        return (step(deltaX, remainder: &x), step(deltaY, remainder: &y))
    }
}

/// Posts Quartz events for the `input` messages the headset sends.
///
/// The macOS event conventions below are adapted from the MIT-licensed Enigo component
/// vendored in RustDesk (`libs/enigo`, crate `enigo` 0.0.14, Copyright (c) 2017 pythoneer),
/// read at `rustdesk/rustdesk` commit `e5bc204fe4dacc4db9c3cdb1f1338813986c89e7`. No Rust
/// source is copied; this is a Swift reimplementation of the observable behavior. The MIT
/// text is preserved verbatim in `docs/third-party/ENIGO-LICENSE.txt`, and the per-behavior
/// mapping, the AGPL boundary for the rest of RustDesk, and the residual limits are recorded
/// in `docs/RUSTDESK_INPUT.md`.
///
/// Every path requires Accessibility at use time. Posting a CGEvent reports no delivery
/// status, so "posted" here only ever means constructed and handed to the HID tap.
@MainActor
final class InputOutput {
    /// Enigo builds its source with `CGEventSourceStateID::CombinedSessionState`, which
    /// describes the session including synthesized input rather than the raw hardware.
    private let source = CGEventSource(stateID: .combinedSessionState)

    /// Our own record of the left button. Set only once a down event actually exists, so a
    /// construction failure can never be counted as a held button.
    private var held = false

    /// The last point an event was posted at, so a release never has to fall back to (0, 0).
    private var lastPoint: CGPoint?
    private var scrollRemainder = ScrollRemainder()
    private var scrollDisplay: UInt32?

    private(set) var dragStarted: TimeInterval?

    /// Shared by every caller, so the pair of checks each event makes costs one preflight.
    private var permission = InputPermissionCache()

    /// A source tag lets the opt-in local diagnostic distinguish our posted events from a
    /// person's hardware input. Remote messages cannot set it. Checks pass a permission cache with
    /// fake probes, so they never depend on this Mac's own grants.
    init(diagnosticTag: Int64 = 0, permission: InputPermissionCache = InputPermissionCache()) {
        self.permission = permission
        source?.userData = diagnosticTag
    }
    func setDiagnosticTag(_ tag: Int64) { source?.userData = tag }

    /// Still `AXIsProcessTrusted() && CGPreflightPostEventAccess()`, except the preflight half
    /// may be answered from the last one inside `InputPermissionCache.maximumAge`. Reading this
    /// can therefore call Quartz, exactly as it always could.
    var hasPermission: Bool { permission.isAllowed() }

    /// Invalidates on both sides of the prompt: before, so nothing reuses an answer taken
    /// moments before the person was asked, and after, so a grant made during the prompt is
    /// visible to the very next check rather than up to a window later.
    func requestPermission() {
        permission.invalidate()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        permission.invalidate()
    }

    /// Always posts the matching up while `held`, then clears the hold unconditionally so the
    /// watchdog can never be left waiting on a drag that has already ended.
    func release() {
        if held { post(.leftMouseUp, point: currentPoint()) }
        held = false
        dragStarted = nil
        scrollRemainder = ScrollRemainder(); scrollDisplay = nil
    }

    func apply(_ message: DeskMessage) {
        guard hasPermission, let id = message.displayID, CGDisplayIsOnline(id) != 0 else { return }
        let point = Self.point(x: message.x, y: message.y, in: CGDisplayBounds(id))
        switch message.action {
        case "move":
            scrollRemainder = ScrollRemainder(); scrollDisplay = nil
            guard let point else { return }
            post(isDragging() ? .leftMouseDragged : .mouseMoved, point: point)
        case "leftDown":
            guard let point, !held else { return }
            // Enigo takes the button down at the cursor's current location, after a separate
            // move, so the view under the pointer sees the hover before the press.
            post(.mouseMoved, point: point)
            guard post(.leftMouseDown, point: point) else { return }
            held = true
            dragStarted = ProcessInfo.processInfo.systemUptime
        case "leftUp":
            guard held else { return }
            post(.leftMouseUp, point: point ?? currentPoint())
            held = false
            dragStarted = nil
        case "rightClick":
            guard let point else { return }
            release()
            post(.mouseMoved, point: point)
            postAtomically([Step(.rightMouseDown, point, .right), Step(.rightMouseUp, point, .right)])
        case "doubleClick":
            guard let point else { return }
            release()
            post(.mouseMoved, point: point)
            // Click state 2 on the second pair is what makes the system read a double click;
            // Enigo likewise only sets the field once the count passes one.
            postAtomically((1...2).flatMap { count in
                [Step(.leftMouseDown, point, .left, count), Step(.leftMouseUp, point, .left, count)]
            })
        case "scroll":
            if scrollDisplay != id { scrollRemainder = ScrollRemainder(); scrollDisplay = id }
            scroll(deltaX: message.deltaX, deltaY: message.deltaY, point: point)
        case "text":
            guard let text = message.text, !text.isEmpty else { return }
            for chunk in Self.textChunks(text) { type(chunk) }
        case "key":
            guard let name = message.text, let shortcut = Self.keys[name] else { return }
            press(code: shortcut.0, flags: shortcut.1)
        default: break
        }
    }

    // MARK: - Pointer

    /// Reconciles the recorded hold against the live button state the way Enigo picks its
    /// move event type, from `NSEvent.pressedMouseButtons`. This only ever retires a hold the
    /// system no longer reports; it never invents one, so a dropped event cannot leave the
    /// watchdog guarding a phantom drag. The grace window keeps a down posted microseconds
    /// ago from being retired before the HID state catches up.
    private func isDragging() -> Bool {
        guard held else { return false }
        if NSEvent.pressedMouseButtons & 1 != 0 { return true }
        guard let started = dragStarted,
              ProcessInfo.processInfo.systemUptime - started >= Self.holdReconcileGrace else { return true }
        held = false
        dragStarted = nil
        return false
    }

    private func scroll(deltaX: Double?, deltaY: Double?, point: CGPoint?) {
        let units = scrollRemainder.take(x: deltaX, y: deltaY)
        let wheelY = units.y
        let wheelX = units.x
        guard wheelY != 0 || wheelX != 0 else { return }
        // Enigo never moves the pointer to scroll. Only an explicitly addressed point moves it,
        // so a scroll aimed at another display cannot drag the cursor across screens.
        if let point { post(isDragging() ? .leftMouseDragged : .mouseMoved, point: point) }
        // wheel1 is vertical and wheel2 is horizontal, matching Enigo's wheel-count usage.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: wheelY, wheel2: wheelX, wheel3: 0) else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    static let holdReconcileGrace: TimeInterval = 0.25

    /// Maps normalized coordinates onto the display's global point rectangle. `CGDisplayBounds`
    /// is the same point-space rectangle `CompanionModel` publishes as `DisplayInfo.originX`
    /// and `pointWidth`, so this agrees with `DisplayInfo.point(x:y:)`. Re-validating here keeps
    /// an unvalidated caller from pushing the pointer off every screen.
    static func point(x: Double?, y: Double?, in bounds: CGRect) -> CGPoint? {
        guard let x, let y, isNormalized(x), isNormalized(y) else { return nil }
        return CGPoint(x: bounds.minX + x * max(0, bounds.width - 1),
                       y: bounds.minY + y * max(0, bounds.height - 1))
    }

    static func isNormalized(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }

    private func currentPoint() -> CGPoint { CGEvent(source: nil)?.location ?? lastPoint ?? .zero }

    // MARK: - Keyboard

    static let maximumTextChunkUnits = 20

    /// Splits UTF-16 for `keyboardSetUnicodeString` on extended grapheme cluster boundaries.
    ///
    /// Enigo sends one event per grapheme cluster for exactly this reason (enigo-rs/enigo#68),
    /// with a standing note to batch roughly twenty units at a time. Splitting mid-cluster
    /// delivers the pieces as separate insertions: a surrogate pair becomes two replacement
    /// characters, and a combining mark, ZWJ sequence or regional-indicator flag lands as two
    /// glyphs instead of one. Batching keeps the event count down without that risk.
    static func textChunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for cluster in text {
            let units = Array(String(cluster).utf16)
            if units.count > maximumTextChunkUnits {
                // A cluster past the bound cannot stay whole without an unbounded payload.
                if !current.isEmpty { chunks.append(current); current = [] }
                chunks.append(contentsOf: surrogateSafeChunks(units))
                continue
            }
            if current.count + units.count > maximumTextChunkUnits {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Last resort for a single cluster longer than the bound: split it, but never between the
    /// halves of a surrogate pair. Backing off requires at least two units, so this terminates.
    private static func surrogateSafeChunks(_ units: [UInt16]) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var offset = 0
        while offset < units.count {
            var end = min(offset + maximumTextChunkUnits, units.count)
            if end < units.count, end > offset + 1, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            chunks.append(Array(units[offset..<end]))
            offset = end
        }
        return chunks
    }

    static let keys: [String: (CGKeyCode, CGEventFlags)] = [
        "return": (36, []), "tab": (48, []), "escape": (53, []), "backspace": (51, []), "space": (49, []),
        "left": (123, []), "right": (124, []), "down": (125, []), "up": (126, []),
        "cmd+c": (8, .maskCommand), "cmd+v": (9, .maskCommand), "cmd+a": (0, .maskCommand),
        "cmd+z": (6, .maskCommand), "cmd+shift+z": (6, [.maskCommand, .maskShift]), "cmd+space": (49, .maskCommand)
    ]

    /// Unicode events do not change the clipboard or depend on keyboard layout. Both halves are
    /// built before either is posted so a failure cannot leave the virtual key logically down.
    private func type(_ chunk: [UInt16]) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        for event in [down, up] {
            chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
            // Enigo forces the flags on every event because macOS otherwise carries the previous
            // event's modifiers into the next one. Unqualified text must never inherit a stale
            // Shift or Command, which would upper-case it or fire a menu shortcut instead.
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    /// Both halves carry the shortcut's flags and both are built before either is posted, so a
    /// failure cannot strand a key or a modifier in the down state.
    private func press(code: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Posting

    private struct Step {
        let type: CGEventType
        let point: CGPoint
        let button: CGMouseButton
        let clickCount: Int64

        init(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left, _ clickCount: Int64 = 1) {
            self.type = type
            self.point = point
            self.button = button
            self.clickCount = clickCount
        }
    }

    private func makeEvent(_ step: Step) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: step.type,
                                  mouseCursorPosition: step.point, mouseButton: step.button) else { return nil }
        if step.clickCount > 1 { event.setIntegerValueField(.mouseEventClickState, value: step.clickCount) }
        // Same reason as the text path: a pointer event must not inherit a latched modifier.
        event.flags = []
        return event
    }

    /// Returns whether the event was constructed and handed to the HID tap. macOS reports no
    /// delivery result, so a `true` here is not evidence that anything consumed the event.
    @discardableResult
    private func post(_ type: CGEventType, point: CGPoint, button: CGMouseButton = .left, clickCount: Int64 = 1) -> Bool {
        guard let event = makeEvent(Step(type, point, button, clickCount)) else { return false }
        event.post(tap: .cghidEventTap)
        lastPoint = point
        return true
    }

    /// Builds every step before posting any of them, so a half-finished click can never leave a
    /// button down with no matching up.
    @discardableResult
    private func postAtomically(_ steps: [Step]) -> Bool {
        var events: [(CGEvent, CGPoint)] = []
        events.reserveCapacity(steps.count)
        for step in steps {
            guard let event = makeEvent(step) else { return false }
            events.append((event, step.point))
        }
        for (event, point) in events {
            event.post(tap: .cghidEventTap)
            lastPoint = point
        }
        return true
    }
}
