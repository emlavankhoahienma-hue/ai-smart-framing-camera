"""Reproducible expert-rating evaluation; crop preferences are not human ground truth."""
from __future__ import annotations

import argparse
import io
import json
import time
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw
from scipy.stats import spearmanr

from composition_model import WEIGHTS_SHA256, inputs, load_model, sha256
from prepare_composition_photos import DATA_SHA256, DATA_URL


def metrics(rows: list[dict]) -> dict:
    target = [row["humanMean"] for row in rows]
    predicted = [row["predictedMean"] for row in rows]
    return {"images": len(rows), "spearman": float(spearmanr(target, predicted).statistic),
            "pearson": float(np.corrcoef(target, predicted)[0, 1]),
            "mae": float(np.abs(np.array(target) - predicted).mean())}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--crop-only", action="store_true", help="Resume crop diagnostics after a completed expert-rating run")
    args = parser.parse_args()
    if sha256(args.archive) != DATA_SHA256:
        raise RuntimeError("Evaluation archive does not match the author dataset")
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(2)
    model = load_model(args.cache)
    records = []
    started = time.perf_counter()
    with zipfile.ZipFile(args.archive) as archive, torch.inference_mode():
        prefix = "CADB_Dataset/"
        split = json.loads(archive.read(prefix + "split.json"))
        scenes = json.loads(archive.read(prefix + "scene_categories.json"))
        scores = json.loads(archive.read(prefix + "composition_scores.json"))
        # Every image in the author's test split, in filename order.
        for name in ([] if args.crop_only else sorted(split["test"])):
            image = Image.open(io.BytesIO(archive.read(prefix + "images/" + name))).convert("RGB")
            distribution = model(*inputs(image))[2].numpy().reshape(-1)
            mean = float(np.dot(distribution, np.arange(1, 6)))
            if not np.isfinite(mean):
                raise RuntimeError(f"Non-finite composition score: {name}")
            records.append({"file": name, "scene": scenes[name], "humanMean": scores[name]["mean"],
                            "predictedMean": mean, "distribution": distribution.tolist()})
            if len(records) % 50 == 0:
                print(f"Expert-rating test: {len(records)}/{len(split['test'])}", flush=True)
    by_scene = defaultdict(list)
    for row in records:
        by_scene[row["scene"]].append(row)
    report = {"model": "SAMP-Net, author checkpoint", "weightsSHA256": WEIGHTS_SHA256,
              "datasetSource": DATA_URL, "archiveSHA256": DATA_SHA256,
              "split": "CADB official test; not used to tune this app", "metrics": metrics(records) if records else {},
              "scenes": {scene: metrics(rows) for scene, rows in sorted(by_scene.items())},
              "secondsCPU": time.perf_counter() - started,
              "scope": "Expert scores assess whole-image composition. This is not a human preference test of app crops.",
              "records": records}
    if args.crop_only:
        report = json.loads((args.output / "expert-ratings.json").read_text())
        if report["weightsSHA256"] != WEIGHTS_SHA256 or report["metrics"]["images"] != len(split["test"]):
            raise RuntimeError("Cannot resume mismatched expert-rating evidence")
    else:
        (args.output / "expert-ratings.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({"metrics": report["metrics"], "scenes": report["scenes"]}, indent=2), flush=True)
    # A broad model-preference diagnostic, with the original always a candidate.
    # No fabricated human labels or claim that maximizing this score proves beauty.
    fixtures = json.loads((args.photos / "manifest.json").read_text())["images"]
    crop_records = []
    sheets = []
    with torch.inference_mode():
        for index, fixture in enumerate(fixtures):
            image = Image.open(args.photos / "source" / fixture["file"]).convert("RGB")
            preview_size = (round(image.width * 288 / image.height), 288)
            boxes = [(0, 0, image.width, image.height)]
            for scale in (0.9, 0.8, 0.7):
                width, height = round(image.width * scale), round(image.height * scale)
                for y in (0, 0.5, 1):
                    for x in (0, 0.5, 1):
                        left, top = round((image.width - width) * x), round((image.height - height) * y)
                        boxes.append((left, top, left + width, top + height))
            means = []
            for offset in range(0, len(boxes), 4):
                batch = [inputs(image.crop(box).resize(preview_size, Image.Resampling.BILINEAR))
                         for box in boxes[offset:offset + 4]]
                distributions = model(torch.cat([pair[0] for pair in batch]),
                                      torch.cat([pair[1] for pair in batch]))[2].numpy()
                means.extend((distributions @ np.arange(1, 6)).tolist())
            best = int(np.argmax(means))
            crop_records.append({"file": fixture["file"], "scene": fixture["scene"],
                                 "candidates": len(boxes), "originalScore": means[0],
                                 "preferredScore": means[best], "preferredBox": boxes[best],
                                 "warning": "Unconstrained crop diagnostic; app separately protects detected people and faces"})
            if index % 10 == 0:
                print(f"Crop diagnostic: {index + 1}/{len(fixtures)}", flush=True)
            if index < 40:
                panel = Image.new("RGB", (480, 205), "#17191d")
                for column, view in enumerate([image, image.crop(boxes[best])]):
                    view.thumbnail((230, 170))
                    panel.paste(view, (column * 240 + (230 - view.width) // 2, 25))
                draw = ImageDraw.Draw(panel)
                draw.text((8, 5), f"{fixture['file']} {fixture['scene']} original {means[0]:.2f}", fill="white")
                draw.text((248, 5), f"Model preference {means[best]:.2f}", fill="white")
                sheets.append(panel)
    for page in range((len(sheets) + 7) // 8):
        panels = sheets[page * 8:(page + 1) * 8]
        sheet = Image.new("RGB", (960, 205 * 4), "#17191d")
        for i, panel in enumerate(panels):
            sheet.paste(panel, ((i % 2) * 480, (i // 2) * 205))
        sheet.save(args.output / f"model-preference-diagnostic-{page + 1}.jpg", quality=90)
    (args.output / "crop-diagnostics.json").write_text(json.dumps({
        "images": len(crop_records), "crops": sum(r["candidates"] for r in crop_records),
        "input": "Crops sampled from original full-resolution source; resize after cropping",
        "scope": "Model preferences only; production crop safety is tested separately", "records": crop_records}, indent=2), encoding="utf-8")
    if report["metrics"]["spearman"] < 0.45:
        raise RuntimeError("Author test-split correlation is unexpectedly weak; do not ship this conversion")


if __name__ == "__main__":
    main()
