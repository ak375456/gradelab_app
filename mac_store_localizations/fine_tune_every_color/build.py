from pathlib import Path
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
SOURCE = Path('/var/folders/zb/y42b932j141_v69qzz_xpsy00000gn/T/codex-clipboard-f418908d-61a8-446a-bd6a-fa66c8b95459.png')
FONT_DIR = Path('/Users/aftab/Desktop/dummy name/dummy name/Resources/Fonts')
TITLE_FONT = FONT_DIR / 'Inter_28pt-Bold.ttf'
BODY_FONT = FONT_DIR / 'Inter_28pt-Regular.ttf'

COPY = {
    'English': ('Fine-Tune', 'Every Color', 'Adjust hue, saturation and luminance with precision.'),
    'French': ('Peaufinez', 'chaque couleur', 'Ajustez la teinte, la saturation et la luminance avec précision.'),
    'German': ('Jede Farbe', 'fein abstimmen', 'Farbton, Sättigung und Luminanz präzise anpassen.'),
    'Italian': ('Perfeziona', 'ogni colore', 'Regola tonalità, saturazione e luminanza con precisione.'),
    'Spanish_Spain': ('Perfecciona', 'cada color', 'Ajusta el tono, la saturación y la luminancia con precisión.'),
}

W, H = 2880, 1800
APP_X, APP_Y, APP_W, APP_H = 345, 430, 2190, 1369


def background() -> Image.Image:
    yy, xx = np.mgrid[0:H, 0:W]
    base = np.empty((H, W, 3), dtype=np.float32)
    base[:] = (10, 25, 47)
    left = np.exp(-(((xx + 140) / 1120)**2 + ((yy - 170) / 930)**2))
    right = np.exp(-(((xx - 3000) / 1200)**2 + ((yy - 120) / 1000)**2))
    lower = np.exp(-(((xx - 1450) / 2400)**2 + ((yy - 1800) / 1050)**2))
    base += left[..., None] * np.array((14, 52, 100), dtype=np.float32)
    base += right[..., None] * np.array((10, 42, 87), dtype=np.float32)
    base += lower[..., None] * np.array((5, 19, 39), dtype=np.float32)
    return Image.fromarray(np.uint8(np.clip(base, 0, 255)), 'RGB')


def text_font(text: str, path: Path, target: int, max_width: int) -> ImageFont.FreeTypeFont:
    probe = ImageDraw.Draw(Image.new('RGB', (1, 1)))
    for size in range(target, 50, -1):
        font = ImageFont.truetype(str(path), size)
        if probe.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(text)


def centered(draw: ImageDraw.ImageDraw, text: str, y: int, font: ImageFont.FreeTypeFont,
             fill: str) -> None:
    bbox = draw.textbbox((0, 0), text, font=font)
    x = (W - (bbox[2] - bbox[0])) / 2 - bbox[0]
    draw.text((x, y - bbox[1]), text, font=font, fill=fill)


def label(canvas: Image.Image, text: str, x: int, y: int) -> None:
    font = ImageFont.truetype(str(BODY_FONT), 37)
    overlay = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    bbox = draw.textbbox((0, 0), text, font=font)
    width = bbox[2] - bbox[0] + 48
    draw.rounded_rectangle((x, y, x + width, y + 62), radius=30,
                           fill=(19, 31, 45, 221))
    draw.text((x + 24, y + 11 - bbox[1]), text, font=font, fill='white')
    canvas.paste(overlay, (0, 0), overlay)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    source_copy = ROOT / 'original_mac_screenshot.png'
    if not source_copy.exists():
        shutil.copy2(SOURCE, source_copy)
    screenshot = Image.open(source_copy).convert('RGB').resize((APP_W, APP_H), Image.Resampling.LANCZOS)
    mask = Image.new('L', (APP_W, APP_H), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, APP_W-1, APP_H-1), radius=26, fill=255)
    for language, (first, second, subtitle) in COPY.items():
        canvas = background()
        shadow = Image.new('RGBA', (APP_W+80, APP_H+80), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((36, 36, APP_W+43, APP_H+43),
                                                 radius=32, fill=(0, 0, 0, 135))
        shadow = shadow.filter(ImageFilter.GaussianBlur(30))
        canvas.paste(shadow, (APP_X-40, APP_Y-34), shadow)
        canvas.paste(screenshot, (APP_X, APP_Y), mask)
        draw = ImageDraw.Draw(canvas)
        draw.rounded_rectangle((APP_X-1, APP_Y-1, APP_X+APP_W,
                                APP_Y+APP_H), radius=26,
                               outline='#5A7896', width=3)
        centered(draw, first, 55, text_font(first, TITLE_FONT, 124, 2450), '#FFFFFF')
        centered(draw, second, 163, text_font(second, TITLE_FONT, 124, 2450), '#59C5FF')
        centered(draw, subtitle, 310, text_font(subtitle, BODY_FONT, 51, 2400), '#D0D9E7')
        label(canvas, 'Before', 635, 492)
        label(canvas, 'After', 1490, 492)
        canvas.save(ROOT / f'GradeLab_Mac_Fine_Tune_{language}.png', optimize=True)
        print(language)


if __name__ == '__main__':
    main()
