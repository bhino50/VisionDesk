# Meet VisionDesk

![VisionDesk illustrated workspace](images/visiondesk-hero.png)

Keep your Mac applications on the Mac, and bring its existing displays into separate
Apple Vision Pro windows. VisionDesk shares up to four connected physical displays.
The Mac must remain awake, logged in, and unlocked.

## 1. Get the Mac ready

![Mac sharing controls](images/mac-companion.png)

Open the Mac companion and allow Screen Recording. Choose the displays to share, then
select **Start Sharing**. If the pairing key is hidden, select **Show Pairing Key**.

Mac control is optional. To enable it, grant Accessibility and allow the paired Vision
Pro to control the Mac. Start with viewing if you only need the screens.

## 2. Pair from Vision Pro

![Vision Pro pairing screen](images/vision-pairing.jpg)

Allow Local Network access and choose your Mac. Enter the pairing key shown on the
Mac. Both devices need a network that allows them to communicate. The app can remember
a successfully paired Mac so the next session does not need the key again.

## 3. Open and arrange your displays

![Four-display overview](images/vision-workspace.jpg)

Select a display preview to open that screen, or choose **Open All**. Each display gets
its own window. Use visionOS window controls to move and resize the windows around you.
The overview also offers larger previews and connection details.

![Display window with pointer and keyboard controls](images/vision-controls.jpg)

When Mac control is enabled, focus the intended application on the Mac before typing.
Use **Stop Control** to release remote input. **Stop Sharing** on the Mac ends sharing
availability; simply closing the companion window can leave sharing active in its menu bar.

![Share, pair, and open workflow](images/how-it-works.svg)

## Install the preview

Choose the current preview from [VisionDesk releases](https://github.com/bhino50/VisionDesk/releases),
then follow [Install & connect](INSTALL.md). The Mac build is ad-hoc signed and unnotarized.
The unsigned visionOS build needs your Apple development signing and provisioning.
It cannot be installed directly as a consumer download.

## About these pictures

The cover is an AI-generated product illustration made with the built-in image tool.
It explains the physical-display-to-spatial-window idea; its desktop artwork is illustrative.

The Mac picture renders the actual companion's SwiftUI view with neutral sample state.
The visionOS pictures capture the actual app views in a dedicated simulator with
synthetic display images and a sample Mac name. No user desktop, saved connection,
pairing secret, or private account content is shown. These images document the interface,
not measured streaming quality or new physical-headset acceptance.

The documentation fixtures live outside the shipped app. They do not change pairing,
permissions, or the production connection flow. The workflow diagram is editable SVG.
See [image provenance and the cover prompt](images/README.md).
