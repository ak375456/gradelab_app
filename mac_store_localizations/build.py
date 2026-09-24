from pathlib import Path
import shutil

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent
SOURCE = Path('/Users/aftab/Downloads/GradeLab_Mac_English.png')
GERMAN = Path('/Users/aftab/Downloads/GradeLab_Mac_German.png')
FONT_DIR = Path('/Users/aftab/Desktop/dummy name/dummy name/Resources/Fonts')
TITLE_FONT = FONT_DIR / 'Inter_28pt-Bold.ttf'
BODY_FONT = FONT_DIR / 'Inter_28pt-Regular.ttf'

COPY = {
    'French': (
        'Étalonnage couleur pro pour photo et vidéo',
        'Des outils professionnels. Un flux de travail fluide.',
    ),
    'Italian': (
        'Color grading professionale per foto e video',
        'Strumenti professionali. Un flusso di lavoro intuitivo.',
    ),
    'Spanish_Spain': (
        'Etalonaje de color profesional para foto y vídeo',
        'Herramientas profesionales. Un flujo de trabajo sencillo.',
    ),
}


def clean_header(source: Image.Image) -> Image.Image:
    # The reference's background is a smooth blue gradient. Fit it using only
    # dark background pixels, excluding the bright text, then retain the exact
    # source pixels below the copy area.
    pixels = np.asarray(source.convert('RGB'), dtype=np.uint8)
    sample = pixels[:390:4, ::4].astype(np.float64)
    yy, xx = np.mgrid[0:390:4, 0:2880:4]
    x = xx / 1440 - 1
    y = yy / 195 - 1
    mask = sample.max(axis=2) < 105
    cols = [np.ones_like(x), x, y, x*x, x*y, y*y,
            x*x*x, x*x*y, x*y*y, y*y*y,
            x**4, x**3*y, x*x*y*y, x*y**3, y**4]
    design = np.stack(cols, axis=-1)
    coeff = np.linalg.lstsq(design[mask], sample[mask], rcond=None)[0]
    full_y, full_x = np.mgrid[0:390, 0:2880]
    x = full_x / 1440 - 1
    y = full_y / 195 - 1
    full_cols = [np.ones_like(x), x, y, x*x, x*y, y*y,
                 x*x*x, x*x*y, x*y*y, y*y*y,
                 x**4, x**3*y, x*x*y*y, x*y**3, y**4]
    gradient = np.stack(full_cols, axis=-1) @ coeff
    gradient = np.uint8(np.clip(gradient, 0, 255))
    result = pixels.copy()
    # Fade into the original background before the screenshot begins.
    alpha = np.ones((390, 1, 1), dtype=np.float64)
    alpha[340:, 0, 0] = np.linspace(1, 0, 50)
    result[:390] = np.uint8(np.round(gradient * alpha + pixels[:390] * (1-alpha)))
    return Image.fromarray(result)


def fit_font(text: str, path: Path, max_size: int, max_width: int) -> ImageFont.FreeTypeFont:
    for size in range(max_size, 50, -1):
        font = ImageFont.truetype(str(path), size)
        if ImageDraw.Draw(Image.new('RGB', (1, 1))).textlength(text, font=font) <= max_width:
            return font
    raise ValueError(f'Text is too wide: {text}')


def centered(draw: ImageDraw.ImageDraw, text: str, baseline_top: int,
             font: ImageFont.FreeTypeFont, fill: str) -> None:
    bbox = draw.textbbox((0, 0), text, font=font)
    draw.text(((2880 - (bbox[2] - bbox[0])) / 2 - bbox[0], baseline_top - bbox[1]),
              text, font=font, fill=fill)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE, ROOT / 'GradeLab_Mac_English.png')
    shutil.copy2(GERMAN, ROOT / 'GradeLab_Mac_German.png')
    source = Image.open(SOURCE).convert('RGB')
    blank = clean_header(source)
    for language, (title, subtitle) in COPY.items():
        result = blank.copy()
        draw = ImageDraw.Draw(result)
        title_font = fit_font(title, TITLE_FONT, 112, 2410)
        subtitle_font = fit_font(subtitle, BODY_FONT, 54, 2340)
        centered(draw, title, 115, title_font, '#FCFCFF')
        centered(draw, subtitle, 250, subtitle_font, '#C4CBDA')
        result.save(ROOT / f'GradeLab_Mac_{language}.png', optimize=True)
        print(language, title_font.size, subtitle_font.size)


if __name__ == '__main__':
    main()
