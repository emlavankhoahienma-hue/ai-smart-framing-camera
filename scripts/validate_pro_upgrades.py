"""Contract tests for the 7 Pro Camera Upgrades:
1. True Rec.709 RGB+Luma 48-bin Histogram & Expanded Scope
2. Default Natural Color (no persisted default preset; AI-only color when enabled)
3. Deduplicated Settings (hide toggles already in 6-dot control sheet)
4. Centralized Capability Gating (CameraFeatureGate)
5. Complete removal of AI Video Director
6. Multi-Mode Viewfinder Grid with animated button icon
7. High-Fidelity Master Frame for Video (AVAssetReader/AVAssetWriter + Audio Passthrough)
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "AISmartFramingCamera"
PBXPROJ = Path(__file__).resolve().parents[1] / "AISmartFramingCamera.xcodeproj" / "project.pbxproj"


def source(rel_path: str) -> str:
    return (ROOT / rel_path).read_text(encoding="utf-8")


class ProCameraUpgradesContracts(unittest.TestCase):
    def test_01_true_rgb_luma_histogram_engine_and_hud(self):
        engine = source("Services/RealtimeHistogramEngine.swift")
        self.assertIn("computeTelemetry(from pixelBuffer: CVPixelBuffer) -> HistogramTelemetry", engine)
        self.assertIn("CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)", engine)
        self.assertIn("robustPeak", engine)
        self.assertIn("shadowClipRatio", engine)
        self.assertIn("highlightClipRatio", engine)

        hud = source("Views/LiveColorHistogramHUDView.swift")
        self.assertIn("struct ProHistogramExpandedHUDView: View", hud)
        self.assertIn("viewModel.histogramTelemetry", hud)
        self.assertNotIn("channelValues(weights:", hud)

    def test_02_default_natural_color_and_no_default_preset(self):
        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("public var selectedFilmPreset: FilmPreset = .standard", vm)
        self.assertNotIn('defaults.string(forKey: "selectedFilmPreset")', vm)
        self.assertNotIn('defaults.bool(forKey: "isFilmSimulationActive")', vm)
        self.assertIn("if self.isAIFullColorEnabled {", vm)
        self.assertIn("private var isColorAppliedByAI: Bool = false", vm)

        settings = source("Views/SettingsSheetView.swift")
        self.assertNotIn("Preset mặc định", settings)
        self.assertNotIn("DANH SÁCH MẪU FILM NHANH", settings)

    def test_03_settings_deduplicated_against_six_dot_sheet(self):
        settings = source("Views/SettingsSheetView.swift")
        for hidden_title in [
            'Text("Định dạng chụp")',
            'title: "Chụp Ultra Sharp (Độ nét cao)"',
            'title: "Độ phân giải & FPS"',
            'title: "Chuẩn nén video"',
            'title: "Tự động cân màu bối cảnh"',
            'title: "Thanh thông số & Biểu đồ HUD"',
            'title: "Đóng khung Master"',
            'title: "Preset mặc định"',
        ]:
            self.assertNotIn(hidden_title, settings)

        # Deep settings that do NOT live in 6-dot sheet must remain available
        for kept in [
            'title: "Lưu kèm bản gốc"',
            'Số khung hình gộp Ultra Sharp',
            'title: "Focus peaking (Báo nét)"',
            'title: "Biểu đồ Pro RGB & báo cháy sáng"',
            'title: "Áp dụng Khung Master cho Video"',
            'title: "Tự động cân chỉnh màu AI"',
        ]:
            self.assertIn(kept, settings)

    def test_04_centralized_capability_gating(self):
        gate = source("Models/CameraFeatureGate.swift")
        for feature in [
            "case aiComposition",
            "case livePhoto",
            "case ultraSharp",
            "case captureTimer",
            "case horizonLeveler",
            "case horizonLock",
            "case dualCamera",
            "case windowedZoom",
            "case masterWatermark",
            "case filmColor",
            "case focusPeaking",
        ]:
            self.assertIn(feature, gate)

        main_view = source("Views/CameraMainView.swift")
        controls = source("Views/CameraControlsView.swift")
        self.assertIn("viewModel.featureAvailability(.ultraSharp)", main_view)
        self.assertIn("viewModel.featureAvailability(.captureTimer)", main_view)
        self.assertIn("viewModel.featureAvailability(.masterWatermark)", main_view)
        self.assertIn("viewModel.attemptFeature(.aiComposition)", controls)
        self.assertIn("viewModel.attemptFeature(.cameraFlip)", controls)
        self.assertIn("viewModel.attemptFeature(.filmColor)", controls)

    def test_05_ai_video_director_completely_removed_from_ui_and_triggers(self):
        forbidden_in_views = [
            "AIVideoDirectorGuidance",
            "AIVideoDirectorOverlayView",
            "DirectorHUDCard",
            "TrajectoryPathView",
            "CinematicWaypointMarker",
            "isAIVideoDirectorActive",
            "isAIVideoDirectorAnalyzing",
            "activeVideoGuidance",
            "requestAIVideoCinematographyGuidance",
            "dismissAIVideoDirector",
            "aiVideoDirectorDockTarget",
            "ĐẠO DIỄN QUAY PHIM AI",
            "ĐẠO DIỄN AI CLOUD",
        ]
        for swift_file in (ROOT / "Views").rglob("*.swift"):
            text = swift_file.read_text(encoding="utf-8")
            for symbol in forbidden_in_views:
                self.assertNotIn(symbol, text, f"Found removed Video Director UI {symbol} in {swift_file.name}")

        gemini = source("Services/GeminiService.swift")
        self.assertNotIn("buildVideoCinematographyPrompt", gemini)
        self.assertNotIn("tryVideoCinematographyChain", gemini)
        self.assertNotIn("parseVideoDirectorResponse", gemini)

    def test_06_multi_mode_grid_cycle_and_animated_icon(self):
        models = source("Models/FramingModels.swift")
        for case_name in [
            "case off",
            "case ruleOfThirds",
            "case goldenRatio",
            "case diagonal",
            "case square4x4",
            "case centerCrosshair",
        ]:
            self.assertIn(case_name, models)

        main_view = source("Views/CameraMainView.swift")
        overlay = source("Views/ARFramingOverlayView.swift")
        self.assertIn("struct AnimatedGridStyleIcon: View", main_view)
        self.assertIn("viewModel.cycleViewfinderGridStyle()", main_view)
        self.assertIn("struct ViewfinderGridOverlayView: View", overlay)

    def test_07_high_fidelity_master_frame_for_video(self):
        exporter = source("Services/HighFidelityVideoExporter.swift")
        self.assertIn("AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)", exporter)
        self.assertIn("AVAssetWriterInput(mediaType: .audio, outputSettings: nil", exporter)
        self.assertIn("AVAssetWriterInputPixelBufferAdaptor", exporter)
        self.assertIn("MasterWatermarkRenderer.shared.renderFooterBarImage", exporter)
        self.assertIn("AVVideoCodecType.hevc", exporter)

        preview = source("Views/VideoPreviewSheetView.swift")
        self.assertIn("HighFidelityVideoExporter.export(options: options)", preview)
        self.assertIn("shouldAutoApplyMasterFrame", preview)
        self.assertNotIn("AVAssetExportSession", preview)
        self.assertNotIn("electricCyan", preview)
        self.assertNotIn("wand.and.stars", preview)

    def test_08_new_swift_files_registered_in_pbxproj(self):
        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in ["CameraFeatureGate.swift", "HighFidelityVideoExporter.swift"]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)


if __name__ == "__main__":
    unittest.main()
