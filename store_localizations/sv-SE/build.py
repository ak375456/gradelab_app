"""Localize only the marketing headline and subtitle in the supplied artwork."""

from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
FONT_DIR = ROOT.parents[1] / "dummy name" / "Resources" / "Fonts"
BOLD = FONT_DIR / "Inter_28pt-Bold.ttf"
REGULAR = FONT_DIR / "Inter_28pt-Regular.ttf"
WHITE = "#FCFCFF"
BLUE = "#64C3FC"
MUTED = "#C7D0DC"

# The top edge of each device is below clean_end. All device artwork and the
# lower background stay exactly as supplied in the original PNGs.
ARTWORK = {
    "ios": [
        ("01_color_grading", 550, 145, 279, 430, 116, 114, 45, 1150,
         [[("Proffsig färggradering", WHITE)], [("för ", WHITE), ("foto & video", BLUE)]],
         "Professionella verktyg. Smidigt arbetsflöde."),
        ("02_looks", 514, 145, 275, 425, 116, 116, 44, 1150,
         [[("Filmiska looks", WHITE)], [("enkelt skapade", BLUE)]],
         "Använd förinställningar och skapa din egen stil."),
        ("03_curves", 510, 145, 280, 421, 116, 116, 43, 1150,
         [[("Avancerade", WHITE)], [("kurvor & scopes", BLUE)]],
         "Finjustera färger med exakta analysverktyg."),
        ("04_color_warper", 504, 67, 186, 325, 109, 83, 42, 1150,
         [[("Forma varje färg", WHITE)], [("Nyans/mättnad + kroma/luma", BLUE)]],
         "Två precisa lägen i en Color Warper."),
        ("05_fine_tune", 502, 122, 260, 415, 117, 117, 43, 1150,
         [[("Finjustera", WHITE)], [("varje färg", BLUE)]],
         "Justera nyans, mättnad och luminans exakt."),
        ("06_effects", 472, 128, 258, 405, 116, 112, 42, 1150,
         [[("Fullända looken", WHITE)], [("med proffseffekter", BLUE)]],
         "Lägg till fade, skärpa, bloom och filmisk finish."),
    ],
    "ipad": [
        ("01_color_grading", 604, 157, 303, 480, 154, 143, 65, 1840,
         [[("Proffsig färggradering", WHITE)], [("för ", WHITE), ("foto & video", BLUE)]],
         "Professionella verktyg. Smidigt arbetsflöde."),
        ("02_looks", 581, 143, 297, 468, 155, 150, 65, 1840,
         [[("Filmiska looks", WHITE)], [("enkelt skapade", BLUE)]],
         "Använd förinställningar och skapa din egen stil."),
        ("03_curves", 541, 119, 273, 450, 154, 150, 64, 1840,
         [[("Avancerade", WHITE)], [("kurvor & scopes", BLUE)]],
         "Finjustera färger med exakta analysverktyg."),
        ("04_color_warper", 605, 160, 305, 479, 154, 118, 64, 1840,
         [[("Forma varje färg", WHITE)], [("Nyans/mättnad + kroma/luma", BLUE)]],
         "Två precisa lägen i en Color Warper."),
        ("05_fine_tune", 534, 120, 275, 449, 154, 154, 64, 1840,
         [[("Finjustera", WHITE)], [("varje färg", BLUE)]],
         "Justera nyans, mättnad och luminans exakt."),
        ("06_effects", 559, 121, 277, 453, 154, 147, 64, 1840,
         [[("Fullända looken", WHITE)], [("med proffseffekter", BLUE)]],
         "Lägg till fade, skärpa, bloom och filmisk finish."),
    ],
    "mac": [
        ("01_color_grading", 393, 105, None, 250, 112, None, 54, 2470,
         [[("Proffsig färggradering för foto & video", WHITE)]],
         "Professionella verktyg. Smidigt arbetsflöde."),
        ("02_looks", 485, 78, 203, 353, 128, 124, 54, 2480,
         [[("Filmiska looks", WHITE)], [("enkelt skapade", BLUE)]],
         "Använd förinställningar och skapa din egen stil."),
        ("03_fine_tune", 415, 42, 158, 307, 124, 124, 51, 2480,
         [[("Finjustera", WHITE)], [("varje färg", BLUE)]],
         "Justera nyans, mättnad och luminans exakt."),
        ("04_scopes", 480, 62, 186, 358, 124, 124, 53, 2480,
         [[("Avancerade scopes", WHITE)], [("enkla att använda", BLUE)]],
         "Analysera färg med tydliga, intuitiva scopes."),
        ("05_color_warper", 416, 49, 162, 308, 124, 124, 51, 2480,
         [[("Color Warper", WHITE)], [("Forma varje färg", BLUE)]],
         "Forma färg i lägena Nyans/mättnad och Kroma/luma."),
    ],
}


def polynomial_columns(x: np.ndarray, y: np.ndarray) -> np.ndarray:
    return np.stack([np.ones_like(x), x, y, x*x, x*y, y*y,
                     x*x*x, x*x*y, x*y*y, y*y*y,
                     x**4, x**3*y, x*x*y*y, x*y**3, y**4], axis=-1)


def erase_english_copy(image: Image.Image, clean_end: int) -> Image.Image:
    """Replace English glyphs with a fitted version of the original gradient."""
    rgb = image.convert("RGB")
    pixels = np.asarray(rgb, dtype=np.uint8)
    header = pixels[:clean_end]
    height, width = header.shape[:2]
    sample = header[::5, ::5].astype(np.float64)
    yy, xx = np.mgrid[0:height:5, 0:width:5]
    x = xx / (width/2) - 1
    y = yy / (height/2) - 1
    background = (sample[:, :, 0] < 115) & (sample[:, :, 1] < 145)
    columns = polynomial_columns(x, y)
    coefficients = np.linalg.lstsq(columns[background], sample[background],
                                   rcond=None)[0]

    restored = np.empty_like(header)
    for start in range(0, height, 80):
        stop = min(start+80, height)
        yy, xx = np.mgrid[start:stop, 0:width]
        x = xx / (width/2) - 1
        y = yy / (height/2) - 1
        restored[start:stop] = np.uint8(np.clip(
            polynomial_columns(x, y) @ coefficients, 0, 255))
    # Repaint the whole copy area so the old black drop shadows cannot show
    # through. Fade into untouched source pixels before the device begins.
    alpha = np.ones((height, 1, 1), dtype=np.float32)
    fade = min(16, height//8)
    alpha[-fade:, 0, 0] = np.linspace(1, 0, fade)
    merged = np.uint8(np.round(restored*alpha + header*(1-alpha)))
    cleaned = rgb.copy()
    cleaned.paste(Image.fromarray(merged), (0, 0))
    return cleaned


def fitted_font(spans: list[tuple[str, str]], preferred: int,
                max_width: int, path: Path = BOLD) -> ImageFont.FreeTypeFont:
    text = "".join(part for part, _ in spans)
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for size in range(preferred, 30, -1):
        font = ImageFont.truetype(str(path), size)
        if probe.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(f"Text does not fit: {text}")


def centered_spans(draw: ImageDraw.ImageDraw, width: int,
                   spans: list[tuple[str, str]], top: int,
                   font: ImageFont.FreeTypeFont) -> None:
    text = "".join(part for part, _ in spans)
    box = draw.textbbox((0, 0), text, font=font)
    x = (width - (box[2]-box[0]))/2 - box[0]
    y = top-box[1]
    for part, color in spans:
        draw.text((x, y), part, font=font, fill=color)
        x += draw.textlength(part, font=font)


def build_one(device: str, item: tuple) -> Path:
    (stem, clean_end, top1, top2, top_sub, size1, size2, sub_size,
     max_width, title_lines, subtitle) = item
    source = ROOT / "sources" / device / f"{stem}.png"
    with Image.open(source) as original:
        image = erase_english_copy(original, clean_end)
    draw = ImageDraw.Draw(image)
    centered_spans(draw, image.width, title_lines[0], top1,
                   fitted_font(title_lines[0], size1, max_width))
    if len(title_lines) == 2:
        centered_spans(draw, image.width, title_lines[1], top2,
                       fitted_font(title_lines[1], size2, max_width))
    centered_spans(draw, image.width, [(subtitle, MUTED)], top_sub,
                   fitted_font([(subtitle, MUTED)], sub_size,
                               image.width-140, REGULAR))
    destination = ROOT / device / f"GradeLab_{device.upper()}_Swedish_{stem}.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, optimize=True)
    return destination


def main() -> None:
    all_outputs = []
    for device, items in ARTWORK.items():
        outputs = []
        for item in items:
            path = build_one(device, item)
            outputs.append(path)
            all_outputs.append(path)
            print(device, path.name)
        with ZipFile(ROOT/f"GradeLab_Swedish_{device.upper()}.zip", "w",
                     ZIP_DEFLATED, compresslevel=6) as bundle:
            for output in outputs:
                bundle.write(output, output.name)
    with ZipFile(ROOT/"GradeLab_Swedish_All_Devices.zip", "w",
                 ZIP_DEFLATED, compresslevel=6) as bundle:
        for output in all_outputs:
            bundle.write(output, f"{output.parent.name}/{output.name}")
    print("Total:", len(all_outputs))


if __name__ == "__main__":
    main()
