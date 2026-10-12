"""Export the six existing iPhone cards in the six remaining store languages."""
from importlib.util import module_from_spec, spec_from_file_location
from io import BytesIO
from zipfile import ZipFile, ZIP_DEFLATED
import json

from PIL import Image, ImageDraw, ImageFont, ImageOps
import build as artwork

SIZE = (1206, 2622)
TARGET = artwork.PROJECT / "ios_store_localizations/existing_gallery_1206x2622"
SWEDISH = artwork.PROJECT / "store_localizations/sv-SE"
spec = spec_from_file_location("existing_screenshot_style", SWEDISH / "build.py")
style = module_from_spec(spec)
spec.loader.exec_module(style)

LANGUAGES = {"fr-FR": "French", "de-DE": "German", "it-IT": "Italian",
             "es-ES": "Spanish_Spain", "sv-SE": "Swedish", "fi-FI": "Finnish"}
CARDS = [("01_color_grading", "01_Color_Grading"),
         ("02_looks", "02_Cinematic_Looks"),
         ("04_color_warper", "03_Color_Warper"),
         ("03_curves", "04_Curves_and_Scopes"),
         ("05_fine_tune", "05_Fine_Tune"),
         ("06_effects", "06_Pro_Effects")]

# The Color Warper card already has localized source artwork for these four
# languages. The other five cards reuse the English artwork below the headline.
COPY = {
    "fr-FR": {
        "01_color_grading": ("Étalonnage pro", "pour photo et vidéo",
                             "Des outils professionnels. Un flux de travail fluide."),
        "02_looks": ("Des looks cinéma", "en toute simplicité",
                     "Appliquez des préréglages et créez votre propre style."),
        "03_curves": ("Courbes avancées", "et scopes",
                      "Affinez les couleurs avec des outils de mesure précis."),
        "05_fine_tune": ("Affinez", "chaque couleur",
                         "Ajustez précisément la teinte, la saturation et la luminance."),
        "06_effects": ("Finalisez votre look", "avec les effets Pro",
                       "Ajoutez un effet mat, de la netteté et une lueur cinéma."),
    },
    "de-DE": {
        "01_color_grading": ("Profi-Farbkorrektur", "für Fotos & Videos",
                             "Profi-Werkzeuge. Ein flüssiger Workflow."),
        "02_looks": ("Filmische Looks", "leicht gemacht",
                     "Wende Presets an und entwickle deinen eigenen Stil."),
        "03_curves": ("Erweiterte Kurven", "und Scopes",
                      "Stimme Farben mit präzisen Analysewerkzeugen ab."),
        "05_fine_tune": ("Jede Farbe", "fein abstimmen",
                         "Passe Farbton, Sättigung und Luminanz präzise an."),
        "06_effects": ("Vollende deinen Look", "mit Pro-Effekten",
                       "Matte Töne, Schärfe, Bloom und ein filmisches Finish."),
    },
    "it-IT": {
        "01_color_grading": ("Color grading Pro", "per foto e video",
                             "Strumenti professionali. Un flusso di lavoro fluido."),
        "02_looks": ("Look cinematografici", "in tutta semplicità",
                     "Applica preset e crea il tuo stile."),
        "03_curves": ("Curve avanzate", "e strumenti di analisi",
                      "Perfeziona i colori con strumenti di analisi precisi."),
        "05_fine_tune": ("Perfeziona", "ogni colore",
                         "Regola con precisione tonalità, saturazione e luminanza."),
        "06_effects": ("Completa il look", "con effetti Pro",
                       "Aggiungi toni opachi, nitidezza e un bagliore cinematografico."),
    },
    "es-ES": {
        "01_color_grading": ("Etalonaje Pro", "para fotos y vídeos",
                             "Herramientas profesionales. Un flujo de trabajo ágil."),
        "02_looks": ("Looks de cine", "sin complicaciones",
                     "Aplica ajustes predefinidos y crea tu propio estilo."),
        "03_curves": ("Curvas avanzadas", "y herramientas de análisis",
                      "Afina el color con herramientas de análisis precisas."),
        "05_fine_tune": ("Afina", "cada color",
                         "Ajusta con precisión el tono, la saturación y la luminancia."),
        "06_effects": ("Completa tu look", "con efectos Pro",
                       "Añade tonos mate, nitidez y un resplandor cinematográfico."),
    },
}


def to_medium(image):
    rgba = image.convert("RGBA")
    rgb = Image.new("RGB", rgba.size, "#0F1C2E")
    rgb.paste(rgba, (0, 0), rgba)
    resized = ImageOps.contain(rgb, SIZE, Image.Resampling.LANCZOS)
    assert resized.width == SIZE[0]
    top = (SIZE[1] - resized.height) // 2
    bottom = SIZE[1] - resized.height - top
    card = Image.new("RGB", SIZE)
    if top:
        card.paste(resized.crop((0, 0, SIZE[0], 1)).resize((SIZE[0], top)), (0, 0))
    card.paste(resized, (0, top))
    if bottom:
        card.paste(resized.crop((0, resized.height - 1, SIZE[0], resized.height))
                   .resize((SIZE[0], bottom)), (0, top + resized.height))
    return card, top, bottom


def prepare_templates():
    templates = {}
    for item in style.ARTWORK["ios"]:
        stem, clean_end = item[:2]
        if stem == "04_color_warper":
            continue
        source = SWEDISH / "sources/ios" / f"{stem}.png"
        with Image.open(source) as original:
            cleaned = style.erase_english_copy(original, clean_end)
            lower = (0, clean_end, original.width, original.height)
            assert cleaned.crop(lower).tobytes() == original.convert("RGB").crop(lower).tobytes()
        templates[stem] = (cleaned, item, source)
    return templates


def localized_card(locale, stem, templates):
    image, item, source = templates[stem]
    image = image.copy()
    (_, clean_end, top1, top2, top_sub, size1, size2, sub_size,
     max_width, _, _) = item
    first, second, subtitle = COPY[locale][stem]
    draw = ImageDraw.Draw(image)
    bounds = []
    for text, top, preferred, width, path, color, bottom_limit in [
        (first, top1, size1, max_width, style.BOLD, style.WHITE, top2 - 20),
        (second, top2, size2, max_width, style.BOLD, style.BLUE, top_sub - 20),
        (subtitle, top_sub, sub_size, image.width - 140, style.REGULAR, style.MUTED, clean_end - 13),
    ]:
        spans = [(text, color)]
        font = style.fitted_font(spans, preferred, width, path)
        box = draw.textbbox((0, 0), text, font=font)
        # Accents and descenders can require more vertical room than the
        # English headings even when the measured width already fits.
        while top + box[3] - box[1] > bottom_limit:
            font = style.fitted_font(spans, font.size - 1, width, path)
            box = draw.textbbox((0, 0), text, font=font)
        left = (image.width - (box[2] - box[0])) / 2
        bottom = top + box[3] - box[1]
        assert left >= 44 and bottom < clean_end - 12
        style.centered_spans(draw, image.width, spans, top, font)
        bounds.append({"text": text, "size": font.size,
                       "bounds": [left, top, image.width - left, bottom]})
    assert bounds[0]["bounds"][3] + 20 <= bounds[1]["bounds"][1]
    assert bounds[1]["bounds"][3] + 20 <= bounds[2]["bounds"][1]
    return image, source, "localized marketing copy over preserved English artwork", bounds


def package(path, files):
    with ZipFile(path, "w", ZIP_DEFLATED) as archive:
        for source, member in files:
            archive.write(source, member)
    with ZipFile(path) as archive:
        assert len(archive.namelist()) == len(files) and archive.testzip() is None


def contact_sheet(locale, language, outputs):
    width = 230
    height = round(SIZE[1] * width / SIZE[0])
    sheet = Image.new("RGB", (width * 7, height + 38), "#0C1522")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(str(artwork.REGULAR), 16)
    for i, output in enumerate(outputs):
        with Image.open(output) as card:
            sheet.paste(card.resize((width, height), Image.Resampling.LANCZOS), (i * width, 30))
        draw.text((i * width + 10, 7), f"{locale} · {i + 1:02}", font=font, fill=artwork.WHITE)
    with ZipFile(artwork.PROJECT / "ios_store_localizations/masking_tracking/GradeLab_iPhone_Masking_Tracking_1206x2622_7_languages.zip") as archive:
        name = f"{locale}/GradeLab_iPhone_Masking_Tracking_{language}_1206x2622.png"
        with Image.open(BytesIO(archive.read(name))) as card:
            sheet.paste(card.resize((width, height), Image.Resampling.LANCZOS), (6 * width, 30))
    draw.text((6 * width + 10, 7), f"{locale} · 07", font=font, fill=artwork.WHITE)
    sheet.save(artwork.ROOT / f"{locale}_complete_medium_gallery.jpg", quality=92)


def main():
    templates = prepare_templates()
    manifest, combined = [], []
    for locale, language in LANGUAGES.items():
        target = TARGET / locale
        target.mkdir(parents=True, exist_ok=True)
        outputs = []
        for stem, output_stem in CARDS:
            if locale in ("sv-SE", "fi-FI"):
                source = artwork.PROJECT / f"store_localizations/{locale}/ios/GradeLab_IOS_{language}_{stem}.png"
                with Image.open(source) as original:
                    image = original.convert("RGB")
                provenance, bounds = "existing localized card", []
            elif stem == "04_color_warper":
                source = artwork.PROJECT / f"ios_store_localizations/color_warper/GradeLab_iOS_Color_Warper_{language}.png"
                with Image.open(source) as original:
                    image = original.convert("RGB")
                provenance, bounds = "existing localized card", []
            else:
                image, source, provenance, bounds = localized_card(locale, stem, templates)
            card, top, bottom = to_medium(image)
            output = target / f"{output_stem}_{language}_1206x2622.png"
            card.save(output, compress_level=6)
            with Image.open(output) as saved:
                assert saved.mode == "RGB" and saved.size == SIZE
                saved.verify()
            outputs.append(output)
            combined.append((output, f"{locale}/{output.name}"))
            manifest.append({"locale": locale, "file": str(output.relative_to(artwork.PROJECT)),
                             "source": str(source.relative_to(artwork.PROJECT)),
                             "provenance": provenance, "pixels": SIZE, "mode": "RGB",
                             "background_extension": [top, bottom], "localized_copy": bounds})
        package(TARGET / f"GradeLab_iPhone_Existing_6_{language}_1206x2622.zip",
                [(output, output.name) for output in outputs])
        contact_sheet(locale, language, outputs)
        print(f"{locale}: six RGB PNGs and ZIP verified", flush=True)
    archive_path = TARGET / "GradeLab_iPhone_Existing_6_Remaining_Languages_1206x2622.zip"
    assert len(combined) == 36
    package(archive_path, combined)
    (artwork.ROOT / "manifest_existing_remaining_medium.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(archive_path, flush=True)


if __name__ == "__main__":
    main()
