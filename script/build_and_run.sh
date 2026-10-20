#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=script/lib/startup_preflight.sh
source "$ROOT_DIR/script/lib/startup_preflight.sh"
MODE="${1:-run}"
case "$MODE" in run|--build-only|--verify|--capture-check|--input-check|--remote-host|--logs|--telemetry) ;; *) echo "usage: $0 [run|--build-only|--verify|--capture-check|--input-check|--remote-host|--logs|--telemetry]" >&2; exit 2 ;; esac
# Decided once, so the modes that launch and then validate a runtime report are not
# re-derived from the same three-way test at each use below.
REPORT_MODE=0
case "$MODE" in --verify|--capture-check|--input-check|--remote-host) REPORT_MODE=1 ;; esac
if [[ "$MODE" == "--remote-host" ]]; then
    : "${VISION_DESK_REMOTE_ADDRESS:?Set the verified Tailscale IPv4 address of this Mac}"
    python3 - "$VISION_DESK_REMOTE_ADDRESS" <<'ADDRESS_PY'
import ipaddress, sys
try:
    address = ipaddress.IPv4Address(sys.argv[1])
    if address not in ipaddress.IPv4Network('100.64.0.0/10'):
        raise ValueError()
except ValueError:
    raise SystemExit('VISION_DESK_REMOTE_ADDRESS must be this Mac\'s Tailscale IPv4 address (100.x.x.x).')
ADDRESS_PY
fi
DEVELOPER_DIR="$(visiondesk_resolve_developer_dir)" || exit 1
export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/swift-module-cache}"
APP_NAME="VisionDeskMac"
BUNDLE_ID="${VISION_DESK_MAC_BUNDLE_ID:-org.visiondesk.VisionDeskMac}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "VISION_DESK_MAC_BUNDLE_ID must be a reverse-DNS bundle identifier." >&2
    exit 2
fi
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
# The file location is overridable so the startup checks can exercise this preflight against
# a fixture instead of reading the real signing configuration. The identity is trimmed and
# required to be a single non-blank line, and is never echoed.
SIGNING_IDENTITY_FILE="${VISION_DESK_SIGNING_IDENTITY_FILE:-$ROOT_DIR/config/mac-signing-identity.txt}"
VISION_DESK_SIGNING_IDENTITY="$(visiondesk_read_signing_identity "$SIGNING_IDENTITY_FILE")" || exit 2
is_running() {
    local result=0
    pgrep -x "$APP_NAME" >/dev/null || result=$?
    if ((result > 1)); then
        echo "Cannot inspect the running companion. Live and staged bundles are preserved." >&2
        exit "$result"
    fi
    return "$result"
}
swift build --product "$APP_NAME"
BIN_DIR="$(swift build --show-bin-path)"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/.build/app-stage.XXXXXX")"
STAGED_BUNDLE="$STAGING_DIR/$APP_NAME.app"
# A staged bundle that outlives a failure is the recoverable candidate, so it is kept and its
# path reported. An empty or already-moved staging directory is removed, which the previous
# `rmdir` could not do once the bundle existed.
#
# The trap is armed before the bundle is copied and signed, so it must not call a half-written
# bundle a signed build. This flag is raised only once verification has passed.
STAGED_VERIFIED=0
trap 'visiondesk_release_staging "$STAGING_DIR" "$STAGED_BUNDLE" "$?" "$STAGED_VERIFIED"' EXIT
mkdir -p "$STAGED_BUNDLE/Contents/MacOS"
cp "$BIN_DIR/$APP_NAME" "$STAGED_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/script/MacInfo.plist" "$STAGED_BUNDLE/Contents/Info.plist"
# Preserve the upstream license in every distributed app before code signing.
mkdir -p "$STAGED_BUNDLE/Contents/Resources/ThirdPartyLicenses"
cp "$ROOT_DIR/docs/third-party/ENIGO-LICENSE.txt" "$STAGED_BUNDLE/Contents/Resources/ThirdPartyLicenses/ENIGO-LICENSE.txt"
cp "$ROOT_DIR/LICENSE" "$STAGED_BUNDLE/Contents/Resources/LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$STAGED_BUNDLE/Contents/Info.plist"
codesign --force --sign "$VISION_DESK_SIGNING_IDENTITY" --options runtime --timestamp=none "$STAGED_BUNDLE"
codesign --verify --strict "$STAGED_BUNDLE"
STAGED_VERIFIED=1
# This verified bundle supersedes any candidate an earlier failed run left behind.
visiondesk_prune_stage_dirs "$ROOT_DIR/.build" "$STAGING_DIR"
if is_running; then
    if [[ "$MODE" == "--build-only" ]]; then
        echo "Running app preserved. New signed build: $STAGED_BUNDLE"
        exit 0
    fi
    # A normal quit runs applicationWillTerminate and releases any held mouse button.
    # Never send SIGTERM or SIGKILL to a companion that may be controlling the pointer.
    # Read the old bundle's identity so a configuration change cannot target the new ID.
    RUNNING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")" || {
        echo "Cannot inspect the installed companion identity. Live and staged bundles are preserved." >&2
        exit 1
    }
    if [[ ! "$RUNNING_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
        echo "The installed companion has an invalid bundle identifier. Live and staged bundles are preserved." >&2
        exit 1
    fi
    /usr/bin/osascript -e "tell application id \"$RUNNING_BUNDLE_ID\" to quit"
    for ((attempt=0; attempt<25; attempt++)); do
        if ! is_running; then break; fi
        sleep 0.2
    done
    if is_running; then
        echo "Companion is still running. Quit it before replacing the app. Signed build: $STAGED_BUNDLE" >&2
        exit 1
    fi
fi
mkdir -p "$ROOT_DIR/dist"
# Moves the previous bundle aside, installs the staged one, restores the previous bundle if
# that fails, and only then bounds the recoverable copies to the three newest.
visiondesk_install_bundle "$STAGED_BUNDLE" "$APP_BUNDLE" "$ROOT_DIR/dist" "$APP_NAME" 3
case "$MODE" in
    --build-only) echo "$APP_BUNDLE" ;;
    *)
        if ((REPORT_MODE)); then
            REPORT_ID="$(uuidgen)"
            rm -f "$ROOT_DIR/dist/runtime-report.json"
            if [[ "$MODE" == "--capture-check" ]]; then rm -f "$ROOT_DIR/dist/capture-check.json"; fi
        fi
        if [[ "$MODE" == "--input-check" ]]; then
            # Move the prior diagnostic aside so receipt cannot be confused with a stale run.
            if [[ -f "$ROOT_DIR/dist/input-latency-check.json" ]]; then
                mv "$ROOT_DIR/dist/input-latency-check.json" "$ROOT_DIR/.build/input-latency-check.$REPORT_ID.json"
            fi
            /usr/bin/open -n "$APP_BUNDLE" --args --input-latency-check --runtime-report-id "$REPORT_ID"
        elif [[ "$MODE" == "--remote-host" ]]; then
            # The address was required and validated during preflight, before anything was built.
            /usr/bin/open -n "$APP_BUNDLE" --args --enable-remote-host "$VISION_DESK_REMOTE_ADDRESS" --runtime-report --runtime-report-id "$REPORT_ID"
        elif [[ "$MODE" == "--capture-check" ]]; then
            /usr/bin/open -n "$APP_BUNDLE" --args --runtime-report --runtime-report-id "$REPORT_ID" --capture-check
        elif [[ "$MODE" == "--verify" ]]; then
            /usr/bin/open -n "$APP_BUNDLE" --args --runtime-report --runtime-report-id "$REPORT_ID"
        else
            /usr/bin/open -n "$APP_BUNDLE"
        fi
        if ((REPORT_MODE)); then
            for ((attempt=0; attempt<300; attempt++)); do
                if [[ -f "$ROOT_DIR/dist/runtime-report.json" ]]; then break; fi
                sleep 0.1
            done
            if [[ ! -f "$ROOT_DIR/dist/runtime-report.json" ]]; then
                echo "The companion did not write its runtime report within 30 seconds. Check the app and any permission prompt." >&2
                exit 1
            fi
            python3 - "$ROOT_DIR/dist/runtime-report.json" "$REPORT_ID" "$BUNDLE_ID" "$MODE" <<'REPORT_PY'
import json, os, sys
try:
    with open(sys.argv[1]) as source:
        report = json.load(source)
except (OSError, ValueError):
    raise SystemExit('The companion runtime report could not be read.')
if not isinstance(report, dict):
    raise SystemExit('The companion runtime report has an invalid format.')
if report.get('reportID') != sys.argv[2] or report.get('bundleID') != sys.argv[3]:
    raise SystemExit('The runtime report does not match this launch.')
if not report.get('windows'):
    raise SystemExit('The companion did not report a visible window.')
try:
    process_id = report['processID']
    if not isinstance(process_id, int) or isinstance(process_id, bool) or process_id <= 0:
        raise ValueError()
    os.kill(process_id, 0)
except (KeyError, ValueError, OSError):
    raise SystemExit('The reported companion process is not running or has an invalid identifier.')
if sys.argv[4] == '--remote-host' and not report.get('sharing'):
    raise SystemExit('The companion launched but remote sharing did not start. Check its status and Tailscale address.')
print('Fresh companion launch verified. Permission and capture results are in dist/runtime-report.json.')
REPORT_PY
        fi
        if [[ "$MODE" == "--input-check" ]]; then
            for ((attempt=0; attempt<300; attempt++)); do
                if [[ -f "$ROOT_DIR/dist/input-latency-check.json" ]]; then break; fi
                sleep 0.1
            done
            python3 - "$ROOT_DIR/dist/input-latency-check.json" <<'INPUT_REPORT_PY'
import json, sys
try:
    with open(sys.argv[1]) as source:
        report = json.load(source)
except (OSError, ValueError):
    raise SystemExit('No readable input receipt report. Check the diagnostic window and Mac control permission.')
if not isinstance(report, dict) or report.get('success') is not True:
    raise SystemExit('Input receipt check failed. Inspect dist/input-latency-check.json.')
print('Pointer and keyboard delivery verified in the diagnostic window only.')
INPUT_REPORT_PY
        fi
        if [[ "$MODE" == "--logs" || "$MODE" == "--telemetry" ]]; then
            /usr/bin/log stream --info --style compact --predicate 'process == "VisionDeskMac"'
        fi
        ;;
esac
