# Mac input: what was taken from RustDesk, and what was not

Scope: `Sources/VisionDeskMac/InputOutput.swift` only — the Quartz event path for the eight
`DeskMessage` actions (`move`, `leftDown`, `leftUp`, `rightClick`, `doubleClick`, `scroll`,
`text`, `key`). Transport, codec and UI are out of scope for this document.

## What this is not

VisionDesk does **not** embed the RustDesk engine. No RustDesk networking, codec, session,
relay or protocol code is present, and no Rust source is vendored. What follows is a Swift
reimplementation of observable macOS event conventions, verified against upstream source but
**not** against a running Mac: no Quartz event was posted while producing this change, and
macOS returns no delivery status from `CGEvent.post`, so nothing here is evidence that an
event reached an application. Root must confirm real behavior on hardware.

## Upstream read

| | |
|---|---|
| Clone | `rustdesk/rustdesk` at `e5bc204fe4dacc4db9c3cdb1f1338813986c89e7` |
| Adapted from (MIT) | `libs/enigo/src/macos/macos_impl.rs`, `libs/enigo/src/macos/keycodes.rs` |
| Read only (AGPL) | `src/server/input_service.rs` |

### License boundary

`libs/enigo` is **MIT** — crate `enigo` 0.0.14, Copyright (c) 2017 pythoneer, author Dustin
Bensing. The license text is preserved verbatim at
[`third-party/ENIGO-LICENSE.txt`](third-party/ENIGO-LICENSE.txt) (byte-identical to
`libs/enigo/LICENSE`, SHA-256 `f4d766d1551a41e213da39e009ea71674e06c7203bcf9526beee583d920ae4eb`),
with the component record in [`third-party/README.md`](third-party/README.md).
`InputOutput.swift` carries a header naming the component, the license file and the commit.

The RustDesk **main application is AGPL-3.0** (`LICENCE` at the clone root).
`src/server/input_service.rs` was read only, to see how the MIT primitives are driven in
production. The three facts recorded from it below are observed numeric and ordering
conventions, not expression; no AGPL code, structure or comment text is copied or translated.
**If anyone later wants to port actual `input_service.rs` logic, that is an AGPL decision and
must be raised before the code is written, not after.**

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

Item 6 is a live bug, not a theoretical one: `DeskClientModel.swift:264` sends `scroll` with
`deltaX`/`deltaY` and **no** `x`/`y`, so the old code warped the cursor to the clamped current
point on *every* scroll event — and across displays, since the clamp targeted the message's
display rather than the one the cursor was on.

Items 1, 2, 3 and 7 are the ones most likely to explain "RustDesk controls my Mac and this
doesn't." Item 1 alone makes typed text arrive upper-cased or fire menu shortcuts whenever a
modifier is latched; item 2 makes first clicks miss views that gate on hover tracking.

### Verified already correct — deliberately unchanged

- **Scroll axes and signs.** Upstream's net result is `wheel1 = evt.y`, `wheel2 = evt.x`.
  `input_service.rs` negates both (`x = -evt.x`; `y = -evt.y` off Windows) and
  `mouse_scroll_impl` negates again (`scroll_direction = -1` for positive length), so the two
  cancel. `wheel1` is vertical and `wheel2` is horizontal. Our `wheel1: deltaY, wheel2: deltaX`
  passed straight through **already matches.** No inversion was added. macOS applies the
  "natural scrolling" preference itself; inverting here would double-apply it.
- **Key codes.** All 15 entries in `InputOutput.keys` match `libs/enigo/src/macos/keycodes.rs`
  exactly: return 36/`0x24`, tab 48/`0x30`, space 49/`0x31`, backspace 51/`0x33`,
  escape 53/`0x35`, arrows 123–126/`0x7B`–`0x7E`, A 0, Z 6, C 8, V 9.
- **Flags-as-modifiers for shortcuts.** Enigo's legacy path uses `add_flag`/`reset_flag` rather
  than separate modifier key events. Setting `CGEventFlags` on both halves matches it.

### Divergences taken on purpose

- **Unicode posts down *and* up.** Enigo posts the key-down only. A down for virtual key 0
  (`kVK_ANSI_A`) with no up leaves that key logically down in the session state; RustDesk
  tolerates this because `fix_key_down_timeout` force-releases stuck keys after 360 s, and we
  have no such sweeper. Both halves carry the same Unicode payload, and insertion happens on
  key-down, so this should not double-insert — **but it is the first thing to check if text
  arrives doubled.**
- **Pixel scroll units, one event per message.** Enigo uses `Line` for a wheel and `Pixel` for
  a trackpad, emitting `|length|` single-unit events. A headset pinch-drag is continuous, so
  `Pixel` fits; one event per message keeps latency down, which matters for the
  "faster than RustDesk" goal.
- **No 12 ms `key_sleep`.** `input_service.rs` paces macOS key events by 12 ms because events
  are otherwise dropped and modifier releases missed. Replicating it synchronously would block
  `@MainActor` for ~2.5 s on a 4096-byte payload. See the open question below.
- **No `EVENT_SOURCE_USER_DATA` tag.** Enigo stamps `100` so it can recognize its own events.
  Nothing in VisionDesk reads injected events back, so there is nothing to filter yet.

## Residual limits

1. **Delivery is unverifiable.** `post()` returning `true` means constructed and handed to the
   HID tap — nothing more. Without Accessibility the post is a silent OS-level no-op, which is
   why `apply` gates on `hasPermission` first.
2. **No pacing.** If fast typing drops characters or sticks a modifier on real hardware, that
   is the missing `key_sleep`, and it needs an async design (below), not a spin loop.
3. **Hold reconciliation is one-way by design.** `isDragging()` can retire a hold the system no
   longer reports but can never create one. A button held by the *local* user reads the same as
   ours, so during the 0.25 s grace a genuinely-lost down still reads as held.
4. **A nil `CGEvent` is silent.** Construction failure returns `false` with no log and no status
   to the headset.
5. **Local event suppression untouched.** Posting with a source suppresses local hardware mouse
   events for the default interval (~0.25 s). Upstream does not configure this either. Harmless
   for unattended use; visible if someone is at the Mac.
6. **No pressure, tilt, middle button, back/forward, or horizontal-only trackpad gesture** —
   the protocol has no actions for them.
7. **Not run.** `script/test_mac_behavior.sh` was not executed here (`swiftc`/`script/*.sh` are
   outside this worker's permissions). `swift build --product VisionDeskMac` compiles clean.

## Note for the unattended four-screen Tailscale goal

Two input-side consequences, no code changes made for them:

- **Unattended means nobody can rescue a stuck button.** Invariants 4, 5 and 10 above carry more
  weight than they did with someone sitting at the Mac. The 30 s `dragStarted` watchdog in
  `CompanionModel` is the only backstop; it is preserved exactly.
- **Multi-display already works per-display.** Points are derived from `CGDisplayBounds(id)` per
  message, which agrees with `DisplayInfo.point(x:y:)`, so four screens need no input change.
  Fix 6 matters more here: cross-display scroll warping gets worse as displays are added.

## Open question for root — needs a decision, not a patch

Pacing text input requires making `apply` asynchronous, which changes ordering guarantees: a
later `key` could overtake an in-flight `text`, and `release()` would need to cancel queued
chunks. That is a protocol/lifecycle change across `CompanionModel`, which this worker does not
own. **Flagging rather than editing.** Only pursue it if hardware testing actually shows dropped
characters.

## Interfaces preserved

Unchanged for `Tests/MacBehaviorChecks/InputMappingChecks.swift`: `InputOutput.textChunks(_:)`,
`InputOutput.maximumTextChunkUnits`, `InputOutput.keys` (same `[String: (CGKeyCode, CGEventFlags)]`
type, same 15 entries). Unchanged for `CompanionModel`: `init()`, `hasPermission`,
`requestPermission()`, `release()`, `dragStarted`, `apply(_:)`. `DeskCore.DisplayInfo.point(x:y:)`
was not touched.

## Tests root must run

**Automated, no hardware:**

1. `script/test_mac_behavior.sh` — must stay green. All four input checks were traced by hand
   against the new chunker and pass: 30×🙂 → 3 chunks of 20 units; 19×"a"+🙂 → `[19, 2]`;
   `""` → `[]`; 20×"a" → 1; 21×"a" → 2; 4096×"a" → 205 chunks summing to 4096; key set still
   equals `DeskMessage.supportedKeys`. **Traced, not executed — confirm.**
2. `swift test` — unaffected, should stay green.

**On hardware, with Accessibility granted and test mode off** (each is a behavior this change
claims to fix; all are currently unverified):

3. **Drag.** Press on a Finder icon, move, release. Icon must follow continuously and drop at
   the release point. Previously the drag could begin with no hover event (fix 2).
4. **Stale modifier.** Hold Shift physically on the Mac, release it, then send `text` "hello"
   from the headset. Must arrive lower-case. Then send `key` `cmd+c`, then `text` "abc" — the
   text must not trigger menu shortcuts (fix 1).
5. **Scroll must not warp.** Put the cursor on display A, send `scroll` targeting display B.
   The cursor must not move at all (fix 6). Then confirm scroll direction matches the Mac's
   own "natural scrolling" setting in both axes, and flip that setting and re-check.
6. **Unicode.** Send `text` containing `🙂`, `é` (as `e` + U+0301), `👨‍👩‍👧` and `🇺🇸`. Each must
   land as one glyph, not two (fix 7). Watch for *doubled* characters — that would mean the
   key-up divergence above is wrong and the up event must drop its Unicode payload.
7. **Release invariant.** Start a drag, then revoke input from the Mac UI mid-drag. The button
   must release, `dragStarted` must clear, and a later `leftDown` must still be accepted.
8. **Watchdog.** Start a drag and hold past 30 s — `CompanionModel` must revoke.
9. **Permission gate.** With Accessibility denied, every action must be a no-op and the UI must
   report it. Revoke mid-session and confirm `CompanionModel` revokes.
10. **Double-click.** Must open a Finder item, not register as two single clicks.
