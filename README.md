# VisionDesk

VisionDesk shows the physical displays attached to a Mac in separate Apple Vision Pro windows. The Mac companion captures up to four displays, streams hardware H.264 video when available, and accepts optional pointer and keyboard input from the paired headset.

## Connect

1. Open **VisionDesk Mac** on a logged-in, unlocked Mac. Grant Screen Recording, then start sharing.
2. Open **VisionDesk** on Apple Vision Pro. Allow Local Network access, choose the nearby Mac, and enter the pairing key displayed on the Mac. If it is hidden, click **Show Pairing Key** on the Mac. Both devices must be on a network that allows communication between them.
3. Open a screen window for each display you want to view. Move and resize each window using visionOS window controls.
4. To control Mac applications, click **Allow Accessibility** on the Mac and grant access in System Settings. Then enable **Allow the paired Vision Pro to control this Mac** (or **Enable Mac Control** after connecting). Click the intended Mac application before sending text or keyboard shortcuts.
5. Use **Stop Control** to release remote input, or **Stop Sharing** to stop screen sharing. Closing the Mac companion window can leave sharing active in its menu bar.

The headset can remember a successfully paired Mac. Pairing credentials stay in the devices' Keychains. A stopped or sleeping Mac cannot provide a live stream. Nearby discovery also depends on Local Network permission and network multicast support. Optional remote hosting requires an existing Tailscale connection configured by the device owner; VisionDesk provides no relay or VPN service.

## Build and install

This repository contains source, synthetic tests, and generic app artwork. It excludes personal diagnostics, desktop captures, saved connection data, developer credentials, and development provisioning profiles.

See [BUILD.md](BUILD.md) for local builds, verification, and the privacy release command. The release command prepares:

- An **ad-hoc signed macOS arm64 application**. It has no developer certificate or notarization ticket. macOS may require a deliberate first-open action and fresh privacy permissions.
- An **unsigned visionOS arm64 application**. It is a compiled build for review and signing; installation on a physical Vision Pro requires signing and provisioning through the installer's own Apple development account.

Build and automated-test success do not establish physical headset discovery, picture quality, hand-gesture behavior, or reconnect reliability. Those require a separate check on the intended Mac, network, and headset.

## Troubleshooting

- **Mac not listed:** open the companion, start sharing, allow Local Network access, and check that both devices can communicate. Guest Wi-Fi and client isolation can block discovery. A saved Mac may need pairing again after its Bonjour name changes.
- **Missing or unexpected screens:** end Apple's Mac Virtual Display session before using the physical-display workflow. Open **Displays** in the companion and select up to four connected screens. VisionDesk shares existing displays; it does not create extra virtual displays.
- **Blank picture:** grant Screen Recording on the Mac, follow any macOS prompt to quit and reopen the app, and keep the Mac logged in, awake, and unlocked.
- **Picture works but input does not:** grant Accessibility, enable Mac control, and use **Request Control** on the headset when available. Focus the intended Mac application before typing.
- **Permissions need granting again after a rebuild:** ad-hoc signing can change the app's identity. Use a stable local signing identity for repeated development.

## Privacy and security

Screen content and control commands travel over an authenticated encrypted connection between the paired devices. Mac control is optional. The app has no analytics uploader, account service, screen recording archive, clipboard synchronization, or cloud relay.

See [PRIVACY.md](PRIVACY.md) for the data boundaries, pairing behavior, and release inspection process. Mac input behavior includes attribution to the MIT-licensed Enigo component; see [third-party attribution](docs/third-party/README.md).

Audio forwarding, independent virtual displays, and automatic login are not implemented.

## License and contributions

VisionDesk is available under the [MIT License](LICENSE). Third-party components retain
their own notices. See [CONTRIBUTING.md](CONTRIBUTING.md) for development checks and
[SECURITY.md](SECURITY.md) for reporting vulnerabilities without exposing private data.
