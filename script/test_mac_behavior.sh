#!/usr/bin/env bash
# Behavior checks for the production Mac sources.
#
# CompanionModel, InputOutput and DisplayCapture live in the VisionDeskMac executable
# target, which the package's XCTest targets cannot import. This script compiles those
# production files, plus the client's DisplayGeometry, against the same shared DeskCore and
# DeskTransport modules the app links, and runs the resulting checks.
#
# The checks post no Quartz events, request no OS permissions, start no capture, and open
# no network service. Run `swift test` for the shared core and transport suites.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

# Building the product first produces the shared module interfaces and static archives.
swift build --product VisionDeskMac
swift build --product DeskCore
swift build --product DeskTransport
BIN_DIR="$(swift build --show-bin-path)"
for library in libDeskCore.a libDeskTransport.a; do
    if [[ ! -f "$BIN_DIR/$library" ]]; then
        echo "Missing $library in $BIN_DIR. Run 'swift build' and retry." >&2
        exit 1
    fi
done

OUT_DIR="$ROOT_DIR/.build/mac-behavior-checks"
BINARY="$OUT_DIR/MacBehaviorChecks"
mkdir -p "$OUT_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="14.0"
TARGET_TRIPLE="$(uname -m)-apple-macos$DEPLOYMENT_TARGET"

PRODUCTION_SOURCES=(
    Sources/VisionDeskMac/RemoteHostConfiguration.swift
    Sources/VisionDeskMac/RemoteAccessSupport.swift
    Sources/VisionDeskMac/OrderedVideoDelivery.swift
    Sources/VisionDeskMac/CompanionModel.swift
    Sources/VisionDeskMac/CompanionModel+RemoteAccess.swift
    Sources/VisionDeskMac/CompanionModel+Setup.swift
    Sources/VisionDeskMac/CompanionModel+LAN.swift
    Sources/VisionDeskMac/CompanionModel+Recovery.swift
    Sources/VisionDeskMac/LANHostSupport.swift
    Sources/VisionDeskMac/DisplayCapture.swift
    Sources/VisionDeskMac/H264Encoder.swift
    Sources/VisionDeskMac/DockAppLauncher.swift
    Sources/VisionDeskMac/InputOutput.swift
    VisionApp/Services/DisplayGeometry.swift
)
CHECK_SOURCES=(Tests/MacBehaviorChecks/*.swift)

xcrun swiftc \
    -swift-version 5 \
    -sdk "$SDK_PATH" \
    -target "$TARGET_TRIPLE" \
    -Onone -g \
    -module-name MacBehaviorChecks \
    -I "$BIN_DIR" -L "$BIN_DIR" -lDeskCore -lDeskTransport \
    -o "$BINARY" \
    "${PRODUCTION_SOURCES[@]}" \
    "${CHECK_SOURCES[@]}"

"$BINARY"
