"""Compose 14 localized App Store cards from the captured GradeLab interface."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parents[2]
SOURCES = ROOT / "sources"
FONTS = PROJECT / "dummy name/Resources/Fonts"
BOLD = FONTS / "Inter_28pt-Bold.ttf"
REGULAR = FONTS / "Inter_28pt-Regular.ttf"
WHITE, BLUE, MUTED = "#FCFCFF", "#70C5FF", "#CCD6E4"

COPY = {
    "en-US": ("English", "Mask with precision", "Track the motion",
              "Draw, refine and track your masks.", "Motion tracking"),
    "fr-FR": ("French", "Masquez avec précision", "Suivez le mouvement",
              "Masques à main levée et suivi de mouvement.", "Suivi de mouvement"),
    "de-DE": ("German", "Masken nach Maß", "Bewegungen verfolgen",
              "Freihand zeichnen, verfeinern und verfolgen.", "Bewegungsverfolgung"),
    "it-IT": ("Italian", "Maschere precise", "Segui il movimento",
              "Disegna, rifinisci e traccia le tue maschere.", "Tracciamento"),
    "es-ES": ("Spanish_Spain", "Máscaras precisas", "Sigue el movimiento",
              "Dibuja, ajusta y sigue tus máscaras.", "Seguimiento de movimiento"),
    "sv-SE": ("Swedish", "Maska med precision", "Följ rörelsen",
              "Rita, finjustera och spåra dina masker.", "Rörelsespårning"),
    "fi-FI": ("Finnish", "Maskaa tarkasti", "Seuraa liikettä",
              "Piirrä, hienosäädä ja seuraa maskeja.", "Liikkeenseuranta"),
}


def background(w, h):
    yy, xx = np.mgrid[0:h, 0:w]
    x, y = xx / w, yy / h
    base = np.empty((h, w, 3), dtype=np.float32)
    base[:] = (15, 28, 46)
    light = np.exp(-(((x + .1) / .9) ** 2 + ((y - .06) / .58) ** 2))
    right = np.exp(-(((x - 1.08) / .9) ** 2 + ((y - .73) / .65) ** 2))
    base += light[..., None] * np.array((28, 49, 80), dtype=np.float32)
    base += right[..., None] * np.array((8, 23, 43), dtype=np.float32)
    return Image.fromarray(np.uint8(np.clip(base, 0, 255)), "RGB")


def font_fit(text, path, preferred, max_width, minimum=28):
    draw = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    for size in range(preferred, minimum - 1, -1):
        font = ImageFont.truetype(str(path), size)
        if draw.textlength(text, font=font) <= max_width:
            return font
    raise ValueError(f"Text does not fit: {text}")


def center_text(image, text, top, font, color):
    draw = ImageDraw.Draw(image)
    box = draw.textbbox((0, 0), text, font=font)
    left = (image.width - (box[2] - box[0])) / 2 - box[0]
    draw.text((left, top - box[1]), text, font=font, fill=color)
    assert left + box[0] >= 40 and left + box[2] <= image.width - 40
    return [round(left + box[0]), top, round(left + box[2]), top + box[3] - box[1]]


def rounded_mask(w, h, radius):
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius, fill=255)
    return mask


def shadow(canvas, rect, radius, blur, alpha=170, offset=22):
    x, y, w, h = rect
    pad = blur * 3
    layer = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle((pad, pad, pad + w, pad + h), radius,
                                          fill=(0, 0, 0, alpha))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.paste(layer, (x - pad, y - pad + offset), layer)


def phone(canvas, source):
    x, y, w, h = 156, 540, 930, 2070
    shadow(canvas, (x, y, w, h), 130, 38, offset=35)
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x + w, y + h), 130, fill="#06080A", outline="#8B98A5", width=6)
    draw.rounded_rectangle((x + 8, y + 8, x + w - 8, y + h - 8), 122, outline="#303C47", width=7)
    # System chrome is part of the device artwork; the app capture stays intact.
    sw = w - 36
    sh = round(source.height * sw / source.width)
    screen = Image.new("RGB", (sw, h - 36), "#080A0C")
    screen.paste(source.resize((sw, sh), Image.Resampling.LANCZOS), (0, 76))
    sd = ImageDraw.Draw(screen)
    time = ImageFont.truetype(str(BOLD), 32)
    sd.text((56, 25), "9:41", font=time, fill=WHITE)
    # Small, quiet Wi-Fi and battery artwork.
    for i in range(3):
        sd.arc((sw - 156 + i * 7, 22 + i * 7, sw - 104 - i * 7, 70 - i * 7),
               216, 324, fill=WHITE, width=4)
    sd.rounded_rectangle((sw - 92, 30, sw - 38, 56), 6, outline=WHITE, width=3)
    sd.rounded_rectangle((sw - 86, 35, sw - 44, 51), 3, fill=WHITE)
    sd.rectangle((sw - 36, 38, sw - 32, 48), fill=WHITE)
    sd.rounded_rectangle((sw // 2 - 100, screen.height - 26, sw // 2 + 100, screen.height - 19),
                         4, fill="#E7EAF0")
    canvas.paste(screen, (x + 18, y + 18), rounded_mask(*screen.size, 110))
    draw = ImageDraw.Draw(canvas)
    for sy, length in [(y + 295, 105), (y + 446, 140)]:
        draw.rounded_rectangle((x - 6, sy, x, sy + length), 3, fill="#7A8793")
    draw.rounded_rectangle((x + w, y + 465, x + w + 6, y + 635), 3, fill="#7A8793")


def tablet(canvas, source):
    x, y, w = 112, 840, 1840
    sw = w - 68
    sh = round(source.height * sw / source.width)
    h = sh + 68
    shadow(canvas, (x, y, w, h), 62, 48, offset=40)
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x, y, x + w, y + h), 62, fill="#05070A", outline="#83919F", width=6)
    draw.rounded_rectangle((x + 9, y + 9, x + w - 9, y + h - 9), 53,
                           outline="#26323D", width=6)
    canvas.paste(source.resize((sw, sh), Image.Resampling.LANCZOS), (x + 34, y + 34),
                 rounded_mask(sw, sh, 26))
    draw = ImageDraw.Draw(canvas)
    draw.ellipse((x + w // 2 - 5, y + 13, x + w // 2 + 5, y + 23), fill="#18232D")


def tracking_card(canvas, source, title, ipad):
    # A magnified crop of the actual controls and the real completed result.
    crop = source.crop((45, 255, 1035, 760))
    x, y, w = (1080, 1920, 900) if ipad else (35, 1740, 735)
    pad, label_h = (30, 95) if ipad else (24, 75)
    image_w = w - pad * 2
    image_h = round(crop.height * image_w / crop.width)
    h = label_h + image_h + pad
    shadow(canvas, (x, y, w, h), 40, 30, 200, 20)
    card = Image.new("RGB", (w, h), "#080A0C")
    card.paste(crop.resize((image_w, image_h), Image.Resampling.LANCZOS), (pad, label_h))
    draw = ImageDraw.Draw(card)
    font = font_fit(title, BOLD, 46 if ipad else 37, w - pad * 2 - 58)
    box = draw.textbbox((0, 0), title, font=font)
    icon_y = label_h // 2
    # Bidirectional motion icon, separate from the interface itself.
    draw.line((pad + 1, icon_y, pad + 35, icon_y), fill=BLUE, width=4)
    draw.line((pad + 1, icon_y, pad + 11, icon_y - 10), fill=BLUE, width=4)
    draw.line((pad + 1, icon_y, pad + 11, icon_y + 10), fill=BLUE, width=4)
    draw.line((pad + 35, icon_y, pad + 25, icon_y - 10), fill=BLUE, width=4)
    draw.line((pad + 35, icon_y, pad + 25, icon_y + 10), fill=BLUE, width=4)
    draw.text((pad + 54, (label_h - (box[3] - box[1])) / 2 - box[1]),
              title, font=font, fill=BLUE)
    canvas.paste(card, (x, y), rounded_mask(w, h, 38))
    ImageDraw.Draw(canvas).rounded_rectangle((x, y, x + w, y + h), 38,
                                             outline="#D4E4F4", width=4)
    assert x + w <= canvas.width - 20 and y + h < canvas.height - 90


def main():
    phone_source = Image.open(SOURCES / "iphone.png").convert("RGB")
    ipad_source = Image.open(SOURCES / "ipad.png").convert("RGB")
    tracking_source = Image.open(SOURCES / "tracking.png").convert("RGB")
    outputs, manifest = [], []
    for device, size, source, drawer in [
        ("iPhone", (1242, 2688), phone_source, phone),
        ("iPad", (2064, 2752), ipad_source, tablet),
    ]:
        target = PROJECT / ("ios_store_localizations" if device == "iPhone" else "ipad_store_localizations") / "masking_tracking"
        target.mkdir(parents=True, exist_ok=True)
        device_outputs = []
        for locale, (language, first, second, subtitle, tracking) in COPY.items():
            image = background(*size)
            drawer(image, source)
            tracking_card(image, tracking_source, tracking, device == "iPad")
            if device == "iPhone":
                title_specs = [(first, 105, BOLD, 112, 1120, WHITE),
                               (second, 240, BOLD, 106, 1120, BLUE),
                               (subtitle, 375, REGULAR, 43, 1110, MUTED)]
            else:
                title_specs = [(first, 150, BOLD, 174, 1840, WHITE),
                               (second, 355, BOLD, 154, 1840, BLUE),
                               (subtitle, 570, REGULAR, 66, 1830, MUTED)]
            bounds = [center_text(image, text, top, font_fit(text, path, font_size, width), color)
                      for text, top, path, font_size, width, color in title_specs]
            assert bounds[0][3] + 24 <= bounds[1][1] and bounds[1][3] + 24 <= bounds[2][1]
            filename = f"GradeLab_{device}_Masking_Tracking_{language}.png"
            output = target / filename
            image.save(output, optimize=True)
            with Image.open(output) as saved:
                assert saved.mode == "RGB" and saved.size == size
                saved.verify()
            outputs.append((output, f"{device}/{locale}/{filename}"))
            device_outputs.append((output, f"{locale}/{filename}"))
            manifest.append({"device": device, "locale": locale, "file": str(output.relative_to(PROJECT)),
                             "pixels": size, "mode": "RGB", "headline_bounds": bounds,
                             "copy": [first, second, subtitle, tracking]})
            print(device, locale, filename)
        with ZipFile(target / f"GradeLab_{device}_Masking_Tracking_7_languages.zip", "w", ZIP_DEFLATED) as archive:
            for output, name in device_outputs:
                archive.write(output, name)
    archive_path = ROOT / "GradeLab_Masking_Tracking_7_languages.zip"
    with ZipFile(archive_path, "w", ZIP_DEFLATED) as archive:
        for output, name in outputs:
            archive.write(output, name)
    (ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    for device in ("iPhone", "iPad"):
        files = [path for path, arc in outputs if arc.startswith(device + "/")]
        thumb_w = 310 if device == "iPhone" else 360
        thumb_h = round(Image.open(files[0]).height * thumb_w / Image.open(files[0]).width)
        sheet = Image.new("RGB", (thumb_w * 4, (thumb_h + 38) * 2), "#0C1522")
        draw = ImageDraw.Draw(sheet)
        label_font = ImageFont.truetype(str(REGULAR), 18)
        for i, path in enumerate(files):
            x, y = i % 4 * thumb_w, i // 4 * (thumb_h + 38)
            with Image.open(path) as image:
                sheet.paste(image.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS), (x, y + 30))
            draw.text((x + 12, y + 6), list(COPY)[i], font=label_font, fill=WHITE)
        sheet.save(ROOT / f"{device.lower()}_contact_sheet.jpg", quality=90)
    preview = Image.new("RGB", (1160, 1120), "#0C1522")
    for device, x, width in [("iPhone", 0, 518), ("iPad", 550, 610)]:
        output = next(path for path, arc in outputs if arc.startswith(f"{device}/en-US/"))
        with Image.open(output) as image:
            height = round(image.height * width / image.width)
            preview.paste(image.resize((width, height), Image.Resampling.LANCZOS), (x, (1120 - height) // 2))
    preview.save(ROOT / "english_preview.jpg", quality=95)
    print(archive_path)


if __name__ == "__main__":
    main()
