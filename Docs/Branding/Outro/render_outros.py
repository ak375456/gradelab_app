"""Render GradeLab's short, silent brand outro in portrait and landscape.

Requires Python with Pillow and NumPy, plus ffmpeg and ffprobe on PATH.
The app icon and font are read from the project; neither source is changed.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import shutil
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFont


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[2]
ICON = PROJECT / "dummy name/Assets.xcassets/AppIcon.appiconset/GradeLabIcon-1024.png"
FONT = PROJECT / "dummy name/Resources/Fonts/Inter_28pt-SemiBold.ttf"
FPS = 60
BLACK = (0, 0, 0)
WHITE = (247, 248, 250)
ACCENT = (117, 225, 241)


def ease_out(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return 1.0 - (1.0 - value) ** 4


def smooth(value: float) -> float:
    value = min(1.0, max(0.0, value))
    return value * value * (3.0 - 2.0 * value)


def logo_layer() -> Image.Image:
    # Luma-key the icon's baked-in near-black background for video compositing.
    # Preserve the actual logo's geometry and colors, including its dark holes.
    source = Image.open(ICON).convert("RGB")
    pixels = np.asarray(source, dtype=np.float32)
    brightness = pixels.max(axis=2)
    amount = np.clip((brightness - 16.0) / 24.0, 0.0, 1.0)
    alpha = amount * amount * (3.0 - 2.0 * amount)
    rgba = np.dstack((pixels, alpha * 255.0)).astype(np.uint8)
    layer = Image.fromarray(rgba)
    bounds = layer.getbbox()
    if bounds is None:
        raise ValueError("The GradeLab logo is empty")
    x0, y0, x1, y1 = bounds
    return layer.crop((max(0, x0 - 16), max(0, y0 - 16),
                       min(source.width, x1 + 16), min(source.height, y1 + 16)))


def text_layer(text: str, size: int, color: tuple = WHITE) -> Image.Image:
    # Draw at double resolution for clean type at Full HD.
    factor = 2
    font = ImageFont.truetype(str(FONT), size * factor)
    bounds = font.getbbox(text)
    pad = 8 * factor
    layer = Image.new("RGBA", (bounds[2] - bounds[0] + pad * 2,
                              bounds[3] - bounds[1] + pad * 2))
    draw = ImageDraw.Draw(layer)
    draw.text((pad - bounds[0], pad - bounds[1]), text, font=font,
              fill=color + (255,), stroke_width=0)
    return layer.resize((round(layer.width / factor), round(layer.height / factor)),
                        Image.Resampling.LANCZOS)


def wordmark(size: int) -> Image.Image:
    return text_layer("GradeLab", size)


def cta_layer(portrait: bool) -> Image.Image:
    factor = 2
    width, height = (696, 132) if portrait else (824, 88)
    layer = Image.new("RGBA", (width * factor, height * factor))
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle((1, 1, width * factor - 2, height * factor - 2),
                           radius=24 * factor, fill=(13, 18, 21, 255),
                           outline=(40, 63, 72, 255), width=2)

    def centered_segments(segments: list[tuple[str, tuple]], size: int, cy: int):
        font = ImageFont.truetype(str(FONT), size * factor)
        total = sum(draw.textlength(text, font=font) for text, _ in segments)
        x = (width * factor - total) / 2
        # All segments share the same baseline.
        bounds = font.getbbox("Comment APP")
        y = cy * factor - (bounds[3] - bounds[1]) / 2 - bounds[1]
        for text, color in segments:
            draw.text((x, y), text, font=font, fill=color + (255,))
            x += draw.textlength(text, font=font)

    if portrait:
        centered_segments([("Comment ", WHITE), ("“APP”", ACCENT)], 42, 44)
        centered_segments([("for the free app link", (178, 190, 196))], 31, 94)
    else:
        centered_segments([("Comment ", WHITE), ("“APP”", ACCENT),
                           (" for the free app link", WHITE)], 38, 44)
    return layer.resize((width, height), Image.Resampling.LANCZOS)


def place(canvas: Image.Image, layer: Image.Image, center: tuple[float, float],
          opacity: float, scale: float = 1.0, offset_y: float = 0.0) -> None:
    if opacity <= 0.0:
        return
    if scale != 1.0:
        layer = layer.resize((round(layer.width * scale), round(layer.height * scale)),
                             Image.Resampling.LANCZOS)
    alpha = layer.getchannel("A")
    if opacity < 1.0:
        alpha = alpha.point(lambda value: round(value * opacity))
    x = round(center[0] - layer.width / 2)
    y = round(center[1] - layer.height / 2 + offset_y)
    canvas.paste(layer.convert("RGB"), (x, y), alpha)


def composition(orientation: str, style: str):
    portrait = orientation == "portrait"
    width, height = (1080, 1920) if portrait else (1920, 1080)
    logo = logo_layer()
    logo_width = (84 if portrait else 78) if style == "cta" else (268 if portrait else 222)
    logo = logo.resize((logo_width, round(logo.height * logo_width / logo.width)),
                       Image.Resampling.LANCZOS)
    name = wordmark((46 if portrait else 44) if style == "cta" else (90 if portrait else 110))
    if style == "cta":
        gap = 20
        brand_y = 650 if portrait else 300
        total_width = logo.width + gap + name.width
        left = (width - total_width) / 2
        logo_center = (left + logo.width / 2, brand_y)
        name_center = (left + logo.width + gap + name.width / 2, brand_y)
        elements = [
            (logo, logo_center, "logo", 0.0),
            (name, name_center, "name", 0.0),
            (text_layer("Cinematic color grading.", 70 if portrait else 78),
             (width / 2, 850 if portrait else 475), "headline", 0.06),
            (text_layer("Made simple.", 96, ACCENT),
             (width / 2, 955 if portrait else 580), "headline", 0.10),
            (cta_layer(portrait), (width / 2, 1160 if portrait else 755), "cta", 0.16),
        ]
    elif portrait:
        gap = 46
        total_height = logo.height + gap + name.height
        top = height * 0.47 - total_height / 2
        logo_center = (width / 2, top + logo.height / 2)
        name_center = (width / 2, top + logo.height + gap + name.height / 2)
    else:
        gap = 64
        total_width = logo.width + gap + name.width
        left = (width - total_width) / 2
        logo_center = (left + logo.width / 2, height / 2)
        name_center = (left + logo.width + gap + name.width / 2, height / 2)
    if style == "brand":
        elements = [(logo, logo_center, "logo", 0.025),
                    (name, name_center, "name", 0.16)]
    return (width, height), elements


def make_frame(orientation: str, time: float, duration: float, style: str) -> Image.Image:
    size, elements = LAYOUTS[(orientation, style)]
    canvas = Image.new("RGB", size, BLACK)
    # A quiet reveal followed by a long, readable hold. The final frame stays
    # fully visible, so the branding remains on screen when a video finishes.
    tempo = min(1.0, duration / 2.0)
    for layer, center, role, delay in elements:
        reveal_duration = (0.32 if role in ("logo", "name") else 0.38) if style == "cta" else (0.52 if role == "logo" else 0.44)
        progress = (time - delay * tempo) / (reveal_duration * tempo)
        motion = ease_out(progress)
        scale = 0.94 + 0.06 * motion if role == "logo" else 1.0
        place(canvas, layer, center, smooth(progress), scale=scale,
              offset_y=(8 if style == "cta" else 12) * (1 - motion))
    return canvas


LAYOUTS = {(orientation, style): composition(orientation, style)
           for orientation in ("portrait", "landscape") for style in ("brand", "cta")}


def render(orientation: str, duration: float, output: Path, style: str) -> Path:
    width, height = LAYOUTS[(orientation, style)][0]
    duration_label = f"{duration:g}s"
    ratio = "9x16" if orientation == "portrait" else "16x9"
    suffix = "_CTA" if style == "cta" else ""
    path = output / f"GradeLab_Outro_{orientation.title()}_{ratio}{suffix}_{duration_label}.mp4"
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
        "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "libx264",
        "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
        "-vf", "scale=out_color_matrix=bt709:out_range=tv",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-color_range", "tv", "-movflags", "+faststart",
        "-metadata", "title=GradeLab Outro", str(path),
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    assert process.stdin is not None
    try:
        for number in range(round(duration * FPS)):
            frame = make_frame(orientation, number / FPS, duration, style)
            process.stdin.write(frame.tobytes())
    finally:
        process.stdin.close()
    if process.wait() != 0:
        raise RuntimeError(f"ffmpeg failed for {orientation}")
    make_frame(orientation, 1.0, duration, style).save(output / f"{orientation}-still.png")
    print(f"Rendered {path.name}", flush=True)
    return path


def verify(path: Path, duration: float) -> dict:
    probe = subprocess.run([
        "ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format",
        "-of", "json", str(path),
    ], check=True, capture_output=True, text=True)
    data = json.loads(probe.stdout)
    video = data["streams"][0]
    assert video["codec_name"] == "h264"
    assert video["pix_fmt"] == "yuv420p"
    assert int(video["nb_read_frames"]) == round(duration * FPS)
    assert abs(float(data["format"]["duration"]) - duration) < 1 / FPS
    assert len(data["streams"]) == 1
    return {
        "file": path.name, "size": [video["width"], video["height"]],
        "seconds": float(data["format"]["duration"]), "fps": video["r_frame_rate"],
        "codec": video["codec_name"], "frames": int(video["nb_read_frames"]),
        "bytes": path.stat().st_size,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--style", choices=("brand", "cta"), default="cta",
                        help="CTA version (default) or the original logo-only version")
    parser.add_argument("--duration", type=float, default=None,
                        help="Clip length in seconds (1 to 3; defaults: CTA 3, brand 2)")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    if args.duration is None:
        args.duration = 3.0 if args.style == "cta" else 2.0
    if args.output is None:
        args.output = HERE / "exports" / "cta" if args.style == "cta" else HERE / "exports"
    if not math.isfinite(args.duration) or not 1 <= args.duration <= 3:
        parser.error("Choose a duration from 1 to 3 seconds")
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        parser.error("ffmpeg and ffprobe are required")
    args.output.mkdir(parents=True, exist_ok=True)
    paths = [render(orientation, args.duration, args.output, args.style)
             for orientation in ("portrait", "landscape")]
    report = [verify(path, args.duration) for path in paths]
    (args.output / "export-specs.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
