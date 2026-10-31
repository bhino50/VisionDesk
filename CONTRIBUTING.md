# Contributing

Start with [BUILD.md](BUILD.md). Use an Apple silicon Mac, full Xcode with the visionOS
SDK and Swift 6 or newer, and Python 3. The project has no external Swift package
dependencies. For headset signing, use `./script/setup_vision.sh` to keep local signing
choices in a separate project.

## Making a change

Create a focused branch from the current default branch. Describe the user-visible
problem before choosing an implementation. Preserve existing work and keep unrelated
formatting or refactors out of the change. Use Swift's existing naming and indentation
conventions, respect `@MainActor` ownership, and cancel work when its session, display,
or gesture owner changes.

Add a focused regression for changes to capture, input, connection recovery, or saved
Stop decisions. Tests should exercise observable behavior rather than duplicate the
implementation. Use injected persistence and synthetic input so a test does not alter
real preferences, pairings, or another application's keyboard/mouse state.

Run these checks before a pull request:

```sh
swift test
./script/test_mac_behavior.sh
./script/test_startup.sh
python3 script/test_app_bundle.py
python3 script/test_release_archive.py
python3 script/test_release_privacy.py
python3 script/test_repository_privacy.py
python3 script/test_mac_dmg.py
python3 script/test_vision_runner.py
python3 script/verify_release_privacy.py --source .
python3 script/verify_repository.py --source .
```

Run `./script/test_vision.sh` with an explicitly selected existing visionOS simulator
UUID for client changes, and the hardware video checks for codec changes. The
[repeated stress commands](BUILD.md#repeated-control-and-portrait-stress-tests) cover
input ownership, reconnects, and portrait geometry. Record a failed run as failed even
when a later repaired run passes.

Use synthetic display content in tests and screenshots. Never include pairing keys,
desktop captures, host addresses, saved connections, signing settings, provisioning
profiles, or local diagnostic logs in an issue or pull request.

## Review and reports

Use the pull request template to describe the problem, resulting behavior, and checks
performed. State which checks used a simulator and which used physical devices. For
bug reports, include version, platform, repeatable steps, expected result, and actual
result. Keep vulnerability details out of public issues; follow [SECURITY.md](SECURITY.md).

The GitHub workflow runs shared tests, Mac behavior and startup checks, Python packaging
checks, source/history inspection, and the native visionOS test suite in a job-owned
simulator. It preserves failed native test logs and result bundles for seven days.
It does not sign for distribution, publish, install on a physical device, inject Mac
input, or establish physical headset acceptance.
Hosted CI results are meaningful only after a workflow has actually run on the commit.

Restore the neutral Xcode project after local signing as described in BUILD.md.
Preserve third-party notices. Run `python3 script/verify_repository.py --source .`
before pushing: a clean working tree alone does not remove private data from Git history.

Public release archives must be produced by `script/build_release.sh`. Local development
builds, certificates, and provisioning profiles are not release assets.

## Using Codex

[AGENTS.md](AGENTS.md) maps the code and commands. Give an assistant a bounded problem,
the affected platform, and expected behavior. Review generated changes and test evidence
as you would any other contribution. Do not give it secrets in prompts or approve a
public release on the basis of a passing scanner alone.
