"""Export Open-World Photographic YOLOE-26s (101 classes) to Core ML FP16 for iOS 17+.

Bakes MobileCLIP2-B text embeddings for 101 photographic subjects (people, faces,
animals, flowers, blossoms, leaves, trees, sky, clouds, sunset, mountains, sea,
beach, rivers, buildings, skyscrapers, temples, bridges, coffee, dishes, cameras,
watches, furniture, everyday objects) offline into standard Conv2d weights so
on-device iPhone inference runs purely on Apple Neural Engine with zero text-encoder
RAM overhead.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from ultralytics import YOLOE


MODEL_NAME = "yoloe-26s-seg.pt"
WEIGHTS_SHA256 = "48f24206bc8680d60cbbfa296b0140da849669b9515058b72f5a945142df0654"
INPUT_SIZE = 640

# 101 photographic open-vocabulary classes complementing 80-class COCO YOLO12s.
# Order is frozen into OpenWorldPhotoClasses.json and matched 1:1 by OpenWorldSubjectDetector.swift.
OPENWORLD_CLASSES = [
    # People & Portrait
    "person", "human face",
    # Animals & Wildlife
    "dog", "cat", "bird", "horse", "elephant", "butterfly", "fish", "animal",
    # Flora & Nature (non-COCO!)
    "flower", "blossom", "rose", "sunflower", "tulip", "bouquet",
    "leaf", "green plant", "potted plant", "tree", "palm tree", "branch", "forest", "grass", "cactus",
    # Sky, Clouds & Landscapes (non-COCO!)
    "sky", "cloud", "sunset", "sun", "moon", "mountain", "hill", "sea", "ocean",
    "beach", "river", "lake", "waterfall", "rainbow",
    # Architecture & Street (non-COCO!)
    "building", "house", "skyscraper", "tower", "bridge", "temple", "church",
    "window", "doorway", "balcony", "stairs", "street", "alley", "road", "street sign",
    # Food & Drinks
    "food", "dish", "cake", "dessert", "fruit", "pizza", "burger", "noodle", "bread",
    "coffee", "cup", "tea", "drink", "glass", "bottle", "bowl", "plate",
    # Vehicles
    "car", "motorcycle", "bicycle", "bus", "train", "boat", "airplane",
    # Everyday Objects & Products
    "laptop", "monitor", "tv", "keyboard", "mouse", "smartphone", "camera", "watch", "eyeglasses",
    "book", "lamp", "vase", "clock", "chair", "sofa", "table", "bag", "backpack",
    "shoe", "hat", "umbrella", "statue", "guitar",
]


class YOLOEOpenWorldDetWrapper(torch.nn.Module):
    """Slices purely the [1, 4 + nc, 8400] detection tensor (cx, cy, w, h + nc class probs),
    eliminating mask prototypes/coefficients so ANE latency and IPA footprint stay minimal.
    """

    def __init__(self, inner: torch.nn.Module, num_classes: int):
        super().__init__()
        self.inner = inner
        self.num_classes = num_classes

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        out = self.inner(image)
        pred = out[0] if isinstance(out, (tuple, list)) else out
        if isinstance(pred, (tuple, list)):
            pred = pred[0]
        return pred[:, : 4 + self.num_classes, :]


def letterbox_pil(image: Image.Image, size: int = INPUT_SIZE) -> Image.Image:
    w, h = image.size
    ratio = min(size / float(w), size / float(h))
    nw, nh = max(1, int(round(w * ratio))), max(1, int(round(h * ratio)))
    resized = image.resize((nw, nh), Image.Resampling.BILINEAR)
    canvas = Image.new("RGB", (size, size), (114, 114, 114))
    canvas.paste(resized, ((size - nw) // 2, (size - nh) // 2))
    return canvas


def synthetic_fixture() -> Image.Image:
    yy, xx = np.mgrid[0:INPUT_SIZE, 0:INPUT_SIZE]
    pixels = np.stack(
        ((xx * 3) % 256, (yy * 2) % 256, ((xx + yy) * 2) % 256),
        axis=-1,
    ).astype(np.uint8)
    return Image.fromarray(pixels, "RGB")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default=MODEL_NAME)
    parser.add_argument("--output", default="OpenWorldPhotoYOLOE.mlpackage")
    parser.add_argument("--classes-out", default="OpenWorldPhotoClasses.json")
    parser.add_argument("--manifest-out", default="OpenWorldPhotoManifest.json")
    parser.add_argument("--parity-image", default=None)
    args = parser.parse_args()

    model = YOLOE(args.weights)
    ckpt_path = Path(model.ckpt_path or args.weights)
    if not ckpt_path.is_file():
        raise RuntimeError(f"Expected YOLOE checkpoint file at {ckpt_path}")
    digest = hashlib.sha256(ckpt_path.read_bytes()).hexdigest()
    if digest != WEIGHTS_SHA256:
        raise RuntimeError(f"YOLOE-26s weight SHA256 mismatch: {digest} != {WEIGHTS_SHA256}")

    nc = len(OPENWORLD_CLASSES)
    text_pe = model.get_text_pe(OPENWORLD_CLASSES)
    model.set_classes(OPENWORLD_CLASSES, text_pe)
    model.model.eval()
    model.model.fuse()
    model.model.model[-1].export = True

    wrapper = YOLOEOpenWorldDetWrapper(model.model, nc).eval()
    example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE, dtype=torch.float32)
    with torch.no_grad():
        eager_sample = wrapper(example)
        if tuple(eager_sample.shape) != (1, 4 + nc, 8400):
            raise RuntimeError(f"Unexpected YOLOE detection shape: {tuple(eager_sample.shape)}")
        traced = torch.jit.trace(wrapper, example, strict=False)
        traced_sample = traced(example)
        trace_err = float((eager_sample - traced_sample).abs().max())
        if not np.isfinite(trace_err) or trace_err > 1e-4:
            raise RuntimeError(f"TorchScript trace parity mismatch: max_err={trace_err}")

    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
            )
        ],
        outputs=[ct.TensorType(name="detections")],
    )

    parity_img = (
        letterbox_pil(Image.open(args.parity_image).convert("RGB"))
        if args.parity_image and Path(args.parity_image).is_file()
        else synthetic_fixture()
    )
    arr = np.asarray(parity_img, dtype=np.float32) / 255.0
    ten = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        pt_out = wrapper(ten).numpy()[0]  # [4 + nc, 8400]

    cm_raw = converted.predict({"image": parity_img})["detections"]
    cm_out = np.asarray(cm_raw, dtype=np.float32)[0]
    if cm_out.shape != pt_out.shape:
        raise RuntimeError(f"Core ML shape mismatch: {cm_out.shape} != {pt_out.shape}")

    pt_scores = pt_out[4:, :].max(axis=0)
    cm_scores = cm_out[4:, :].max(axis=0)
    score_max_diff = float(np.abs(pt_scores - cm_scores).max())
    score_corr = float(np.corrcoef(pt_scores, cm_scores)[0, 1]) if float(pt_scores.std()) > 1e-6 else 1.0
    top_idx = int(np.argmax(pt_scores))
    box_diff = float(np.abs(pt_out[:4, top_idx] - cm_out[:4, top_idx]).max())
    if not np.isfinite(score_max_diff) or score_max_diff > 0.06 or score_corr < 0.99:
        raise RuntimeError(
            f"Core ML parity failed: score_max_diff={score_max_diff:.4f}, corr={score_corr:.4f}, box_diff={box_diff:.2f}"
        )

    converted.save(args.output)
    Path(args.classes_out).write_text(
        json.dumps(OPENWORLD_CLASSES, indent=2) + "\n", encoding="utf-8"
    )
    Path(args.manifest_out).write_text(
        json.dumps(
            {
                "model": MODEL_NAME,
                "weightsSHA256": WEIGHTS_SHA256,
                "inputSize": INPUT_SIZE,
                "classCount": nc,
                "outputShape": [1, 4 + nc, 8400],
                "parity": {
                    "checked": True,
                    "scoreMaxAbsDiff": round(score_max_diff, 5),
                    "scorePearsonCorr": round(score_corr, 6),
                    "topBoxMaxPixelDiff": round(box_diff, 3),
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(
        f"OpenWorldPhotoYOLOE exported cleanly ({nc} classes, "
        f"score_max_diff={score_max_diff:.4f}, corr={score_corr:.5f}, box_diff={box_diff:.2f}px)"
    )


if __name__ == "__main__":
    main()
