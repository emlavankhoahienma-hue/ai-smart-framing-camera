"""Fetch and verify Apple's official Core ML DepthAnythingV2SmallF16 (pure FP16) model.

Pinned to Hugging Face revision cfef6f6f2a70783dedc0bfae40cecbc2052285d3 and
verified against weight.bin SHA-256 before compiling with xcrun coremlc.
Pure FP16 avoids INT8 weight-decompression MIL ops that cause +1.77 GB compiler
memory spikes on A12/4GB iOS 18 devices while providing higher numeric precision.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from huggingface_hub import snapshot_download


REPO = "apple/coreml-depth-anything-v2-small"
REVISION = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
PACKAGE_NAME = "DepthAnythingV2SmallF16.mlpackage"
WEIGHT_BIN_SHA256 = "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=PACKAGE_NAME)
    parser.add_argument("--manifest-out", default="DepthAnythingManifest.json")
    args = parser.parse_args()

    snap_dir = Path(
        snapshot_download(
            repo_id=REPO,
            revision=REVISION,
            allow_patterns=[f"{PACKAGE_NAME}/**"],
        )
    )
    src_pkg = snap_dir / PACKAGE_NAME
    weight_file = src_pkg / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    if not weight_file.is_file():
        raise RuntimeError(f"Missing weight.bin inside {src_pkg}")

    digest = hashlib.sha256(weight_file.read_bytes()).hexdigest()
    if digest != WEIGHT_BIN_SHA256:
        raise RuntimeError(f"DepthAnythingV2 weight.bin SHA256 mismatch: {digest} != {WEIGHT_BIN_SHA256}")

    dst_pkg = Path(args.output)
    if dst_pkg.exists():
        shutil.rmtree(dst_pkg)
    shutil.copytree(src_pkg, dst_pkg)

    Path(args.manifest_out).write_text(
        json.dumps(
            {
                "repository": REPO,
                "revision": REVISION,
                "packageName": PACKAGE_NAME,
                "weightsSHA256": WEIGHT_BIN_SHA256,
                "license": "Apache-2.0",
                "polarity": "higher_is_closer",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Fetched & verified {PACKAGE_NAME} ({weight_file.stat().st_size / (1024 * 1024):.1f} MB)")


if __name__ == "__main__":
    main()
