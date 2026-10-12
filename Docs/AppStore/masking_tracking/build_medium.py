"""Render the seven cards for App Store Connect's Dynamic Island medium slot."""
from zipfile import ZipFile, ZIP_DEFLATED
import json

from PIL import Image, ImageDraw, ImageFont
import build as artwork


def main():
    size = (1206, 2622)
    # Keep the original artwork coordinates and allow the slightly taller canvas.
    # Only the background gains space; the phone, callout and text remain intact.
    design_size = (1242, round(size[1] * 1242 / size[0]))
    target = artwork.PROJECT / "ios_store_localizations/masking_tracking/iphone_dynamic_island_medium"
    target.mkdir(parents=True, exist_ok=True)
    phone_source = Image.open(artwork.SOURCES / "iphone.png").convert("RGB")
    tracking_source = Image.open(artwork.SOURCES / "tracking.png").convert("RGB")
    outputs, manifest = [], []

    for locale, (language, first, second, subtitle, tracking) in artwork.COPY.items():
        card = artwork.background(*design_size)
        artwork.phone(card, phone_source)
        artwork.tracking_card(card, tracking_source, tracking, False)
        title_specs = [(first, 105, artwork.BOLD, 112, 1120, artwork.WHITE),
                       (second, 240, artwork.BOLD, 106, 1120, artwork.BLUE),
                       (subtitle, 375, artwork.REGULAR, 43, 1110, artwork.MUTED)]
        bounds = [artwork.center_text(card, text, top,
                  artwork.font_fit(text, path, preferred, width), color)
                  for text, top, path, preferred, width, color in title_specs]
        assert bounds[0][3] + 24 <= bounds[1][1]
        assert bounds[1][3] + 24 <= bounds[2][1]
        card = card.resize(size, Image.Resampling.LANCZOS)
        filename = f"GradeLab_iPhone_Masking_Tracking_{language}_1206x2622.png"
        output = target / filename
        card.save(output, optimize=True)
        with Image.open(output) as saved:
            assert saved.mode == "RGB" and saved.size == size
            saved.verify()
        outputs.append((locale, output))
        manifest.append({"locale": locale, "file": str(output.relative_to(artwork.PROJECT)),
                         "pixels": size, "mode": "RGB",
                         "app_store_slot": "iPhone with Dynamic Island (medium display)",
                         "copy": [first, second, subtitle, tracking]})
        print(locale, filename)

    archive_path = target.parent / "GradeLab_iPhone_Masking_Tracking_1206x2622_7_languages.zip"
    with ZipFile(archive_path, "w", ZIP_DEFLATED) as archive:
        for locale, output in outputs:
            archive.write(output, f"{locale}/{output.name}")
    with ZipFile(archive_path) as archive:
        assert len(archive.namelist()) == 7 and archive.testzip() is None
    (artwork.ROOT / "manifest_iphone_medium.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    thumb_w = 310
    thumb_h = round(size[1] * thumb_w / size[0])
    sheet = Image.new("RGB", (thumb_w * 4, (thumb_h + 38) * 2), "#0C1522")
    draw = ImageDraw.Draw(sheet)
    label_font = ImageFont.truetype(str(artwork.REGULAR), 18)
    for i, (locale, output) in enumerate(outputs):
        x, y = i % 4 * thumb_w, i // 4 * (thumb_h + 38)
        with Image.open(output) as card:
            sheet.paste(card.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS), (x, y + 30))
        draw.text((x + 12, y + 6), locale, font=label_font, fill=artwork.WHITE)
    sheet.save(artwork.ROOT / "iphone_medium_contact_sheet.jpg", quality=92)
    print(archive_path)


if __name__ == "__main__":
    main()
