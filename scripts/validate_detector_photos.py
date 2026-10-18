"""Build real production detector code in resource-bearing macOS test bundles."""
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
destination = root / "validation/detection"
destination.mkdir(parents=True, exist_ok=True)
source = (root / "AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
category = source[source.index("public enum NeuralSubjectCategory"):source.index("/// Optional semantic evidence")]
candidate = source[source.index("public struct NeuralSubjectCandidate"):source.index("/// Kết quả phân tích")]
types = destination / "ProductionDetectionTypes.swift"
types.write_text("import Foundation\nimport CoreGraphics\n" + category + candidate, encoding="utf-8")
for name in ("yolo12n", "yolo12s"):
    bundle = destination / f"{name}-validation.app/Contents"
    executable = bundle / "MacOS/DetectionValidation"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = bundle / "Resources"
    resources.mkdir(exist_ok=True)
    shutil.copytree(root / f"{name}.mlmodelc", resources / f"{name}.mlmodelc", dirs_exist_ok=True)
    with (bundle / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleExecutable": executable.name, "CFBundleIdentifier": "com.alignai.validation." + name,
                       "CFBundlePackageType": "APPL"}, stream)
    files = ["CompositionTuning.swift", "CompositionPureCalculations.swift", "CompositionExperiments.swift",
             "TrackingGeometry.swift", "CompositionPlanning.swift", "CompositionImageEvidence.swift",
             "YOLODetectionEngine.swift", "CameraLogger.swift"]
    subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors",
                    *[str(root / "AISmartFramingCamera/Services" / file) for file in files],
                    str(types), str(root / "tests/DetectionModelValidation.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(root / "validation/photos/source"),
                    str(destination / f"{name}-real-photos.json"), name], check=True)
