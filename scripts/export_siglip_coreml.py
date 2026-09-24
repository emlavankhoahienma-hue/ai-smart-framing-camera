"""Export the pinned Apache-2.0 SigLIP image encoder for iOS 16.

Runs on the macOS IPA builder. Conversion is rejected unless Core ML and
PyTorch embeddings agree on deterministic fixtures. No camera data is used.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import coremltools as ct
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
}


class ImageEncoder(torch.nn.Module):
    def __init__(self, model: SiglipModel):
        super().__init__()
        self.vision_model = model.vision_model
        self.projection = model.visual_projection

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
    converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             color_layout=ct.colorlayout.RGB,
                             scale=2.0 / 255.0, bias=[-1.0, -1.0, -1.0])],
        outputs=[ct.TensorType(name="embedding")],
    )
    for seed in (1, 5, 11):
        image = fixture(seed)
        inputs = processor(images=image, return_tensors="pt")
        with torch.no_grad():
            reference = encoder(inputs["pixel_values"]).numpy().reshape(-1)
        actual = np.asarray(converted.predict({"image": image})["embedding"]).reshape(-1)
        cosine = float(np.dot(reference, actual) /
                       (np.linalg.norm(reference) * np.linalg.norm(actual)))
        if not np.isfinite(cosine) or cosine < 0.98:
            raise RuntimeError(f"Core ML parity failed on fixture {seed}: cosine={cosine}")

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
        "parityMinimumCosine": 0.98,
    }, indent=2), encoding="utf-8")
    print("SigLIP Core ML export and parity checks passed")


if __name__ == "__main__":
    main()
