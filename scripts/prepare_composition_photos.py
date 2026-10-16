"""Deterministic author-test-split photos; never copy them into the app bundle."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import urllib.request
import zipfile
from collections import Counter
from pathlib import Path

from PIL import Image

DATA_URL = ("https://www.dropbox.com/scl/fi/fvlsnit7on6218szply4q/CADB_Dataset.zip"
            "?rlkey=mwt9eftdhmnawomv44x4deliw&dl=1")
DATA_SHA256 = "c219283a31fa46d002d1f4465e3c0d22e840e454aed3e0bb9d4284f0d3264757"


def prepare(archive: Path, output: Path, per_scene: int = 16) -> dict:
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(DATA_URL, archive)
    digest = hashlib.file_digest(archive.open("rb"), "sha256").hexdigest()
    if digest != DATA_SHA256:
        raise RuntimeError(f"CADB archive checksum mismatch: {digest}")
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as data:
        prefix = "CADB_Dataset/"
        split = json.loads(data.read(prefix + "split.json"))
        scenes = json.loads(data.read(prefix + "scene_categories.json"))
        scores = json.loads(data.read(prefix + "composition_scores.json"))
        counts = Counter()
        records = []
        for name in sorted(split["test"], key=lambda n: hashlib.sha256(n.encode()).hexdigest()):
            scene = scenes[name]
            if counts[scene] >= per_scene:
                continue
            counts[scene] += 1
            source = data.read(prefix + "images/" + name)
            image = Image.open(io.BytesIO(source)).convert("RGB")
            # Preserve the complete frame; a bounded size is also used by the app's
            # candidate previews. This file is an evaluation fixture, not a label.
            height = 288
            image = image.resize((round(image.width * height / image.height), height), Image.Resampling.BILINEAR)
            if image.width > 1024:
                image.thumbnail((1024, 1024), Image.Resampling.BILINEAR)
            image.save(output / name, quality=95, subsampling=0)
            records.append({"file": name, "scene": scene, "humanMean": scores[name]["mean"],
                            "sourceSHA256": hashlib.sha256(source).hexdigest(),
                            "fixtureSHA256": hashlib.sha256((output / name).read_bytes()).hexdigest()})
    manifest = {"dataset": "CADB", "source": DATA_URL, "archiveSHA256": digest,
                "split": "author test (not training)", "testPopulation": len(split["test"]),
                "selection": "SHA256 filename order, at most N per scene; no score-based selection",
                "perSceneLimit": per_scene, "scenes": dict(counts), "images": records}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, default=Path(".model-cache/CADB_Dataset.zip"))
    parser.add_argument("--output", type=Path, default=Path("validation/photos"))
    parser.add_argument("--per-scene", type=int, default=16)
    arguments = parser.parse_args()
    result = prepare(arguments.archive, arguments.output, arguments.per_scene)
    print(json.dumps({"images": len(result["images"]), "scenes": result["scenes"]}))
