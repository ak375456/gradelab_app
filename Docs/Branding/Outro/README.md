# GradeLab Spectrum outro

The current version is in `exports/spectrum/`:

- `GradeLab_Spectrum_Portrait_9x16_3s.mp4` — 1080 × 1920.
- `GradeLab_Spectrum_Landscape_16x9_3s.mp4` — 1920 × 1080.

Both are three seconds long, with 60 fps H.264 video, BT.709 color, and no audio
track. Append the appropriate clip to a finished video; music can continue
underneath it.

The animation traces the logo's spectrum stroke, draws the grading rail, moves
the two controls in opposite directions, and adds rotating color-wheel guides
and localized spectral light. The logo moves and scales into its final position
while the GradeLab letters rise individually through a mask. A short benefit
follows: **Color grading. Made simple.** The final card holds from 1.4 seconds
and includes the black **Download on the App Store** badge.

The final logo uses the actual current app icon, with its baked-in near-black
background keyed out for compositing. The App Store badge is Apple's original
vector artwork, rasterized at high resolution. It is stationary and unmodified
when displayed.

Run `render_motion_outro.py` to render the current version. Use `--preview` for
still frames and storyboards only. Requirements: Python with Pillow and NumPy,
plus `ffmpeg` and `ffprobe` on PATH. The renderer verifies the exported frame
count, dimensions, duration and codec, and decodes each full video to check it.

Earlier versions remain in `exports/` and `exports/cta/`. Their renderer is
`render_outros.py`.

App Store badge source:
[Apple's original SVG](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg).
Reference: [Apple App Store marketing resources](https://developer.apple.com/app-store/marketing/guidelines/).

Apple, the Apple logo, and App Store are trademarks of Apple Inc., registered
in the U.S. and other countries.
