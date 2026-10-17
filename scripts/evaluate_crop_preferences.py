"""Compare real model crop preferences with published FCDB human pair votes.

This measures the learned scorers, not the camera planner, tracking, or FPS.
Selection is fixed by photo-id hashes before downloading or scoring any image.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request

import numpy as np
from PIL import Image
import torch

import charm_model
import composition_model

REVISION = "546a02124e137be508d52104c667cab05e3aae48"
ANNOTATIONS = f"https://raw.githubusercontent.com/yiling-chen/flickr-cropping-dataset/{REVISION}/ranking_annotation.json"


def bounded(image):
    image = image.convert("RGB")
    if max(image.size) > 288:
        ratio = 288 / max(image.size)
        image = image.resize((max(1, int(image.width * ratio)), max(1, int(image.height * ratio))), Image.Resampling.BILINEAR)
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(".model-cache/crop-preferences"))
    parser.add_argument("--samp-cache", type=Path, default=Path(".model-cache/samp"))
    parser.add_argument("--charm-cache", type=Path, default=Path(".model-cache/charm"))
    parser.add_argument("--photos", type=int, default=32)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    annotation_file = args.cache / "ranking_annotation.json"
    if not annotation_file.exists():
        annotation_file.write_bytes(urllib.request.urlopen(ANNOTATIONS, timeout=30).read())
    rows = json.loads(annotation_file.read_text())
    rows.sort(key=lambda row: hashlib.sha256(str(row["flickr_photo_id"]).encode()).hexdigest())
    selected = rows[:args.photos]

    def download(row):
        path = args.cache / f"{row['flickr_photo_id']}.jpg"
        try:
            if not path.exists():
                path.write_bytes(urllib.request.urlopen(row["url"], timeout=20).read())
            image = Image.open(path).convert("RGB")
            for pair in row["crops"]:
                for key in ("crop_0", "crop_1"):
                    x, y, w, h = pair[key]  # Dataset windows: left, top, width, height.
                    if min(x, y) < 0 or min(w, h) <= 0 or x + w > image.width or y + h > image.height:
                        raise ValueError("Annotation/image coordinates do not agree")
            return row, path, None
        except Exception as error:
            return row, path, str(error)

    with ThreadPoolExecutor(max_workers=6) as pool:
        downloads = list(pool.map(download, selected))
    failures = [{"id": row["flickr_photo_id"], "url": row["url"], "error": error}
                for row, _, error in downloads if error]
    if len(downloads) - len(failures) < 24:
        raise RuntimeError(f"Too few valid source photographs: {failures}")
    torch.set_num_threads(2)
    samp = composition_model.load_model(args.samp_cache)
    author, position = charm_model.load_model(args.charm_cache)
    modern = charm_model.MobileCharm(author).eval()
    records = []
    started = time.monotonic()
    with torch.inference_mode():
        for row, path, error in downloads:
            if error:
                continue
            image = Image.open(path).convert("RGB")
            scores = {}
            for pair in row["crops"]:
                for key in ("crop_0", "crop_1"):
                    crop = tuple(pair[key])
                    if crop not in scores:
                        x, y, w, h = crop
                        preview = bounded(image.crop((x, y, x + w, y + h)))
                        a = samp(*composition_model.inputs(preview))[2].numpy().reshape(-1)
                        b = modern(*charm_model.tokens(preview, position)).numpy().reshape(-1)
                        composition = float(np.dot(a, np.arange(1, 6)))
                        aesthetic = float(np.dot(b, np.arange(1, 5.5, .5)))
                        scores[crop] = {"samp": composition, "charm": aesthetic,
                                        "combined": .45 * (composition - 1) / 4 + .40 * (aesthetic - 1) / 4}
                first, second = scores[tuple(pair["crop_0"])], scores[tuple(pair["crop_1"])]
                records.append({"id": row["flickr_photo_id"], "sourceURL": row["url"],
                    "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "crop0": pair["crop_0"], "crop1": pair["crop_1"],
                    "votes0": pair["vote_for_0"], "votes1": pair["vote_for_1"], "scores0": first, "scores1": second})
            print(f"Human crop preferences: {len(records)} pairs from {row['flickr_photo_id']}", flush=True)

    def metrics(items):
        result = {}
        for name in ("samp", "charm", "combined"):
            correct = sum((r["scores1"][name] > r["scores0"][name]) == (r["votes1"] > r["votes0"]) for r in items)
            result[name] = {"correct": correct, "pairs": len(items), "accuracy": correct / len(items) if items else None}
        return result

    report = {"dataset": "FCDB published crop-pair ranking annotations", "revision": REVISION,
        "annotationSHA256": hashlib.sha256(annotation_file.read_bytes()).hexdigest(),
        "selection": "First photo ids by SHA256; selected before predictions; unavailable images are reported, not replaced",
        "requestedPhotos": args.photos, "availablePhotos": len(downloads) - len(failures), "failedDownloads": failures,
        "scope": "Learned scorer preference versus human votes; no planner geometry, camera integration or device performance",
        "models": {"samp": composition_model.WEIGHTS_SHA256, "charm": charm_model.WEIGHTS_SHA256},
        "metrics": metrics(records),
        "strongConsensus": metrics([r for r in records if max(r["votes0"], r["votes1"]) >= 4]),
        "secondsCPU": time.monotonic() - started, "records": records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("availablePhotos", "metrics", "strongConsensus")}, indent=2))


if __name__ == "__main__":
    main()
