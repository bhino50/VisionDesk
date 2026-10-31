# Build, verification, and installation

For the shortest first-time path, see [Install & connect](docs/INSTALL.md). This document covers development, verification, and release packaging.

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
python3 script/test_app_bundle.py
python3 script/test_release_archive.py
python3 script/test_mac_dmg.py
python3 script/test_release_privacy.py
python3 script/test_repository_privacy.py
python3 script/test_vision_runner.py
python3 script/verify_release_privacy.py --source .
python3 script/verify_repository.py --source .
./script/build_vision.sh simulator
./script/test_vision.sh <existing-visionOS-simulator-UUID>
```

The shared and native client suites use synthetic or loopback fixtures. The Mac behavior harness does not capture desktop pixels or inject Quartz input. The separate hardware video check uses detailed synthetic fixtures and reports encoder admission, output, throughput and teardown measurements. A command's output determines what it actually verified; do not infer physical headset success from a simulator result.

Each native test invocation preserves its `xcodebuild.log` and `VisionTests.xcresult` in
a unique `build/vision-tests/run.*` directory, including failed runs. Set
`VISION_DESK_TEST_OUTPUT_BASE` to use another private output directory. The script requires
an exact available visionOS simulator UUID and fails when its SDK or runtime is missing.
It does not create or delete a local simulator. CI creates and deletes its own simulator
and executes the same native suite using the toolchain pinned in the workflow.

For the companion, `VISION_DESK_SIGNING_IDENTITY=- ./script/build_and_run.sh --build-only` prepares an ad-hoc development build without launching it. For repeated local use, set `VISION_DESK_SIGNING_IDENTITY` to an existing stable identity using your local secure configuration. Never commit that configuration. Changing application signing identity or bundle identifier can require fresh Screen Recording, Accessibility, or Keychain access.

On a first build the app is `dist/VisionDeskMac.app`; open it with:

```sh
open dist/VisionDeskMac.app
```

If a companion is already running, `--build-only` preserves it and prints a staged
candidate path instead. Open that candidate only after quitting the existing companion.
For an ordinary rebuild and launch, use `VISION_DESK_SIGNING_IDENTITY=- ./script/build_and_run.sh`.
The launcher gracefully quits the current companion before replacing its bundle.

Allow Screen Recording for viewing and Accessibility for optional control in System
Settings → Privacy & Security. Follow macOS's request to reopen the app if shown.
For a downloaded release, open the Mac DMG and drag the app to Applications. The Mac ZIP remains an alternative: extract it and move the app to Applications.
If macOS blocks this unnotarized preview, review the source/release provenance and use
the explicit Open Anyway option in Privacy & Security if you choose to trust it.
Do not disable Gatekeeper globally.

## Repeated control and portrait stress tests

After generating the project, run the control stress suites against a visionOS simulator:

```sh
python3 script/generate_xcode_project.py
xcodebuild -project VisionDesk.xcodeproj -scheme VisionDesk \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -only-testing:VisionTests/PointerStressTests \
  -only-testing:VisionTests/KeyboardStressTests \
  -only-testing:VisionTests/PortraitStreamStressTests \
  -only-testing:VisionTests/InputTransitionTests \
  -only-testing:VisionTests/KeyboardOwnershipTests \
  -only-testing:VisionTests/InputReconnectTests \
  -only-testing:VisionTests/KeyboardReconnectTests \
  -test-iterations 3 CODE_SIGNING_ALLOWED=NO test
```

Choose the intended installed simulator when more than one matches that name. These
bounded, deterministic suites cover pointer ownership and release ordering, scrolling
under load, Unicode delivery and queue recovery, stale mouse callbacks during typing,
portrait geometry, delayed decoding, and four-screen resize/hotplug recovery. Reconnect
cases replace real authenticated TLS connections while input is queued, then verify
that old gestures, text, acknowledgements, and connection callbacks cannot affect the
replacement session. Fresh mouse, scroll, and native keyboard input must work afterward.
They use synthetic input, in-memory credentials, and local test connections. They do not post
input to another Mac application or establish physical headset latency or gesture quality.

## Privacy release

Run after the final source snapshot has passed review and the appropriate tests:

```sh
./script/build_release.sh
```

The script builds **Release**, never installs or launches either app, and refuses to overwrite an existing output directory. Set `VISION_DESK_RELEASE_DIR` to a new output directory to create another build. Build work happens in a temporary directory; a failed run preserves that directory for local diagnosis and prints its location. Build logs may include local tool details and must remain private.

The Mac release requires Hardened Runtime with no debugging, injected-library, or
executable-memory exceptions. Packaging rejects a signature that lacks that protection.
Ad-hoc signing does not provide Developer ID notarization.

Remote access must be configured through the companion's settings. The `--remote-host`
launcher opens the app and prints setup guidance; process arguments cannot grant new
capture or control consent. Previously saved hosting keeps its existing configuration.

Successful output in `release/` contains:

| File | Purpose |
| --- | --- |
| `VisionDesk-macOS-arm64.dmg` | Drag-to-Applications Mac disk image; same signing limits as the ZIP |
| `VisionDesk-macOS-arm64.zip` | Ad-hoc signed Mac companion; no developer certificate or notarization |
| `VisionDesk-visionOS-arm64-unsigned.zip` | Compiled visionOS app requiring the installer's signing/provisioning |
| `VisionDesk-<version>-source.zip` | Reviewed source snapshot for building and local headset signing |
| `BUILD.json` | Neutral source inventory digest and build/platform facts |
| `privacy-scan.json` | Source and archive inspection results without matched values |
| `SHA256SUMS` | SHA-256 hashes of the app downloads, source archive, and reports |

The Mac app includes the Enigo notice in its resources. Both app archives include the
VisionDesk MIT license. Verify downloaded checksums with `shasum -a 256 -c SHA256SUMS`
from the directory containing all release files. The manifest lists each payload file; it does not hash itself.

The unpacked applications are retained in the same output directory for inspection. Publish only the documented DMG, three ZIPs, and three reports. Do not upload a working directory, Xcode archive, provisioning profile, build log, `.dSYM`, or cache.

The release command also checks that the source and application ZIPs exactly match the
inspected files, including Unix regular-file types and permissions. The archive regression
extracts synthetic source and app ZIPs with macOS `ditto` and verifies that setup scripts
and application binaries remain executable.

To inspect a prepared output again:

```sh
python3 script/verify_release_privacy.py \
  --source . --artifacts release --report release/privacy-scan.json
```

If you replace a report after the release command, regenerate `SHA256SUMS` before publishing. Any scan failure stops packaging and leaves the candidate local.

## Physical Vision Pro installation

The distributed visionOS ZIP intentionally contains no development provisioning profile, device identifiers, or developer certificate. It cannot be installed directly on a physical headset in that state.

For first-time setup, use the source ZIP and run:

```sh
./script/setup_vision.sh
```

The helper opens a separate local Xcode setup project. Follow [Install & connect](docs/INSTALL.md#install-on-apple-vision-pro) to select your team, a unique bundle identifier, and your headset, then use Product → Run. Keep signing changes in that local project; do not commit credentials or personal signing configuration.

For command-line development after provisioning is configured:

```sh
VISION_DESK_TEAM_ID=<your-team-id> \
VISION_DESK_BUNDLE_ID=<your-registered-app-id> \
  ./script/build_vision.sh device
```

This command builds to `build/vision-device/Build/Products/Debug-xros/VisionDesk.app`; it does not install or launch. The lower-level build script can regenerate the tracked Xcode project with your local signing settings. Restore its neutral settings before committing:

```sh
env -u VISION_DESK_TEAM_ID \
  VISION_DESK_BUNDLE_ID=org.visiondesk.VisionDesk \
  python3 script/generate_xcode_project.py
```

The unsigned release ZIP is a compiled artifact for review or a separately managed signing workflow. It is not a one-tap installer, and the simulator build cannot be installed on a headset.

Keep locally signed development builds and installation diagnostics private. Pair the installed applications afresh if their generic app identity or Keychain namespace differs from a previous build.

## Physical acceptance

Verify discovery, authenticated pairing, each intended display, readable text, pointer/click/scroll/keyboard delivery, Stop/Resume, and a fresh reconnect on the real devices. Record only synthetic or deliberately non-sensitive content when collecting evidence. These acceptance results are separate from the distributable archives and are not implied by building them.
