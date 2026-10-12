"""Preserve the six existing English cards in the Dynamic Island medium slot."""
from zipfile import ZipFile, ZIP_DEFLATED
from io import BytesIO
import json

from PIL import Image, ImageDraw, ImageFont, ImageOps
import build as artwork


def main():
    size = (1206, 2622)
    source_dir = artwork.PROJECT / "store_localizations/sv-SE/sources/ios"
    target = artwork.PROJECT / "ios_store_localizations/existing_gallery_1206x2622/en-US"
    target.mkdir(parents=True, exist_ok=True)
    # Match the order visible in the supplied App Store Connect screenshot.
    cards = [("01_color_grading", "01_Color_Grading"),
             ("02_looks", "02_Cinematic_Looks"),
             ("04_color_warper", "03_Color_Warper"),
             ("03_curves", "04_Curves_and_Scopes"),
             ("05_fine_tune", "05_Fine_Tune"),
             ("06_effects", "06_Pro_Effects")]
    outputs, manifest = [], []
    for source_stem, output_stem in cards:
        source = source_dir / f"{source_stem}.png"
        with Image.open(source) as original:
            rgba = original.convert("RGBA")
            rgb = Image.new("RGB", rgba.size, "#0F1C2E")
            rgb.paste(rgba, (0, 0), rgba)
            resized = ImageOps.contain(rgb, size, Image.Resampling.LANCZOS)
        assert resized.width == size[0]
        top = (size[1] - resized.height) // 2
        bottom = size[1] - resized.height - top
        card = Image.new("RGB", size)
        # Extend only the quiet background edge rows. No content is cropped or
        # stretched; the complete source card keeps its aspect ratio.
        if top:
            card.paste(resized.crop((0, 0, size[0], 1)).resize((size[0], top)), (0, 0))
        card.paste(resized, (0, top))
        if bottom:
            card.paste(resized.crop((0, resized.height - 1, size[0], resized.height))
                       .resize((size[0], bottom)), (0, top + resized.height))
        output = target / f"{output_stem}_English_1206x2622.png"
        card.save(output, optimize=True)
        with Image.open(output) as saved:
            assert saved.size == size and saved.mode == "RGB"
            saved.verify()
        outputs.append(output)
        manifest.append({"source": str(source.relative_to(artwork.PROJECT)),
                         "file": str(output.relative_to(artwork.PROJECT)),
                         "pixels": size, "mode": "RGB", "locale": "en-US",
                         "resized_content": resized.size, "background_extension": [top, bottom]})
        print(output.name)

    archive_path = target.parent / "GradeLab_iPhone_Existing_6_English_1206x2622.zip"
    with ZipFile(archive_path, "w", ZIP_DEFLATED) as archive:
        for output in outputs:
            archive.write(output, output.name)
    with ZipFile(archive_path) as archive:
        assert len(archive.namelist()) == 6 and archive.testzip() is None
    (artwork.ROOT / "manifest_existing_english_medium.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    thumb_w = 230
    thumb_h = round(size[1] * thumb_w / size[0])
    sheet = Image.new("RGB", (thumb_w * 7, thumb_h + 38), "#0C1522")
    draw = ImageDraw.Draw(sheet)
    label_font = ImageFont.truetype(str(artwork.REGULAR), 16)
    mask_archive = artwork.PROJECT / ("ios_store_localizations/masking_tracking/"
                   "GradeLab_iPhone_Masking_Tracking_1206x2622_7_languages.zip")
    with ZipFile(mask_archive) as archive:
        with Image.open(BytesIO(archive.read(
                "en-US/GradeLab_iPhone_Masking_Tracking_English_1206x2622.png"))) as card:
            mask_card = card.convert("RGB")
    # The seven-image contact sheet includes the mask already uploaded by the
    # user; the ZIP deliberately contains only the six missing screenshots.
    for i, output in enumerate(outputs + [None]):
        if output is None:
            card = mask_card
        else:
            with Image.open(output) as saved:
                card = saved.convert("RGB")
        sheet.paste(card.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS), (i * thumb_w, 30))
        draw.text((i * thumb_w + 10, 7), f"{i + 1:02}", font=label_font, fill=artwork.WHITE)
    sheet.save(artwork.ROOT / "english_complete_medium_gallery.jpg", quality=92)
    print(archive_path)


if __name__ == "__main__":
    main()
