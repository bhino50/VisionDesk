# Mac input provenance and behavior

VisionDesk implements Mac input in Swift using Quartz. It does not embed the RustDesk
engine, relay, networking protocol, codec, or Rust sources. This document records the
input conventions consulted during development and the remaining verification limits.

## Upstream attribution

| Component | Source |
| --- | --- |
| MIT-licensed Enigo 0.0.14 | `libs/enigo/src/macos/macos_impl.rs` and `keycodes.rs` |
| Source revision inspected | `rustdesk/rustdesk` commit `e5bc204fe4dacc4db9c3cdb1f1338813986c89e7` |
| Upstream notice | [ENIGO-LICENSE.txt](third-party/ENIGO-LICENSE.txt) |

The preserved Enigo notice has SHA-256
`f4d766d1551a41e213da39e009ea71674e06c7203bcf9526beee583d920ae4eb`.
The component record and copyright details are in [third-party attribution](third-party/README.md).

The original implementation record says RustDesk's AGPL-licensed
`src/server/input_service.rs` was consulted to understand scroll signs, modifier reset
points, and how Enigo is called. No AGPL source, structure, or comment text was copied
or translated. Preserve this boundary: importing or porting additional upstream logic
requires a separate license review before including it in this MIT-licensed project.

## Behavior-by-behavior

### Changed

| # | Behavior | Upstream | Was | Now |
|---|---|---|---|---|
| 1 | Stale modifier flags | `Enigo::post_event` force-sets `event.set_flags` on every event, commented: macOS "may use the previous event flag to generate the next event" | flags never set — every event inherited whatever the source reported | `flags = []` on all pointer, scroll and Unicode events; `flags = shortcut` on key events |
| 2 | Click location | `mouse_down`/`mouse_up` fire at the cursor's current location, after a separate `mouse_move_to` | `leftDown`/`rightClick`/`doubleClick` posted the button with no preceding move | a `.mouseMoved` is posted to the target point first |
| 3 | Drag state | `mouse_move_to_impl` reads `NSEvent.pressedMouseButtons` live to pick `MouseMoved` vs `LeftMouseDragged` | internal `held` flag only, never reconciled | `isDragging()` reconciles `held` against `pressedMouseButtons`, after a 0.25 s grace |
| 4 | Failed construction | — | `held = true` was set even when `CGEvent(...)` returned nil | `held`/`dragStarted` are set only after the down event exists |
| 5 | Paired events | — | each half posted independently; a nil second half stranded a button or modifier | `postAtomically` / `press` / `type` build both halves first and post none unless all exist |
| 6 | Scroll cursor warp | Enigo never moves the pointer to scroll | every scroll posted a move to the current point clamped into the target display | the pointer moves only when the message carries normalized `x`/`y` |
| 7 | Unicode chunking | `key_sequence` emits one event per grapheme cluster (enigo-rs/enigo#68), with a standing TODO to batch ~20 units | split at 20 UTF-16 units, backing off only for surrogate pairs | batches whole grapheme clusters up to 20 units; `surrogateSafeChunks` is the fallback for a single oversize cluster |
| 8 | Delta conversion | — | `Int32(delta.rounded())` — **traps** on a non-finite delta | `ScrollRemainder.take` drops non-finite values, clamps to ±2000, and preserves subpixel distance; a zero result posts nothing |
| 9 | Coordinate trust | — | `x`/`y` used unvalidated | re-validated finite and `0...1` inside `InputOutput` |
| 10 | Release fallback | — | `release()` fell back to `.zero` — a lost `CGEvent(source:)` warped the pointer to the top-left corner | falls back to `lastPoint` |
| 11 | Event source | `CGEventSourceStateID::CombinedSessionState` | `.hidSystemState` | `.combinedSessionState` |

## Current delivery path

`VisionApp/Services/KeyboardDelivery.swift` bounds and sequences keyboard messages.
Only an explicit zero-work busy response is retried. A missing acknowledgement or
transport failure is ambiguous, so input is stopped rather than replayed into a possible
new destination. The Mac validates session/control ownership, rate limits, and message
contents before `InputOutput` constructs Quartz events.

Pointer, scroll, and keyboard input still require macOS Accessibility and event-posting
permission. Screen capture separately requires Screen Recording. Pairing, a successful
transport send, or an accepted message does not bypass those OS permissions.

## Verification limits

`CGEvent.post` does not report delivery to the intended application. Successful event
construction and a host acknowledgement do not prove that a visible text field received
all characters or that a headset gesture felt correct. Test fixtures and physical
application-receipt checks must be reported separately.

The Mac behavior harness exercises permission caching, event budgets, Unicode chunking,
scroll remainders, ownership, and lifecycle logic without injecting events. Native client
regressions exercise input queues and authenticated loopback sessions. See
[BUILD.md](../BUILD.md) for commands and repeated stress suites.

Physical acceptance should use non-sensitive sample content and check click, double
click, drag/release, scrolling across displays, Unicode typing, focus changes, reconnect,
and revoking control while a button is held. Verify that no input resumes after Stop
without the required consent. These checks remain specific to the tested build, devices,
OS versions, and network; this provenance document makes no physical acceptance claim.
