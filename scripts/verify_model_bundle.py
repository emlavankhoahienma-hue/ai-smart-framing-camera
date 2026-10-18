"""Verify that pinned Core ML models survived unsigned IPA packaging."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


YOLO_WEIGHTS_SHA256 = {
    "yolo12n": "419ff3dca37d69bacc93a50fa0c186a1c6f9fe62fae0f108b0872829689e9ca6",
    "yolo12s": "e915c2c4286e3f6f8610ef106fa3f94a7b8c19b30eccede5887e22c33ef75f58",
    "yolo26s": "646f8bc3fe0a656803d95c294f7852321748cb29d13466a1af8862e2db384a1b",
}


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
    focal_path = bundle / "FocalModelManifest.json"
    focal = json.loads(focal_path.read_text(encoding="utf-8"))
    if focal.get("weightsSHA256") != "82c4d695310c220e5f3bcfbf5e64d315a5e826cfd77e945e61e032460014480a":
        raise RuntimeError("Invalid released crop checkpoint")
    parity = focal.get("swiftParity") or {}
    if parity.get("images", 0) < 32 or parity.get("maxPreferenceError", 1) >= 0.002 or parity.get("maxImportanceError", 1) >= 0.001:
        raise RuntimeError("Crop model did not pass production Swift preprocessing parity")
    decoded = focal.get("photoDecoderComparison") or {}
    if decoded.get("images", 0) < 32 or decoded.get("maxInputMAE", 1) >= 0.01 or decoded.get("maxInputError", 1) >= 0.04:
        raise RuntimeError("Native crop input differs excessively from author preprocessing")
    human = focal.get("humanPreferences") or {}
    if human.get("pairs", 0) != 300 or human.get("accuracy", 0) < 0.68:
        raise RuntimeError("Crop model did not pass human preference comparison")
    if not (bundle / "FocalNet-LICENSE.txt").is_file():
        raise RuntimeError("Missing released crop-model license")
    focal["compiledSHA256"] = tree_hash(bundle / "FocalCrop.mlmodelc")
    focal_path.write_text(json.dumps(focal, indent=2), encoding="utf-8")
    charm_path = bundle / "CharmModelManifest.json"
    charm = json.loads(charm_path.read_text(encoding="utf-8"))
    if charm.get("weightsSHA256") != "d7ce85f65ed25fa8c15eeb52f63310e7207cf76fd11ca763f284576d3824a9cb":
        raise RuntimeError("Invalid Charm-PARA checkpoint provenance")
    if charm.get("inputProfile") != "Pillow bilinear <=336 long edge; author normal_flow; RGB [0,1]; zero-pad right/bottom to 14; no token dropping; <=1024 patches":
        raise RuntimeError("Charm input profile does not match production Swift")
    parity = charm.get("parity") or {}
    if parity.get("images", 0) < 24 or parity.get("maxMeanScoreError", 1) > 0.04:
        raise RuntimeError("Charm has not passed real-photo Core ML parity")
    position = hashlib.sha256((bundle / "CharmPositionEmbedding.bin").read_bytes()).hexdigest()
    if position != charm.get("positionBinarySHA256") or not (bundle / "Charm-LICENSE.txt").is_file():
        raise RuntimeError("Charm position embeddings/license missing or inconsistent")
    charm["compiledSHA256"] = tree_hash(bundle / "CharmAesthetics.mlmodelc")
    charm_path.write_text(json.dumps(charm, indent=2), encoding="utf-8")
    composition = tree_hash(bundle / "SAMPComposition.mlmodelc")
    composition_manifest_path = bundle / "SAMPModelManifest.json"
    composition_manifest = json.loads(composition_manifest_path.read_text(encoding="utf-8"))
    if composition_manifest.get("weightsSHA256") != "d3d02f36967734fd6f0d2770380a04b777b5cd800a9ba68d4ccc9656f6fef603":
        raise RuntimeError("Invalid SAMP-Net weight provenance")
    if composition_manifest.get("imageInput") != "RGB float32 NCHW [0,1]; Pillow antialiased bilinear":
        raise RuntimeError("SAMP-Net input profile does not match Swift preprocessing")
    parity = composition_manifest.get("parity") or {}
    if parity.get("images", 0) < 24 or parity.get("maxMeanScoreError", 1) > 0.04:
        raise RuntimeError("SAMP-Net has not passed real-photo Core ML parity")
    if not (bundle / "SAMP-Net-LICENSE.txt").is_file():
        raise RuntimeError("Missing SAMP-Net license")
    composition_manifest["compiledSHA256"] = composition
    composition_manifest_path.write_text(json.dumps(composition_manifest, indent=2), encoding="utf-8")
    siglip = tree_hash(bundle / "SigLIPBaseImage.mlmodelc")
    yolo = {name: tree_hash(bundle / f"{name}.mlmodelc")
            for name in YOLO_WEIGHTS_SHA256}
    photographic_detector = json.loads((bundle / "YOLO26PhotographicModel.json").read_text(encoding="utf-8"))
    if (photographic_detector.get("weightsSHA256") != YOLO_WEIGHTS_SHA256["yolo26s"] or
            photographic_detector.get("weightsRevision") != "45588070f19053475015dd860367c7780dd34b2a" or
            photographic_detector.get("export") != {"format": "coreml", "imgsz": 640, "nms": True,
                                                     "quantize": 16, "dynamic": False, "batch": 1}):
        raise RuntimeError("Photographic YOLO26 source/export provenance differs from the tested NMS pipeline")
    
    prompt_path = bundle / "SigLIPPrompts.json"
    source_manifest = bundle / "SigLIPModelManifest.json"
    prompts = json.loads(prompt_path.read_text(encoding="utf-8"))
    manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
    if not prompts or manifest.get("weightsSHA256") != (
        "2c63cb7d1f2e95ba501893cbb8faeb4ea9a3af295498d35097126228659c2af8"
    ):
        raise RuntimeError("Invalid SigLIP prompt/model provenance")
    required = {"person", "person_scenery", "group", "building", "landscape", "animal",
                "object", "food", "flower", "foliage", "macro", "sky", "water", "sunset", "street"}
    if not required.issubset(prompts) or manifest.get("promptSchemaVersion") != 2:
        raise RuntimeError("Composition prompt bank missing or out of date")
    manifest["compiledSHA256"] = siglip
    source_manifest.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    
    yolo_manifest_data = {
        "models": {name: {"weightsSHA256": YOLO_WEIGHTS_SHA256[name],
                           "compiledSHA256": yolo[name],
                           "role": "one-shot photographic detection" if name == "yolo26s" else "preserved optical target recovery",
                           "weightsURL": photographic_detector["weightsURL"] if name == "yolo26s" else
                               f"https://github.com/ultralytics/assets/releases/download/v8.3.0/{name}.pt"}
                   for name in yolo},
        "ultralyticsVersion": "8.4.178",
        "export": {"nms": True, "quantize": 16, "imgsz": 640, "dynamic": False, "batch": 1},
    }
    (bundle / "YOLOModelManifest.json").write_text(json.dumps(yolo_manifest_data, indent=2), encoding="utf-8")
    print(f"SigLIP compiled SHA256: {siglip}")
    print(f"YOLO compiled SHA256: {yolo}")
    print(f"SAMP-Net compiled SHA256: {composition}")


if __name__ == "__main__":
    main()
