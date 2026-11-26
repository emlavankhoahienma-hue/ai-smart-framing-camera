"""Convert author SAMP-Net weights, rejecting numerical drift on real photographs."""
from __future__ import annotations

import argparse
import contextlib
import copy
import json
import math
import os
import platform
from pathlib import Path

os.environ["TQDM_DISABLE"] = "1"
os.environ["TQDM_MONITOR_INTERVAL"] = "0"

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from composition_model import (ExportModel, PAPER, REPOSITORY, REVISION,
                               WEIGHTS_SHA256, inputs, load_model)


class StaticSurround(torch.nn.Module):
    """The author's fixed 7x7 / 56x56 surround masks, without tensor mutation."""
    def __init__(self):
        super().__init__()
        for side, prefix in ((7, "feature"), (56, "saliency")):
            start, end = int(side / 2 - side / 4), int(side / 2 + side / 4)
            inside, outside = [], []
            for y in range(side):
                for x in range(side):
                    (inside if start <= x < end and start <= y < end else outside).append(y * side + x)
            self.register_buffer(prefix + "_inside", torch.tensor(inside), persistent=False)
            self.register_buffer(prefix + "_outside", torch.tensor(outside), persistent=False)

    def forward(self, features, saliency):
        features = features.flatten(2)
        inner = features.index_select(2, self.feature_inside).mean(2)
        outer = features.index_select(2, self.feature_outside).mean(2)
        feature = torch.stack((inner, outer), dim=2).unsqueeze(3)
        saliency = saliency.flatten(2)
        inner_saliency = saliency.index_select(2, self.saliency_inside).flatten(1)
        outer_saliency = saliency.index_select(2, self.saliency_outside).flatten(1)
        outer_saliency = outer_saliency.reshape(1, 784, 3).amax(2)
        return feature, torch.stack((inner_saliency, outer_saliency), dim=2).unsqueeze(3)


@contextlib.contextmanager
def fixed_shape_pooling():
    """Exact adaptive-max windows expressed using Core ML supported operators.

    PyTorch's adaptive-max tracer accepts neither all shape scalars nor every
    non-integral pooling ratio. These static gather/reduce windows preserve its
    floor(start)/ceil(end) definition, without changing any learned parameter.
    """
    functional = torch.nn.functional
    original1, original2 = functional.adaptive_max_pool1d, functional.adaptive_max_pool2d
    original_avg2 = functional.adaptive_avg_pool2d
    original_upper, original_lower = torch.triu_indices, torch.tril_indices

    def safe_avg2d(value, output_size):
        if output_size == (1, 1) or output_size == 1 or output_size == [1, 1]:
            return value.mean(dim=(-2, -1), keepdim=True)
        return original_avg2(value, output_size)

    def triangle(row, col, offset=0, dtype=torch.long, device=None, layout=torch.strided, *, upper):
        pairs = [(y, x) for y in range(int(row)) for x in range(int(col))
                 if (x - y >= int(offset) if upper else x - y <= int(offset))]
        return torch.tensor([[y for y, _ in pairs], [x for _, x in pairs]], dtype=dtype, device=device)

    def axis(value, dimension, target):
        source = int(value.shape[dimension])
        target = int(target)
        starts = [math.floor(i * source / target) for i in range(target)]
        ends = [math.ceil((i + 1) * source / target) for i in range(target)]
        span = max(end - start for start, end in zip(starts, ends))
        indices = torch.tensor([min(start + d, end - 1) for start, end in zip(starts, ends)
                                for d in range(span)], dtype=torch.long, device=value.device)
        gathered = torch.index_select(value, dimension, indices)
        shape = list(value.shape)
        shape[dimension:dimension + 1] = [target, span]
        return gathered.reshape(shape).amax(dimension + 1)

    def one(value, output_size, return_indices=False):
        if return_indices:
            raise ValueError("SAMP inference does not request pooling indices")
        return axis(value, 2, output_size)

    def two(value, output_size, return_indices=False):
        if return_indices:
            raise ValueError("SAMP inference does not request pooling indices")
        h, w = (output_size, output_size) if isinstance(output_size, int) else output_size
        return axis(axis(value, 2, h), 3, w)

    functional.adaptive_max_pool1d, functional.adaptive_max_pool2d = one, two
    functional.adaptive_avg_pool2d = safe_avg2d
    torch.triu_indices = lambda *a, **kw: triangle(*a, **kw, upper=True)
    torch.tril_indices = lambda *a, **kw: triangle(*a, **kw, upper=False)
    try:
        yield
    finally:
        functional.adaptive_max_pool1d, functional.adaptive_max_pool2d = original1, original2
        functional.adaptive_avg_pool2d = original_avg2
        torch.triu_indices, torch.tril_indices = original_upper, original_lower


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(".model-cache/samp"))
    parser.add_argument("--photos", type=Path)
    parser.add_argument("--skip-predict", action="store_true", help="Conversion inspection on non-macOS only")
    args = parser.parse_args()
    torch.set_num_threads(1)
    model = load_model(args.cache)
    portable_model = copy.deepcopy(model)
    portable_model.pattern_module.pool_list[4] = StaticSurround()
    wrapped = ExportModel(portable_model).eval()
    author_reference = ExportModel(model).eval()
    example = (torch.rand(1, 3, 224, 224), torch.rand(1, 1, 224, 224))
    with torch.inference_mode(), fixed_shape_pooling():
        traced = torch.jit.trace(wrapped, example, strict=True)
    # Validate the operator rewrite against the unmodified author implementation.
    with torch.inference_mode():
        for seed in range(4):
            torch.manual_seed(seed)
            sample = (torch.rand_like(example[0]), torch.rand_like(example[1]))
            if not torch.allclose(author_reference(*sample), traced(*sample), atol=1e-5, rtol=1e-4):
                raise RuntimeError("Static pooling rewrite changed the author network")
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 224, 224), dtype=np.float32),
                ct.TensorType(name="saliency", shape=(1, 1, 224, 224), dtype=np.float32)],
        outputs=[ct.TensorType(name="compositionDistribution", dtype=np.float32)])
    converted.author = "Bo Zhang, Li Niu, Liqing Zhang; Core ML conversion by this project"
    converted.license = "MIT; see SAMP-Net-LICENSE.txt"
    converted.short_description = "SAMP-Net, BMVC 2021, CADB expert image composition assessment (1 to 5)"
    converted.user_defined_metadata["paper"] = PAPER
    converted.user_defined_metadata["weightsSHA256"] = WEIGHTS_SHA256
    converted.save("SAMPComposition.mlpackage")
    manifest = {"model": "SAMP-Net", "paper": PAPER, "repository": REPOSITORY,
                "revision": REVISION, "weightsSHA256": WEIGHTS_SHA256,
                "trainingDataset": "CADB", "ratingScale": [1, 2, 3, 4, 5],
                "preprocessing": "RGB/ImageNet normalization + author spectral-residual saliency",
                "imageInput": "RGB float32 NCHW [0,1]; Pillow antialiased bilinear",
                "precision": "FP16", "minimumOS": "iOS 17", "parity": None}
    if not args.skip_predict:
        if platform.system() != "Darwin" or args.photos is None:
            raise RuntimeError("Release conversion requires Core ML prediction on real photos on macOS")
        photos = sorted(args.photos.glob("*.jpg"))[:24]
        if len(photos) < 24:
            raise RuntimeError("At least 24 real-photo conversion fixtures are required")
        errors = []
        references = []
        for photo in photos:
            image = Image.open(photo).convert("RGB")
            image_tensor, saliency = inputs(image)
            with torch.inference_mode(), fixed_shape_pooling():
                expected = model(image_tensor, saliency)[2].numpy().reshape(-1)
            rgb = np.asarray(image.resize((224, 224), Image.Resampling.BILINEAR), dtype=np.float32).transpose(2, 0, 1)[None] / 255
            actual = converted.predict({"image": rgb,
                                        "saliency": saliency.numpy()})["compositionDistribution"].reshape(-1)
            error = float(np.max(np.abs(expected - actual)))
            score_error = float(abs(np.dot(actual - expected, np.arange(1, 6))))
            if error > 0.02 or score_error > 0.04 or not np.isfinite(actual).all():
                raise RuntimeError(f"Core ML parity failed: {photo.name}, probability {error}, mean {score_error}")
            errors.append({"image": photo.name, "maxProbabilityError": error, "meanScoreError": score_error})
            saliency.numpy().astype("<f4").tofile(args.photos / f"{photo.stem}.saliency.f32")
            np.asarray(image.resize((224, 224), Image.Resampling.BILINEAR), dtype=np.uint8).tofile(args.photos / f"{photo.stem}.rgb.u8")
            references.append({"file": photo.name, "distribution": expected.tolist()})
        (args.photos / "parity-references.json").write_text(json.dumps(references, indent=2), encoding="utf-8")
        manifest["parity"] = {"images": len(errors), "maxProbabilityError": max(x["maxProbabilityError"] for x in errors),
                              "maxMeanScoreError": max(x["meanScoreError"] for x in errors), "details": errors}
        print(json.dumps(manifest["parity"], indent=2))
    Path("SAMPModelManifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
