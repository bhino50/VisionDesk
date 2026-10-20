# Privacy and security

## Data used during a session

The Mac companion captures the physical displays selected by the app's sharing flow. Live screen pixels, display names and geometry, pointer positions, and requested keyboard input are exchanged with the paired headset. Every shared display may show sensitive information present on that display, including other applications and notifications. Start sharing only the desktop content you intend the paired headset to see.

VisionDesk implements no cloud account, analytics uploader, advertising SDK, relay service, automatic screen archive, or clipboard synchronization. The app does not read a credential store to populate login forms. Screen capture and Mac input use the operating system's Screen Recording and Accessibility permissions.

## Pairing and control

On macOS, existing classic Keychain items are accepted only when their complete access
policy matches this application's own policy. Unexpected trusted applications or ACL
grants are refused before reading or rotating a pairing secret.

Stop Input decisions made by the Mac owner or headset persist across remote-host
restarts. Saved hosting resumes only within that consent and when the console session
is awake and unlocked. New remote configuration requires the in-app settings flow.

A securely generated 128-bit pairing secret authenticates the connection using TLS 1.2 PSK with AES-GCM. The protocol checks the negotiated suite and application protocol before accepting messages. This PSK suite does not provide forward secrecy: protect the pairing key and rotate it by forgetting the pairing if it may have been exposed.

Remembered pairing secrets use the operating system Keychain and are not synchronized to other devices by this app. Preferences retain connection names, routes, and availability/control decisions. The person configuring the Mac decides whether remembered sessions may control it. Stop, stale heartbeats, lost permissions, sleep, and disconnection release or suspend input through the app's session controls.

The nearby listener advertises a service name on the local network. Device names and discovery records are therefore visible to other devices on that network. Optional remote hosting binds to an existing Tailscale address; the VPN's routing and access policy remain the owner's responsibility. VisionDesk does not create port-forwarding rules or publish a remote access service on the internet.

## Diagnostics

Opt-in local diagnostic commands can write runtime status, display metadata, connection addresses, and performance reports alongside local build outputs. These reports are not automatically uploaded. Keep them private and review their contents before sharing them. Ordinary screen streaming does not save screenshots to a diagnostics archive.

## Distribution boundary

This distribution uses generic identifiers beginning with `org.visiondesk`. Saved pairings, preferences, signing credentials, device IDs, development profiles, historical diagnostics, local build caches, and personal filesystem paths are excluded from the repository and release archives.

`script/build_release.sh` builds in a temporary source directory, maps compiler source paths to neutral paths, removes debug/module artifacts and profiles from the packaged applications, signs the Mac app ad hoc, and verifies the release with `script/verify_release_privacy.py`. That inspection checks source and application/archive contents for credential signatures, personal user paths, the build user's name, forbidden files, and certificate-backed code signatures. It emits only categories and relative paths when reporting a problem; it does not print matched secret values.

The source inventory, build mode, platform, archive hashes, and privacy inspection report accompany each release. Automated inspection reduces publication mistakes; it does not establish the absence of every possible privacy or security defect. Physical device acceptance and any operational diagnostics remain separate from the distributable build.

## Publication checks

Network examples are synthetic fixtures. Maintainers should set `VISION_DESK_PRIVACY_DENYLIST` to a private JSON file containing identifiers that must never appear in a release. Keep that file outside this repository. The scanner checks these literals without printing their values, including binary UTF-16 strings. Run both repository and release scanners: history, metadata, and downloadable artifacts are separate surfaces. Pattern checks cannot prove absence of every private fact.
