# Contributing

Start with [BUILD.md](BUILD.md). Use an Apple silicon Mac, Xcode with the visionOS SDK,
and Python 3. Run shared tests, Mac behavior checks, startup checks, and both privacy
test scripts before proposing a change. Run the visionOS suite for client changes.

Use synthetic display content in tests and screenshots. Never include pairing keys,
desktop captures, host addresses, saved connections, signing settings, provisioning
profiles, or local diagnostic logs in an issue or pull request.

Describe the problem, resulting behavior, and checks performed. State which checks
used a simulator and which used physical devices. Include focused regression coverage
for changes to capture, input, connection recovery, or saved Stop decisions.

Restore the neutral Xcode project after local signing as described in BUILD.md.
Preserve third-party notices. Run `python3 script/verify_repository.py --source .`
before pushing: a clean working tree alone does not remove private data from Git history.

Public release archives must be produced by `script/build_release.sh`. Local development
builds, certificates, and provisioning profiles are not release assets.
