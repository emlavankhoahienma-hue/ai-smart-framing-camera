"""Run the production Swift crop wrapper on parity photos and human crop votes."""
from pathlib import Path
import hashlib
import json
import subprocess
import urllib.request

root = Path(__file__).resolve().parents[1]
output = root / "validation/focal"
output.mkdir(parents=True, exist_ok=True)
fixtures = json.loads((output / "pytorch-parity.json").read_text())
for row in fixtures:
    row["file"] = str(root / "validation/photos/source" / row["file"])
    row["inputTensor"] = str(output / row["inputTensor"])
baseline_path = root / "docs/evaluation/fcdb-crop-preferences-300.json"
baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
annotations = root / ".model-cache/crop-preferences/ranking_annotation.json"
annotations.parent.mkdir(parents=True, exist_ok=True)
if not annotations.exists():
    url = f"https://raw.githubusercontent.com/yiling-chen/flickr-cropping-dataset/{baseline['revision']}/ranking_annotation.json"
    annotations.write_bytes(urllib.request.urlopen(url, timeout=60).read())
assert hashlib.sha256(annotations.read_bytes()).hexdigest() == baseline["annotationSHA256"]
author = {row["flickr_photo_id"]: row for row in json.loads(annotations.read_text())}
groups = {}
for row in baseline["records"]:
    groups.setdefault(row["id"], []).append(row)


def prepare(item):
    key, rows = item
    path = root / "tests/fixtures/fcdb" / f"{key}.jpg"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == rows[0]["sourceSHA256"], key
    from PIL import Image
    with Image.open(path) as image:
        width, height = image.size
    boxes = []
    for row in rows:
        votes = next(pair for pair in author[key]["crops"] if pair["crop_0"] == row["crop0"] and pair["crop_1"] == row["crop1"])
        assert votes["vote_for_0"] == row["votes0"] and votes["vote_for_1"] == row["votes1"]
        for index in [0, 1]:
            x, y, w, h = row[f"crop{index}"]
            boxes.append([x / width, y / height, (x + w) / width, (y + h) / height])
    return dict(file=str(path), regions=boxes), rows


pairs = [prepare(item) for item in groups.items()]
fixtures.extend(fixture for fixture, _ in pairs)
assert len(pairs) == 30 and sum(len(rows) for _, rows in pairs) == 300
fixture_path = output / "native-input.json"
fixture_path.write_text(json.dumps(fixtures), encoding="utf-8")
files = ["TrackingGeometry.swift", "CompositionPlanning.swift", "CompositionImageEvidence.swift",
         "PhotographicCompositionModel.swift", "FocalCropModel.swift"]
executable = output / "focal-validation"
subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors",
    *[str(root / "AISmartFramingCamera/Services" / name) for name in files],
    str(root / "tests/FocalModelValidation.swift"), "-o", str(executable)], check=True)
result_path = output / "swift-predictions.json"
subprocess.run([str(executable), str(root / "FocalCrop.mlmodelc"), str(fixture_path), str(result_path)], check=True)
results = json.loads(result_path.read_text())
parity = results[:32]
import numpy as np
import torch
from export_focal_coreml import load_reference

torch.set_num_threads(2)
reference, _ = load_reference()
for row in parity:
    tensor = np.fromfile(row["nativeInputTensor"], dtype="<f4").reshape(1, 3, 256, 256)
    boxes = np.asarray(row["nativeBoxes"], dtype=np.float32).reshape(1, 128, 4)
    content = np.asarray(row["nativeContent"], dtype=np.float32).reshape(1, 4)
    with torch.inference_mode():
        importance, scores = reference(torch.from_numpy(tensor), torch.from_numpy(boxes), torch.from_numpy(content))
    row["sameTensorPreferenceError"] = float(np.max(np.abs(scores.numpy()[0, :len(row["preferences"])] - row["preferences"])))
    row["sameTensorImportanceError"] = float(np.max(np.abs(importance.numpy().flatten() - row["importance"])))
result_path.write_text(json.dumps(results), encoding="utf-8")
correct = strong = strong_pairs = 0
records = []
for result, (_, rows) in zip(results[32:], pairs, strict=True):
    scores = result["preferences"]
    for index, row in enumerate(rows):
        ok = (scores[index * 2] > scores[index * 2 + 1]) == (row["votes0"] > row["votes1"])
        correct += ok
        if abs(row["votes0"] - row["votes1"]) >= 3:
            strong_pairs += 1
            strong += ok
        records.append(dict(row, cropScore0=scores[index * 2], cropScore1=scores[index * 2 + 1], correct=ok))
report = dict(model="Released Appwrite FocalNet; production Swift/Core ML inputs",
    photos=30, pairs=300, correct=correct, accuracy=correct / 300,
    strongPairs=strong_pairs, strongCorrect=strong, priorCombined=baseline["metrics"]["combined"],
    scope="Same published FCDB crop-pair votes; training overlap is not established; no camera or phone performance measurement",
    records=records)
(output / "fcdb-human-preferences.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
manifest_path = root / "FocalModelManifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["photoDecoderComparison"] = dict(images=len(parity),
    scope="Same JPEG bytes decoded independently by Pillow and ImageIO/Core Image; normalized input and resulting output differences",
    maxPreferenceError=max(row["maxPreferenceError"] for row in parity),
    maxImportanceError=max(row["maxImportanceError"] for row in parity),
    maxImportanceMAE=max(row["importanceMAE"] for row in parity),
    maxInputMAE=max(row["inputMAE"] for row in parity),
    maxInputError=max(row["maxInputError"] for row in parity))
manifest["swiftParity"] = dict(images=len(parity),
    scope="Exact image, boxes and content tensors used by production Swift Core ML replayed in the pinned author PyTorch network",
    maxPreferenceError=max(row["sameTensorPreferenceError"] for row in parity),
    maxImportanceError=max(row["sameTensorImportanceError"] for row in parity))
manifest["humanPreferences"] = {key: value for key, value in report.items() if key != "records"}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(json.dumps({"parity": manifest["swiftParity"], "photoDecoding": manifest["photoDecoderComparison"], "humanPreferenceCorrect": correct, "pairs": 300}))
if report["accuracy"] < 0.68:
    raise RuntimeError(f"Crop preference quality regressed: {correct}/300")
if manifest["swiftParity"]["maxPreferenceError"] >= 0.002 or manifest["swiftParity"]["maxImportanceError"] >= 0.001:
    raise RuntimeError(f"Swift crop preprocessing parity failed: {manifest['swiftParity']}")
if manifest["photoDecoderComparison"]["maxInputMAE"] >= 0.01 or manifest["photoDecoderComparison"]["maxInputError"] >= 0.04:
    raise RuntimeError(f"Native photo input contract failed: {manifest['photoDecoderComparison']}")
