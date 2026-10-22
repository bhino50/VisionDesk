# Vision Pro installation without Xcode

TestFlight is the intended beta-distribution route for people who do not use Xcode.
The source repository can stay private. **No VisionDesk TestFlight invitation is
available yet**: a verified organization publisher, signed distribution build,
App Store Connect processing and external beta approval are still required.

## What a tester will do once the beta is available

1. Install Apple's free **TestFlight** app from the App Store on Vision Pro.
2. Open the actual VisionDesk invitation link supplied by the publisher.
3. Accept the invitation and tap **Install**. Use TestFlight for updates.
4. Install the Mac companion separately, start sharing, and pair in VisionDesk.

Testers do not need Xcode or an Apple development membership. Beta builds expire
after 90 days; the publisher must provide replacement builds. This is not a
permanent App Store installation, and the unsigned GitHub ZIP is not a TestFlight
installer. Never enter Apple credentials into an unofficial signing website.

## Publisher preparation

Keep private account information, certificates, provisioning profiles, archives,
build logs and App Store Connect credentials out of Git and downloadable releases.
Use an organization membership whose legal publisher identity is acceptable to the
owner. An individual membership must not be assumed to hide the owner's name.
Use a dedicated business feedback address: Apple shows the feedback email to testers
and uses it as the reply-to address on invitations. Verify all tester-visible
metadata before inviting anyone. Review contacts requested privately by Apple are
separate from information shown to testers.

The account holder must review any updated Apple agreements. Do not accept an
agreement automatically, register an invented organization, or use an enterprise
certificate to distribute this consumer preview.

For local preparation only, run:

```sh
./script/prepare_testflight.sh
```

This creates an **unsigned** Release archive in a fresh ignored
`build/testflight-preparation.*` directory. It never signs, uploads or invites
testers. It is a packaging check, not an installable or approved beta. The archive
includes app and transport-framework privacy manifests for their own preferences
and elapsed-time API use. Inspect the final signed archive too.

After verifying the organization in Apple Developer and App Store Connect:

1. Prepare a private publisher project with that organization's team and a registered
   app identifier for VisionDesk. Retain neutral signing in the shared source.
2. Create the visionOS app record, configure signing for all targets, and archive a
   Release build using that verified team. Validate and upload through Apple's tools.
3. Complete Apple's encryption/export questionnaire based on the actual build. The
   current transport uses operating-system Network/Security TLS; do not invent a
   declaration or treat a local unsigned archive as an export approval.
4. Supply an accurate beta description, what-to-test notes, dedicated feedback
   contact, and review instructions for using the separate Mac companion. Do not
   provide a live personal Mac's address, pairing key or remote-access credentials.
5. Create internal and external test groups, submit the first external build for
   Apple's review, and wait for its approved/ready-to-test state.
6. Inspect the invitation and TestFlight app as an external tester. Confirm publisher
   identity, contact details, install, pairing and reconnect before sharing a link.

Keep the GitHub repository private throughout. A beta invitation distributes the
compiled app through Apple; it does not require publishing GitHub source or granting
testers repository access. Do not claim installation is ready until a real approved
build installs successfully through TestFlight.

TestFlight is operated by Apple and can collect crash, usage and feedback information
under its own privacy terms. Avoid sending screenshots with sensitive desktop content.

## Apple references

- [TestFlight on Vision Pro and installation](https://testflight.apple.com/)
- [TestFlight overview and 90-day builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [External testers and beta review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)
- [Tester-visible feedback email](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)
- [Organization versus individual publisher identity](https://developer.apple.com/programs/enroll/)
- [Updating membership to an organization](https://developer.apple.com/help/account/membership/updating-your-account-information/)
- [TestFlight privacy](https://www.apple.com/legal/privacy/data/en/test-flight/)
