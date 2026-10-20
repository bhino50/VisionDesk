# Documentation image sources

These visuals document the audited 0.2.1 interface. They are licensed with the project.

| File | Origin | What it represents |
| --- | --- | --- |
| `visiondesk-hero.png` | Built-in image generation tool | Conceptual workspace illustration, not a screenshot |
| `how-it-works.svg` | Editable vector diagram | Share existing displays, pair, then open windows |
| `mac-companion.png` | Production SwiftUI rendering with sample state | Mac sharing controls and display selection |
| `vision-pairing.jpg` | App running in visionOS Simulator | Pairing interface with neutral sample state |
| `vision-workspace.jpg` | App running in visionOS Simulator | Four-display overview with synthetic content |
| `vision-controls.jpg` | App running in visionOS Simulator | Single display window with pointer and keyboard controls |

Capture fixtures use neutral names and content. No real pairing keys, saved connection
details, personal desktop images, or device identifiers belong in documentation assets.
The fixtures are excluded from the shipped applications. Screenshots represent app UI;
they do not establish physical-device, network-latency, or streaming-quality results.

## Cover generation prompt

Built-in image generation was used. The final prompt was:

> Use case: ads-marketing. Asset type: wide hero banner for the VisionDesk GitHub README. Create a polished editorial 3D illustration, landscape 16:9, light ivory and soft pale-blue background, subtle glass and precise silver aluminum hardware. Left third: very large crisp dark navy title, exact text 'VisionDesk'. Below it in clean smaller typography exact text 'Your Mac displays. In your space.' Right two thirds: an open modern Mac laptop on a minimal desk, connected to three physical monitors (one landscape, two portrait), and a beautiful spatial arrangement of four distinct translucent rounded rectangular screen windows hovering above/right, communicating one independent window per existing physical display. Screens contain tasteful abstract sample content: simple colorful code-like lines, an image canvas, a calendar-like grid, a small analytics chart; no readable private content, no fake app controls, no logos on screens. A small elegant white-and-silver spatial-computing headset rests at the lower right, with believable proportions. Cool blue/cyan highlights, airy generous spacing, sophisticated product launch art, clean precision, no people, no watermarks. Composition must be completely in frame, no cropped hardware. Do not imply extra virtual displays are created. The screen arrangements are a conceptual illustration, not actual screenshots. Include a small unobtrusive lower-left label exact text 'Mac + Apple Vision Pro'. Render one coherent cover image, no separate panels or collage.
