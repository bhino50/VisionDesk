# VisionDesk contributor guide

Swift/SwiftUI macOS companion and visionOS client. The companion captures up to four
Mac displays and streams them over authenticated TLS. Remote hosting uses port **58271**;
nearby sessions use Bonjour. Mac control requires explicit owner consent.

## Setup and commands

Use an Apple silicon Mac, full Xcode with visionOS support and Swift 6+, and Python 3.
There are no external Swift package dependencies. See BUILD.md for installation details.

```sh
swift test                                      # Core and authenticated transport tests
./script/test_mac_behavior.sh                    # Production Mac logic, synthetic input
./script/test_startup.sh                         # Isolated startup/packaging fixtures
python3 script/test_app_bundle.py                # Bundle identity regressions
python3 script/test_release_archive.py            # ZIP extraction and executable modes
python3 script/test_release_privacy.py           # Source/archive scanner regressions
python3 script/test_repository_privacy.py        # Index/history scanner regressions
python3 script/test_mac_dmg.py                    # DMG packaging regressions
python3 script/test_vision_runner.py              # Simulator selection and test-runner failures
python3 script/verify_release_privacy.py --source .
python3 script/verify_repository.py --source .
./script/build_vision.sh simulator               # Unsigned simulator build
./script/setup_vision.sh --prepare-only           # Separate local signing project
```

For native tests, list devices with `xcrun simctl list devices available`, then pass an
existing visionOS simulator UUID to `./script/test_vision.sh`. Do not reuse another
developer's active simulator without coordination. Each run preserves its log and result
bundle in a unique `build/vision-tests/run.*` directory. Set `VISION_DESK_TEST_OUTPUT_BASE`
to store those runs elsewhere; keep this private evidence out of commits.

`VISION_DESK_SIGNING_IDENTITY=- ./script/build_and_run.sh --build-only` prepares an
ad-hoc Mac candidate without launching it. Ordinary launcher and diagnostic modes can
replace/launch the running app or request permissions: inspect their effects first.

## Architecture

```text
Sources/DeskCore/              Validated messages, display geometry, readiness
Sources/DeskTransport/         TLS connections, framing, discovery, Keychain pairing
Sources/VisionDeskMac/         Capture, encoder, input consent and Quartz events
Sources/VirtualDisplayBridge/ Experimental Objective-C virtual-display bridge
VisionApp/                    visionOS UI, decoder, session and input ownership
Tests/                        Shared, Mac behavior, hardware-codec and latency checks
VisionTests/                  Hosted visionOS client regressions and stress suites
script/                       Builds, local signing setup and privacy packaging
```

The Mac sends display metadata and bounded video frames. The client decodes each display
and sends optional input. Control, stream, connection, gesture, and scene generations
prevent old callbacks from affecting a new owner or session. Preserve these boundaries.

## Working rules

- Keep changes focused; preserve concurrent edits and unrelated local configuration.
- Reproduce a behavioral defect and add meaningful coverage before calling it fixed.
- Do not weaken TLS authentication, Keychain access checks, input consent, queue limits,
  Stop persistence, or permission checks to make a test pass.
- Tests must inject configuration/credential stores and synthetic content. Never expose
  real desktop pixels, pairing keys, addresses, user paths or device/signing identifiers.
- Keep optional extra desktops experimental: their bridge uses an undocumented OS API.
- Generate the Xcode project with `script/generate_xcode_project.py`; do not hand-edit its
  source file list. Keep `org.visiondesk` identifiers and an empty team in shared files.
- Use `script/setup_vision.sh` for private signing choices; configuration and evidence
  stay in ignored local folders. Never commit credentials, profiles or personal builds.
- `script/verify_release_privacy.py` owns the explicit public-source inventory. Add new
  public support files there and test inclusion; do not export entire working folders.
- Review code and run the affected suites before delivery. Report exact test scope;
  simulator, synthetic hardware codec and physical headset evidence are distinct.
- Public artifacts come only from `script/build_release.sh`. A passing scan reduces
  publication mistakes but cannot prove the absence of every private fact or defect.

See CONTRIBUTING.md, SECURITY.md, PRIVACY.md and docs/third-party/README.md.
