"""Rebuild the Color Warper card using the supplied iPad artwork as its base."""

from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
REFERENCE = ROOT / "reference_ipad_english.png"
SOURCES = PROJECT / "ios_store_localizations" / "color_warper"
FONT_DIR = PROJECT / "dummy name" / "Resources" / "Fonts"
TITLE_FONT = FONT_DIR / "Inter_28pt-Bold.ttf"
BODY_FONT = FONT_DIR / "Inter_28pt-Regular.ttf"
W, H = 2064, 2752

COPY = {
    "English": ("Shape Every Color", "Hue/Sat + Chroma/Luma",
                "Two precise modes in one Color Warper."),
    "French": ("Modelez chaque couleur", "Teinte/Sat + Chroma/Luma",
               "Deux modes précis dans le Color Warper."),
    "German": ("Forme jede Farbe", "Farbton/Sätt. + Chroma/Luma",
               "Zwei präzise Modi im Color Warper."),
    "Italian": ("Modella ogni colore", "Tonalità/Sat + Croma/Luma",
                "Due modalità precise nel Color Warper."),
    "Spanish_Spain": ("Moldea cada color", "Tono/Sat + Croma/Luma",
                      "Dos modos precisos en Color Warper."),
}


def clean_header(reference: Image.Image) -> Image.Image:
    """Recover the original navy gradient behind the old headline."""
    pixels = np.asarray(reference.convert("RGB"), dtype=np.uint8)
    sample = pixels[:620:4, ::4].astype(np.float64)
    yy, xx = np.mgrid[0:620:4, 0:W:4]
    x, y = xx / (W / 2) - 1, yy / 310 - 1
    mask = sample.max(axis=2) < 117
    cols = [np.ones_like(x), x, y, x*x, x*y, y*y,
            x*x*x, x*x*y, x*y*y, y*y*y,
            x**4, x**3*y, x*x*y*y, x*y**3, y**4]
    coefficients = np.linalg.lstsq(np.stack(cols, axis=-1)[mask],
                                   sample[mask], rcond=None)[0]
    yy, xx = np.mgrid[0:620, 0:W]
    x, y = xx / (W / 2) - 1, yy / 310 - 1
    cols = [np.ones_like(x), x, y, x*x, x*y, y*y,
            x*x*x, x*x*y, x*y*y, y*y*y,
            x**4, x**3*y, x*x*y*y, x*y**3, y**4]
    fitted = np.uint8(np.clip(np.stack(cols, axis=-1) @ coefficients, 0, 255))
    result = pixels.copy()
    alpha = np.ones((620, 1, 1), dtype=np.float64)
    alpha[565:, 0, 0] = np.linspace(1, 0, 55)
    result[:620] = np.uint8(np.round(fitted*alpha + pixels[:620]*(1-alpha)))
    return Image.fromarray(result)


def font_that_fits(text: str, path: Path, preferred: int,
                   max_width: int) -> ImageFont.FreeTypeFont:
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for size in range(preferred, 30, -1):
        font = ImageFont.truetype(str(path), size)
        if probe.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(text)


def center_text(draw: ImageDraw.ImageDraw, text: str, top: int,
                font: ImageFont.FreeTypeFont, color: str) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    draw.text(((W-(box[2]-box[0]))/2-box[0], top-box[1]),
              text, font=font, fill=color)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0]-1, size[1]-1),
                                           radius=radius, fill=255)
    return mask


def replace_feature_content(canvas: Image.Image, luma: Image.Image) -> None:
    # Reuse the source tablet frame and app chrome exactly. Only its preview
    # and color controls change. The preview crop preserves its source ratio.
    x, width = 367, 1338
    photo = luma.crop((0, 432, 1179, 1010))
    canvas.paste(photo.resize((width, 655), Image.Resampling.LANCZOS), (x, 880))
    tools = luma.crop((0, 1180, 1179, 1595))
    canvas.paste(tools.resize((width, 310), Image.Resampling.LANCZOS), (x, 1535))
    graph = luma.crop((0, 1595, 1179, 2255))
    canvas.paste(graph.resize((width, 600), Image.Resampling.LANCZOS), (x, 1845))


def replace_inset(canvas: Image.Image, wheel: Image.Image) -> None:
    # Matches the exact footprint of the original Before card.
    x, y, width, height = 99, 858, 605, 534
    card = Image.new("RGB", (width, height), "#080A0C")
    crop = wheel.crop((210, 1525, 970, 2285))
    card.paste(crop.resize((488, 488), Image.Resampling.LANCZOS),
               ((width-488)//2, 31))
    canvas.paste(card, (x, y), rounded_mask((width, height), 47))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x+width, y+height), radius=47,
                           outline="#E4EEF6", width=5)
    label = "Hue / Sat"
    font = ImageFont.truetype(str(TITLE_FONT), 35)
    label_width = int(draw.textlength(label, font=font)) + 50
    draw.rounded_rectangle((x+25, y+23, x+25+label_width, y+83),
                           radius=30, fill="#333D48")
    box = draw.textbbox((0, 0), label, font=font)
    draw.text((x+50, y+35-box[1]), label, font=font, fill="#FCFCFF")


def main() -> None:
    reference = Image.open(REFERENCE).convert("RGB")
    wheel = Image.open(SOURCES / "source_hue_sat.png").convert("RGB")
    luma = Image.open(SOURCES / "source_chroma_luma.png").convert("RGB")
    if reference.size != (W, H):
        raise ValueError(f"Unexpected iPad reference size: {reference.size}")
    base = clean_header(reference)
    replace_feature_content(base, luma)
    replace_inset(base, wheel)
    outputs = []
    for language, (first, second, subtitle) in COPY.items():
        image = base.copy()
        draw = ImageDraw.Draw(image)
        center_text(draw, first, 166, font_that_fits(first, TITLE_FONT, 154, 1770),
                    "#FCFCFF")
        center_text(draw, second, 302, font_that_fits(second, TITLE_FONT, 116, 1780),
                    "#70C5FF")
        center_text(draw, subtitle, 471,
                    font_that_fits(subtitle, BODY_FONT, 66, 1750), "#C5CCD7")
        output = ROOT / f"GradeLab_iPad_Color_Warper_{language}.png"
        image.save(output, optimize=True)
        outputs.append(output)
        print(language, output.name)
    archive = ROOT / "GradeLab_iPad_Color_Warper_5_languages.zip"
    with ZipFile(archive, "w", ZIP_DEFLATED, compresslevel=6) as bundle:
        for output in outputs:
            bundle.write(output, output.name)
    print(archive.name)


if __name__ == "__main__":
    main()
