"""Build five 2880 × 1800 Mac App Store Color Warper screenshots."""

from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[1]
SOURCE_HUE = Path('/var/folders/zb/y42b932j141_v69qzz_xpsy00000gn/T/codex-clipboard-8b8c055f-aa0d-4c68-913a-0957e824b0df.png')
SOURCE_CHROMA = Path('/var/folders/zb/y42b932j141_v69qzz_xpsy00000gn/T/codex-clipboard-aad91094-8602-41cb-a186-ef0c475822d0.png')
PHONE_HUE = PROJECT / 'ios_store_localizations' / 'color_warper' / 'source_hue_sat.png'
MOUNTAIN_PHOTO = ROOT / 'source_alpine_lake.png'
FONT_DIR = PROJECT / 'dummy name' / 'Resources' / 'Fonts'
TITLE_FONT = FONT_DIR / 'Inter_28pt-Bold.ttf'
BODY_FONT = FONT_DIR / 'Inter_28pt-Regular.ttf'

W, H = 2880, 1800
APP_X, APP_Y, APP_W, APP_H = 345, 430, 2190, 1369

COPY = {
    'English': ('Color Warper', 'Shape Every Color',
                'Sculpt color in Hue/Sat and Chroma/Luma modes.'),
    'French': ('Color Warper', 'Modelez chaque couleur',
               'Sculptez les couleurs en modes Teinte/Sat et Chroma/Luma.'),
    'German': ('Color Warper', 'Jede Farbe formen',
               'Farben mit Farbton/Sättigung und Chroma/Luma gezielt formen.'),
    'Italian': ('Color Warper', 'Modella ogni colore',
                'Modella i colori con Tonalità/Sat e Croma/Luma.'),
    'Spanish_Spain': ('Color Warper', 'Moldea cada color',
                      'Moldea los colores con Tono/Sat y Croma/Luma.'),
}


def background() -> Image.Image:
    # Matches the existing Fine-Tune Every Color Mac set.
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


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new('L', size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0]-1, size[1]-1),
                                           radius=radius, fill=255)
    return mask


def text_font(text: str, path: Path, target: int,
              max_width: int) -> ImageFont.FreeTypeFont:
    probe = ImageDraw.Draw(Image.new('RGB', (1, 1)))
    for size in range(target, 35, -1):
        font = ImageFont.truetype(str(path), size)
        if probe.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(text)


def centered(draw: ImageDraw.ImageDraw, text: str, top: int,
             font: ImageFont.FreeTypeFont, fill: str) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    x = (W-(box[2]-box[0]))/2-box[0]
    draw.text((x, top-box[1]), text, font=font, fill=fill)


def shadow(canvas: Image.Image, rect: tuple[int, int, int, int],
           radius: int, blur: int, alpha: int, offset_y: int) -> None:
    x, y, width, height = rect
    pad = blur*3
    layer = Image.new('RGBA', (width+pad*2, height+pad*2), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        (pad, pad, pad+width, pad+height), radius=radius,
        fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(layer, (x-pad, y-pad+offset_y), layer)


def draw_chroma_paths(app: Image.Image) -> None:
    """Show a real-looking edited Chroma/Luma mesh in the Mac inspector."""
    x, y, width, height, scale = 2658, 310, 642, 284, 3
    overlay = Image.new('RGBA', (width*scale, height*scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    def point(p: tuple[float, float]) -> tuple[int, int]:
        return (round(p[0]*width*scale), round(p[1]*height*scale))

    ghosts = [
        [(0.02, 0.17), (0.53, 0.55), (0.99, 0.82)],
        [(0.04, 0.85), (0.48, 0.57), (0.95, 0.10)],
        [(0.18, 0.77), (0.63, 0.39), (0.99, 0.17)],
    ]
    for path in ghosts:
        draw.line([point(p) for p in path], fill=(180, 190, 198, 85),
                  width=3*scale, joint='curve')

    paths = [
        [(0.02, 0.13), (0.98, 0.82)],
        [(0.05, 0.91), (0.99, 0.04)],
        [(0.10, 0.66), (0.72, 0.31), (0.97, 0.12)],
        [(0.52, 0.98), (0.56, 0.03)],
        [(0.31, 0.84), (0.76, 0.29)],
        [(0.65, 0.91), (0.81, 0.35)],
    ]
    for path in paths:
        pixels = [point(p) for p in path]
        draw.line(pixels, fill=(10, 13, 17, 235), width=7*scale, joint='curve')
        draw.line(pixels, fill=(242, 246, 250, 235), width=3*scale, joint='curve')
        for px, py in pixels:
            radius = 8*scale
            draw.ellipse((px-radius, py-radius, px+radius, py+radius),
                         fill=(26, 31, 37, 255), outline=(246, 249, 252, 255),
                         width=3*scale)
    px, py = point((0.68, 0.23))
    radius = 13*scale
    draw.ellipse((px-radius, py-radius, px+radius, py+radius),
                 fill=(83, 177, 236, 255), outline=(253, 254, 255, 255),
                 width=4*scale)
    overlay = overlay.resize((width, height), Image.Resampling.LANCZOS)
    app.paste(overlay, (x, y), overlay)


def prepare_app(chroma: Image.Image, mountain: Image.Image) -> Image.Image:
    """Replace the source preview, thumbnail, and timeline with a new mountain scene."""
    app = chroma.copy()
    app.paste(ImageOps.fit(mountain, (1942, 1023), Image.Resampling.LANCZOS),
              (568, 67))

    # Keep the media thumbnail and the timeline in sync with the preview.
    draw = ImageDraw.Draw(app)
    draw.rectangle((121, 18, 455, 53), fill='#0A0A0B')
    draw.text((123, 23), 'Alpine Lake',
              font=ImageFont.truetype(str(TITLE_FONT), 26), fill='#F8F9FB')
    draw.rectangle((108, 140, 410, 169), fill='#141518')
    draw.text((110, 143), 'Alpine Lake.mov',
              font=ImageFont.truetype(str(TITLE_FONT), 25), fill='#F8F9FB')
    thumbnail = ImageOps.fit(mountain, (82, 45), Image.Resampling.LANCZOS)
    app.paste(thumbnail, (19, 145), rounded_mask((82, 45), 8))
    strip_x, strip_y, strip_w, strip_h = 755, 1795, 1806, 91
    for index, x in enumerate(range(strip_x, strip_x+strip_w, 258)):
        part_w = min(258, strip_x+strip_w-x)
        frame = ImageOps.fit(mountain, (part_w, strip_h),
                             Image.Resampling.LANCZOS,
                             centering=(0.43 + index*0.02, 0.5))
        app.paste(frame, (x, strip_y))
    dim = Image.new('RGBA', (strip_w, strip_h), (8, 17, 27, 82))
    app.paste(dim, (strip_x, strip_y), dim)
    draw = ImageDraw.Draw(app)
    draw.line((752, 1789, 2567, 1789), fill='#55D4C9', width=3)
    draw.line((752, 1891, 2567, 1891), fill='#55D4C9', width=3)
    draw.rounded_rectangle((763, 1803, 1064, 1839), radius=18,
                           fill='#34383D')
    draw.text((782, 1806), 'Alpine Lake.mov',
              font=ImageFont.truetype(str(TITLE_FONT), 25), fill='#FFFFFF')
    draw.line((1541, 1790, 1541, 1900), fill='#F7FAFD', width=3)
    draw_chroma_paths(app)
    return app


def draw_app(canvas: Image.Image, chroma: Image.Image) -> None:
    shadow(canvas, (APP_X, APP_Y, APP_W, APP_H), 28, 30, 135, 26)
    screen = chroma.resize((APP_W, APP_H), Image.Resampling.LANCZOS)
    canvas.paste(screen, (APP_X, APP_Y), rounded_mask((APP_W, APP_H), 26))
    ImageDraw.Draw(canvas).rounded_rectangle(
        (APP_X-1, APP_Y-1, APP_X+APP_W, APP_Y+APP_H),
        radius=26, outline='#5A7896', width=3)


def draw_hue_inset(canvas: Image.Image, hue: Image.Image) -> None:
    # The floating feature close-up mirrors the reference Before/After card.
    x, y, width, height = 232, 620, 732, 565
    shadow(canvas, (x, y, width, height), 32, 23, 140, 16)
    card = Image.new('RGB', (width, height), '#08090B')
    # The supplied Hue/Sat capture already contains edited paths and handles.
    wheel = hue.crop((210, 1525, 970, 2285))
    wheel = wheel.resize((483, 483), Image.Resampling.LANCZOS)
    card.paste(wheel, ((width-483)//2, 51))
    canvas.paste(card, (x, y), rounded_mask((width, height), 32))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x+width, y+height), radius=32,
                           outline='#DFEDF9', width=4)
    label = 'Hue / Sat'
    font = ImageFont.truetype(str(TITLE_FONT), 38)
    label_width = int(draw.textlength(label, font=font))+54
    draw.rounded_rectangle((x+27, y+24, x+27+label_width, y+90),
                           radius=33, fill='#253241')
    box = draw.textbbox((0, 0), label, font=font)
    draw.text((x+54, y+37-box[1]), label, font=font, fill='white')


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for source, target in ((SOURCE_HUE, ROOT/'source_hue_sat.png'),
                           (SOURCE_CHROMA, ROOT/'source_chroma_luma.png')):
        if not target.exists():
            shutil.copy2(source, target)
    hue = Image.open(ROOT/'source_hue_sat.png').convert('RGB')
    chroma = Image.open(ROOT/'source_chroma_luma.png').convert('RGB')
    phone_hue = Image.open(PHONE_HUE).convert('RGB')
    mountain = Image.open(MOUNTAIN_PHOTO).convert('RGB')
    if hue.size != (3360, 2100) or chroma.size != (3360, 2100):
        raise ValueError('Unexpected Mac capture dimensions')
    if phone_hue.size != (1179, 2556):
        raise ValueError('Unexpected iPhone capture dimensions')
    chroma = prepare_app(chroma, mountain)
    base = background()
    draw_app(base, chroma)
    draw_hue_inset(base, phone_hue)
    outputs = []
    for language, (first, second, subtitle) in COPY.items():
        image = base.copy()
        draw = ImageDraw.Draw(image)
        centered(draw, first, 55, text_font(first, TITLE_FONT, 124, 2450), '#FFFFFF')
        centered(draw, second, 163, text_font(second, TITLE_FONT, 124, 2450), '#59C5FF')
        centered(draw, subtitle, 310, text_font(subtitle, BODY_FONT, 51, 2400), '#D0D9E7')
        output = ROOT/f'GradeLab_Mac_Color_Warper_{language}.png'
        image.save(output, optimize=True)
        outputs.append(output)
        print(language, output.name)
    archive = ROOT/'GradeLab_Mac_Color_Warper_5_languages.zip'
    with ZipFile(archive, 'w', ZIP_DEFLATED, compresslevel=6) as bundle:
        for output in outputs:
            bundle.write(output, output.name)
    print(archive.name)


if __name__ == '__main__':
    main()
