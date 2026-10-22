# Install and connect

VisionDesk is a developer preview for an Apple silicon Mac running macOS 14 or newer and Apple Vision Pro running visionOS 2 or newer. The Mac must stay logged in, awake, and unlocked while sharing.

The Mac download is ad-hoc signed and unnotarized. Headset installation requires a Mac with full Xcode, the visionOS SDK, Python 3, and your own Apple development account for signing and provisioning. There is currently no App Store, TestFlight, or one-tap Vision Pro installer.

## Download

Use the files attached to the [VisionDesk release](https://github.com/bhino50/VisionDesk/releases) you intend to install:

| File | Choose it for |
| --- | --- |
| `VisionDesk-macOS-arm64.dmg` | Installing the Mac companion by dragging it to Applications |
| `VisionDesk-<version>-source.zip` | Setting up and installing VisionDesk on your own headset with Xcode |
| `VisionDesk-macOS-arm64.zip` | An alternative Mac download without a disk image |
| `VisionDesk-visionOS-arm64-unsigned.zip` | A compiled headset app for a separately managed signing workflow; it cannot install as downloaded |
| `SHA256SUMS`, `BUILD.json`, `privacy-scan.json` | Checking download integrity, source/build facts, and packaging inspection results |

While the repository is private, downloads require access to it. A checksum verifies that a file matches the release manifest; it does not independently establish that the publisher or application is trustworthy. Developers can verify all downloaded files with `shasum -a 256 -c SHA256SUMS` in their download folder.

## Install on the Mac

1. Open `VisionDesk-macOS-arm64.dmg` and drag **VisionDesk Mac** to **Applications**. Eject the disk image, then open the app from Applications. If using the ZIP, extract it and move the app to Applications instead.
2. If macOS blocks the unnotarized preview, first confirm that you trust the source and release. Open **System Settings → Privacy & Security**, find the blocked-app message, and choose **Open Anyway** if you decide to proceed. Do not disable Gatekeeper globally.
3. Allow **Screen Recording** when requested. Follow macOS's instruction to quit and reopen the app if shown. Accessibility permission is only needed when you want headset mouse and keyboard control.

Do not run the companion directly from the disk image. Updating or changing signing identity may require granting permissions again.

## Install on Apple Vision Pro

1. Install full Xcode and its visionOS platform support on the Mac. Extract the source ZIP to a folder you own.
2. In the extracted folder, open **Terminal** at that folder and run `./script/setup_vision.sh`. This opens a separate local Xcode setup project so your signing choices stay out of the repository's neutral project. This setup step does not install the app by itself. Keep the printed project path and reopen that copy for later builds; running the helper again creates a fresh source copy and new signing setup.
3. In Xcode, add your Apple development account under **Settings → Accounts**. Select each target—**VisionDesk**, **DeskCore**, **DeskTransport**, and **VisionTests**—and choose the same team in **Signing & Capabilities** with automatic signing. Give the **VisionDesk** app a unique bundle identifier for your copy. Xcode will explain any account or provisioning requirements; resolve these before continuing.
4. Pair your Vision Pro with Xcode, keep it awake and unlocked, and select it as the run destination for the **VisionDesk** scheme. Enable **Developer Mode** and approve device trust if prompted by Apple.
5. Choose **Product → Run**. Wait for Xcode to finish installing and launching VisionDesk. Signing credentials, profiles, and local diagnostic output stay on your devices; do not upload them with bug reports.

Xcode and Apple account provisioning are required for this preview. Development profiles can expire and require another install from Xcode. A simulator build cannot run on a physical headset. See [BUILD.md](../BUILD.md) for development commands and neutral-project restoration.

## Connect for the first time

1. Start **VisionDesk Mac**, select up to four displays, and choose **Start Sharing**. For extra desktops, stop sharing, choose **Add Desktop**, then select the screens to share and start again. Extra desktops are experimental and close when the companion quits.
2. Open **VisionDesk** on Vision Pro and allow **Local Network** access. Choose the Mac from Nearby Macs. Both devices need a network that allows direct communication; guest networks can block this.
3. Show the pairing key on the Mac and enter it on Vision Pro. Treat the key as a password: do not include it in screenshots, messages, or bug reports.
4. Choose a screen preview or **Open All**. You can also pinch and hold a preview, drag it into empty space, and release to open its own window. Move and resize windows with the standard visionOS controls. Portrait screens keep their display proportions.
5. For input, grant **Accessibility** on the Mac and enable **Allow the paired Vision Pro to control this Mac**. Use **Request Control** on the headset if shown. Choose **Point & Click**, **Trackpad**, or **Scroll** as needed; open **Keyboard** to type. Focus the intended Mac app before sending text or shortcuts.
6. Choose **Stop Control** to release input or **Stop Sharing** to end the stream. Closing the companion window can leave sharing active in its menu bar.

Pairing credentials are saved in the devices' Keychains when remembered pairing is enabled. The app cannot wake a sleeping Mac or log into a locked account.

## Connect through a private VPN

Set up a private VPN such as Tailscale or WireGuard on both devices first. Verify that it provides a route between them. In the Mac companion's remote-access settings, select a locally assigned private IPv4 or ULA IPv6 address and enable remote access. On Vision Pro use **Connect by Address**, the configured address, port **58271**, and the pairing key.

VisionDesk does not install a VPN or provide an internet relay. Configure your VPN's device access rules and firewall deliberately; a private-looking address alone does not prove VPN protection. Remote mode uses the saved address rather than Nearby Macs. To return to Bonjour discovery, choose **Use Same-Network Connection** on the Mac.

## If something does not work

| Symptom | Check |
| --- | --- |
| Mac is missing from Nearby Macs | Start sharing, allow Local Network access on both devices, and check Wi-Fi/client isolation. If remote access is enabled, use its address or switch to Same-Network Connection. |
| Connect fails | Keep the Mac awake and unlocked. Confirm sharing is running and the key belongs to that Mac. In VPN mode check the route, configured address, port, and VPN access rules. |
| Keychain or saved-pairing error | Unlock the Mac and approve a legitimate Keychain access prompt for VisionDesk. Read the displayed error before resetting pairing; a reset requires pairing again on the headset. |
| Screen is blank or frozen | Check Screen Recording permission and macOS's reopen request. Keep the Mac awake and ensure the selected display still exists. |
| Screen previews appear but windows do not | Try dragging a preview into empty space. If the issue persists, report the app version, visionOS version, and exact action without including private screen contents. |
| Picture works but input does not | Check Accessibility, Mac control consent, and Request Control. Focus a Mac application. Stop and resume control if needed. |
| Updating asks for permissions again | Ad-hoc builds can change identity. Regrant only the permissions you intend. Developers should use a stable local signing identity for repeated use. |

Before reporting a problem, use synthetic content and redact device names, addresses, pairing keys, account details, and unrelated applications. See [PRIVACY.md](../PRIVACY.md) for data handling and [SECURITY.md](../SECURITY.md) for private vulnerability reporting.

Apple explains [opening an unnotarized Mac app](https://support.apple.com/102445), [running an app on a device](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices), and [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
