"""Execute and evaluate the actual generated production subject-fusion path.

COCO has object boxes, not photographic hero/group annotations. People and animal
box diagnostics exclude standalone face candidates and synthetic group unions.
Hero/group choices remain observations to inspect, never manufactured GT labels.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from evaluate_detector_coco import ANIMALS, evaluate, overlap
from prepare_detector_coco import prepare

ROOT = Path(__file__).resolve().parents[1]


def generated_source() -> tuple[Path, str]:
    """Reuse the existing macOS adapter and verify the production code it wraps."""
    source = (ROOT / "AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
    tail = source[source.index("    private func analyzeCapturedFrame("):]
    digest = hashlib.sha256(tail.encode()).hexdigest()
    boundary = json.loads((ROOT / "tests/PhotographicDetectionBoundary.json").read_text(encoding="utf-8"))
    expected = next(row["sha256"] for row in boundary["protected"]
                    if row.get("start") == "    private func analyzeCapturedFrame(")
    if digest != expected:
        raise RuntimeError("Subject fusion must use the protected production recognition implementation")
    generated = ROOT / "validation/ProductionSubjectAnalysis.swift"
    semantic = source[source.index("private final class SemanticCropRanker"):source.index("/// Ứng viên chủ thể")]
    types = source[source.index("public struct NeuralSubjectCandidate"):source.index("// CGImage is immutable")]
    if not generated.exists() or not generated.read_text(encoding="utf-8").endswith(tail):
        # The existing script is the single adapter generator. Its compile-only
        # mode does not load models or execute unrelated photographic searches.
        subprocess.run([sys.executable, str(ROOT / "scripts/validate_composition_photos.py"), "--compile-only"], check=True)
    text = generated.read_text(encoding="utf-8")
    if not text.endswith(tail) or semantic not in text or types not in text:
        raise RuntimeError("Generated subject adapter differs from current production recognition/types")
    return generated, digest


def collapsed_truth(truth: dict) -> dict:
    annotations = []
    for annotation in truth["annotations"]:
        category = annotation["category_id"]
        if category == 1 or category in ANIMALS:
            annotations.append({**annotation, "category_id": 1 if category == 1 else 17})
    return {"images": truth["images"], "annotations": annotations,
            "categories": [{"id": 1, "name": "person"},
                           {"id": 17, "name": "animal (all COCO animal species collapsed)"}]}


def evaluate_fusion(truth: dict, native: dict, digest: str) -> dict:
    images = {image["file_name"]: image for image in truth["images"]}
    records = native["records"]
    if len(records) != len(images) or {row["file"] for row in records} != set(images):
        raise RuntimeError("Fused records must cover every frozen source exactly once")
    evaluation_records = []
    diagnostics = []
    for row in records:
        image = images[row["file"]]
        boxes = []
        for annotation in truth["annotations"]:
            if annotation["image_id"] != image["id"]:
                continue
            category = annotation["category_id"]
            if category != 1 and category not in ANIMALS:
                continue
            x, y, width, height = annotation["bbox"]
            boxes.append({"annotationID": annotation["id"], "classID": category,
                "group": "people" if category == 1 else "animals",
                "crowd": bool(annotation.get("iscrowd", 0)),
                "box": [x / image["width"], y / image["height"],
                        width / image["width"], height / image["height"]]})
        predictions = []
        for candidate in row["candidates"]:
            group = candidate["evaluationGroup"]
            if not candidate["isGroup"] and group in ("people", "animals"):
                predictions.append({"classID": 1 if group == "people" else 17,
                    "confidence": candidate["confidence"], "box": candidate["box"]})
        evaluation_records.append({"file": row["file"], "detections": predictions})
        hero = row["hero"]
        # Individual-box overlaps are diagnostics only: a group union or face
        # patch is not expected to equal a COCO whole-person annotation.
        overlaps = []
        if hero is not None:
            for annotation in boxes:
                if not annotation["crowd"]:
                    overlaps.append({"annotationID": annotation["annotationID"],
                        "classID": annotation["classID"], "group": annotation["group"],
                        "IoU": overlap(hero["box"], annotation["box"])})
        overlaps.sort(key=lambda item: item["IoU"], reverse=True)
        diagnostics.append({**row, "authorPeopleAnimalBoxes": boxes,
                            "heroIndividualGTOverlaps": overlaps,
                            "heroIsPhotographicGroundTruth": False})
    metrics = evaluate(collapsed_truth(truth), {"records": evaluation_records}, False)
    return {"images": len(records), "model": native["model"],
        "annotationSHA256": truth["annotationSHA256"],
        "productionSubjectAnalysisSHA256": digest,
        "scope": "Fused production candidates versus all non-crowd author COCO person/animal boxes on the frozen 96-image subset. Animals are collapsed across COCO species. Whole-person candidates only; standalone faces and coherent-group unions are reported separately and excluded from box precision/recall. Grouped matching uses IoU >=0.50, ignored crowd uses intersection/prediction area >=0.50 with repeated crowd matching. Retained candidate scores come from different production experts and are not calibrated; this is not official COCO AP, a hero-correctness benchmark or iPhone performance measurement.",
        "metrics": metrics, "records": diagnostics}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--detector", choices=("yolo12s", "yolo26s"), default="yolo26s")
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / "tests/test_subject_fusion.py")], check=True)
    generated, digest = generated_source()
    destination = ROOT / "validation/subject-fusion"
    destination.mkdir(parents=True, exist_ok=True)
    contents = destination / (args.detector + "-fusion.app/Contents")
    executable = contents / "MacOS/SubjectFusionValidation"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": executable.name,
            "CFBundleIdentifier": "com.alignai.validation.fusion." + args.detector,
            "CFBundlePackageType": "APPL"}, stream)
    files = ["TrackingGeometry.swift", "CompositionPlanning.swift", "CompositionImageEvidence.swift",
             "YOLODetectionEngine.swift", "CameraLogger.swift"]
    subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors",
        *[str(ROOT / "AISmartFramingCamera/Services" / name) for name in files],
        str(generated), str(ROOT / "tests/SubjectFusionValidation.swift"), "-o", str(executable)], check=True)
    if args.compile_only:
        print("PASS: production subject-fusion harness compiled; no inference executed")
        return
    required = ["yolo12n", "yolo12s", "SigLIPBaseImage"]
    if args.detector == "yolo26s":
        required.append("yolo26s")
    elif (resources / "yolo26s.mlmodelc").exists():
        raise RuntimeError("YOLO12 baseline bundle unexpectedly contains the YOLO26 specialist")
    for name in required:
        shutil.copytree(ROOT / (name + ".mlmodelc"), resources / (name + ".mlmodelc"), dirs_exist_ok=True)
    shutil.copyfile(ROOT / "SigLIPPrompts.json", resources / "SigLIPPrompts.json")
    truth = prepare()
    native_path = destination / (args.detector + "-native-subject-fusion.json")
    subprocess.run([str(executable), str(ROOT / "validation/detection/coco/photos"),
        str(ROOT / "validation/detection/coco/ground-truth.json"), str(native_path), args.detector], check=True)
    native = json.loads(native_path.read_text(encoding="utf-8"))
    report = evaluate_fusion(truth, native, digest)
    output = destination / (args.detector + "-coco-subject-fusion.json")
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    critical_ids = {110784, 576955, 227187, 463842, 342006, 357501}
    critical = [row for row in report["records"] if row["imageID"] in critical_ids]
    if len(critical) != len(critical_ids):
        raise RuntimeError("Frozen subset no longer covers the six reviewed detector regressions")
    (destination / (args.detector + "-critical-subject-fusion.json")).write_text(json.dumps({
        "scope": "Diagnostic extracts after completing all 96 images; no expected hero labels.",
        "records": critical}, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"images": report["images"], "model": args.detector,
        "scope": report["scope"], "groups": report["metrics"]["groups"], "report": str(output)}, indent=2))


if __name__ == "__main__":
    main()
