"""Export Open-World Photographic YOLOE-26m (143 curated classes @ 512x512) to Core ML FP16 for iOS 17+.

Bakes MobileCLIP2-B text embeddings for 143 curated photographic subjects (people, faces,
pets, wildlife, insects, flowers, blossoms, succulents, trees, sky, clouds, sunset, mountains,
sea, beach, rivers, buildings, skyscrapers, castles, temples, cathedrals, bridges, monuments,
sculptures, coffee, dishes, collectibles, accessories, tech, everyday objects) offline into
standard Conv2d weights so on-device iPhone inference runs purely on Apple Neural Engine with
zero text-encoder RAM overhead and 36% fewer anchors (5376 vs 8400) for faster decoding.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image
from ultralytics import YOLOE


MODEL_NAME = "yoloe-26m-seg.pt"
WEIGHTS_SHA256 = "585f5ec9028fd358035da8d860c27c56be285a795cba2076fba536a4391c2c83"
INPUT_SIZE = 512
EXPECTED_ANCHORS = (INPUT_SIZE // 8) ** 2 + (INPUT_SIZE // 16) ** 2 + (INPUT_SIZE // 32) ** 2

# 143 curated photographic open-vocabulary classes complementing 80-class COCO YOLO12s.
# Order is frozen into OpenWorldPhotoClasses.json and matched 1:1 by OpenWorldSubjectDetector.swift.
OPENWORLD_CLASSES = [
    # People & Portrait (2)
    "person", "human face",
    # Animals, Pets & Wildlife (18)
    "dog", "cat", "bird", "duck", "parrot", "horse", "cow", "elephant",
    "deer", "rabbit", "snake", "frog", "turtle",
    "butterfly", "insect", "beetle", "fish", "animal",
    # Flora & Nature (18)
    "flower", "blossom", "rose", "sunflower", "bouquet",
    "succulent", "cactus", "mushroom", "leaf", "green plant", "potted plant",
    "tree", "palm tree", "branch", "forest", "grass", "rock", "cliff",
    # Sky, Water & Landscapes (13)
    "sky", "cloud", "sunset", "sun", "mountain", "hill", "sea", "ocean",
    "beach", "river", "lake", "waterfall", "rainbow",
    # Architecture, Landmarks & Street (23)
    "building", "house", "skyscraper", "tower", "castle", "pagoda", "temple", "church", "cathedral",
    "bridge", "arch", "fountain", "monument", "sculpture", "statue",
    "window", "doorway", "balcony", "stairs", "street", "alley", "road", "street sign",
    # Food & Drinks (21)
    "food", "dish", "cake", "ice cream", "dessert", "fruit", "pizza", "burger", "noodle", "bread",
    "coffee", "tea", "cocktail", "drink", "cup", "mug", "glass", "bottle", "bowl", "plate", "teapot",
    # Vehicles & Gear (9)
    "car", "motorcycle", "scooter", "bicycle", "bus", "train", "boat", "airplane", "helmet",
    # Everyday Objects, Tech, Fashion & Collectibles (39)
    "laptop", "monitor", "tv", "keyboard", "mouse", "smartphone", "camera", "headphones", "speaker",
    "watch", "eyeglasses", "sunglasses", "perfume", "ring", "book", "lamp", "chandelier", "candle", "lantern",
    "vase", "clock", "mirror", "chair", "sofa", "table", "bag", "handbag", "backpack",
    "shoe", "sneaker", "hat", "umbrella", "toy", "figurine", "guitar", "barrel", "box", "package", "fireworks",
]


class YOLOEOpenWorldDetWrapper(torch.nn.Module):
    """Slices purely the [1, 4 + nc, anchors] detection tensor (cx, cy, w, h + nc class probs),
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
        raise RuntimeError(f"YOLOE-26m weight SHA256 mismatch: {digest} != {WEIGHTS_SHA256}")

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
        if tuple(eager_sample.shape) != (1, 4 + nc, EXPECTED_ANCHORS):
            raise RuntimeError(f"Unexpected YOLOE detection shape: {tuple(eager_sample.shape)}")
        traced = torch.jit.trace(wrapper, example, strict=False)
        traced_sample = traced(example)
        trace_err = float((eager_sample - traced_sample).abs().max())
        if not np.isfinite(trace_err) or trace_err > 1e-4:
            raise RuntimeError(f"TorchScript trace parity mismatch: max_err={trace_err}")

    fp16_converted = ct.convert(
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
        pt_out = wrapper(ten).numpy()[0]  # [4 + nc, anchors]
    pt_scores = pt_out[4:, :].max(axis=0)
    top_idx = int(np.argmax(pt_scores))

    def measure_parity(candidate_model: ct.models.MLModel) -> tuple[float, float, float]:
        cm_raw = candidate_model.predict({"image": parity_img})["detections"]
        cm_out = np.asarray(cm_raw, dtype=np.float32)[0]
        if cm_out.shape != pt_out.shape:
            raise RuntimeError(f"Core ML shape mismatch: {cm_out.shape} != {pt_out.shape}")
        cm_scores = cm_out[4:, :].max(axis=0)
        s_diff = float(np.abs(pt_scores - cm_scores).max())
        s_corr = float(np.corrcoef(pt_scores, cm_scores)[0, 1]) if float(pt_scores.std()) > 1e-6 else 1.0
        b_diff = float(np.abs(pt_out[:4, top_idx] - cm_out[:4, top_idx]).max())
        return s_diff, s_corr, b_diff

    converted = fp16_converted
    selected_precision = "FP16"
    score_max_diff, score_corr, box_diff = float("nan"), float("nan"), float("nan")
    for quant_mode, label in (("linear_symmetric", "W8A16-symmetric"), ("linear", "W8A16-linear")):
        q_cfg = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(
                mode=quant_mode,
                dtype="int8",
                granularity="per_channel",
                weight_threshold=512,
            )
        )
        candidate = cto.linear_quantize_weights(fp16_converted, config=q_cfg)
        s_diff, s_corr, b_diff = measure_parity(candidate)
        if np.isfinite(s_diff) and s_diff <= 0.06 and s_corr >= 0.99:
            converted = candidate
            selected_precision = label
            score_max_diff, score_corr, box_diff = s_diff, s_corr, b_diff
            print(f"OpenWorldPhotoYOLOE {label} passed parity (diff={s_diff:.4f}, corr={s_corr:.5f}, box={b_diff:.2f}px)")
            break
        print(f"OpenWorldPhotoYOLOE {label} drifted (diff={s_diff:.4f}, corr={s_corr:.5f}), trying fallback")

    if selected_precision == "FP16":
        score_max_diff, score_corr, box_diff = measure_parity(converted)
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
                "precision": selected_precision,
                "inputSize": INPUT_SIZE,
                "classCount": nc,
                "outputShape": [1, 4 + nc, EXPECTED_ANCHORS],
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
        f"OpenWorldPhotoYOLOE exported cleanly ({selected_precision}, {nc} classes, "
        f"score_max_diff={score_max_diff:.4f}, corr={score_corr:.5f}, box_diff={box_diff:.2f}px)"
    )


if __name__ == "__main__":
    main()
