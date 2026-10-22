#!/usr/bin/env bash
# Package an already signed companion without changing, launching, or mounting it.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: $0 /path/to/VisionDeskMac.app /path/to/new-output.dmg" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Disk image packaging requires macOS." >&2
    exit 1
fi
APP="$1"
OUTPUT="$2"
# Check every path component before resolving it: resolve() alone hides symlinks.
python3 - "$APP" "$OUTPUT" <<'VALIDATE'
from pathlib import Path
import sys
app, output = (Path(value).absolute() for value in sys.argv[1:])
for path in (app, output):
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise SystemExit("Symbolic paths are not accepted for disk image packaging.")
if not app.is_dir() or app.name != "VisionDeskMac.app":
    raise SystemExit("Choose the existing VisionDeskMac.app release bundle.")
if any(path.is_symlink() for path in app.rglob("*")):
    raise SystemExit("Unexpected application symlink; inspect the release bundle first.")
if output.suffix.lower() != ".dmg" or not output.parent.is_dir():
    raise SystemExit("Choose a .dmg output in an existing directory.")
if output.exists():
    raise SystemExit("Output already exists; choose a new disk image filename.")
if app == output or app in output.parents:
    raise SystemExit("Disk image output must be outside the application bundle.")
VALIDATE
/usr/bin/codesign --verify --deep --strict "$APP"
SIGNATURE="$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)"
if ! [[ "$SIGNATURE" =~ flags=0x[0-9a-fA-F]+\([^\)]*runtime ]]; then
    echo "The companion must be signed with Hardened Runtime before packaging." >&2
    exit 1
fi
WORK_DIR="$(mktemp -d /private/tmp/visiondesk-dmg.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/content"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$WORK_DIR/content/VisionDeskMac.app"
/usr/bin/codesign --verify --deep --strict "$WORK_DIR/content/VisionDeskMac.app"
ln -s /Applications "$WORK_DIR/content/Applications"
cat > "$WORK_DIR/content/INSTALL.txt" <<'INSTALL'
VisionDesk for Mac

1. Drag VisionDeskMac.app to Applications, then eject this disk image.
2. Open VisionDeskMac from Applications.
3. Allow Screen Recording when requested. Allow Accessibility only if you
   want to control this Mac from your paired Apple Vision Pro.
4. Choose Start Sharing, then pair from VisionDesk on your Vision Pro.

This preview is ad-hoc signed and is not notarized by Apple. Only install
it if you trust its source and have checked the release SHA256SUMS.
If macOS blocks it, first try opening the app, then use System Settings >
Privacy & Security > Open Anyway for this app. Never disable Gatekeeper.
If macOS reports damage or malware, stop and verify the download.

The Vision Pro app is a separate install requiring your own Apple signing
and provisioning. See the release's README and BUILD.md for instructions.
INSTALL
/usr/bin/hdiutil create -quiet -format UDZO -volname VisionDesk \
    -srcfolder "$WORK_DIR/content" "$WORK_DIR/VisionDesk.dmg"
/usr/bin/hdiutil verify -quiet "$WORK_DIR/VisionDesk.dmg"
# A hard link publishes atomically and fails if another process created OUTPUT.
# Copy into its destination filesystem first so this also works across volumes.
PUBLISH_DIR="$(mktemp -d "$(dirname "$OUTPUT")/.visiondesk-dmg.XXXXXX")"
trap 'rm -rf "$WORK_DIR" "$PUBLISH_DIR"' EXIT
cp "$WORK_DIR/VisionDesk.dmg" "$PUBLISH_DIR/VisionDesk.dmg"
ln "$PUBLISH_DIR/VisionDesk.dmg" "$OUTPUT"
echo "Created $OUTPUT"
