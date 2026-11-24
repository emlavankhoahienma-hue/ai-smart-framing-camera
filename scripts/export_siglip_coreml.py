"""Export the pinned Apache-2.0 SigLIP encoder and composition prompts for iOS 17.

Runs on the macOS IPA builder. Conversion is rejected unless Core ML and
PyTorch embeddings agree on deterministic fixtures. No camera data is used.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from huggingface_hub import snapshot_download
from PIL import Image
from transformers import AutoImageProcessor, AutoTokenizer, SiglipModel


REPO = "google/siglip-base-patch16-224"
REVISION = "7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed"
WEIGHTS_SHA256 = "2c63cb7d1f2e95ba501893cbb8faeb4ea9a3af295498d35097126228659c2af8"
PROMPTS = {
    "person": "a photo of one person",
    "person_scenery": "a photo of a person with a scenic background",
    "group": "a photo of a group of people",
    "building": "a photo of a building or architectural landmark",
    "landscape": "a photo of a natural landscape",
    "animal": "a photo of an animal",
    "object": "a photo of an interesting everyday object",
    "food": "a photo of food",
    "vehicle": "a photo of a vehicle",
    "flower": "a close-up photo of a flower with its petals visible",
    "foliage": "a photo of leaves, plants and natural greenery",
    "macro": "a close-up photo showing small natural details and textures",
    "sky": "a wide photo of a sky filled with clouds",
    "water": "a wide photo of the sea, a lake or a river",
    "sunset": "a landscape photo at sunset or sunrise",
    "street": "a street photograph of people and their surroundings",
    "architecture_facade": "exterior view of residential houses, gabled rooftops, and building facades",
    "street_perspective": "an alley, street, or paved road with receding perspective leading lines",
    "desk_workspace": "a computer desk workspace with monitor, keyboard, mouse, or study items",
    "tabletop_ensemble": "everyday tabletop arrangement of cups, bottles, stationery, or boxes on a desk",
    "indoor_furnished": "indoor room corner showing wardrobe, closet, study table, books, and furniture",
    "frame_aperture": "scenic outdoor view seen through a doorway, window, or balcony opening",
    "foliage_garden": "lush green trees, palm fronds, leaves, and garden greenery",
    "horizon_sky": "wide scenic view with dramatic clouds, sky, and horizon above skyline",
    "dead_wall": "an empty plain blank white or beige wall with almost nothing interesting",
    "dead_floor": "a bare empty tiled floor or plain concrete ground filling the bottom",
    "edge_obstacle": "close-up vertical palm tree trunk, pole, door post, or metal railing blocking the frame edge",
    "wire_clutter": "messy coiled electrical wires on a wall, sockets, or tangled power cords on floor",
    "tin_roof_clutter": "plain corrugated metal tin shed roof clutter at the foreground edge",
    "clean_composition": "a clean well-composed balanced photograph with clear subject framing and minimal distractions",
    "dramatic_clouds": "a wide scenic photograph of dramatic clouds across an open sky",
    "clear_blue_sky": "a bright outdoor scene with a clear blue sky and distant horizon",
    "mountain_vista": "a scenic landscape photograph of mountains, hills, or a valley",
    "ocean_beach": "a coastal landscape photograph of ocean waves, sea, or sandy beach",
    "forest_woods": "a nature photograph of forest trees, woodland path, or lush greenery",
    "flower_closeup": "a close-up photograph of colorful flowers, blossoms, or petals in focus",
    "coffee_drink": "a photograph of a coffee cup, tea, beverage, or cafe tabletop drink",
    "portrait_closeup": "a close-up portrait photograph focused on a person's face and eyes",
    "portrait_fullbody": "a full-body portrait photograph of a standing person in environment",
    "night_city": "a night photograph with glowing city lights, neon signs, or bokeh",
    "architecture_symmetry": "a symmetrical architectural photograph of a building facade, bridge, or temple",
    "single_product": "a clean still-life photograph of a single foreground object or product",
    "pet_portrait": "a close-up portrait photograph of a dog, cat, bird, or pet animal",
    "food_spread": "a top-down or angled photograph of delicious dishes, pizza, cake, or meal",
    "water_reflection": "a calm landscape with reflections on a lake, river, or still water",
    "golden_hour": "a warm golden hour sunset or sunrise photograph with glowing light",
    "minimalist_space": "a minimalist photograph with clean negative space and a single focal point",
    "indoor_living_room": "an indoor living room or cozy room interior with sofa, lamp, and decor",
}


class ImageEncoder(torch.nn.Module):
    def __init__(self, model: SiglipModel):
        super().__init__()
        self.vision_model = model.vision_model
        if hasattr(model, "visual_projection"):
            self.projection = model.visual_projection
        else:
            self.projection = torch.nn.Identity()

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        pooled = self.vision_model(pixel_values=image, return_dict=False)[1]
        return torch.nn.functional.normalize(self.projection(pooled), dim=-1)


def fixture(seed: int) -> Image.Image:
    yy, xx = np.mgrid[0:224, 0:224]
    pixels = np.stack(
        ((xx + seed * 23) % 256, (yy * 2 + seed * 17) % 256,
         ((xx + yy) * (seed + 1)) % 256), axis=-1
    ).astype(np.uint8)
    return Image.fromarray(pixels, "RGB")


def main() -> None:
    model_dir = Path(snapshot_download(
        repo_id=REPO, revision=REVISION,
        allow_patterns=["*.json", "model.safetensors", "spiece.model"],
    ))
    digest = hashlib.sha256((model_dir / "model.safetensors").read_bytes()).hexdigest()
    if digest != WEIGHTS_SHA256:
        raise RuntimeError(f"SigLIP weight checksum mismatch: {digest}")
    processor = AutoImageProcessor.from_pretrained(model_dir)
    if list(processor.image_mean) != [0.5] * 3 or list(processor.image_std) != [0.5] * 3:
        raise RuntimeError("Unexpected image normalization; Core ML preprocessing must be reviewed")

    torch.manual_seed(0)
    model = SiglipModel.from_pretrained(model_dir, attn_implementation="eager").eval()
    encoder = ImageEncoder(model).eval()
    example = torch.zeros(1, 3, 224, 224)
    traced = torch.jit.trace(encoder, example, strict=False)
    fp16_converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             color_layout=ct.colorlayout.RGB,
                             scale=2.0 / 255.0, bias=[-1.0, -1.0, -1.0])],
        outputs=[ct.TensorType(name="embedding")],
    )

    fixtures = []
    for seed in (1, 5, 11):
        image = fixture(seed)
        inputs = processor(images=image, return_tensors="pt")
        with torch.no_grad():
            reference = encoder(inputs["pixel_values"]).numpy().reshape(-1)
        fixtures.append((seed, image, reference))

    def measure_min_cosine(candidate_model: ct.models.MLModel) -> float:
        min_cos = 1.0
        for seed, image, reference in fixtures:
            actual = np.asarray(candidate_model.predict({"image": image})["embedding"]).reshape(-1)
            cosine = float(np.dot(reference, actual) /
                           (np.linalg.norm(reference) * np.linalg.norm(actual)))
            if not np.isfinite(cosine):
                return float("nan")
            min_cos = min(min_cos, cosine)
        return min_cos

    converted = fp16_converted
    selected_precision = "FP16"
    min_cosine = float("nan")
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
        cos = measure_min_cosine(candidate)
        if np.isfinite(cos) and cos >= 0.985:
            converted = candidate
            selected_precision = label
            min_cosine = cos
            print(f"SigLIP {label} quantization passed parity (min_cosine={cos:.5f})")
            break
        print(f"SigLIP {label} quantization drifted (min_cosine={cos:.5f}), trying fallback")

    if selected_precision == "FP16":
        min_cosine = measure_min_cosine(converted)
        if not np.isfinite(min_cosine) or min_cosine < 0.98:
            raise RuntimeError(f"Core ML parity failed: min_cosine={min_cosine}")

    converted.save("SigLIPBaseImage.mlpackage")
    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    encoded = tokenizer(list(PROMPTS.values()), padding="max_length",
                        max_length=64, truncation=True, return_tensors="pt")
    with torch.no_grad():
        text = model.get_text_features(**encoded)
        text = torch.nn.functional.normalize(text, dim=-1).numpy()
    vectors = {key: [float(v) for v in row]
               for key, row in zip(PROMPTS.keys(), text)}
    Path("SigLIPPrompts.json").write_text(
        json.dumps(vectors, separators=(",", ":")), encoding="utf-8")
    Path("SigLIPModelManifest.json").write_text(json.dumps({
        "repository": REPO, "revision": REVISION,
        "weightsSHA256": WEIGHTS_SHA256,
        "license": "Apache-2.0",
        "precision": selected_precision,
        "parityMinimumCosine": 0.98,
        "parityMeasuredMinCosine": round(min_cosine, 6),
        "promptSchemaVersion": 2,
        "promptKeys": sorted(PROMPTS),
    }, indent=2), encoding="utf-8")
    print(f"SigLIP Core ML export ({selected_precision}) and parity checks passed (min_cosine={min_cosine:.5f})")


if __name__ == "__main__":
    main()
