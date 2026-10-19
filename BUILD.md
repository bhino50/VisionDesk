# Build, verification, and installation

## Requirements

- Apple silicon Mac running macOS 14 or newer.
- Full Xcode with visionOS SDK support and Swift 6 or newer.
- Python 3 and the standard macOS development tools.
- An Apple development account only when signing for physical Vision Pro installation.

The visionOS application targets visionOS 2 or newer. Select the intended Xcode installation with the `DEVELOPER_DIR` environment variable if needed. These scripts do not change the system's selected Xcode installation.

## Local verification

```sh
swift test
./script/test_mac_behavior.sh
./script/test_startup.sh
./script/test_hardware_video.sh
./script/test_input_latency.sh
python3 script/test_release_privacy.py
./script/build_vision.sh simulator
./script/test_vision.sh <existing-visionOS-simulator-UUID>
```

The shared and native client suites use synthetic or loopback fixtures. The Mac behavior harness does not capture desktop pixels or inject Quartz input. The separate hardware video check uses moving-color fixtures. A command's output determines what it actually verified; do not infer physical headset success from a simulator result.

For the companion, `VISION_DESK_SIGNING_IDENTITY=- ./script/build_and_run.sh --build-only` prepares an ad-hoc development build without launching it. For repeated local use, set `VISION_DESK_SIGNING_IDENTITY` to an existing stable identity using your local secure configuration. Never commit that configuration. Changing application signing identity or bundle identifier can require fresh Screen Recording, Accessibility, or Keychain access.

## Privacy release

Run after the final source snapshot has passed review and the appropriate tests:

```sh
./script/build_release.sh
```

The script builds **Release**, never installs or launches either app, and refuses to overwrite an existing output directory. Set `VISION_DESK_RELEASE_DIR` to a new output directory to create another build. Build work happens in a temporary directory; a failed run preserves that directory for local diagnosis and prints its location. Build logs may include local tool details and must remain private.

Successful output in `release/` contains:

| File | Purpose |
| --- | --- |
| `VisionDesk-macOS-arm64.zip` | Ad-hoc signed Mac companion; no developer certificate or notarization |
| `VisionDesk-visionOS-arm64-unsigned.zip` | Compiled visionOS app requiring the installer's signing/provisioning |
| `BUILD.json` | Neutral source inventory digest and build/platform facts |
| `privacy-scan.json` | Source and archive inspection results without matched values |
| `SHA256SUMS` | SHA-256 hashes of the two archives and their reports |

The unpacked applications are retained in the same output directory for inspection. Publish only the two ZIPs and their three reports. Do not upload a working directory, Xcode archive, provisioning profile, build log, `.dSYM`, or cache. The release command also checks that ZIP member contents match the inspected application files.

To inspect a prepared output again:

```sh
python3 script/verify_release_privacy.py \
  --source . --artifacts release --report release/privacy-scan.json
```

If you replace a report after the release command, regenerate `SHA256SUMS` before publishing. Any scan failure stops packaging and leaves the candidate local.

## Physical Vision Pro installation

The distributed visionOS ZIP intentionally contains no development provisioning profile, device identifiers, or developer certificate. It cannot be installed directly on a physical headset in that state.

Open the included Xcode project, choose your own development team and a unique bundle identifier, select your paired headset, and build/install. Alternatively, generate a local signing project and build:

```sh
VISION_DESK_TEAM_ID=<your-team-id> \
VISION_DESK_BUNDLE_ID=<your-registered-app-id> \
  ./script/build_vision.sh device
```

The generator writes signing choices into the local Xcode project. Restore a neutral project before committing:

```sh
env -u VISION_DESK_TEAM_ID \
  VISION_DESK_BUNDLE_ID=org.visiondesk.VisionDesk \
  python3 script/generate_xcode_project.py
```

Keep locally signed development builds and installation diagnostics private. Pair the installed applications afresh if their generic app identity or Keychain namespace differs from a previous build.

## Physical acceptance

Verify discovery, authenticated pairing, each intended display, readable text, pointer/click/scroll/keyboard delivery, Stop/Resume, and a fresh reconnect on the real devices. Record only synthetic or deliberately non-sensitive content when collecting evidence. These acceptance results are separate from the distributable archives and are not implied by building them.
