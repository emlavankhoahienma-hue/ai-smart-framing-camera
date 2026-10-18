"""Evaluate saved production Core ML predictions against author COCO boxes.

These are fixed-subset, class-aware IoU=0.50 metrics at the app's 0.45 score
threshold and photographic size filters. They are not official full-COCO AP.
"""
from __future__ import annotations

import json
import math
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANIMALS = {16, 17, 18, 19, 20, 21, 22, 23, 24, 25}


def group(category: int) -> str:
    return "people" if category == 1 else "animals" if category in ANIMALS else "objects"


def overlap(first: list[float], second: list[float], crowd: bool = False) -> float:
    ax, ay, aw, ah = first
    bx, by, bw, bh = second
    intersection = max(0.0, min(ax + aw, bx + bw) - max(ax, bx)) * max(0.0, min(ay + ah, by + bh) - max(ay, by))
    denominator = aw * ah if crowd else aw * ah + bw * bh - intersection
    return intersection / denominator if denominator > 0 else 0.0


def eligible(box: list[float]) -> bool:
    _, _, width, height = box
    return 0.04 <= width <= 0.95 and 0.04 <= height <= 0.95 and 0.15 <= width / height <= 6.5


def metrics(decisions: list[tuple[float, bool]], count: int) -> dict:
    ordered = sorted(decisions, key=lambda item: -item[0])
    true_positive = 0
    precisions, recalls = [], []
    for index, (_, matched) in enumerate(ordered, 1):
        true_positive += int(matched)
        precisions.append(true_positive / index)
        recalls.append(true_positive / count if count else 0.0)
    ap = None
    if count:
        envelope = 0.0
        for index in range(len(precisions) - 1, -1, -1):
            envelope = max(envelope, precisions[index])
            precisions[index] = envelope
        # The COCO-style 101-point interpolation is used at a single IoU;
        # predictions below the app's confidence threshold were never retained.
        ap = sum(max((p for p, r in zip(precisions, recalls) if r + 1e-12 >= step / 100), default=0.0)
                 for step in range(101)) / 101
    return {"groundTruth": count, "predictions": len(ordered), "truePositives": true_positive,
            "falsePositives": len(ordered) - true_positive, "falseNegatives": count - true_positive,
            "precision": true_positive / len(ordered) if ordered else 0.0,
            "recall": true_positive / count if count else None,
            "AP50_retainedPredictions": ap}


def evaluate(truth: dict, predictions: dict, restrict: bool) -> dict:
    by_name = {image["file_name"]: image for image in truth["images"]}
    if {row["file"] for row in predictions["records"]} != set(by_name):
        raise RuntimeError("Native predictions do not cover exactly the frozen COCO images")
    boxes = defaultdict(list)
    counts = defaultdict(int)
    for annotation in truth["annotations"]:
        image = next(image for image in truth["images"] if image["id"] == annotation["image_id"])
        raw = annotation["bbox"]
        box = [raw[0] / image["width"], raw[1] / image["height"], raw[2] / image["width"], raw[3] / image["height"]]
        ignored = bool(annotation.get("iscrowd", 0)) or (restrict and not eligible(box))
        boxes[image["id"]].append({"id": annotation["id"], "classID": annotation["category_id"],
                                    "box": box, "ignored": ignored, "crowd": bool(annotation.get("iscrowd", 0))})
        if not ignored:
            counts[annotation["category_id"]] += 1
    decisions = defaultdict(list)
    matched_rows = []
    ignored_predictions = 0
    for record in predictions["records"]:
        image = by_name[record["file"]]
        used = set()
        for prediction in sorted(record["detections"], key=lambda item: -item["confidence"]):
            category, score, box = prediction["classID"], prediction["confidence"], prediction["box"]
            if not all(math.isfinite(value) for value in [score, *box]) or len(box) != 4:
                raise RuntimeError("Non-finite native detection")
            targets = [item for item in boxes[image["id"]] if item["classID"] == category]
            available = [item for item in targets if not item["ignored"] and item["id"] not in used]
            best = max(available, key=lambda item: overlap(box, item["box"]), default=None)
            matched = best is not None and overlap(box, best["box"]) >= 0.5
            if matched:
                used.add(best["id"])
            elif any(item["ignored"] and overlap(box, item["box"], crowd=item["crowd"]) >= 0.5 for item in targets):
                ignored_predictions += 1
                continue
            decisions[category].append((score, matched))
            matched_rows.append({"file": record["file"], "classID": category, "confidence": score,
                                 "matched": matched, "box": box,
                                 "matchedAnnotation": best["id"] if matched else None})
    classes = {str(item["id"]): {"name": item["name"], **metrics(decisions[item["id"]], counts[item["id"]])}
               for item in truth["categories"]}
    groups = {}
    for name in ("people", "animals", "objects"):
        identifiers = [item["id"] for item in truth["categories"] if group(item["id"]) == name]
        groups[name] = metrics([row for identifier in identifiers for row in decisions[identifier]],
                               sum(counts[identifier] for identifier in identifiers))
    present = [item["AP50_retainedPredictions"] for item in classes.values() if item["groundTruth"]]
    return {"macroClassAP50_retainedPredictions": sum(present) / len(present) if present else None, "groups": groups,
            "perClass": classes, "ignoredPredictions": ignored_predictions, "matching": matched_rows}


def render_review(truth: dict, predictions: dict[str, dict], directory: Path) -> None:
    from PIL import Image, ImageDraw, ImageOps

    destination = directory / "review"
    destination.mkdir(exist_ok=True)
    categories = {item["id"]: item["name"] for item in truth["categories"]}
    annotations = defaultdict(list)
    for item in truth["annotations"]:
        if not item.get("iscrowd", 0):
            annotations[item["image_id"]].append(item)
    outputs = {name: {row["file"]: row["detections"] for row in report["records"]}
               for name, report in predictions.items()}
    for offset in range(0, len(truth["images"]), 6):
        rows = truth["images"][offset:offset + 6]
        sheet = Image.new("RGB", (960, 260 * len(rows)), "#101215")
        for row_index, image in enumerate(rows):
            with Image.open(directory / "coco/photos" / image["file_name"]) as source:
                original = source.convert("RGB")
            preview = ImageOps.contain(original, (320, 224), Image.Resampling.LANCZOS)
            for column, name in enumerate(("author GT", "yolo12s", "yolo26s")):
                panel = Image.new("RGB", (320, 260), "#101215")
                x, y = (320 - preview.width) // 2, 30 + (224 - preview.height) // 2
                panel.paste(preview, (x, y))
                draw = ImageDraw.Draw(panel)
                draw.text((5, 7), image["file_name"] + " | " + name, fill="white")
                if name == "author GT":
                    boxes = [{"classID": item["category_id"], "box": [item["bbox"][0] / image["width"],
                        item["bbox"][1] / image["height"], item["bbox"][2] / image["width"],
                        item["bbox"][3] / image["height"]]} for item in annotations[image["id"]]]
                else:
                    boxes = outputs[name][image["file_name"]]
                for box in boxes:
                    left, top, width, height = box["box"]
                    coordinates = (x + left * preview.width, y + top * preview.height,
                                   x + (left + width) * preview.width, y + (top + height) * preview.height)
                    color = "#ffd666" if name == "author GT" else "#73d6ff"
                    draw.rectangle(coordinates, outline=color, width=2)
                    text = categories[box["classID"]]
                    if "confidence" in box:
                        text += f" {box['confidence']:.2f}"
                    draw.text((coordinates[0] + 2, max(28, coordinates[1] - 11)), text, fill=color,
                              stroke_width=1, stroke_fill="black")
                sheet.paste(panel, (column * 320, row_index * 260))
        sheet.save(destination / f"coco-{offset // 6 + 1:02d}.jpg", quality=93)


def main() -> dict:
    directory = ROOT / "validation/detection"
    truth = json.loads((directory / "coco/ground-truth.json").read_text(encoding="utf-8"))
    result = {"dataset": truth["dataset"], "images": len(truth["images"]),
              "annotationSHA256": truth["annotationSHA256"],
              "scope": "Fixed COCO val2017 subset; production Swift/Core ML predictions, confidence >=0.45, class-aware IoU >=0.50. 101-point interpolated AP of retained predictions only, not official full-COCO AP. No iPhone latency or memory claim.",
              "models": {}}
    native_predictions = {}
    for name in ("yolo12s", "yolo26s"):
        predictions = json.loads((directory / f"{name}-coco-predictions.json").read_text(encoding="utf-8"))
        native_predictions[name] = predictions
        result["models"][name] = {
            "allNonCrowdAuthorBoxes": evaluate(truth, predictions, False),
            "photographicSizeEligibleAuthorBoxes": evaluate(truth, predictions, True),
        }
    (directory / "coco-comparison.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    render_review(truth, native_predictions, directory)
    for name, report in result["models"].items():
        for scope, scores in report.items():
            print(name, scope, json.dumps({"AP50_retainedPredictions": scores["macroClassAP50_retainedPredictions"],
                                          "groups": scores["groups"]}))
    return result


if __name__ == "__main__":
    main()
