#!/usr/bin/env bash
# Synthetic pixels only: no desktop capture, windows, permissions, or posted input.
# JSON goes to stdout so callers can preserve each independent run; diagnostics use stderr.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# Build the library product explicitly: building the app can leave an older standalone
# libDeskCore archive beside updated module interfaces, which would test stale sizing logic.
swift build --product DeskCore >&2
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .build/hardware-video-checks
xcrun swiftc -O -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos14.0" -I "$BIN_DIR" -L "$BIN_DIR" -lDeskCore \
    Sources/VisionDeskMac/H264Encoder.swift VisionApp/Services/H264Decoder.swift \
    Tests/HardwareVideoChecks/HardwareVideoChecks.swift -o .build/hardware-video-checks/check
.build/hardware-video-checks/check "$@"
