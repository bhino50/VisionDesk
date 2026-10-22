#!/usr/bin/env bash
# Build a local unsigned archive for distribution preparation. Never uploads or signs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ $# != 0 ]]; then
    echo "Usage: $0 (requires full Xcode with the visionOS SDK; no upload or signing)" >&2
    exit 2
fi
source "$ROOT_DIR/script/lib/startup_preflight.sh"
DEVELOPER_DIR="$(visiondesk_resolve_developer_dir full-xcode)"
export DEVELOPER_DIR
command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 1; }
WORK_DIR="$(mktemp -d /private/tmp/visiondesk-testflight.XXXXXX)"
mkdir -p "$ROOT_DIR/build"
OUTPUT_DIR="$(mktemp -d "$ROOT_DIR/build/testflight-preparation.XXXXXX")"
echo "Private preparation output: $OUTPUT_DIR"
echo "Build logs stay local; this command does not upload, sign, or invite testers."
trap 'result=$?; if [[ $result == 0 ]]; then rm -rf "$WORK_DIR"; else echo "Private failed build work: $WORK_DIR" >&2; fi' EXIT
python3 - "$ROOT_DIR" "$WORK_DIR/source" <<'COPY'
import importlib.util
from pathlib import Path
import shutil
import sys
root, target = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("release_privacy", root / "script/verify_release_privacy.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for source in module.source_inventory(root):
    if not source.is_file() or source.is_symlink():
        raise SystemExit("Required source is missing or symbolic.")
    destination = target / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
COPY
env -u VISION_DESK_TEAM_ID VISION_DESK_BUNDLE_ID=org.visiondesk.VisionDesk \
    python3 "$WORK_DIR/source/script/generate_xcode_project.py"
flags="\$(inherited) -file-prefix-map $WORK_DIR/source=/source/VisionDesk -debug-prefix-map $WORK_DIR/source=/source/VisionDesk -file-prefix-map $WORK_DIR=/build/VisionDesk -debug-prefix-map $WORK_DIR=/build/VisionDesk"
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -project "$WORK_DIR/source/VisionDesk.xcodeproj" -scheme VisionDesk \
    -configuration Release -destination 'generic/platform=visionOS' \
    -archivePath "$OUTPUT_DIR/VisionDesk.xcarchive" \
    -derivedDataPath "$WORK_DIR/derived-data" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=' \
    'DEVELOPMENT_TEAM=' 'PROVISIONING_PROFILE_SPECIFIER=' \
    ENABLE_DEBUG_DYLIB=NO "OTHER_SWIFT_FLAGS=$flags" archive \
    > "$OUTPUT_DIR/archive-build.log" 2>&1
python3 "$ROOT_DIR/script/verify_app_bundle.py" \
    "$OUTPUT_DIR/VisionDesk.xcarchive/Products/Applications/VisionDesk.app"
echo "Unsigned preparation archive: $OUTPUT_DIR/VisionDesk.xcarchive"
echo "Not installable and not TestFlight-approved. Select a verified organization team"
echo "and registered app identifier for the signed distribution build before upload."
