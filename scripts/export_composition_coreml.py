"""Convert author SAMP-Net weights, rejecting numerical drift on real photographs."""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import platform
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

from composition_model import (ExportModel, PAPER, REPOSITORY, REVISION,
                               WEIGHTS_SHA256, inputs, load_model)


@contextlib.contextmanager
def fixed_shape_pooling():
    """Exact adaptive-max windows expressed using Core ML supported operators.

    PyTorch's adaptive-max tracer accepts neither all shape scalars nor every
    non-integral pooling ratio. These static gather/reduce windows preserve its
    floor(start)/ceil(end) definition, without changing any learned parameter.
    """
    functional = torch.nn.functional
    original1, original2 = functional.adaptive_max_pool1d, functional.adaptive_max_pool2d

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
    try:
        yield
    finally:
        functional.adaptive_max_pool1d, functional.adaptive_max_pool2d = original1, original2


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(".model-cache/samp"))
    parser.add_argument("--photos", type=Path)
    parser.add_argument("--skip-predict", action="store_true", help="Conversion inspection on non-macOS only")
    args = parser.parse_args()
    torch.set_num_threads(2)
    model = load_model(args.cache)
    wrapped = ExportModel(model).eval()
    example = (torch.rand(1, 3, 224, 224), torch.rand(1, 1, 224, 224))
    with torch.inference_mode(), fixed_shape_pooling():
        traced = torch.jit.trace(wrapped, example, strict=True)
        traced = torch.jit.freeze(traced)
        torch._C._jit_pass_peephole(traced.graph, False)
        torch._C._jit_pass_constant_propagation(traced.graph)
    # Validate the operator rewrite against the unmodified author implementation.
    with torch.inference_mode():
        for seed in range(4):
            torch.manual_seed(seed)
            sample = (torch.rand_like(example[0]), torch.rand_like(example[1]))
            if not torch.allclose(wrapped(*sample), traced(*sample), atol=1e-5, rtol=1e-4):
                raise RuntimeError("Static pooling rewrite changed the author network")
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB),
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
                "precision": "FP16", "minimumOS": "iOS 17", "parity": None}
    if not args.skip_predict:
        if platform.system() != "Darwin" or args.photos is None:
            raise RuntimeError("Release conversion requires Core ML prediction on real photos on macOS")
        photos = sorted(args.photos.glob("*.jpg"))[:32]
        if len(photos) < 24:
            raise RuntimeError("At least 24 real-photo conversion fixtures are required")
        errors = []
        for photo in photos:
            image = Image.open(photo).convert("RGB")
            image_tensor, saliency = inputs(image)
            with torch.inference_mode():
                expected = model(image_tensor, saliency)[2].numpy().reshape(-1)
            actual = converted.predict({"image": image.resize((224, 224), Image.Resampling.BILINEAR),
                                        "saliency": saliency.numpy()})["compositionDistribution"].reshape(-1)
            error = float(np.max(np.abs(expected - actual)))
            score_error = float(abs(np.dot(actual - expected, np.arange(1, 6))))
            if error > 0.02 or score_error > 0.04 or not np.isfinite(actual).all():
                raise RuntimeError(f"Core ML parity failed: {photo.name}, probability {error}, mean {score_error}")
            errors.append({"image": photo.name, "maxProbabilityError": error, "meanScoreError": score_error})
        manifest["parity"] = {"images": len(errors), "maxProbabilityError": max(x["maxProbabilityError"] for x in errors),
                              "maxMeanScoreError": max(x["meanScoreError"] for x in errors), "details": errors}
        print(json.dumps(manifest["parity"], indent=2))
    Path("SAMPModelManifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
