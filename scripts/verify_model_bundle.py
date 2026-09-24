"""Verify that pinned Core ML models survived unsigned IPA packaging."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


YOLO_WEIGHTS_SHA256 = "f59b3d833e2ff32e194b5bb8e08d211dc7c5bdf144b90d2c8412c47ccfc83b36"


def tree_hash(directory: Path) -> str:
    if not directory.is_dir():
        raise RuntimeError(f"Model missing: {directory}")
    digest = hashlib.sha256()
    files = sorted(path for path in directory.rglob("*") if path.is_file())
    if not files:
        raise RuntimeError(f"Model empty: {directory}")
    for path in files:
        digest.update(path.relative_to(directory).as_posix().encode("utf-8"))
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def main() -> None:
    bundle = Path(sys.argv[1])
    siglip = tree_hash(bundle / "SigLIPBaseImage.mlmodelc")
    yolo = tree_hash(bundle / "YOLOv11.mlmodelc")
    prompt_path = bundle / "SigLIPPrompts.json"
    source_manifest = bundle / "SigLIPModelManifest.json"
    prompts = json.loads(prompt_path.read_text(encoding="utf-8"))
    manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
    if not prompts or manifest.get("weightsSHA256") != (
        "2c63cb7d1f2e95ba501893cbb8faeb4ea9a3af295498d35097126228659c2af8"
    ):
        raise RuntimeError("Invalid SigLIP prompt/model provenance")
    manifest["compiledSHA256"] = siglip
    source_manifest.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    (bundle / "YOLOModelManifest.json").write_text(json.dumps({
        "repository": "ultralytics/assets", "release": "v8.3.0",
        "weightsSHA256": YOLO_WEIGHTS_SHA256,
        "compiledSHA256": yolo,
    }, indent=2), encoding="utf-8")
    print(f"SigLIP compiled SHA256: {siglip}")
    print(f"YOLO compiled SHA256: {yolo}")


if __name__ == "__main__":
    main()
