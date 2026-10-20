#!/usr/bin/env bash
# Build privacy-reviewed release archives without installing or launching either app.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/lib/startup_preflight.sh"
DEVELOPER_DIR="$(visiondesk_resolve_developer_dir full-xcode)"
export DEVELOPER_DIR
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Release packaging requires an Apple silicon Mac." >&2
    exit 1
fi
OUTPUT_DIR="${VISION_DESK_RELEASE_DIR:-$ROOT_DIR/release}"
OUTPUT_DIR="$(python3 - "$OUTPUT_DIR" "$ROOT_DIR" <<'OUTPUT_PATH'
from pathlib import Path
import sys
path = Path(sys.argv[1]).expanduser()
if not path.is_absolute(): path = Path(sys.argv[2]) / path
print(path.resolve())
OUTPUT_PATH
)"
if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Release output already exists. Choose a new VISION_DESK_RELEASE_DIR." >&2
    exit 1
fi
WORK_DIR="$(mktemp -d /private/tmp/visiondesk-release.XXXXXX)"
SOURCE_DIR="$WORK_DIR/source"
STAGE_DIR="$WORK_DIR/output"
SUCCEEDED=0
finish() {
    local result=$?
    if ((SUCCEEDED)); then
        rm -rf "$WORK_DIR"
    else
        echo "Release preparation stopped. Private work and logs are preserved at: $WORK_DIR" >&2
    fi
    return "$result"
}
trap finish EXIT
mkdir -p "$SOURCE_DIR" "$STAGE_DIR"

# The snapshot is an explicit allowlist. No credentials, diagnostics, Git history, or caches
# enter the build directory. The actual build root has no personal username or spaces.
python3 - "$ROOT_DIR" "$SOURCE_DIR" <<'COPY_SOURCE'
import importlib.util
from pathlib import Path
import shutil
import sys
root, target = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("release_privacy", root / "script/verify_release_privacy.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for path in module.source_inventory(root):
    if not path.is_file() or path.is_symlink():
        raise SystemExit("A required release source file is absent or symbolic.")
    destination = target / path.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, destination)
    shutil.copymode(path, destination)
COPY_SOURCE
python3 "$SOURCE_DIR/script/verify_release_privacy.py" --source "$SOURCE_DIR" > "$WORK_DIR/source-scan.json"
env -u VISION_DESK_TEAM_ID VISION_DESK_BUNDLE_ID=org.visiondesk.VisionDesk \
    python3 "$SOURCE_DIR/script/generate_xcode_project.py" > "$WORK_DIR/project-generation.log"

cd "$SOURCE_DIR"
SWIFT_BIN="$(xcrun --find swift)"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"
swift_args=(--configuration release --scratch-path "$WORK_DIR/swift-build")
swift_flags=(
    -Xswiftc -file-prefix-map -Xswiftc "$SOURCE_DIR=/source/VisionDesk"
    -Xswiftc -debug-prefix-map -Xswiftc "$SOURCE_DIR=/source/VisionDesk"
    -Xswiftc -file-prefix-map -Xswiftc "$WORK_DIR=/build/VisionDesk"
    -Xswiftc -debug-prefix-map -Xswiftc "$WORK_DIR=/build/VisionDesk"
)
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$WORK_DIR/swift-module-cache"
"$SWIFT_BIN" build "${swift_args[@]}" "${swift_flags[@]}" --product VisionDeskMac > "$WORK_DIR/mac-build.log" 2>&1
BIN_DIR="$("$SWIFT_BIN" build "${swift_args[@]}" --show-bin-path)"
MAC_APP="$STAGE_DIR/macOS/VisionDeskMac.app"
mkdir -p "$MAC_APP/Contents/MacOS"
cp "$BIN_DIR/VisionDeskMac" "$MAC_APP/Contents/MacOS/VisionDeskMac"
cp "$SOURCE_DIR/script/MacInfo.plist" "$MAC_APP/Contents/Info.plist"
# Preserve the upstream license in every distributed app before code signing.
mkdir -p "$MAC_APP/Contents/Resources/ThirdPartyLicenses"
cp "$SOURCE_DIR/docs/third-party/ENIGO-LICENSE.txt" "$MAC_APP/Contents/Resources/ThirdPartyLicenses/ENIGO-LICENSE.txt"
cp "$SOURCE_DIR/LICENSE" "$MAC_APP/Contents/Resources/LICENSE"

# Xcode accepts a build-setting value as one argument. Its individual compiler arguments are
# already whitespace-free because compilation uses the neutral temporary source root.
mapped_flags="\$(inherited) -file-prefix-map $SOURCE_DIR=/source/VisionDesk -debug-prefix-map $SOURCE_DIR=/source/VisionDesk -file-prefix-map $WORK_DIR=/build/VisionDesk -debug-prefix-map $WORK_DIR=/build/VisionDesk"
xcode_args=(
    -project "$SOURCE_DIR/VisionDesk.xcodeproj" -scheme VisionDesk -configuration Release
    -destination 'generic/platform=visionOS' -derivedDataPath "$WORK_DIR/vision-build"
    "MODULE_CACHE_DIR=$WORK_DIR/vision-module-cache"
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY='
    'DEVELOPMENT_TEAM=' 'PROVISIONING_PROFILE_SPECIFIER=' ENABLE_DEBUG_DYLIB=NO
    SWIFT_EMIT_LOC_STRINGS=NO STRIP_INSTALLED_PRODUCT=YES COPY_PHASE_STRIP=YES
    "OTHER_SWIFT_FLAGS=$mapped_flags" build
)
"$XCODEBUILD" "${xcode_args[@]}" > "$WORK_DIR/vision-build.log" 2>&1
VISION_APP="$STAGE_DIR/visionOS/VisionDesk.app"
mkdir -p "$(dirname "$VISION_APP")"
cp -R "$WORK_DIR/vision-build/Build/Products/Release-xros/VisionDesk.app" "$VISION_APP"
cp "$SOURCE_DIR/LICENSE" "$VISION_APP/LICENSE"

python3 - "$MAC_APP" "$VISION_APP" <<'CLEAN_APPS'
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
mac, vision = map(Path, sys.argv[1:])
info = mac / "Contents/Info.plist"
data = plistlib.loads(info.read_bytes())
data["CFBundleIdentifier"] = "org.visiondesk.VisionDeskMac"
info.write_bytes(plistlib.dumps(data))
mach_o = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
for app in (mac, vision):
    for path in sorted(app.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if path.is_symlink():
            raise SystemExit("Unexpected application symlink; inspect the local build before packaging.")
        if path.name in {"Headers", "PrivateHeaders", "Modules", "_CodeSignature"} or path.suffix == ".dSYM":
            if path.is_dir(): shutil.rmtree(path)
            else: path.unlink()
        elif path.suffix in {".mobileprovision", ".provisionprofile", ".swiftdoc", ".swiftmodule", ".swiftsourceinfo"}:
            if path.is_dir(): shutil.rmtree(path)
            else: path.unlink()
        elif path.name.endswith(".debug.dylib") or path.name == "__preview.dylib":
            raise SystemExit("Unexpected Debug binary in Release output.")
    for path in app.rglob("*"):
        if not path.is_file(): continue
        with path.open("rb") as binary: magic = binary.read(4)
        if magic not in mach_o: continue
        description = subprocess.run(["/usr/bin/codesign", "-d", str(path)], capture_output=True)
        if description.returncode == 0:
            subprocess.run(["/usr/bin/codesign", "--remove-signature", str(path)], check=True, capture_output=True)
        subprocess.run(["/usr/bin/xcrun", "strip", "-S", str(path)], check=True, capture_output=True)
    subprocess.run(["/usr/bin/xattr", "-cr", str(app)], check=True, capture_output=True)
CLEAN_APPS
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$MAC_APP" > "$WORK_DIR/mac-signing.log" 2>&1
/usr/bin/codesign --verify --strict "$MAC_APP" >> "$WORK_DIR/mac-signing.log" 2>&1

python3 - "$SOURCE_DIR" "$STAGE_DIR" "$XCODEBUILD" <<'ARCHIVES'
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import zipfile
root, output = map(Path, sys.argv[1:3])
spec = importlib.util.spec_from_file_location("release_privacy", root / "script/verify_release_privacy.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for name, app in [("VisionDesk-macOS-arm64.zip", output / "macOS/VisionDeskMac.app"), ("VisionDesk-visionOS-arm64-unsigned.zip", output / "visionOS/VisionDesk.app")]:
    with zipfile.ZipFile(output / name, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(app.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(app.name + "/" + path.relative_to(app).as_posix(), date_time=(2020, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (path.stat().st_mode & 0o777) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, path.read_bytes(), compresslevel=9)
toolchain = subprocess.run([sys.argv[3], "-version"], capture_output=True, text=True, check=True).stdout.strip().splitlines()
report = {
    "sourceDigestSHA256": module.source_digest(root),
    "configuration": "Release", "architecture": "arm64",
    "macOSSigning": "ad-hoc; hardened runtime; not notarized", "visionOSSigning": "unsigned; installer signing required",
    "visionOSMinimumVersion": "2.0", "toolchain": toolchain,
    "sourcePathsMapped": True, "personalDevelopmentProfilesIncluded": False,
    "physicalDeviceAcceptance": "separate; not certified by this build",
}
(output / "BUILD.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
ARCHIVES
python3 "$SOURCE_DIR/script/verify_release_privacy.py" --source "$SOURCE_DIR" \
    --artifacts "$STAGE_DIR" --report "$STAGE_DIR/privacy-scan.json" > "$WORK_DIR/final-scan.log"
python3 - "$STAGE_DIR" <<'HASHES'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
names = ["VisionDesk-macOS-arm64.zip", "VisionDesk-visionOS-arm64-unsigned.zip", "BUILD.json", "privacy-scan.json"]
(root / "SHA256SUMS").write_text("".join(hashlib.sha256((root / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
HASHES
mkdir -p "$(dirname "$OUTPUT_DIR")"
if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Release destination appeared during this build; preserved local candidate." >&2
    exit 1
fi
mv "$STAGE_DIR" "$OUTPUT_DIR"
SUCCEEDED=1
echo "Privacy inspection passed. Release archives and hashes: $OUTPUT_DIR"
