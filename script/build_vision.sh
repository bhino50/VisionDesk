#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=script/lib/startup_preflight.sh
source "$ROOT_DIR/script/lib/startup_preflight.sh"
# Resolving first rejects an unset or non-Xcode developer directory with this script's own
# message. Appending to an empty value used to produce `/usr/bin/xcodebuild`, the xcrun shim,
# which is executable and therefore passed the check before failing with the shim's error.
DEVELOPER_DIR="$(visiondesk_resolve_developer_dir full-xcode)" || exit 1
export DEVELOPER_DIR
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"

MODE="${1:-simulator}"
case "$MODE" in
    simulator|device-unsigned) ;;
    device)
        : "${VISION_DESK_TEAM_ID:?Set VISION_DESK_TEAM_ID to your Apple development team}"
        : "${VISION_DESK_BUNDLE_ID:?Set VISION_DESK_BUNDLE_ID to your registered app identifier}"
        ;;
    *) echo "usage: $0 [simulator|device-unsigned|device]" >&2; exit 2 ;;
esac
python3 script/generate_xcode_project.py
case "$MODE" in
    simulator)
        "$XCODEBUILD" -project VisionDesk.xcodeproj -scheme VisionDesk \
            -destination 'generic/platform=visionOS Simulator' \
            -derivedDataPath build/vision-simulator \
            CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
        ;;
    device-unsigned)
        "$XCODEBUILD" -project VisionDesk.xcodeproj -scheme VisionDesk \
            -destination 'generic/platform=visionOS' \
            -derivedDataPath build/vision-device-unsigned \
            CODE_SIGNING_ALLOWED=NO build
        ;;
    device)
        # Both inputs were already required by the preflight above, before generation.
        "$XCODEBUILD" -project VisionDesk.xcodeproj -scheme VisionDesk \
            -destination 'generic/platform=visionOS' \
            -derivedDataPath build/vision-device \
            "DEVELOPMENT_TEAM=$VISION_DESK_TEAM_ID" build
        ;;
esac
