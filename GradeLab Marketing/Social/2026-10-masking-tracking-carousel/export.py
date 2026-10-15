"""Copy selected masters and export the two requested carousel sizes."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse
import json
import shutil
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    plan = json.loads((ROOT / "assets.json").read_text())
    manifest = []
    for item in plan:
        master = ROOT / item["master"]
        output = ROOT / item["output"]
        master.parent.mkdir(parents=True, exist_ok=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        if not master.exists():
            shutil.copy2(item["source"], master)
        if args.overwrite or not output.exists():
            width, height = item["pixels"]
            subprocess.run(["sips", "-s", "format", "png", "--resampleHeightWidth",
                            str(height), str(width), str(master), "--out", str(output)],
                           check=True, capture_output=True)
        with Image.open(output) as image:
            assert image.size == tuple(item["pixels"]) and image.mode == "RGB"
            image.verify()
        manifest.append({"platform": item["platform"], "slide": item["slide"],
                         "topic": item["topic"], "file": item["output"],
                         "pixels": item["pixels"], "mode": "RGB",
                         "generator": "built-in image_gen",
                         "master": item["master"]})
        print(item["output"], "verified", flush=True)
    (ROOT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    extras = ["caption.txt", "prompts.md", "README.md", "manifest.json"]
    files = [ROOT / item["output"] for item in plan] + [ROOT / name for name in extras]
    archive_path = ROOT / "GradeLab_Instagram_TikTok_3_Slide_Carousel.zip"
    with ZipFile(archive_path, "w", ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, str(path.relative_to(ROOT)))
    with ZipFile(archive_path) as archive:
        assert len(archive.namelist()) == 10 and archive.testzip() is None
    print(archive_path, flush=True)


if __name__ == "__main__":
    main()
