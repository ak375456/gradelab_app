"""Build five 1242 × 2688 Color Warper App Store screenshots.

The UI comes from the two unmodified iPhone captures in this directory. This
script only scales, crops, and frames them for the store artwork.
"""

from pathlib import Path
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
FONT_DIR = ROOT.parents[1] / "dummy name" / "Resources" / "Fonts"
TITLE_FONT = FONT_DIR / "Inter_28pt-Bold.ttf"
BODY_FONT = FONT_DIR / "Inter_28pt-Regular.ttf"
SOURCE_WHEEL = Path("/Users/aftab/Downloads/IMG_4845.PNG")
SOURCE_LUMA = Path("/Users/aftab/Downloads/IMG_4846.PNG")

W, H = 1242, 2688
BLUE = "#67C4FF"
WHITE = "#FCFCFF"
MUTED = "#C9D3E0"

COPY = {
    "English": (
        "Shape Every Color",
        "Hue/Sat + Chroma/Luma",
        "Two precise modes in one Color Warper.",
    ),
    "French": (
        "Modelez chaque couleur",
        "Teinte/Sat + Chroma/Luma",
        "Deux modes précis dans le Color Warper.",
    ),
    "German": (
        "Forme jede Farbe",
        "Farbton/Sätt. + Chroma/Luma",
        "Zwei präzise Modi im Color Warper.",
    ),
    "Italian": (
        "Modella ogni colore",
        "Tonalità/Sat + Croma/Luma",
        "Due modalità precise nel Color Warper.",
    ),
    "Spanish_Spain": (
        "Moldea cada color",
        "Tono/Sat + Croma/Luma",
        "Dos modos precisos en Color Warper.",
    ),
}


def background() -> Image.Image:
    yy, xx = np.mgrid[0:H, 0:W]
    base = np.empty((H, W, 3), dtype=np.float32)
    base[:] = (17, 31, 48)
    upper_left = np.exp(-(((xx + 130) / 930) ** 2 + ((yy - 10) / 850) ** 2))
    middle_right = np.exp(-(((xx - 1350) / 870) ** 2 + ((yy - 1330) / 1480) ** 2))
    lower_left = np.exp(-(((xx + 120) / 740) ** 2 + ((yy - 2420) / 850) ** 2))
    base += upper_left[..., None] * np.array((25, 45, 73), dtype=np.float32)
    base += middle_right[..., None] * np.array((5, 17, 35), dtype=np.float32)
    base += lower_left[..., None] * np.array((17, 31, 50), dtype=np.float32)
    return Image.fromarray(np.uint8(np.clip(base, 0, 255)), "RGB")


def fit_font(text: str, path: Path, size: int, max_width: int) -> ImageFont.FreeTypeFont:
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for candidate in range(size, 25, -1):
        font = ImageFont.truetype(str(path), candidate)
        if probe.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(f"Text does not fit: {text}")


def centered(draw: ImageDraw.ImageDraw, text: str, top: int,
             font: ImageFont.FreeTypeFont, color: str) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    x = (W - (box[2] - box[0])) / 2 - box[0]
    draw.text((x, top - box[1]), text, font=font, fill=color)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0]-1, size[1]-1),
                                           radius=radius, fill=255)
    return mask


def add_shadow(canvas: Image.Image, rect: tuple[int, int, int, int],
               radius: int, blur: int, alpha: int, offset_y: int = 25) -> None:
    x, y, width, height = rect
    padding = blur * 3
    layer = Image.new("RGBA", (width+padding*2, height+padding*2), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (padding, padding, padding+width, padding+height),
        radius=radius, fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(layer, (x-padding, y-padding+offset_y), layer)


def draw_phone(canvas: Image.Image, screenshot: Image.Image) -> None:
    shell = (139, 530, 964, 2062)
    sx, sy, sw, sh = shell
    add_shadow(canvas, shell, 135, 40, 175, 42)
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((sx, sy, sx+sw, sy+sh), radius=134,
                           fill="#06080A", outline="#9BA3AA", width=7)
    draw.rounded_rectangle((sx+7, sy+7, sx+sw-7, sy+sh-7), radius=127,
                           outline="#353B40", width=8)
    draw.rounded_rectangle((sx+17, sy+18, sx+sw-17, sy+sh-18), radius=112,
                           outline="#1C2228", width=3)
    # Small hardware details keep the silhouette close to the reference set.
    draw.rounded_rectangle((sx-7, sy+302, sx+1, sy+414), radius=3, fill="#727980")
    draw.rounded_rectangle((sx-7, sy+470, sx+1, sy+620), radius=3, fill="#727980")
    draw.rounded_rectangle((sx+sw-1, sy+515, sx+sw+7, sy+691), radius=3,
                           fill="#727980")
    screen_x, screen_y, screen_w, screen_h = sx+18, sy+21, 928, 2013
    resized = screenshot.resize((screen_w, screen_h), Image.Resampling.LANCZOS)
    canvas.paste(resized, (screen_x, screen_y),
                 rounded_mask((screen_w, screen_h), 108))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((screen_x, screen_y, screen_x+screen_w,
                            screen_y+screen_h), radius=108,
                           outline="#11171B", width=3)


def draw_wheel_card(canvas: Image.Image, source: Image.Image) -> None:
    x, y, size = 35, 918, 596
    add_shadow(canvas, (x, y, size, size), 48, 28, 170, 22)
    # The wheel is cropped directly from the other supplied iOS capture.
    wheel = source.crop((210, 1525, 970, 2285))
    wheel = wheel.resize((size, size), Image.Resampling.LANCZOS)
    canvas.paste(wheel, (x, y), rounded_mask((size, size), 46))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x+size, y+size), radius=46,
                           outline="#DCEAF7", width=5)
    label = "Hue / Sat"
    font = ImageFont.truetype(str(TITLE_FONT), 35)
    label_w = int(draw.textlength(label, font=font)) + 48
    draw.rounded_rectangle((x+24, y+22, x+24+label_w, y+85), radius=31,
                           fill="#242D39")
    box = draw.textbbox((0, 0), label, font=font)
    draw.text((x+48, y+35-box[1]), label, font=font, fill=WHITE)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for source, target in ((SOURCE_WHEEL, ROOT / "source_hue_sat.png"),
                           (SOURCE_LUMA, ROOT / "source_chroma_luma.png")):
        if not target.exists():
            shutil.copy2(source, target)
    wheel = Image.open(ROOT / "source_hue_sat.png").convert("RGB")
    luma = Image.open(ROOT / "source_chroma_luma.png").convert("RGB")
    if wheel.size != (1179, 2556) or luma.size != (1179, 2556):
        raise ValueError("Unexpected iOS screenshot dimensions")
    for language, (first, second, subtitle) in COPY.items():
        canvas = background()
        draw_phone(canvas, luma)
        draw_wheel_card(canvas, wheel)
        draw = ImageDraw.Draw(canvas)
        centered(draw, first, 70, fit_font(first, TITLE_FONT, 110, 1120), WHITE)
        centered(draw, second, 195, fit_font(second, TITLE_FONT, 83, 1145), BLUE)
        centered(draw, subtitle, 325, fit_font(subtitle, BODY_FONT, 43, 1110), MUTED)
        output = ROOT / f"GradeLab_iOS_Color_Warper_{language}.png"
        canvas.save(output, optimize=True)
        print(f"{language}: {output.name}")


if __name__ == "__main__":
    main()
