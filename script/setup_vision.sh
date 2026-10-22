#!/usr/bin/env bash
# Prepare a private local Xcode workspace without changing the shared project.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [--prepare-only]"
        echo "Copies publishable sources into build/vision-setup.XXXXXX and opens Xcode."
        echo "Choose your Team for every target and a unique app identifier, then Run on your headset."
        exit 0 ;;
    ''|--prepare-only) ;;
    *) echo "Usage: $0 [--prepare-only]" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Vision Pro setup requires a Mac with Xcode and the visionOS SDK." >&2
    exit 1
fi
command -v python3 >/dev/null || { echo "Install Python 3 before preparing the project." >&2; exit 1; }
source "$ROOT_DIR/script/lib/startup_preflight.sh"
DEVELOPER_DIR="$(visiondesk_resolve_developer_dir full-xcode)"
export DEVELOPER_DIR
mkdir -p "$ROOT_DIR/build"
SETUP_DIR="$(mktemp -d "$ROOT_DIR/build/vision-setup.XXXXXX")"
python3 - "$ROOT_DIR" "$SETUP_DIR" <<'COPY'
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
        raise SystemExit("Required source is missing or symbolic; setup stopped.")
    destination = target / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
COPY
env -u VISION_DESK_TEAM_ID VISION_DESK_BUNDLE_ID=org.visiondesk.VisionDesk \
    python3 "$SETUP_DIR/script/generate_xcode_project.py"
echo "Your local setup project: $SETUP_DIR/VisionDesk.xcodeproj"
echo "In Xcode: Signing & Capabilities > choose the same Team for VisionDesk, DeskCore, DeskTransport and VisionTests."
echo "Give the VisionDesk app a unique bundle identifier. Select your unlocked Vision Pro, then Run."
echo "This copy keeps signing choices out of the shared project. Reopen it for later builds."
echo "Run this helper again only when you want a fresh copy of updated source."
if [[ "${1:-}" != --prepare-only ]]; then
    /usr/bin/open -a "$DEVELOPER_DIR/../.." "$SETUP_DIR/VisionDesk.xcodeproj"
fi
