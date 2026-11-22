"""Contract tests for the 7 Pro Camera Upgrades:
1. True Rec.709 RGB+Luma 48-bin Histogram & Expanded Scope
2. Default Natural Color (no persisted default preset; AI-only color when enabled)
3. Deduplicated Settings (hide toggles already in 6-dot control sheet)
4. Centralized Capability Gating (CameraFeatureGate)
5. Complete removal of AI Video Director
6. Multi-Mode Viewfinder Grid with animated button icon
7. High-Fidelity Master Frame for Video (AVAssetReader/AVAssetWriter + Audio Passthrough)
"""
import re
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
            'title: "Biểu đồ Pro RGB"',
            'title: "Khung Master cho Video"',
            'title: "Tự động cân chỉnh màu AI"',
        ]:
            self.assertIn(kept, settings)
        self.assertNotIn('icon: "boundingbox"', settings)

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

    def test_09_livecompose_inspired_local_ai_and_zoom_intelligence(self):
        neural = source("Services/NeuralSubjectIntelligenceEngine.swift")
        self.assertIn("func heroSelectionScore(_ c: NeuralSubjectCandidate) -> Double", neural)
        self.assertIn("func isPeripheralClippedEquipment(_ c: NeuralSubjectCandidate) -> Bool", neural)
        self.assertIn("var secondaryHero: NeuralSubjectCandidate? = nil", neural)
        self.assertIn("// Case A2: Dominant Foreground YOLO Object", neural)
        self.assertLess(
            neural.index("// Case A2: Dominant Foreground YOLO Object"),
            neural.index("// Case B: Desk Workspace or Tabletop Ensemble"),
        )

        planner = source("Services/CompositionPlanning.swift")
        self.assertIn("let multipliers: [CGFloat] = [1.12, 1.20, 1.30, 1.40, 1.50, 1.65, 1.80, 2.00, 2.25]", planner)
        self.assertIn("let sceneClusterAnchors: [CGPoint]", planner)

        search = source("Services/CompositionAestheticSearch.swift")
        self.assertIn("let bonusScale = usedGAIC ? 0.32 : 1.0", search)
        self.assertIn("if usedGAIC && rankedEligible[index].proposal.gaicScore < baseline.proposal.gaicScore - 0.045", search)

        calc = source("Services/CompositionCalculator.swift")
        self.assertIn("let opticalQualityBonus = isOpticalRung ? 0.030 : (isPrimeSensorCrop ? 0.012 : 0.0)", calc)
        self.assertIn("if Double(subject.width * subject.height) >= 0.22 {", calc)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("let isStabilizedOrTimedOut = (now - requestedAt >= 0.34)", vm)
        self.assertIn("if isCrampedAtCurrentZoom && evaluatedFraming.recommendedZoomFactor < displayZoom - 0.10", vm)
        self.assertIn("if abs(effectiveZoom - displayZoom) < 0.11 {", vm)
        self.assertNotIn("isDistant && evaluatedFraming.recommendedZoomFactor < 1.7 ? 2.0", vm)
        self.assertIn("sensorSubjectRect: normalizedSubjectRect(cloudTrackingSource?.subjectRect)", vm)

        gemini = source("Services/GeminiService.swift")
        self.assertIn("let maxSafeZoom = (0.5 - margin) / maxSpan", gemini)

    def test_10_openworld_depth_and_3d_camera_director(self):
        director = source("Services/CameraFramingDirector.swift")
        self.assertIn("enum CameraFramingDirector", director)
        self.assertIn("let solvedRotation = simd_quatd(from: targetRay, to: sourceRay)", director)
        self.assertIn("isCornerHeadless", director)
        self.assertIn("isSeverelyCramped", director)
        self.assertIn("extractSharpForegroundClusters", director)

        ow = source("Services/OpenWorldSubjectDetector.swift")
        self.assertIn("OpenWorldPhotoYOLOE", ow)
        self.assertIn("OpenWorldPhotoClasses", ow)
        self.assertIn("VNGenerateForegroundInstanceMaskRequest", ow)

        evidence = source("Services/CompositionImageEvidence.swift")
        self.assertIn('"DepthAnythingV2SmallF16INT8"', evidence)
        self.assertIn("private func depthBufferMap(", evidence)

        neural = source("Services/NeuralSubjectIntelligenceEngine.swift")
        self.assertIn("OpenWorldSubjectDetector.shared.detect(", neural)
        self.assertIn("CameraFramingDirector.direct(", neural)

        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in ["CameraFramingDirector.swift", "OpenWorldSubjectDetector.swift"]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)

    def test_11_six_real_device_bugfixes(self):
        # 1. Faster local AI (concurrent OpenWorld + hardware Float16 + cached models + trimmed budgets)
        ow = source("Services/OpenWorldSubjectDetector.swift")
        self.assertIn("DispatchGroup()", ow)
        self.assertIn("Float16.self", ow)
        gaic = source("Services/GAICCompositionModel.swift")
        self.assertIn("static func cachedOrLoad(url: URL)", gaic)
        search = source("Services/CompositionAestheticSearch.swift")
        self.assertIn("GAICCompositionModel.cachedOrLoad(url: resolvedGaicURL)", search)

        # 2. Target alignment -> 2x zoom & auto-capture reliability (no dead zone or stale lock)
        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("let effectiveRadius = max(alignmentRadius, 0.072)", vm)
        self.assertIn("zoomAwaitingVerification || isRevealingZoomTarget", vm)

        # 3 & 6. Smooth animatable Histogram + Real Highlight Clipping & High Noise alerts
        histo_engine = source("Services/RealtimeHistogramEngine.swift")
        self.assertIn("smoothedRefPeak", histo_engine)
        self.assertIn("flatNoiseSum", histo_engine)
        self.assertIn("sensorISO: Float", histo_engine)
        histo_hud = source("Views/LiveColorHistogramHUDView.swift")
        self.assertIn("SmoothHistogramCurveShape", histo_hud)
        self.assertIn("telemetry.isHighNoise", histo_hud)
        self.assertIn("Cháy sáng", histo_hud)

        # 4. In-app Align Studio gallery EXIF orientation fix
        models = source("Models/FramingModels.swift")
        self.assertIn("private func orientedCGImage(from source: CGImageSource)", models)
        self.assertIn("kCGImagePropertyOrientation", models)

        # 5. Photo Detail interactive Zoom Navigator Mini-Map restored
        preview = source("Views/CapturedPhotoPreviewView.swift")
        self.assertIn("private func zoomRegionMiniMap(viewportSize: CGSize)", preview)

    def test_12_pro_photo_manual_controls_and_telemetry(self):
        service = source("Services/ProPhotoManualControlsService.swift")
        for token in [
            "CameraService.shared.scheduleDeviceConfiguration",
            "format.minISO",
            "format.maxISO",
            "format.minExposureDuration",
            "format.maxExposureDuration",
            "camera.exposureTargetOffset",
            "camera.maxWhiteBalanceGain",
            "camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported",
            "!camera.isVirtualDevice",
            "AVCaptureDevice.currentWhiteBalanceGains",
            "camera.grayWorldDeviceWhiteBalanceGains",
            "clampedWhiteBalanceGains(",
            "areGainsStrictlyValid(",
            "camera.isLockingFocusWithCustomLensPositionSupported",
            "camera.isAutoFocusRangeRestrictionSupported",
            "camera.isLowLightBoostSupported",
            "camera.isGeometricDistortionCorrectionSupported",
            "camera.setTorchModeOn(level:",
            "func resetToFullAuto()",
        ]:
            self.assertIn(token, service)

        pro_video = source("Services/ProVideoManualControlsService.swift")
        self.assertIn("camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported", pro_video)
        self.assertIn("!camera.isVirtualDevice", pro_video)

        film_engine = source("Services/FilmFilterEngine.swift")
        for token in [
            "public struct FilmSimulationTuning:",
            "public struct ProPhotoSoftwareWBGrade:",
            "applySoftwareWhiteBalance(",
            "applyFilmTuning(",
            "case .standard, .aiFullAuto, .proColorGrade:",
        ]:
            self.assertIn(token, film_engine)

        overlay = source("Views/ProPhotoControlsOverlayView.swift")
        self.assertIn("public struct ProPhotoTelemetryHUDView: View", overlay)
        self.assertIn("public struct ProPhotoManualDeckView: View", overlay)
        self.assertIn("ProPrecisionRulerDial", overlay)
        self.assertIn("enum FilmTuningAxis", overlay)
        self.assertIn("private var filmPanel: some View", overlay)
        self.assertIn("AlignTheme.studioAccent", overlay)
        self.assertNotIn("electricCyan", overlay)
        self.assertNotIn("iridescentRainbow", overlay)

        gate = source("Models/CameraFeatureGate.swift")
        self.assertIn("case proPhoto", gate)

        controls = source("Views/CameraControlsView.swift")
        self.assertIn('case proPhoto = "PRO"', controls)
        self.assertIn("viewModel.selectProPhotoMode()", controls)
        self.assertIn("private var filmTuningBar: some View", controls)

        main_view = source("Views/CameraMainView.swift")
        self.assertIn("ProPhotoTelemetryHUDView(viewModel: viewModel)", main_view)
        self.assertIn("ProPhotoManualDeckView(viewModel: viewModel)", main_view)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("public let proPhotoService = ProPhotoManualControlsService.shared", vm)
        self.assertIn("public func selectProPhotoMode()", vm)
        self.assertIn("public var filmTuning: FilmSimulationTuning = .neutral", vm)
        self.assertIn("public var activeProSoftwareWB: ProPhotoSoftwareWBGrade = .inactive", vm)

        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in ["ProPhotoManualControlsService.swift", "ProPhotoControlsOverlayView.swift"]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)

    def test_13_horizon_leveler_single_motion_manager_and_360_overhead(self):
        leveler = source("Services/HorizonLevelerService.swift")
        for token in [
            "DeviceMotionService.shared.subscribe",
            "DeviceMotionService.shared.unsubscribe",
            "q.inverse.act(SIMD3<Double>(0.0, 0.0, -1.0))",
            "evaluateGravity(",
            "isOverheadMode",
            "cardinalDeviationDegrees",
            "nearestCardinalDegrees",
            "wrapAngle180(",
        ]:
            self.assertIn(token, leveler)

        overlay = source("Views/ARFramingOverlayView.swift")
        self.assertIn("HorizonLevelerView(leveler: viewModel.horizonLevelerService)", overlay)
        self.assertIn("private var overheadBubbleLevel: some View", overlay)
        self.assertNotIn("abs(rollDegrees) > 15.0 ? 0.0", overlay)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("public let horizonLevelerService = HorizonLevelerService.shared", vm)
        self.assertIn("public func syncHorizonLevelerLifecycle()", vm)
        self.assertIn("horizonMotionManager.stopDeviceMotionUpdates()", vm)

        pro_photo = source("Services/ProPhotoManualControlsService.swift")
        self.assertIn("private var pendingAWBLockWorkItem: DispatchWorkItem?", pro_photo)

        pbx = PBXPROJ.read_text(encoding="utf-8")
        self.assertIn("/* HorizonLevelerService.swift */", pbx)
        self.assertIn("/* HorizonLevelerService.swift in Sources */", pbx)

    def test_14_local_ai_speed_oom_and_freeform_director(self):
        charm = source("Services/CharmPhotographicModel.swift")
        self.assertIn("configuration.computeUnits = .cpuAndGPU", charm)
        self.assertIn("static func cachedOrLoad(url: URL, positionURL: URL)", charm)
        self.assertIn("SharedPositionCache", charm)

        samp = source("Services/PhotographicCompositionModel.swift")
        self.assertIn("static func cachedOrLoad(url: URL)", samp)
        self.assertIn("configuration.computeUnits = .all", samp)

        evidence = source("Services/CompositionImageEvidence.swift")
        self.assertIn("private var activeRequests: [ObjectIdentifier: VNRequest] = [:]", evidence)
        self.assertIn("var isSoftDeadlineReached: Bool", evidence)
        self.assertIn("func releaseDepthModel()", evidence)

        ow = source("Services/OpenWorldSubjectDetector.swift")
        self.assertIn("group.wait(timeout:", ow)
        self.assertIn("renderLock.withLock", ow)

        search = source("Services/CompositionAestheticSearch.swift")
        self.assertIn("var allGAICProposals: [CompositionProposal] = []", search)
        self.assertIn("PhotographicCompositionModel.cachedOrLoad(url: modelURL)", search)
        self.assertIn("CharmPhotographicModel.cachedOrLoad(url: aestheticModelURL, positionURL: positionURL)", search)

        neural = source("Services/NeuralSubjectIntelligenceEngine.swift")
        self.assertIn("func releaseModelNow()", neural)
        self.assertIn("func scoreProposalsFromSpatialProfile(", neural)
        self.assertIn("func analyzeCompositionAsync(", neural)
        self.assertIn("gaicProposals: result.allGAICProposals", neural)

        director = source("Services/CameraFramingDirector.swift")
        self.assertIn("enum DirectorCompositionStyle", director)
        self.assertIn("case centerFocus", director)
        self.assertIn("case negativeSpace", director)
        self.assertIn("case diagonalDynamic", director)
        self.assertIn("case frameInFrame", director)
        self.assertIn("bystanderOverridden", director)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("private static func clonePixelBuffer(", vm)
        self.assertIn("CompositionAnalysisCancellation(softTimeoutSeconds:", vm)
        self.assertIn("NeuralSubjectIntelligenceEngine.shared.analyzeCompositionAsync(", vm)
        self.assertIn("if captureMode.isVideo { selectCaptureMode(.photo) }", vm)

    def test_15_live_photo_oom_guard_yoloe26m_and_clean_white_leveler(self):
        # 1. Pure minimalist white horizon balance bar (no numeric degree pill)
        overlay = source("Views/ARFramingOverlayView.swift")
        self.assertNotIn("private var angleLabel: String", overlay)
        self.assertNotIn("Text(angleLabel)", overlay)
        self.assertIn("private var horizonBarLevel: some View", overlay)
        self.assertIn("private var overheadBubbleLevel: some View", overlay)

        # 2. Live Photo + Local AI zero-contention & strict single-model-resident memory guards
        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("var isAnalyzingLocalAI = false", vm)
        self.assertIn("if snapshot.isAnalyzingLocalAI && !needsImmediateCapture", vm)
        self.assertIn("tracksSuggestions: aiSessionState == .analyzing && localAnalysisFinished && !localEvidenceCandidates.isEmpty", vm)
        self.assertIn("NeuralSubjectIntelligenceEngine.shared.releaseAllModelCaches()", vm)
        self.assertIn("lowMemoryBudget: livePhotoLowMemoryBudget", vm)

        neural = source("Services/NeuralSubjectIntelligenceEngine.swift")
        self.assertIn("public func releaseAllModelCaches()", neural)
        self.assertIn("preferSequential: lowMem", neural)
        self.assertIn("lowMemoryBudget: lowMem", neural)

        search = source("Services/CompositionAestheticSearch.swift")
        self.assertIn("GAICCompositionModel.clearCache()", search)
        self.assertIn("PhotographicCompositionModel.clearCache()", search)
        self.assertIn("CharmPhotographicModel.clearCache()", search)

        gaic = source("Services/GAICCompositionModel.swift")
        self.assertIn("static func clearCache()", gaic)

        # 3. Upgraded YOLOE-26m @ 512 + fast row-major decoder + giant-tie monument fix
        ow = source("Services/OpenWorldSubjectDetector.swift")
        self.assertIn("preferSequential: Bool = false", ow)
        self.assertIn("private let defaultInputSide: Int = 512", ow)
        self.assertIn("strictThresholdClasses", ow)
        self.assertIn("var bestScores = [Float](repeating:", ow)

        director = source("Services/CameraFramingDirector.swift")
        self.assertIn("monumentDets", director)
        self.assertIn("maskInstances.first(where: { !$0.isEdgeSliver })", director)

        export_script = (Path(__file__).resolve().parent / "export_openworld_yoloe_coreml.py").read_text(encoding="utf-8")
        self.assertIn('MODEL_NAME = "yoloe-26m-seg.pt"', export_script)
        self.assertIn("INPUT_SIZE = 512", export_script)
        self.assertIn("EXPECTED_ANCHORS =", export_script)

    def test_16_hysteresis_clusters_vision_filter_ranker_and_bundle_hygiene(self):
        # 1. Hysteresis dual-threshold foreground clusters & breathing room guard
        director = source("Services/CameraFramingDirector.swift")
        self.assertIn("let seedThresh =", director)
        self.assertIn("let growThresh =", director)
        self.assertIn("let breathingPen:", director)

        # 2. Display P3 sRGB-accurate 3D LUT application
        film_core = source("Services/FilmSimulations/FilmSimulationCore.swift")
        self.assertIn("CIColorCubeWithColorSpace", film_core)
        self.assertIn("CGColorSpace.sRGB", film_core)

        # 3. Real iOS 18+ Apple Vision Aesthetic AI Filter Ranking (0ms delay, iOS 17 fallback)
        models = source("Models/FramingModels.swift")
        self.assertIn("public var candidateFilmPresets: [FilmPreset]", models)

        film_engine = source("Services/FilmFilterEngine.swift")
        self.assertIn("public struct FilmFilterRankingResult: Sendable", film_engine)
        self.assertIn("public func rankBestFilmPreset(", film_engine)
        self.assertIn("VNCalculateImageAestheticsScoresRequest", film_engine)
        self.assertIn("candEval.isUtility", film_engine)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("private var aiFilterRankingTask: Task<Void, Never>?", vm)
        self.assertIn("FilmFilterEngine.shared.rankBestFilmPreset(", vm)

        # 4. Per-stage Local AI timing telemetry
        neural = source("Services/NeuralSubjectIntelligenceEngine.swift")
        self.assertIn("LocalAI timings [lowMem=%d]:", neural)

        # 5. ATS security hardening & non-duplicated LUT/Noise packaging
        plist = source("Info.plist")
        self.assertIn("<key>NSAllowsLocalNetworking</key>", plist)
        self.assertNotIn("<key>NSAllowsArbitraryLoads</key>", plist)

        ci_yml = (Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("cp AISmartFramingCamera/Resources/LUTs/*.bin Payload/AISmartFramingCamera.app/LUTs/", ci_yml)
        self.assertNotIn("cp -r AISmartFramingCamera/Resources/LUTs/* Payload/AISmartFramingCamera.app/", ci_yml)

    def test_17_photographic_styles_metal_color_science_and_pad(self):
        # 1. Models: 8 presets split cleanly into standard / undertone / mood + real HUD numbers
        models = source("Models/PhotographicStyleModels.swift")
        for token in [
            "public enum PhotographicStylePreset:",
            "case standard",
            "case warmAmber",
            "case softRose",
            "case neutral",
            "case richContrast",
            "case vibrant",
            "case coolMood",
            "case starkBW",
            "public struct PhotographicStyleState:",
            "public var isIdentity: Bool",
            "public var isModifiedFromPresetDefault: Bool",
        ]:
            self.assertIn(token, models)

        # 2. Single-Pass Metal CIImageProcessorKernel (Linear RGBAh, OkLab, Skin Mask, Filmic Shoulder, Linear Mix)
        kernel = source("Services/PhotographicStyleMetalKernel.swift")
        for token in [
            "CIImageProcessorKernel",
            "formatForInput(at input: Int32) -> CIFormat",
            ".RGBAh",
            "signedCbrt",
            "linearSRGBToOkLab",
            "okLabToLinearSRGB",
            "computeSkinMaskOkLab",
            "applyHighlightShoulder",
            "mix(origLinear, graded, palette)",
            "dispatchThreadgroups",
            "applyCoreImageFallback",
        ]:
            self.assertIn(token, kernel)
        # Ensure MSL never uses invalid cbrt() and every literal smoothstep(e0, e1, ...) satisfies e0 < e1
        self.assertNotIn("cbrtf(", kernel)
        for m_ss in re.finditer(r"smoothstep\(\s*([+-]?\d+(?:\.\d+)?)f\s*,\s*([+-]?\d+(?:\.\d+)?)f", kernel):
            self.assertLess(float(m_ss.group(1)), float(m_ss.group(2)), f"Reversed MSL smoothstep: {m_ss.group(0)}")
        # Verify exact Björn Ottosson OkLab inverse matrix (guards against transposed M1_inv regression)
        self.assertIn("+4.0767416613f * l - 3.3077115904f * m + 0.2309699287f * s", kernel)
        self.assertIn("-1.2684380041f * l + 2.6097574007f * m - 0.3413193963f * s", kernel)
        self.assertIn("-0.0041960865f * l - 0.7034186145f * m + 1.7076147009f * s", kernel)

        # 3. Real pipeline wired into FilmFilterEngine, CameraPreviewView, CameraViewModel & FeatureGate
        engine = source("Services/FilmFilterEngine.swift")
        self.assertIn("public var activePhotographicStyle: PhotographicStyleState", engine)
        self.assertIn("PhotographicStyleMetalKernel.apply(to: inputImage, style: style)", engine)

        preview = source("Views/CameraPreviewView.swift")
        self.assertIn("photographicStyle: viewModel.effectivePhotographicStyle", preview)
        self.assertIn("photographicStyle == lastPhotographicStyle", preview)

        gate = source("Models/CameraFeatureGate.swift")
        self.assertIn("case photographicStyles", gate)
        self.assertIn("if ctx.isVideo", gate)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("private var photographicStyleMemory: [PhotographicStylePreset: PhotographicStyleState]", vm)
        self.assertIn("public var effectivePhotographicStyle: PhotographicStyleState", vm)
        self.assertIn("@Published public var photographicStyle: PhotographicStyleState = .standard", vm)
        self.assertIn("@Published public var isShowingPhotographicStylePad: Bool = false", vm)
        self.assertIn("public func resetActivePhotographicStylePreset()", vm)

        # 4. Native iOS 2D Control Pad UI (no AI/neon slop, Gaussian proximity Canvas, hysteresis snap, numbered slider)
        pad = source("Views/PhotographicStylesPadView.swift")
        for token in [
            "public struct PhotographicStyleQuickTriggerButton: View",
            "public struct PhotographicStylesControlPadOverlay: View",
            "snapEnterDeadzone: Float = 0.04",
            "snapExitDeadzone: Float = 0.065",
            "monospacedDigit()",
            "PhotographicPaletteSlider",
            "triggerPadGridTick()",
        ]:
            self.assertIn(token, pad)
        self.assertNotIn("electricCyan", pad)
        self.assertNotIn("iridescentRainbow", pad)

        main_view = source("Views/CameraMainView.swift")
        self.assertIn("PhotographicStyleQuickTriggerButton(viewModel: viewModel)", main_view)
        self.assertIn("PhotographicStylesControlPadOverlay(viewModel: viewModel, compact: layout.isCompact)", main_view)

        # 5. All 3 new Swift files registered cleanly in project.pbxproj
        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in [
            "PhotographicStyleModels.swift",
            "PhotographicStyleMetalKernel.swift",
            "PhotographicStylesPadView.swift",
        ]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)


if __name__ == "__main__":
    unittest.main()
