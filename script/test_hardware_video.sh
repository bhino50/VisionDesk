#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --product VisionDeskMac >&2
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .build/hardware-video-checks
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos14.0" -I "$BIN_DIR" -L "$BIN_DIR" -lDeskCore \
    Sources/VisionDeskMac/H264Encoder.swift VisionApp/Services/H264Decoder.swift \
    Tests/HardwareVideoChecks/HardwareVideoChecks.swift -o .build/hardware-video-checks/check
.build/hardware-video-checks/check
