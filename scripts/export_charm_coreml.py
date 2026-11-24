"""Export genuine 2025 Charm-PARA and verify author/Core ML photo parity."""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image

from charm_model import (HF_REVISION, PAPER, POSITION_SHA256, REVISION, WEIGHTS_SHA256,
                         MobileCharm, author_tokens, load_model, tokens)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(".model-cache/charm"))
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--inspect-only", action="store_true")
    args = parser.parse_args()
    torch.set_num_threads(1)
    author, position = load_model(args.cache)
    portable = MobileCharm(author).eval()
    photos = sorted(args.photos.glob("*.jpg"))[:24]
    if len(photos) < 24:
        raise RuntimeError("At least 24 held-out photo fixtures are required")
    examples, references = [], []
    with torch.inference_mode():
        for photo in photos:
            patches, positions = tokens(Image.open(photo), position)
            upstream, upstream_positions, mask = author_tokens(args.cache, photo)
            if not torch.equal(patches[0], upstream[1:].flatten(1)) or not torch.equal(positions[0], upstream_positions):
                raise RuntimeError(f"Tokenization differs from author: {photo}")
            expected = author(upstream[None], upstream_positions[None], mask[None]).numpy().reshape(-1)
            actual = portable(patches, positions).numpy().reshape(-1)
            if not np.allclose(expected, actual, atol=1e-5, rtol=1e-4):
                raise RuntimeError(f"Export operator rewrite differs from author: {photo}")
            examples.append((photo, patches, positions, expected))
        traced = torch.jit.trace(portable, examples[0][1:3], strict=True)
        for photo, patches, positions, expected in examples:
            if not np.allclose(traced(patches, positions).numpy().reshape(-1), expected, atol=1e-5, rtol=1e-4):
                raise RuntimeError(f"Trace does not support this sequence length: {photo}")
    patch_count = ct.RangeDim(lower_bound=1, upper_bound=1024, default=336)
    position_count = ct.RangeDim(lower_bound=2, upper_bound=1025, default=337)
    options = dict(inputs=[ct.TensorType(name="patches", shape=(1, patch_count, 588), dtype=np.float32),
                           ct.TensorType(name="positions", shape=(1, position_count, 384), dtype=np.float32)],
                   outputs=[ct.TensorType(name="aestheticDistribution", dtype=np.float32)],
                   minimum_deployment_target=ct.target.iOS17)
    if args.inspect_only:
        program = ct.convert(traced, convert_to="milinternal", **options)
        print(f"Verified {len(examples)} author photos; MIL operations: {len(program.functions['main'].operations)}")
        return
    if platform.system() != "Darwin":
        raise RuntimeError("Release export requires Core ML execution on macOS")
    fp16_converted = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, **options)
    scale = np.arange(1, 5.5, .5)

    for photo, patches, positions, expected in examples:
        references.append({"file": photo.name, "distribution": expected.tolist()})
        positions.numpy().astype("<f4").tofile(args.photos / (photo.stem + ".charm-position.f32"))

    def evaluate_charm_parity(candidate_model: ct.models.MLModel) -> tuple[bool, list[dict]]:
        errs = []
        ok = True
        for photo, patches, positions, expected in examples:
            actual = candidate_model.predict(
                {"patches": patches.numpy(), "positions": positions.numpy()}
            )["aestheticDistribution"].reshape(-1)
            probability_error = float(np.max(np.abs(actual - expected)))
            score_error = float(abs(np.dot(actual - expected, scale)))
            errs.append({"file": photo.name, "maxProbabilityError": probability_error, "meanScoreError": score_error})
            if not np.isfinite(actual).all() or probability_error > .02 or score_error > .04:
                ok = False
        return ok, errs

    converted = fp16_converted
    selected_precision = "FP16"
    errors = []
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
        passed, errs = evaluate_charm_parity(candidate)
        if passed:
            converted = candidate
            selected_precision = label
            errors = errs
            print(f"Charm-PARA {label} quantization passed 24-photo parity "
                  f"(maxProb={max(x['maxProbabilityError'] for x in errs):.4f}, "
                  f"maxMean={max(x['meanScoreError'] for x in errs):.4f})")
            break
        print(f"Charm-PARA {label} drifted on 24-photo parity "
              f"(maxProb={max(x['maxProbabilityError'] for x in errs):.4f}, "
              f"maxMean={max(x['meanScoreError'] for x in errs):.4f}), trying fallback")

    if selected_precision == "FP16":
        passed, errors = evaluate_charm_parity(converted)
        if not passed:
            worst = max(errors, key=lambda x: max(x["maxProbabilityError"], x["meanScoreError"]))
            raise RuntimeError(
                f"Charm Core ML parity failed: {worst['file']}, {worst['maxProbabilityError']}, {worst['meanScoreError']}"
            )

    converted.author = "Fatemeh Behrad et al.; author Charm-PARA checkpoint"
    converted.license = "Apache-2.0; see Charm-LICENSE.txt"
    converted.short_description = "Charm (2025), DINOv2-small, pretrained PARA photographic aesthetics"
    converted.user_defined_metadata["paper"] = PAPER
    converted.user_defined_metadata["weightsSHA256"] = WEIGHTS_SHA256
    converted.save("CharmAesthetics.mlpackage")
    position_data = position.numpy().astype("<f4").tobytes()
    Path("CharmPositionEmbedding.bin").write_bytes(position_data)
    (args.photos / "charm-references.json").write_text(json.dumps(references, indent=2), encoding="utf-8")
    manifest = {"model": "Charm-PARA", "paper": PAPER, "year": 2025,
        "repository": "https://github.com/FBehrad/Charm", "revision": REVISION,
        "checkpointRevision": HF_REVISION, "weightsSHA256": WEIGHTS_SHA256,
        "positionSourceSHA256": POSITION_SHA256, "positionBinarySHA256": hashlib.sha256(position_data).hexdigest(),
        "parameters": 21_538_185, "trainingDataset": "PARA", "ratingScale": scale.tolist(),
        "inputProfile": "Pillow bilinear <=336 long edge; author normal_flow; RGB [0,1]; zero-pad right/bottom to 14; no token dropping; <=1024 patches",
        "precision": selected_precision, "parity": {"images": len(errors),
            "maxMeanScoreError": max(x["meanScoreError"] for x in errors), "details": errors}}
    Path("CharmModelManifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
