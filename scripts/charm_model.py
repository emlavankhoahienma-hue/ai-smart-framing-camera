"""Author-released Charm-PARA (2025), with its bounded, unpadded token path."""
from __future__ import annotations

import importlib
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torch.nn import functional as F

from composition_model import verified_download

PAPER = "https://arxiv.org/abs/2504.02522"
REVISION = "ef79fcffaf69ab0527ba9733960cae4290e765e2"
HF_REVISION = "7feb32371796b4e6732e6f662c55fa4e87538835"
WEIGHTS_SHA256 = "d7ce85f65ed25fa8c15eeb52f63310e7207cf76fd11ca763f284576d3824a9cb"
POSITION_SHA256 = "0ce8ffc052e1d8a65c47abe65400e8ce3f06be10f843644c913fed30a6c76d45"
WHEEL_SHA256 = "14fdac5e0bcdf88702dc2ed3679796291435f750d2cf22af671df30b2bb3c650"
SOURCE_HASHES = {
    "model.py": "4c248e62c9b2ac4bf1ba9c12ca2df77e4f29b8682f30b5f37aa7ce703f397fee",
    "mixout/example_huggingface.py": "c735ee5c1b8e7f022782cad2c9ece58988c4430554c75ca68b83b515fc8b8cc7",
    "mixout/mixout/__init__.py": "d93551d79efa1dae9f2ab11b4bbd74ab0c3b057e05874e8f72acbfdc2a5a8b92",
    "mixout/mixout/mixlinear.py": "d731209ef2fad87ff77413791af59e2e0307e6ff935c0800a3947508daea2089",
    "mixout/mixout/functional/__init__.py": "5cb4f500a82e74a4b22feb487f870a15ff329cd3acce33fb2e51bf9f5b1f2669",
    "mixout/mixout/mixout.py": "40a60738c258cd2852c5a9506b9ec11f2bf50e67d6d7f817d45fbdd55cb1127d",
}


def load_model(cache: Path):
    for name, digest in SOURCE_HASHES.items():
        verified_download(f"https://raw.githubusercontent.com/FBehrad/Charm/{REVISION}/{name}", cache / name, digest)
    base = f"https://huggingface.co/FatemehBehrad/Charm/resolve/{HF_REVISION}/"
    weights = verified_download(base + "para_charm.pth", cache / "para_charm.pth", WEIGHTS_SHA256)
    position = verified_download(base + "dino_small_pos.pt", cache / "dino_small_pos.pt", POSITION_SHA256)
    sys.path.insert(0, str(cache.resolve()))
    importlib.import_module("model")
    # The author publishes a pickled complete nn.Module, not a state-dict-only
    # file. Only deserialize after verifying its pinned SHA-256 and source.
    model = torch.load(weights, map_location="cpu", weights_only=False)["model_state_dict"].eval()
    if model.data != "para" or sum(p.numel() for p in model.parameters()) != 21_538_185:
        raise RuntimeError("Unexpected Charm architecture or checkpoint")
    model.patch_embeddings.scales = 2  # Author inference package config_correction.
    return model, torch.load(position, map_location="cpu", weights_only=True).detach()


def bounded_image(image: Image.Image) -> Image.Image:
    image = image.convert("RGB")
    scale = min(1, 336 / max(image.size))
    size = (max(1, int(image.width * scale)), max(1, int(image.height * scale)))
    return image.resize(size, Image.Resampling.BILINEAR) if size != image.size else image


def tokens(image: Image.Image, position: torch.Tensor):
    """The author's normal_flow for <=1024 image patches; no spatial distortion."""
    rgb = np.asarray(bounded_image(image), dtype=np.float32) / 255
    h, w = rgb.shape[:2]
    rows, cols = (h + 13) // 14, (w + 13) // 14
    if rows * cols > 1024:
        raise ValueError("Charm mobile scorer accepts at most 1024 unpadded patches")
    value = torch.from_numpy(rgb).permute(2, 0, 1)
    value = F.pad(value, (0, cols * 14 - w, 0, rows * 14 - h))
    patches = value.unfold(1, 14, 14).unfold(2, 14, 14).permute(1, 2, 0, 3, 4).reshape(-1, 3 * 14 * 14)
    grid = position[:, 1:].reshape(1, 37, 37, 384).permute(0, 3, 1, 2)
    interpolated = F.interpolate(grid.float(), scale_factor=((rows + .1) / 37, (cols + .1) / 37),
                                 mode="bicubic", align_corners=False)
    if interpolated.shape[2:] != (rows, cols):
        raise RuntimeError("Position interpolation shape mismatch")
    positions = torch.cat((position[:, :1], interpolated.permute(0, 2, 3, 1).reshape(1, -1, 384)), 1)
    return patches.unsqueeze(0), positions


def author_tokens(cache: Path, image_path: Path):
    """Independent upstream tokenizer for export parity, not our own reference."""
    wheel = cache / "Charm_tokenizer-1.0.17-py3-none-any.whl"
    if not wheel.exists():
        info = json.load(urllib.request.urlopen("https://pypi.org/pypi/Charm-tokenizer/1.0.17/json"))
        url = next(row["url"] for row in info["urls"] if row["filename"].endswith(".whl"))
        verified_download(url, wheel, WHEEL_SHA256)
    else:
        verified_download("", wheel, WHEEL_SHA256)
    package = cache / "tokenizer"
    if not (package / "Charm_tokenizer/ImageProcessor.py").exists():
        with zipfile.ZipFile(wheel) as archive:
            archive.extractall(package)
    sys.path.insert(0, str(package.resolve()))
    processor = importlib.import_module("Charm_tokenizer.ImageProcessor")
    previous = processor.hf_hub_download
    processor.hf_hub_download = lambda **kw: str(cache / "dino_small_pos.pt")
    try:
        tokenizer = processor.Charm_Tokenizer(training_dataset="para", without_pad_or_dropping=True)
    finally:
        processor.hf_hub_download = previous
    bounded = cache / ("input-" + image_path.stem + ".png")
    bounded_image(Image.open(image_path)).save(bounded)
    return tokenizer.preprocess(str(bounded))


class MobileCharm(torch.nn.Module):
    """Algebraically identical patch projection, scale embedding and DINOv2 head.

    Inference only uses the author's normal_flow (all patches at one scale).
    NumPy tensor detaches in add_scale_embed become constant learned weights.
    """
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, patches, positions):
        emb = self.model.patch_embeddings
        value = F.linear(patches, emb.patch_embedder.weight.flatten(1), emb.patch_embedder.bias)
        value = value + emb.se[:, :1]
        value = torch.cat((emb.cls_token, value), dim=1) + positions
        value = self.model.encoder(value)
        return self.model.mlp_head(value)
