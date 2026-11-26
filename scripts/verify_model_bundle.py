"""Verify that pinned Core ML models survived unsigned IPA packaging."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


YOLO_WEIGHTS_SHA256 = {
    "yolo12n": "419ff3dca37d69bacc93a50fa0c186a1c6f9fe62fae0f108b0872829689e9ca6",
    "yolo12s": "e915c2c4286e3f6f8610ef106fa3f94a7b8c19b30eccede5887e22c33ef75f58",
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
        "repository": "ultralytics/assets",
        "release": "v8.3.0",
        "models": {name: {"weightsSHA256": YOLO_WEIGHTS_SHA256[name],
                           "compiledSHA256": yolo[name]} for name in yolo},
    }
    (bundle / "YOLOModelManifest.json").write_text(json.dumps(yolo_manifest_data, indent=2), encoding="utf-8")
    gaic_manifest_path = bundle / "GAICModelManifest.json"
    gaic_manifest = json.loads(gaic_manifest_path.read_text(encoding="utf-8"))
    gaic_sha = gaic_manifest.get("weights_sha256") or gaic_manifest.get("weightsSHA256")
    if gaic_sha != "82492f3a1c72a8b2db605dc1962b0f50898b11c3676899fdbe3ee60427596b41":
        raise RuntimeError("Invalid GAICCompositionScorer checkpoint provenance")
    gaic_parity = gaic_manifest.get("parity") or {}
    if not gaic_parity.get("checked") or gaic_parity.get("max_abs_diff", 1) > 0.08 or gaic_parity.get("pearson_corr", 0) < 0.995:
        raise RuntimeError(f"GAICCompositionScorer failed macOS Core ML parity check: {gaic_parity}")
    gaic_compiled = tree_hash(bundle / "GAICCompositionScorer.mlmodelc")
    gaic_manifest["compiledSHA256"] = gaic_compiled
    gaic_manifest_path.write_text(json.dumps(gaic_manifest, indent=2), encoding="utf-8")

    ow_manifest_path = bundle / "OpenWorldPhotoManifest.json"
    ow_manifest = json.loads(ow_manifest_path.read_text(encoding="utf-8"))
    if ow_manifest.get("weightsSHA256") != "585f5ec9028fd358035da8d860c27c56be285a795cba2076fba536a4391c2c83":
        raise RuntimeError("Invalid OpenWorldPhotoYOLOE checkpoint provenance")
    ow_classes = json.loads((bundle / "OpenWorldPhotoClasses.json").read_text(encoding="utf-8"))
    if len(ow_classes) < 120 or "flower" not in ow_classes or "sky" not in ow_classes or "building" not in ow_classes:
        raise RuntimeError("OpenWorldPhotoClasses.json missing core photographic categories")
    ow_parity = ow_manifest.get("parity") or {}
    if not ow_parity.get("checked") or ow_parity.get("scorePearsonCorr", 0) < 0.99:
        raise RuntimeError(f"OpenWorldPhotoYOLOE failed Core ML parity: {ow_parity}")
    ow_compiled = tree_hash(bundle / "OpenWorldPhotoYOLOE.mlmodelc")
    ow_manifest["compiledSHA256"] = ow_compiled
    ow_manifest_path.write_text(json.dumps(ow_manifest, indent=2), encoding="utf-8")

    depth_manifest_path = bundle / "DepthAnythingManifest.json"
    depth_manifest = json.loads(depth_manifest_path.read_text(encoding="utf-8"))
    if depth_manifest.get("weightsSHA256") != "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed":
        raise RuntimeError("Invalid DepthAnythingV2SmallF16 provenance")
    depth_compiled = tree_hash(bundle / "DepthAnythingV2SmallF16.mlmodelc")
    depth_manifest["compiledSHA256"] = depth_compiled
    depth_manifest_path.write_text(json.dumps(depth_manifest, indent=2), encoding="utf-8")

    print(f"SigLIP compiled SHA256: {siglip}")
    print(f"YOLO compiled SHA256: {yolo}")
    print(f"SAMP-Net compiled SHA256: {composition}")
    print(f"GAIC compiled SHA256: {gaic_compiled}")
    print(f"OpenWorldPhotoYOLOE compiled SHA256: {ow_compiled}")
    print(f"DepthAnythingV2SmallF16 compiled SHA256: {depth_compiled}")


if __name__ == "__main__":
    main()
