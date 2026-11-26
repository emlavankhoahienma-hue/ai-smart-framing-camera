"""
Export GAICCompositionScorer from pinned PyTorch weights to Core ML .mlpackage
(and verify PyTorch <-> Core ML numerical parity on macOS when coremlpython is available).
"""
from __future__ import annotations

import os
import sys
import json
import hashlib
import argparse
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps
import torch
import coremltools as ct

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from model import GAICCompositionScorer, GAICExportWrapper, MAX_EXPORT_BOXES, IMAGE_SIZE


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def verify_weight_digest(weights_path: Path, digest_file: Path) -> str:
    actual = sha256_file(weights_path)
    if digest_file.exists():
        expected = digest_file.read_text(encoding="utf-8").strip().split()[0]
        if expected and actual != expected:
            raise RuntimeError(f"GAIC weight digest mismatch: expected {expected}, got {actual}")
    return actual


def make_candidate_grid_256() -> np.ndarray:
    boxes = []
    for s in (0.95, 0.85, 0.75, 0.65, 0.55):
        for cy in np.linspace(0.0, 1.0 - s, 4):
            for cx in np.linspace(0.0, 1.0 - s, 4):
                boxes.append([float(cx), float(cy), float(cx + s), float(cy + s)])
    while len(boxes) < MAX_EXPORT_BOXES:
        boxes.append([0.0, 0.0, 1.0, 1.0])
    return np.asarray(boxes[:MAX_EXPORT_BOXES], dtype=np.float32)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, default=THIS_DIR / "gaic_cropper.pt")
    parser.add_argument("--output", type=Path, default=THIS_DIR / "GAICCompositionScorer.mlpackage")
    parser.add_argument("--manifest", type=Path, default=None)
    parser.add_argument("--parity-image", type=Path, default=None)
    parser.add_argument("--precision", choices=("fp16", "fp32"), default="fp16")
    args = parser.parse_args()

    digest = verify_weight_digest(args.weights, THIS_DIR / "weights_sha256.txt")
    ckpt = torch.load(args.weights, map_location="cpu", weights_only=True)
    state = ckpt["state_dict"] if isinstance(ckpt, dict) and "state_dict" in ckpt else ckpt
    meta = ckpt.get("meta", {}) if isinstance(ckpt, dict) else {}

    core = GAICCompositionScorer(pretrained=False)
    core.load_state_dict(state, strict=True)
    core.eval()
    wrapper = GAICExportWrapper(core, num_boxes=MAX_EXPORT_BOXES).eval()

    dummy_img = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE, dtype=torch.float32)
    dummy_boxes = torch.from_numpy(make_candidate_grid_256()).unsqueeze(0)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_img, dummy_boxes))

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
                bias=[0.0, 0.0, 0.0],
            ),
            ct.TensorType(name="boxes", shape=(1, MAX_EXPORT_BOXES, 4)),
        ],
        outputs=[ct.TensorType(name="scores")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
    )

    mlmodel.author = "AI Smart Framing Camera"
    mlmodel.short_description = "RoI+RoD multi-scale compositional crop scorer (MobilenetV3-FPN)."
    mlmodel.user_defined_metadata["weights_sha256"] = digest
    mlmodel.user_defined_metadata["max_boxes"] = str(MAX_EXPORT_BOXES)
    mlmodel.user_defined_metadata["image_size"] = str(IMAGE_SIZE)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.output))
    print(f"[GAIC-Export] Saved {args.output} ({args.precision})")

    parity_info = {"checked": False}
    if sys.platform == "darwin":
        if args.parity_image and args.parity_image.exists():
            pil = ImageOps.exif_transpose(Image.open(args.parity_image)).convert("RGB").resize(
                (IMAGE_SIZE, IMAGE_SIZE), Image.Resampling.BILINEAR
            )
        else:
            arr = np.clip(np.linspace(0, 255, IMAGE_SIZE * IMAGE_SIZE * 3).reshape(IMAGE_SIZE, IMAGE_SIZE, 3), 0, 255).astype(np.uint8)
            pil = Image.fromarray(arr, mode="RGB")
        img_t = torch.from_numpy(np.asarray(pil, dtype=np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0)
        bxs = make_candidate_grid_256()
        with torch.no_grad():
            pt_scores = wrapper(img_t, torch.from_numpy(bxs).unsqueeze(0))[0].numpy()
        cm_out = mlmodel.predict({"image": pil, "boxes": bxs[None, ...]})
        cm_scores = np.asarray(cm_out["scores"], dtype=np.float32).reshape(-1)
        max_abs = float(np.max(np.abs(pt_scores - cm_scores)))
        corr = float(np.corrcoef(pt_scores, cm_scores)[0, 1])
        parity_info = {"checked": True, "max_abs_diff": round(max_abs, 5), "pearson_corr": round(corr, 6)}
        print(f"[GAIC-Export] macOS CoreML parity: max_abs_diff={max_abs:.5f}, corr={corr:.6f}")
        if max_abs > 0.08 or corr < 0.995:
            raise RuntimeError(f"PyTorch vs CoreML GAICCompositionScorer parity failed: {parity_info}")

    if args.manifest:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest_data = {
            "model": "GAICCompositionScorer",
            "backbone": "mobilenetv3_large_100",
            "image_size": IMAGE_SIZE,
            "max_boxes": MAX_EXPORT_BOXES,
            "precision": args.precision,
            "weights_sha256": digest,
            "training_metrics": meta,
            "parity": parity_info,
        }
        args.manifest.write_text(json.dumps(manifest_data, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
