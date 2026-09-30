import os
import zipfile
from pathlib import Path

repo_root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
dl_dir.mkdir(parents=True, exist_ok=True)

# 1. Pure iOS Swift files only (AISmartFramingCamera + tests)
app_root = repo_root / "AISmartFramingCamera"
tests_root = repo_root / "tests"

all_app_swifts = sorted(app_root.rglob("*.swift"))
all_test_swifts = sorted(tests_root.rglob("*.swift")) if tests_root.exists() else []

priority_order = [
    # App entry & ViewModels
    "AISmartFramingCameraApp.swift",
    "CameraViewModel.swift",
    # Core camera & capture engines
    "CameraService.swift",
    "SuperResolutionRAWEngine.swift",
    "SuperResolutionMetalShaders.swift",
    # AI & Tracking engines
    "SpatialTrackingEngine.swift",
    "TargetPatchFlow.swift",
    "TrackingGeometry.swift",
    "VisionFramingEngine.swift",
    "NeuralTargetTracker.swift",
    "NeuralSubjectIntelligenceEngine.swift",
    "DeviceMotionService.swift",
    "CompositionCalculator.swift",
    "FilmFilterEngine.swift",
    "FocusPeakingEngine.swift",
    "RealtimeHistogramEngine.swift",
    "VisualOdometryEngine.swift",
    "YOLODetectionEngine.swift",
    "StreetSpatialTrackingEngine.swift",
    "ProVideoManualControlsService.swift",
    "CameraLogger.swift",
    # Models
    "FramingModels.swift",
    # UI Views
    "ARFramingOverlayView.swift",
    "CameraControlsView.swift",
    "CameraMainView.swift",
    "CameraPreviewView.swift",
    "SettingsSheetView.swift",
    "CapturedPhotoPreviewView.swift",
    "AIStatusHUDView.swift",
    "FeedbackView.swift",
    "GyroCalibrationSheetView.swift",
    "LiveColorHistogramHUDView.swift",
    "LuxuryInteractiveGoldButtonStyle.swift",
    "PhotoGallerySheetView.swift",
    "ProVideoManualControlsView.swift",
    "VideoPreviewSheetView.swift",
    "WindowedZoomOverlayView.swift",
]

ordered_swifts = []
for p in priority_order:
    for f in all_app_swifts:
        if f.name == p and f not in ordered_swifts:
            ordered_swifts.append(f)
for f in all_app_swifts:
    if f not in ordered_swifts:
        ordered_swifts.append(f)

# Append test files at the end
ordered_swifts.extend(all_test_swifts)

header = (
    "================================================================================\n"
    "AI SMART FRAMING CAMERA - SOURCE CODE APP IOS (100% NGUYEN BAN PURE IOS)\n"
    f"Tong so tep Swift iOS: {len(ordered_swifts)} (40 App files + {len(all_test_swifts)} Test files)\n"
    "HOAN TOAN KHONG CO PHAN WEB - CHI CHUA DUY NHAT MA NGUON APP IOS XCODE\n"
    "Bao gom 100% ma nguon day du tung dong, khong cat bot, khong omit.\n"
    "================================================================================\n\n"
)

# 2. Write single text and markdown files
txt_path = dl_dir / "AI_Camera_iOS_Source_Code.txt"
md_path = dl_dir / "AI_Camera_iOS_Source_Code.md"

for target in [txt_path, md_path]:
    with open(target, "w", encoding="utf-8") as out:
        out.write(header)
        for f in ordered_swifts:
            rel = f.relative_to(repo_root)
            out.write("================================================================================\n")
            out.write(f"FILE: {rel.as_posix()}\n")
            out.write("================================================================================\n")
            content = f.read_text(encoding="utf-8")
            out.write(content)
            if not content.endswith("\n"):
                out.write("\n")
            out.write("\n")
    print(f"Generated iOS source file: {target} ({target.stat().st_size} bytes)")

# 3. Create pure iOS project ZIP archive (excluding web, .git, python scripts)
zip_path = dl_dir / "AISmartFramingCamera_iOS_SourceCode.zip"

ios_include_dirs = ["AISmartFramingCamera", "AISmartFramingCamera.xcodeproj", "tests"]
ios_include_files = [".gitignore", "README.md", "ARCHITECTURE.md"]

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for d in ios_include_dirs:
        dir_path = repo_root / d
        if dir_path.exists():
            for f in dir_path.rglob("*"):
                if f.is_file() and not f.name.endswith(".pyc"):
                    rel = f.relative_to(repo_root).as_posix()
                    zipf.write(f, rel)

    for f_name in ios_include_files:
        p = repo_root / f_name
        if p.exists() and p.is_file():
            zipf.write(p, p.name)

print(f"Generated pure iOS ZIP archive: {zip_path} ({zip_path.stat().st_size} bytes)")
