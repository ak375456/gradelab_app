"""GradeLab Spectrum: a three-second motion ident with an App Store end card.

Render with Python/Pillow/NumPy and ffmpeg. Use --preview for storyboard frames.
The original app artwork is used again on the final card for an exact match.
"""

from __future__ import annotations

import argparse
from functools import lru_cache
import json
import math
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[2]
ASSETS = ROOT / "assets"
OUTPUT = ROOT / "exports" / "spectrum"
FONT = PROJECT / "dummy name/Resources/Fonts/Inter_28pt-SemiBold.ttf"
REGULAR = PROJECT / "dummy name/Resources/Fonts/Inter_28pt-Regular.ttf"
ICON = PROJECT / "dummy name/Assets.xcassets/AppIcon.appiconset/GradeLabIcon-1024.png"
FPS = 60
DURATION = 3.0
WHITE = (246, 248, 251)
CROP = (180, 180, 836, 800)
PALETTE = np.array([[2, 244, 231], [0, 171, 249], [58, 45, 252],
                    [173, 32, 244], [247, 34, 158], [255, 117, 68],
                    [255, 214, 86]], dtype=float)


def clamp(x):
    return max(0.0, min(1.0, x))


def progress(t, start, end):
    return clamp((t - start) / (end - start))


def out(x):
    return 1.0 - (1.0 - clamp(x)) ** 4


def in_out(x):
    x = clamp(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def smooth(x):
    x = clamp(x)
    return x * x * (3 - 2 * x)


def spring(x):
    x = clamp(x)
    if x == 1:
        return 1.0
    return 1 - math.exp(-7 * x) * math.cos(10 * x)


def lerp(a, b, x):
    return a + (b - a) * x


def color_at(p):
    value = clamp(p) * (len(PALETTE) - 1)
    index = min(len(PALETTE) - 2, int(value))
    return tuple(np.uint8(lerp(PALETTE[index], PALETTE[index + 1], value - index)))


def original_logo():
    image = Image.open(ICON).convert("RGB")
    pixels = np.array(image, dtype=float)
    strength = np.clip((pixels.max(axis=2) - 16) / 24, 0, 1)
    alpha = strength ** 2 * (3 - 2 * strength)
    return Image.fromarray(np.dstack((pixels, alpha * 255)).astype(np.uint8))


ORIGINAL = original_logo()


def make_path():
    """Centerline of the existing G, traced from cyan through the spectrum."""
    points = [(756.0, 672.0)]

    def line(end):
        start = np.array(points[-1])
        for u in np.linspace(0, 1, 40)[1:]:
            points.append(tuple(lerp(start, np.array(end), u)))

    def cubic(a, b, c):
        start = np.array(points[-1])
        for u in np.linspace(0, 1, 100)[1:]:
            v = 1 - u
            p = v ** 3 * start + 3 * v ** 2 * u * np.array(a) + 3 * v * u ** 2 * np.array(b) + u ** 3 * np.array(c)
            points.append(tuple(p))

    cubic((710, 724), (652, 752), (575, 752))
    line((500, 752))
    cubic((356, 752), (239, 647), (239, 501))
    cubic((239, 356), (359, 240), (503, 240))
    line((790, 252))
    array = np.array(points)
    distances = np.concatenate(([0], np.cumsum(np.linalg.norm(np.diff(array, axis=0), axis=1))))
    return array, distances / distances[-1]


PATH, PATH_TIME = make_path()


def path_prefix(p):
    index = max(1, int(np.searchsorted(PATH_TIME, clamp(p))))
    index = min(index, len(PATH) - 1)
    u = clamp((p - PATH_TIME[index - 1]) / (PATH_TIME[index] - PATH_TIME[index - 1]))
    head = lerp(PATH[index - 1], PATH[index], u)
    return [tuple(pt) for pt in PATH[:index]] + [tuple(head)]


def animated_logo(t):
    if t >= 1.02:
        return ORIGINAL.crop(CROP)
    p = in_out(progress(t, 0.025, 0.65))
    mask = Image.new("L", ORIGINAL.size)
    md = ImageDraw.Draw(mask)
    trace = path_prefix(p)
    if p > 0:
        md.line(trace, fill=255, width=120, joint="curve")
        # Union round discs along the centerline to prevent tiny join gaps in
        # Pillow's wide-stroke rasterizer when the cubic is sampled densely.
        for x, y in trace:
            md.ellipse((x - 60, y - 60, x + 60, y + 60), fill=255)
    # Middle rail and both nodes are separate moving controls during the ident.
    md.rectangle((275, 430, 850, 570), fill=0)
    md.ellipse((617, 198, 725, 306), fill=0)
    image = ORIGINAL.copy()
    image.putalpha(ImageChops.multiply(image.getchannel("A"), mask))

    # Rebuild the section of the warm rail covered by the original top node.
    # This allows its node to travel right while the middle node travels left.
    draw = ImageDraw.Draw(image)
    if p > 0.82:
        for x in range(617, 726):
            amount = progress(p, 0.82, 0.95)
            c = color_at(0.79 + (x - 617) / 108 * 0.15)
            draw.line((x, 227, x, 267), fill=c + (round(255 * amount),), width=1)

    rail_p = out(progress(t, 0.27, 0.67))
    if rail_p > 0:
        end = lerp(305, 791, rail_p)
        draw.line((305, 500, end, 500), fill=WHITE + (255,), width=32)
        for x in (305, end):
            draw.ellipse((x - 16, 484, x + 16, 516), fill=WHITE + (255,))

    node_p = spring(progress(t, 0.32, 0.88))
    node_scale = out(progress(t, 0.32, 0.48))
    if node_scale > 0:
        for x, y in [(lerp(700, 436, node_p), 500), (lerp(535, 671, node_p), 252)]:
            ro, ri = 51 * node_scale, 34 * node_scale
            draw.ellipse((x - ro, y - ro, x + ro, y + ro), fill=WHITE + (255,))
            draw.ellipse((x - ri, y - ri, x + ri, y + ri), fill=(0, 0, 0, 255))

    # A small light head and narrow trail make the path's direction readable.
    if 0.04 < t < 0.65:
        head = trace[-1]
        start = max(0, p - 0.035)
        lead = path_prefix(start)[-1]
        # Keep the light head out of the moving top control's hollow center.
        if math.dist(head, (lerp(535, 671, node_p), 252)) > 67:
            draw.line((*lead, *head), fill=(238, 255, 255, 190), width=5)
            x, y = head
            draw.ellipse((x - 6, y - 6, x + 6, y + 6), fill=(255, 255, 255, 255))

    if t > 0.88:
        image = Image.blend(image, ORIGINAL, smooth(progress(t, 0.88, 1.02)))
    return image.crop(CROP)


def make_type(text, size, regular=False, color=WHITE):
    font = ImageFont.truetype(str(REGULAR if regular else FONT), size * 2)
    bounds = font.getbbox(text)
    pad = 12
    layer = Image.new("RGBA", (bounds[2] - bounds[0] + pad * 2,
                               bounds[3] - bounds[1] + pad * 2))
    ImageDraw.Draw(layer).text((pad - bounds[0], pad - bounds[1]), text,
                              font=font, fill=color + (255,))
    image = layer.resize((round(layer.width / 2), round(layer.height / 2)), Image.Resampling.LANCZOS)
    boundaries = [0]
    for i in range(1, len(text)):
        boundaries.append(round((pad + font.getlength(text[:i])) / 2))
    boundaries.append(image.width)
    return image, boundaries


def type_reveal(text_data, t, start, stagger=0.025, speed=0.34):
    image, boundaries = text_data
    layer = Image.new("RGBA", image.size)
    for i, (left, right) in enumerate(zip(boundaries[:-1], boundaries[1:])):
        u = out(progress(t, start + i * stagger, start + i * stagger + speed))
        if u <= 0:
            continue
        piece = image.crop((left, 0, right, image.height))
        shift = round((1 - u) * (image.height + 16))
        layer.paste(piece, (left, shift))
    return layer


def paste(canvas, layer, center, opacity=1):
    if opacity <= 0:
        return
    if opacity < 1:
        layer = layer.copy()
        layer.putalpha(layer.getchannel("A").point(lambda a: round(a * opacity)))
    x = round(center[0] - layer.width / 2)
    y = round(center[1] - layer.height / 2)
    canvas.paste(layer, (x, y), layer)


@lru_cache(maxsize=2)
def layout(orientation):
    portrait = orientation == "portrait"
    size = (1080, 1920) if portrait else (1920, 1080)
    end_logo = (540, 650) if portrait else (590, 540)
    initial_logo = (540, 880) if portrait else (960, 540)
    name_center = (540, 885) if portrait else (1200, 420)
    tagline_center = (540, 1000) if portrait else (1200, 535)
    badge_center = (540, 1200) if portrait else (1200, 695)
    badge = Image.open(ASSETS / "download-on-the-app-store.png").convert("RGBA")
    badge_width = 346 if portrait else 306
    badge = badge.resize((badge_width, round(badge.height * badge_width / badge.width)), Image.Resampling.LANCZOS)
    return {
        "portrait": portrait, "size": size, "end_logo": end_logo,
        "initial_logo": initial_logo, "name_center": name_center,
        "tagline_center": tagline_center, "badge_center": badge_center,
        "badge": badge, "name": make_type("GradeLab", 112),
        "tagline": make_type("Color grading. Made simple.", 40 if portrait else 38,
                             regular=True, color=(177, 187, 200)),
    }


def backdrop(config, t, center, logo_width):
    width, height = config["size"]
    # Render the broad light field at quarter resolution; it stays smooth and
    # dark while the actual logo and typography retain full-resolution edges.
    yy, xx = np.mgrid[0:height:4, 0:width:4]
    x = xx - center[0]
    y = yy - center[1]
    intensity = 0.13 + 0.55 * math.sin(math.pi * progress(t, 0, 1.2)) ** 2
    radius = logo_width * 0.75
    purple = np.exp(-(((x + radius * 0.45) / radius) ** 2 + ((y - radius * 0.02) / (radius * 0.85)) ** 2) * 2)
    cyan = np.exp(-(((x - radius * 0.35) / radius) ** 2 + ((y - radius * 0.4) / (radius * 0.8)) ** 2) * 2)
    pixels = purple[..., None] * np.array([51, 11, 100]) * intensity
    pixels += cyan[..., None] * np.array([0, 57, 72]) * intensity
    # Keep the outer canvas black, with just a localized spectral aura.
    pixels = np.clip(pixels, 0, 255).astype(np.uint8)
    return Image.fromarray(pixels).resize((width, height), Image.Resampling.BILINEAR).convert("RGBA")


def draw_orbits(canvas, t, center, logo_width):
    envelope = math.sin(math.pi * progress(t, 0.0, 1.2)) ** 1.5
    if envelope <= 0:
        return
    # The guides echo a color wheel, then expand out of the brand lockup.
    radius = logo_width * (0.67 + progress(t, 0.5, 1.2) * 0.30)
    side = round(radius * 2.5)
    layer = Image.new("RGBA", (side * 2, side * 2))
    draw = ImageDraw.Draw(layer)
    origin = side
    for orbit, (offset, sweep) in enumerate([(0, 128), (17, 86), (36, 116)]):
        r = (radius + offset) * 2
        angle = -t * 210 + orbit * 120
        for step in range(sweep):
            a = math.radians(angle + step)
            b = math.radians(angle + step + 1.2)
            c = color_at((step / sweep + orbit * 0.2) % 1)
            alpha = round(envelope * 90 * math.sin(math.pi * step / sweep))
            draw.line((origin + r * math.cos(a), origin + r * math.sin(a),
                       origin + r * math.cos(b), origin + r * math.sin(b)),
                      fill=c + (alpha,), width=2 if orbit else 3)
    for i in range(48):
        a = math.radians(i * 7.5 + t * 22)
        r1 = (radius + 54) * 2
        r2 = r1 + (12 if i % 4 == 0 else 5)
        alpha = round(25 * envelope)
        draw.line((origin + r1 * math.cos(a), origin + r1 * math.sin(a),
                   origin + r2 * math.cos(a), origin + r2 * math.sin(a)),
                  fill=(116, 144, 163, alpha), width=2)
    layer = layer.resize((side, side), Image.Resampling.LANCZOS)
    paste(canvas, layer, center)


def spectral_underline(canvas, config, t):
    p = out(progress(t, 0.98, 1.32))
    if p <= 0:
        return
    width = 220
    layer = Image.new("RGBA", (width + 40, 28))
    draw = ImageDraw.Draw(layer)
    extent = round(width * p / 2)
    middle = layer.width / 2
    for x in range(round(middle - extent), round(middle + extent)):
        c = color_at((x - middle + width / 2) / width)
        draw.line((x, 13, x, 15), fill=c + (210,))
    paste(canvas, layer, (config["tagline_center"][0], config["tagline_center"][1] + 63))


def frame(orientation, t):
    config = layout(orientation)
    travel = in_out(progress(t, 0.55, 1.08))
    center = tuple(lerp(a, b, travel) for a, b in zip(config["initial_logo"], config["end_logo"]))
    logo_width = lerp(540, 276 if config["portrait"] else 340, travel)
    canvas = backdrop(config, t, center, logo_width)
    draw_orbits(canvas, t, center, logo_width)
    logo = animated_logo(t)
    logo = logo.resize((round(logo_width), round(logo.height * logo_width / logo.width)), Image.Resampling.LANCZOS)
    # A brief rotation counter-moves the path and straightens during the settle.
    angle = 7 * math.sin(math.pi * progress(t, 0.0, 1.08)) * (1 - travel)
    if abs(angle) > 0.01:
        logo = logo.rotate(angle, Image.Resampling.BICUBIC, expand=True)
    glow_strength = 0.46 * (1 - smooth(progress(t, 0.65, 1.18)))
    if glow_strength > 0:
        glow = logo.filter(ImageFilter.GaussianBlur(13))
        paste(canvas, glow, center, glow_strength)
    paste(canvas, logo, center)
    if t > 0.86:
        name = type_reveal(config["name"], t, 0.86, stagger=0.019, speed=0.30)
        paste(canvas, name, config["name_center"])
    if t > 0.99:
        tagline = type_reveal(config["tagline"], t, 0.99, stagger=0.004, speed=0.28)
        paste(canvas, tagline, config["tagline_center"])
    spectral_underline(canvas, config, t)
    # Apple's artwork is static and unmodified. Cut it onto the settled card.
    if t >= 1.40:
        paste(canvas, config["badge"], config["badge_center"])
    return canvas.convert("RGB")


def sample_frame(orientation, t):
    # Three shutter samples give fast path and node motion a gentle natural blur.
    if 0.05 < t < 1.40:
        images = [frame(orientation, max(0, t + offset / FPS)) for offset in (-0.20, 0, 0.20)]
        return Image.blend(Image.blend(images[0], images[1], 0.5), images[2], 1 / 3)
    return frame(orientation, t)


def preview(orientation):
    times = [0.12, 0.30, 0.48, 0.64, 0.86, 1.06, 1.42, 2.8]
    portrait = orientation == "portrait"
    size = (270, 480) if portrait else (480, 270)
    columns = 4
    rows = 2
    sheet = Image.new("RGB", (columns * (size[0] + 8), rows * (size[1] + 36)), (17, 20, 25))
    font = ImageFont.truetype(str(REGULAR), 15)
    draw = ImageDraw.Draw(sheet)
    for index, t in enumerate(times):
        x, y = (index % columns) * (size[0] + 8), (index // columns) * (size[1] + 36)
        thumb = frame(orientation, t).resize(size, Image.Resampling.LANCZOS)
        sheet.paste(thumb, (x + 4, y + 4))
        draw.text((x + 10, y + size[1] + 11), f"{t:.2f}s", font=font, fill=(210, 218, 229))
    sheet.save(OUTPUT / f"{orientation}-storyboard.jpg", quality=94)
    frame(orientation, 2.0).save(OUTPUT / f"{orientation}-still.png")


def render(orientation):
    width, height = layout(orientation)["size"]
    ratio = "9x16" if orientation == "portrait" else "16x9"
    path = OUTPUT / f"GradeLab_Spectrum_{orientation.title()}_{ratio}_3s.mp4"
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
               "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
               "-framerate", str(FPS), "-i", "pipe:0", "-an", "-c:v", "libx264",
               "-preset", "slow", "-crf", "15", "-pix_fmt", "yuv420p",
               "-vf", "scale=out_color_matrix=bt709:out_range=tv",
               "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
               "-color_range", "tv", "-movflags", "+faststart",
               "-metadata", "title=GradeLab Spectrum Outro", str(path)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    assert process.stdin is not None
    try:
        hold = frame(orientation, 2.0).tobytes()
        for number in range(round(DURATION * FPS)):
            time = number / FPS
            process.stdin.write(sample_frame(orientation, time).tobytes() if time < 1.45 else hold)
            if number in (0, 40, 80, 120):
                print(f"{orientation}: frame {number}/{round(DURATION * FPS)}", flush=True)
    finally:
        process.stdin.close()
    if process.wait() != 0:
        raise RuntimeError("ffmpeg could not encode the video")
    probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_streams",
                            "-show_format", "-of", "json", str(path)],
                           check=True, capture_output=True, text=True)
    data = json.loads(probe.stdout)
    stream = data["streams"][0]
    assert (stream["width"], stream["height"]) == (width, height)
    assert int(stream["nb_read_frames"]) == 180
    assert float(data["format"]["duration"]) == DURATION
    assert stream["pix_fmt"] == "yuv420p" and stream["codec_name"] == "h264"
    subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"], check=True)
    result = {"file": path.name, "size": [width, height], "seconds": DURATION,
              "fps": FPS, "frames": 180, "bytes": path.stat().st_size}
    print(json.dumps(result), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for orientation in ("portrait", "landscape"):
        preview(orientation)
    if not args.preview:
        report = [render(orientation) for orientation in ("portrait", "landscape")]
        (OUTPUT / "export-specs.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
