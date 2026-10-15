# GradeLab — masking, tracking and looks carousel

Three slides, exported separately for each platform:

- Instagram feed carousel: 1080 × 1350 pixels (4:5).
- TikTok photo carousel: 1080 × 1920 pixels (9:16).

Upload the three numbered PNGs from the appropriate platform folder in order: masking, tracking and zoom, then new looks. `caption.txt` is ready to paste for either platform. Suggested TikTok photo title: **Your sky. Your grade.**

These are marketing compositions generated with the built-in image_gen tool using GradeLab's real app screens and icon as references. They use the established navy, white and blue branding. Artwork and UI are stylized for the campaign; they are not raw device screenshots. The free/Pro counts reflect the eight new looks added in this update. The decorative color cards are visual motifs, not calibrated LUT comparisons.

The six selected generated masters are preserved in `sources/`. `prompts.md` records all prompts, including the final TikTok looks-slide layout correction. macOS `sips` only normalizes the exports to the exact requested pixel dimensions, without cropping. `manifest.json` records image modes and sizes. `export.py` rebuilds missing exports and the delivery ZIP; use `--overwrite` only to replace existing exports deliberately. Run with Python containing Pillow (the Codex bundled workspace runtime provides it).

The delivery ZIP contains only the six final PNGs, caption, prompts, README and manifest; generated masters remain in the project folder. Nothing has been posted to a social account.

TikTok composition reference: [TikTok's mobile-first creative guidance](https://ads.tiktok.com/business/en-AU/guides/video-advertising-guide).
