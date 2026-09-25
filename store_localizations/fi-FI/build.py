"""Render Finnish marketing copy over the unchanged English screenshot artwork."""

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
SWEDISH = ROOT.parent / "sv-SE"
spec = spec_from_file_location("swedish_screenshots", SWEDISH / "build.py")
base = module_from_spec(spec)
spec.loader.exec_module(base)

COPY = {
    "ios": [
        ([[('Ammattitason värimäärittely', base.WHITE)], [('kuville ja videoille', base.BLUE)]],
         'Ammattityökalut. Sujuva työnkulku.'),
        ([[('Elokuvamaiset tyylit', base.WHITE)], [('helposti', base.BLUE)]],
         'Käytä esiasetuksia ja luo oma tyylisi.'),
        ([[('Tarkat käyrät', base.WHITE)], [('ja mittarit', base.BLUE)]],
         'Hienosäädä värit tarkkojen mittareiden avulla.'),
        ([[('Muokkaa jokaista väriä', base.WHITE)], [('Sävy/kylläisyys + kroma/luma', base.BLUE)]],
         'Kaksi tarkkaa tilaa yhdessä Color Warperissa.'),
        ([[('Hienosäädä', base.WHITE)], [('jokaista väriä', base.BLUE)]],
         'Säädä sävyä, kylläisyyttä ja luminanssia tarkasti.'),
        ([[('Viimeistele tyyli', base.WHITE)], [('pro-tehosteilla', base.BLUE)]],
         'Lisää häivytystä, terävyyttä ja elokuvamaista hohdetta.'),
    ],
    "ipad": [
        ([[('Ammattitason värimäärittely', base.WHITE)], [('kuville ja videoille', base.BLUE)]],
         'Ammattityökalut. Sujuva työnkulku.'),
        ([[('Elokuvamaiset tyylit', base.WHITE)], [('helposti', base.BLUE)]],
         'Käytä esiasetuksia ja luo oma tyylisi.'),
        ([[('Tarkat käyrät', base.WHITE)], [('ja mittarit', base.BLUE)]],
         'Hienosäädä värit tarkkojen mittareiden avulla.'),
        ([[('Muokkaa jokaista väriä', base.WHITE)], [('Sävy/kylläisyys + kroma/luma', base.BLUE)]],
         'Kaksi tarkkaa tilaa yhdessä Color Warperissa.'),
        ([[('Hienosäädä', base.WHITE)], [('jokaista väriä', base.BLUE)]],
         'Säädä sävyä, kylläisyyttä ja luminanssia tarkasti.'),
        ([[('Viimeistele tyyli', base.WHITE)], [('pro-tehosteilla', base.BLUE)]],
         'Lisää häivytystä, terävyyttä ja elokuvamaista hohdetta.'),
    ],
    "mac": [
        ([[('Ammattitason värimäärittely kuville ja videoille', base.WHITE)]],
         'Ammattityökalut. Sujuva työnkulku.'),
        ([[('Elokuvamaiset tyylit', base.WHITE)], [('helposti', base.BLUE)]],
         'Käytä esiasetuksia ja luo oma tyylisi.'),
        ([[('Hienosäädä', base.WHITE)], [('jokaista väriä', base.BLUE)]],
         'Säädä sävyä, kylläisyyttä ja luminanssia tarkasti.'),
        ([[('Edistyneet mittarit', base.WHITE)], [('helposti käyttöön', base.BLUE)]],
         'Analysoi värit selkeillä ja havainnollisilla mittareilla.'),
        ([[('Color Warper', base.WHITE)], [('Muokkaa jokaista väriä', base.BLUE)]],
         'Muokkaa värejä sävy/kylläisyys- ja kroma/luma-tiloissa.'),
    ],
}


def build_one(device, item, copy):
    stem, clean_end, top1, top2, top_sub, size1, size2, sub_size, max_width, _, _ = item
    title_lines, subtitle = copy
    with Image.open(SWEDISH / "sources" / device / f"{stem}.png") as original:
        image = base.erase_english_copy(original, clean_end)
    draw = ImageDraw.Draw(image)
    base.centered_spans(draw, image.width, title_lines[0], top1,
                        base.fitted_font(title_lines[0], size1, max_width))
    if len(title_lines) == 2:
        base.centered_spans(draw, image.width, title_lines[1], top2,
                            base.fitted_font(title_lines[1], size2, max_width))
    base.centered_spans(draw, image.width, [(subtitle, base.MUTED)], top_sub,
                        base.fitted_font([(subtitle, base.MUTED)], sub_size,
                                         image.width - 140, base.REGULAR))
    destination = ROOT / device / f"GradeLab_{device.upper()}_Finnish_{stem}.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, optimize=True)
    return destination


def main():
    all_outputs = []
    for device, items in base.ARTWORK.items():
        assert len(items) == len(COPY[device])
        outputs = [build_one(device, item, copy)
                   for item, copy in zip(items, COPY[device])]
        all_outputs.extend(outputs)
        with ZipFile(ROOT / f"GradeLab_Finnish_{device.upper()}.zip", "w", ZIP_DEFLATED, compresslevel=6) as bundle:
            for output in outputs:
                bundle.write(output, output.name)
    with ZipFile(ROOT / "GradeLab_Finnish_All_Devices.zip", "w", ZIP_DEFLATED, compresslevel=6) as bundle:
        for output in all_outputs:
            bundle.write(output, f"{output.parent.name}/{output.name}")
    print(f"Rendered {len(all_outputs)} Finnish screenshots")


if __name__ == "__main__":
    main()
