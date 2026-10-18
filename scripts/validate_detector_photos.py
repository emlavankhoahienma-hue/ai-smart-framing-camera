"""Build real production detector code in resource-bearing macOS test bundles."""
from pathlib import Path
import argparse
import plistlib
import shutil
import subprocess
import sys

from prepare_detector_coco import prepare as prepare_coco
from evaluate_detector_coco import main as evaluate_coco

parser = argparse.ArgumentParser()
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--labelled-only", action="store_true")
mode.add_argument("--photographs-only", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
destination = root / "validation/detection"
destination.mkdir(parents=True, exist_ok=True)
source = (root / "AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
category = source[source.index("public enum NeuralSubjectCategory"):source.index("/// Optional semantic evidence")]
candidate = source[source.index("public struct NeuralSubjectCandidate"):source.index("/// Kết quả phân tích")]
types = destination / "ProductionDetectionTypes.swift"
types.write_text("import Foundation\nimport CoreGraphics\n" + category + candidate, encoding="utf-8")
subprocess.run([sys.executable, str(root / "tests/test_detector_evaluation.py")], check=True)
labelled = None if args.photographs_only else prepare_coco()
for name in (("yolo12s", "yolo26s") if args.labelled_only else ("yolo12n", "yolo12s", "yolo26s")):
    bundle = destination / f"{name}-validation.app/Contents"
    executable = bundle / "MacOS/DetectionValidation"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = bundle / "Resources"
    resources.mkdir(exist_ok=True)
    shutil.copytree(root / f"{name}.mlmodelc", resources / f"{name}.mlmodelc", dirs_exist_ok=True)
    if name == "yolo26s":
        # The production optical loader remains YOLO12. Bundle both slots and
        # assert that photographic inference really executes the specialist.
        shutil.copytree(root / "yolo12n.mlmodelc", resources / "yolo12n.mlmodelc", dirs_exist_ok=True)
    with (bundle / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": executable.name, "CFBundleIdentifier": "com.alignai.validation." + name,
                       "CFBundlePackageType": "APPL"}, stream)
    files = ["TrackingGeometry.swift", "CompositionPlanning.swift", "CompositionImageEvidence.swift",
             "YOLODetectionEngine.swift", "CameraLogger.swift"]
    subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors",
                    *[str(root / "AISmartFramingCamera/Services" / file) for file in files],
                    str(types), str(root / "tests/DetectionModelValidation.swift"), "-o", str(executable)], check=True)
    if not args.labelled_only:
        subprocess.run([str(executable), str(root / "validation/photos/source"),
                        str(destination / f"{name}-real-photos.json"), name], check=True)
    if labelled is not None and name in ("yolo12s", "yolo26s"):
        subprocess.run([str(executable), str(destination / "coco/photos"),
                        str(destination / f"{name}-coco-predictions.json"), name,
                        str(len(labelled["images"])), str(destination / "coco/classes.json")], check=True)
if not args.photographs_only:
    evaluate_coco()
