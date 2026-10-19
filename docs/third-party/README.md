# Third-party attribution

## Enigo (MIT)

`Sources/VisionDeskMac/InputOutput.swift` adapts macOS input-synthesis *behavior* from the
Enigo component vendored inside RustDesk.

| Field | Value |
|-------|-------|
| Component | `libs/enigo` (crate `enigo`, version `0.0.14`) |
| License | MIT — see [ENIGO-LICENSE.txt](ENIGO-LICENSE.txt) (byte-identical copy of `libs/enigo/LICENSE`) |
| Copyright | Copyright (c) 2017 pythoneer; authors: Dustin Bensing <dustin.bensing@googlemail.com> |
| Upstream project | <https://github.com/enigo-rs/enigo> |
| Read via | `rustdesk/rustdesk` clone at commit `e5bc204fe4dacc4db9c3cdb1f1338813986c89e7` |
| File read | `libs/enigo/src/macos/macos_impl.rs`, `libs/enigo/src/macos/keycodes.rs` |

No Rust source is copied into this repository. The adaptation is a Swift reimplementation of
the observable Quartz event conventions; see [../RUSTDESK_INPUT.md](../RUSTDESK_INPUT.md) for
the per-behavior mapping and for the AGPL boundary that applies to the rest of RustDesk.

## RustDesk main application (AGPL-3.0) — NOT vendored

`rustdesk/rustdesk` is licensed AGPL-3.0 (`LICENCE` at the clone root). `src/server/input_service.rs`
was **read only**, to confirm how the MIT Enigo primitives are driven in production (scroll sign
and axis chain, grapheme sequencing, modifier reset points). No AGPL code, structure, or comment
text is copied or translated into this project. The facts recorded in `docs/RUSTDESK_INPUT.md`
from that file are observed numeric/ordering conventions, not expression.
