"""Compile production recognition/hero code with macOS data-only type adapters.

The generated scene enum omits iOS filter/UI computed properties. All detector,
face association, saliency, semantic, hero and group algorithms are copied byte
for byte from production; no recognizer outputs are mocked or manufactured.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--parity-only", action="store_true")
args, passthrough = parser.parse_known_args()  # extra flags (e.g. --eval-dir) go to the Swift CLI
root = Path(__file__).resolve().parents[1]
output = root / "validation/swift"
output.mkdir(parents=True, exist_ok=True)
source = (root / "AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
models = (root / "AISmartFramingCamera/Models/FramingModels.swift").read_text(encoding="utf-8")
scene_start = models.index("public enum DetectedSceneType:")
scene = models[scene_start:models.index("    public var", scene_start)] + "}\n"
category = source[source.index("public enum NeuralSubjectCategory"):source.index("/// Optional semantic evidence")]
semantic = source[source.index("private final class SemanticCropRanker"):source.index("/// Ứng viên chủ thể")]
types = source[source.index("public struct NeuralSubjectCandidate"):source.index("// CGImage is immutable")]
intent_start = source.index("    private func compositionIntents(")
tail_start = source.index("    private func analyzeCapturedFrame(")
intents = source[intent_start:tail_start]
tail = source[tail_start:]
boundary = json.loads((root / "tests/PhotographicDetectionBoundary.json").read_text())
expected = next(row["sha256"] for row in boundary["protected"] if row.get("start") == "    private func analyzeCapturedFrame(")
if hashlib.sha256(tail.encode()).hexdigest() != expected:
    raise RuntimeError("Native recognition must use the protected production implementation")
generated = root / "validation/ProductionSubjectAnalysis.swift"
header = "import Foundation\nimport Vision\nimport CoreGraphics\nimport CoreImage\nimport CoreML\nimport simd\n"
adapter = '''
final class NativeSubjectAnalysis {
    private let renderer: CompositionImageRenderer
    private let analysisLock = NSLock()
    init(renderer: CompositionImageRenderer) { self.renderer = renderer }
    func analyze(_ pixels: CVPixelBuffer) -> NeuralAnalysisOutput? {
        analysisLock.lock()
        defer { SemanticCropRanker.shared.endAnalysis(); analysisLock.unlock() }
        return analyzeCapturedFrame(pixelBuffer: pixels, orientation: .up,
                                    cancellation: CompositionAnalysisCancellation())
    }
    func intents(_ output: NeuralAnalysisOutput, hero: NeuralSubjectCandidate) -> [LocalCompositionIntent] {
        compositionIntents(output, hero: hero)
    }
    func subjectKind(_ hero: NeuralSubjectCandidate) -> CompositionSubjectKind {
        hero.isGroup ? .group : kind(hero.category)
    }
'''
generated.write_text(header + scene + category + semantic + types + adapter + intents + tail,
                     encoding="utf-8", newline="\n")
manifest = {"scope": "Production algorithms; scene enum excludes only iOS UI/filter properties",
            "productionSubjectAnalysisSHA256": hashlib.sha256(tail.encode()).hexdigest(),
            "productionIntentsSHA256": hashlib.sha256(intents.encode()).hexdigest()}
(output / "production-source-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
bundle = root / "validation/photo-validation.app/Contents"
executable = bundle / "MacOS/PhotoValidation"
executable.parent.mkdir(parents=True, exist_ok=True)
resources = bundle / "Resources"
resources.mkdir(exist_ok=True)
if not args.parity_only:
    for name in ("yolo12n", "yolo12s", "SigLIPBaseImage"):
        shutil.copytree(root / (name + ".mlmodelc"), resources / (name + ".mlmodelc"), dirs_exist_ok=True)
    shutil.copyfile(root / "SigLIPPrompts.json", resources / "SigLIPPrompts.json")
with (bundle / "Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleExecutable": executable.name, "CFBundleIdentifier": "com.alignai.validation.composition",
                   "CFBundlePackageType": "APPL"}, stream)
files = ["CompositionTuning.swift", "CompositionPureCalculations.swift", "CompositionExperiments.swift",
         "TrackingGeometry.swift", "CompositionPlanning.swift", "CompositionImageEvidence.swift",
         "PhotographicCompositionModel.swift", "CharmPhotographicModel.swift", "PortraitFramingEvidence.swift",
         "CompositionAestheticSearch.swift", "YOLODetectionEngine.swift", "CameraLogger.swift"]
subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors",
                *[str(root / "AISmartFramingCamera/Services" / name) for name in files], str(generated),
                str(root / "tests/CompositionModelValidation.swift"), "-o", str(executable)], check=True)
subprocess.run([str(executable), str(root / "validation/photos"), str(root / "SAMPComposition.mlmodelc"),
                str(output), *(["--parity-only"] if args.parity_only else []), *passthrough], check=True)
