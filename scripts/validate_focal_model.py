"""Run the production Swift crop wrapper on parity photos and human crop votes."""
from pathlib import Path
import hashlib
import json
import subprocess
import urllib.request
from concurrent.futures import ThreadPoolExecutor

root = Path(__file__).resolve().parents[1]
output = root / "validation/focal"
output.mkdir(parents=True, exist_ok=True)
fixtures = json.loads((output / "pytorch-parity.json").read_text())
for row in fixtures:
    row["file"] = str(root / "validation/photos/source" / row["file"])
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
    path = annotations.parent / f"{key}.jpg"
    if not path.exists():
        path.write_bytes(urllib.request.urlopen(rows[0]["sourceURL"], timeout=60).read())
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


with ThreadPoolExecutor(max_workers=6) as executor:
    pairs = list(executor.map(prepare, groups.items()))
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
if report["accuracy"] < 0.68:
    raise RuntimeError(f"Crop preference quality regressed: {correct}/300")
(output / "fcdb-human-preferences.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
manifest_path = root / "FocalModelManifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["swiftParity"] = dict(images=len(parity),
    maxPreferenceError=max(row["maxPreferenceError"] for row in parity),
    maxImportanceError=max(row["maxImportanceError"] for row in parity))
manifest["humanPreferences"] = {key: value for key, value in report.items() if key != "records"}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(json.dumps({"parity": manifest["swiftParity"], "humanPreferenceCorrect": correct, "pairs": 300}))
