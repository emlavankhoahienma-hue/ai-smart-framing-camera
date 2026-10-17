"""Pinned, author-released SAMP-Net; shared by conversion and photo evaluation.

The upstream MIT implementation is loaded without its training-directory assertion.
No weights are trained, substituted, or partially loaded here.
"""
from __future__ import annotations

import hashlib
import importlib.util
import sys
import types
import urllib.request
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image
from torchvision.transforms import functional as TF

REPOSITORY = "bcmi/Image-Composition-Assessment-Dataset-CADB"
REVISION = "b8f80be379d4a4caf9d045db3187cb60bcaca583"
PAPER = "https://arxiv.org/abs/2104.03133"
WEIGHTS_URL = ("https://www.dropbox.com/scl/fi/k1yuyhotuk9ky3m41iobg/samp_net.pth"
               "?rlkey=aoqqxv27wd5qqj3pytxki6vi3&dl=1")
WEIGHTS_SHA256 = "d3d02f36967734fd6f0d2770380a04b777b5cd800a9ba68d4ccc9656f6fef603"
SOURCE_HASHES = {
    "samp_net.py": "d5733316bfa8e6a31d5bb6f8ac42c0ddaa4601334a0fc2875b15d070a1c3401c",
    "samp_module.py": "9ef05c2769e5b380da24ffd8bc24107cb4ad59442403781bbbac4e97519609f2",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_download(url: str, destination: Path, digest: str) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists() or sha256(destination) != digest:
        temporary = destination.with_suffix(destination.suffix + ".download")
        urllib.request.urlretrieve(url, temporary)
        if sha256(temporary) != digest:
            raise RuntimeError(f"Checksum mismatch for {destination.name}")
        temporary.replace(destination)
    return destination


def load_model(cache: Path) -> torch.nn.Module:
    for name, digest in SOURCE_HASHES.items():
        verified_download(f"https://raw.githubusercontent.com/{REPOSITORY}/{REVISION}/SAMPNet/{name}",
                          cache / name, digest)
    weights = verified_download(WEIGHTS_URL, cache / "samp_net.pth", WEIGHTS_SHA256)
    configuration = types.ModuleType("config")
    configuration.Config = type("Config", (), {})
    previous = sys.modules.get("config")
    sys.modules["config"] = configuration
    try:
        for name in ("samp_module", "samp_net"):
            spec = importlib.util.spec_from_file_location(name, cache / f"{name}.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
        cfg = types.SimpleNamespace(
            score_level=5, resnet_layers=18, dropout=0.5, num_attributes=6,
            pool_dropout=0.5, pattern_list=list(range(1, 9)), pattern_fuse="sum",
            use_weighted_loss=True, use_attribute=True, use_channel_attention=True,
            use_saliency=True, use_multipattern=True, use_pattern_weight=True)
        model = sys.modules["samp_net"].SAMPNet(cfg, pretrained=False)
        model.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True), strict=True)
        return model.eval()
    finally:
        if previous is None:
            sys.modules.pop("config", None)
        else:
            sys.modules["config"] = previous


def spectral_saliency(rgb: np.ndarray) -> np.ndarray:
    """Author preprocessing, including its 95th-percentile clipping convention."""
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    height, width = gray.shape
    small = cv2.resize(gray, (max(1, width // 6), max(1, height // 6)), interpolation=cv2.INTER_AREA)
    spectrum = np.fft.fft2(small)
    phase = np.angle(spectrum)
    log_amplitude = np.log(np.abs(spectrum) + 0.000001)
    residual = log_amplitude - cv2.blur(log_amplitude, (3, 3))
    reconstructed = np.exp(residual) * (np.cos(phase) + 1j * np.sin(phase))
    saliency = np.abs(np.fft.ifft2(reconstructed)) ** 2
    saliency = cv2.GaussianBlur(saliency, (9, 9), 2.5)
    saliency = cv2.resize(saliency, (224, 224), interpolation=cv2.INTER_LINEAR)
    threshold = np.quantile(saliency.reshape(-1), 0.95)
    if threshold > 0:
        saliency = (np.minimum(saliency, threshold) - saliency.min()) / threshold
    return saliency.astype(np.float32)


def inputs(image: Image.Image) -> tuple[torch.Tensor, torch.Tensor]:
    image = image.convert("RGB")
    tensor = TF.to_tensor(TF.resize(image, [224, 224]))
    tensor = TF.normalize(tensor, [0.485, 0.456, 0.406], [0.229, 0.224, 0.225])
    saliency = torch.from_numpy(spectral_saliency(np.asarray(image))).unsqueeze(0)
    return tensor.unsqueeze(0), saliency.unsqueeze(0)


class ExportModel(torch.nn.Module):
    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).reshape(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).reshape(1, 3, 1, 1))

    def forward(self, image: torch.Tensor, saliency: torch.Tensor) -> torch.Tensor:
        return self.model((image - self.mean) / self.std, saliency)[2]
