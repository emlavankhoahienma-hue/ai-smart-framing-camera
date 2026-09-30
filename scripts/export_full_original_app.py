import os
import shutil
import zipfile
from pathlib import Path

repo_root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
dl_dir.mkdir(parents=True, exist_ok=True)

# 1. Collect all Swift files (both app and tests)
all_swift_files = sorted(repo_root.rglob("*.swift"))
# Filter out any in .git
all_swift_files = [f for f in all_swift_files if ".git" not in f.parts]

# 2. Collect all Python test and validation scripts
test_scripts = sorted([
    repo_root / "scripts/validate_tracking_geometry.py",
    repo_root / "scripts/validate_tracking_stability.py",
    repo_root / "scripts/validate_local_framing.py",
    repo_root / "scripts/validate_super_resolution.py",
    repo_root / "scripts/validate_patch_flow_reference.py",
    repo_root / "scripts/run_regressions.py",
    repo_root / "scripts/check_swift_brackets.py",
    repo_root / "scripts/check_responsive_layout.py",
])
test_scripts = [f for f in test_scripts if f.exists()]

# Key priority order for Swift files
priority_names = [
    "CameraViewModel.swift",
    "CameraService.swift",
    "SuperResolutionRAWEngine.swift",
    "SuperResolutionMetalShaders.swift",
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
    "FramingModels.swift",
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
    "AISmartFramingCameraApp.swift",
]

ordered_swift_files = []
for p_name in priority_names:
    for f in all_swift_files:
        if f.name == p_name and f not in ordered_swift_files:
            ordered_swift_files.append(f)
for f in all_swift_files:
    if f not in ordered_swift_files:
        ordered_swift_files.append(f)

# 3. Write consolidated full code file
header = (
    "================================================================================\n"
    "AI SMART FRAMING CAMERA - TOAN BO MA NGUON NGUYEN BAN (FULL ORIGINAL CODEBASE)\n"
    f"Tong so tep Swift: {len(ordered_swift_files)}\n"
    f"Tong so script kiem thu va chay he thong: {len(test_scripts)}\n"
    "Bao gom 100% ma nguon goc day du, khong cat bot, khong omit bat ky dong code nao.\n"
    "================================================================================\n\n"
)

out_files = [
    dl_dir / "AI_Camera_Full_Original_Codebase.txt",
    dl_dir / "AI_Camera_Full_Original_Codebase.md",
    dl_dir / "AI_Camera_Full_Source_Code.txt",
    dl_dir / "AI_Camera_Full_Source_Code.md",
]

for out_path in out_files:
    with open(out_path, "w", encoding="utf-8") as out:
        out.write(header)
        for f in ordered_swift_files:
            rel = f.relative_to(repo_root)
            out.write("================================================================================\n")
            out.write(f"FILE: {rel.as_posix()}\n")
            out.write("================================================================================\n")
            content = f.read_text(encoding="utf-8")
            out.write(content)
            if not content.endswith("\n"):
                out.write("\n")
            out.write("\n")

        for f in test_scripts:
            rel = f.relative_to(repo_root)
            out.write("================================================================================\n")
            out.write(f"SCRIPT: {rel.as_posix()}\n")
            out.write("================================================================================\n")
            content = f.read_text(encoding="utf-8")
            out.write(content)
            if not content.endswith("\n"):
                out.write("\n")
            out.write("\n")
    print(f"Generated text package: {out_path} ({out_path.stat().st_size} bytes)")

# 4. Generate complete ZIP archive of the entire project repository
zip_path = dl_dir / "AISmartFramingCamera_Full_Original_Project.zip"
exclude_dirs = {".git", "__pycache__", ".pytest_cache", ".system_generated"}

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for file_path in repo_root.rglob("*"):
        if file_path.is_file():
            # Check exclusions
            parts = file_path.relative_to(repo_root).parts
            if any(ex in parts for ex in exclude_dirs):
                continue
            if file_path.name.endswith(".pyc"):
                continue
            arcname = file_path.relative_to(repo_root).as_posix()
            zipf.write(file_path, arcname)

print(f"Generated full project ZIP archive: {zip_path} ({zip_path.stat().st_size} bytes)")
