#!/usr/bin/env bash
# Benchmarks the production permission cache without requesting permissions or posting input.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --product DeskCore >&2
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p .build/input-latency-checks
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos14.0" -I "$BIN_DIR" -I "$BIN_DIR/Modules" -L "$BIN_DIR" -lDeskCore \
    Sources/VisionDeskMac/InputOutput.swift Tests/LatencyChecks/PermissionLatency.swift \
    -o .build/input-latency-checks/permission-latency
.build/input-latency-checks/permission-latency
