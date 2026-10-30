# Security reports

Do not post pairing keys, access tokens, desktop images, host addresses, or private
diagnostic logs in public issues. Reproduce problems with synthetic content and remove
personal information from reports.

For a suspected vulnerability, use GitHub's private vulnerability reporting option on
the repository's Security tab when it is available. If it is unavailable, ask the
maintainer for a private reporting channel without publishing exploit details or secrets.

VisionDesk is preview software. Pair only devices you trust. Enable Mac control only
when you intend to permit it; Stop Sharing ends availability and keeps remote sharing
stopped across application relaunches until you explicitly start it again. It retains
pairing and the selected connection mode. Keep both devices and their operating systems
updated.

Nearby discovery accepts at most 64 service results and updates the pairing list at most
twice per second. A larger result set stops discovery with a visible explanation; use a
saved Mac or Connect by Address, or search again after changing networks. This bounds
VisionDesk's processing and UI work; it does not bound the operating system's Bonjour
implementation or prevent network-level denial of service.

See [PRIVACY.md](PRIVACY.md) for transport, credential storage, and data boundaries.
Build checks and privacy scans do not constitute an independent security certification.
