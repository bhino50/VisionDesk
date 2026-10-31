#!/usr/bin/env bash
# Hosted visionOS XCTest run for the native client.
# Requires full Xcode with an available visionOS SDK/runtime. Each run gets unique results;
# verbose simulator diagnostic attachment collection is disabled after a collection hang.
#
# Drives the production DeskClientModel and the production UIKit frame decoder against a real
# authenticated DeskTransport loopback server inside the simulator. It posts no Quartz events,
# starts no screen capture, requests no Mac permissions, and changes nothing on a device.
#
# A simulator must be chosen explicitly; this script never invents or creates one. List the
# installed visionOS simulators first:
#
#   xcrun simctl list devices available | grep -B1 -i vision
#
# Usage:
#   script/test_vision.sh <simulator-udid>
#   VISION_DESK_SIM_ID=<simulator-udid> script/test_vision.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
if [[ ! -x "$XCODEBUILD" ]]; then
    echo "Set DEVELOPER_DIR to a full Xcode installation with visionOS support." >&2
    exit 1
fi

SIM_ID="${1:-${VISION_DESK_SIM_ID:-}}"
if [[ -z "$SIM_ID" ]]; then
    echo "usage: $0 <simulator-udid>   (or set VISION_DESK_SIM_ID)" >&2
    echo "List the available visionOS simulators with:" >&2
    echo "  xcrun simctl list devices available | grep -B1 -i vision" >&2
    exit 2
fi
OUTPUT_BASE="${VISION_DESK_TEST_OUTPUT_BASE:-$ROOT_DIR/build/vision-tests}"
mkdir -p "$OUTPUT_BASE"
RUN_DIR="$(mktemp -d "$OUTPUT_BASE/run.XXXXXX")"
echo "Native test run directory: $RUN_DIR"
xcrun --sdk xrsimulator --show-sdk-path > "$RUN_DIR/sdk.txt"
xcrun simctl list -j > "$RUN_DIR/simulators.json"
SIM_ID="$(python3 "$ROOT_DIR/script/vision_simulator.py" validate "$SIM_ID" < "$RUN_DIR/simulators.json")"

python3 script/generate_xcode_project.py

DERIVED="$RUN_DIR/DerivedData"
RESULTS="$RUN_DIR/VisionTests.xcresult"

# CODE_SIGNING_ALLOWED=NO matches script/build_vision.sh. If the simulator refuses to install
# the bundle, re-run without that setting rather than weakening any other check.
"$XCODEBUILD" -project VisionDesk.xcodeproj -scheme VisionDesk \
    -destination "platform=visionOS Simulator,id=$SIM_ID" \
    -destination-timeout 120 \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULTS" \
    -collect-test-diagnostics never \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
    test 2>&1 | tee "$RUN_DIR/xcodebuild.log"

echo "Result bundle: $RESULTS"
