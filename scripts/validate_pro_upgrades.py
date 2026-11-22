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
        self.assertIn("VintageCameraDrawerView(viewModel: viewModel)", controls)

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
        self.assertIn("params != lastRenderParams", preview)

        gate = source("Models/CameraFeatureGate.swift")
        self.assertIn("case photographicStyles", gate)
        self.assertIn("if ctx.isVideo", gate)

        vm = source("ViewModels/CameraViewModel.swift")
        self.assertIn("private var photographicStyleMemory: [PhotographicStylePreset: PhotographicStyleState]", vm)
        self.assertIn("public var effectivePhotographicStyle: PhotographicStyleState", vm)
        self.assertIn("@Published public var photographicStyle: PhotographicStyleState = .standard", vm)
        self.assertIn("@Published public var isShowingPhotographicStylePad: Bool = false", vm)
        self.assertIn("public func resetActivePhotographicStylePreset()", vm)

        # 4. Native iOS 18 Bottom-Deck 2D Control Pad UI (5x5 live-mirror icon, GPU split-screen wipe, English Top HUD, Animatable blurred cursor)
        pad = source("Views/PhotographicStylesPadView.swift")
        for token in [
            "private struct PhotographicStyleLiveIconCanvas: View, Animatable",
            "public struct PhotographicStyleQuickTriggerButton: View",
            "public struct PhotographicStylesTopHUDBar: View",
            "private struct PhotographicStyleRoundedSplitSeam: View",
            "public struct PhotographicStylesViewfinderOverlay: View",
            "public struct PhotographicStylesBottomControlDeck: View",
            'label: "TONE"',
            'label: "COLOR"',
            'label: "PALETTE"',
            "PhotographicStyleDotGridCanvas: View, Animatable",
            "PhotographicStyleLuminousCursor: View, Animatable",
            "snapEnterDeadzone: Float = 0.04",
            "snapExitDeadzone: Float = 0.065",
            "monospacedDigit()",
            "PhotographicPalettePillSlider",
            "triggerPadGridTick()",
            "FillStyle(eoFill: true)",
        ]:
            self.assertIn(token, pad)
        self.assertNotIn("electricCyan", pad)
        self.assertNotIn("iridescentRainbow", pad)

        unified = source("Services/UnifiedMetalColorEngine.swift")
        self.assertIn("params.splitTransition.leftStyle", unified)
        self.assertIn("params.splitTransition.rightStyle", unified)
        self.assertIn("public func finishPhotographicStyleSwipe(", vm)

        main_view = source("Views/CameraMainView.swift")
        self.assertIn("PhotographicStyleQuickTriggerButton(viewModel: viewModel)", main_view)
        self.assertIn("PhotographicStylesTopHUDBar(viewModel: viewModel, compact: layout.isCompact)", main_view)
        self.assertIn("PhotographicStylesViewfinderOverlay(", main_view)
        self.assertIn("PhotographicStylesBottomControlDeck(viewModel: viewModel, compact: layout.isCompact)", main_view)

        # 5. All 3 new Swift files registered cleanly in project.pbxproj
        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in [
            "PhotographicStyleModels.swift",
            "PhotographicStyleMetalKernel.swift",
            "PhotographicStylesPadView.swift",
        ]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)

    def test_18_filmic_metal_color_science_pipeline(self):
        # 1. Single-Pass Metal Filmic Color Science Kernels (Gamut+C1 Rolloff, Local YIQ SH, Matte Fade+Exposure)
        kernel = source("Services/FilmicColorScienceKernel.swift")
        for token in [
            "kernel void filmicGamutHighlightProtect(",
            "kernel void filmicLocalShadowHighlightYIQ(",
            "kernel void filmicMatteFadeAndExposure(",
            "yNew + 0.95605023f * iNew + 0.62075494f * qNew",
            "yNew - 0.27205234f * iNew - 0.64720571f * qNew",
            "yNew - 1.10670432f * iNew + 1.70442128f * qNew",
            "(-0.68f * s3) + (1.04f * s2) + (0.42f * s) + float3(0.145f)",
            "makeQuarterResBlurGuide",
            "applyPreLUTGamutAndHighlightProtection",
            "applyLocalShadowHighlightRecovery",
            "applyMatteFadeAndExposure",
        ]:
            self.assertIn(token, kernel)
        self.assertNotIn("cbrtf(", kernel)
        for m_ss in re.finditer(r"smoothstep\(\s*([+-]?\d+(?:\.\d+)?)f\s*,\s*([+-]?\d+(?:\.\d+)?)f", kernel):
            self.assertLess(float(m_ss.group(1)), float(m_ss.group(2)), f"Reversed MSL smoothstep: {m_ss.group(0)}")

        # 2. FilmSimulationCore: Pre-LUT protection, 60 FPS quarter-res clamped Halation & Diffusion, physical grain
        core = source("Services/FilmSimulations/FilmSimulationCore.swift")
        self.assertIn("FilmicColorScience.applyPreLUTGamutAndHighlightProtection(to: input, threshold: 0.82)", core)
        self.assertIn("CIColorClamp", core)
        self.assertIn("let physicalScale = max(1.0, (maxDim / 1100.0)", core)
        self.assertIn("public static func applyLocalShadowHighlight(", core)
        self.assertIn("public static func applyMatteFade(", core)

        # 3. FilmFilterEngine + CameraPreviewView: unified Extended Linear sRGB RGBAh + Local YIQ + Fade + Halation
        engine = source("Services/FilmFilterEngine.swift")
        for token in [
            "public var fade: Float = 0.0",
            "public var halation: Float = 0.0",
            "CGColorSpace.extendedLinearSRGB",
            "CIFormat.RGBAh",
            "FilmSimulationCore.applyLocalShadowHighlight(",
            "FilmSimulationCore.applyMatteFade(",
            "FilmicColorScience.applyMatteFadeAndExposure(",
        ]:
            self.assertIn(token, engine)

        preview = source("Views/CameraPreviewView.swift")
        self.assertIn("CGColorSpace.extendedLinearSRGB", preview)
        self.assertIn("CIFormat.RGBAh", preview)

        overlay = source("Views/ProPhotoControlsOverlayView.swift")
        self.assertIn('case fade = "Độ phai"', overlay)
        self.assertIn('case halation = "Quầng sáng"', overlay)

        pbx = PBXPROJ.read_text(encoding="utf-8")
        self.assertIn("/* FilmicColorScienceKernel.swift */", pbx)
        self.assertIn("/* FilmicColorScienceKernel.swift in Sources */", pbx)

    def test_19_unified_zero_lag_metal_vintage_cameras_date_stamp_light_leak(self):
        # 1. Verify all 18 studio-lit miniature camera PNGs + sample_look.jpg exist and are packaged in CI
        icons_dir = ROOT / "Resources/CameraIcons"
        expected_icons = [
            "cam_classic35.png", "cam_rangefinder_silver.png", "cam_disposable_green.png",
            "cam_folding_orange.png", "cam_rangefinder_black.png", "cam_titanium_compact.png",
            "cam_ricoh_gr.png", "cam_slr_chrome.png", "cam_medium120.png",
            "cam_vhs.png", "cam_8mm.png", "cam_minidv.png",
            "cam_ccd_silver.png", "cam_powershot_black.png", "cam_16mm_cine.png",
            "cam_instax_mint.png", "cam_polaroid_rainbow.png", "cam_retro_phone.png",
            "sample_look.jpg",
        ]
        for fname in expected_icons:
            fpath = icons_dir / fname
            self.assertTrue(fpath.is_file() and fpath.stat().st_size > 2000, f"Missing or tiny asset: {fname}")

        ci_yml = (Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("Payload/AISmartFramingCamera.app/CameraIcons", ci_yml)

        # 2. Verify VintageCameraModels defines date stamp, light leak, recipes, and references ONLY existing .bin LUTs
        vmodels = source("Models/VintageCameraModels.swift")
        for token in [
            "public enum VintageDateStampStyle:",
            "case classicQuartz",
            "case retroLED",
            "case compactSlanted",
            "public struct VintageLightLeakConfig:",
            "public struct VintageCameraOpticalRecipe:",
            "public var cameraIconAssetName: String",
            "public var cameraDisplayTag: String",
            "public var metalOpticalRecipe: VintageCameraOpticalRecipe",
        ]:
            self.assertIn(token, vmodels)

        lut_dir = ROOT / "Resources/LUTs"
        for lut_name in re.findall(r'"([A-Za-z0-9._-]+)"', vmodels):
            if any(lut_name.startswith(prefix) for prefix in ("Beetle.", "Fuji-", "CCD-", "Canon-")):
                self.assertTrue((lut_dir / f"{lut_name}.bin").is_file(), f"Missing .bin LUT referenced in VintageCameraModels: {lut_name}")

        # 3. Verify UnifiedMetalColorEngine 1:1 Swift/MSL struct alignment, safe MSL, .rgba16Float 3D LUT, Light Leak & Date Stamp
        unified = source("Services/UnifiedMetalColorEngine.swift")
        sw_m = re.search(r"private struct UnifiedColorUniforms \{(.*?)init\(", unified, re.S)
        msl_m = re.search(r"struct UnifiedColorUniforms \{(.*?)\};", unified, re.S)
        self.assertIsNotNone(sw_m)
        self.assertIsNotNone(msl_m)
        sw_fields = re.findall(r"var\s+(\w+):\s*SIMD4<Float>", sw_m.group(1))
        msl_fields = re.findall(r"float4\s+(\w+);", msl_m.group(1))
        self.assertEqual(sw_fields, msl_fields, "UnifiedColorUniforms Swift vs MSL field layout mismatch")
        self.assertNotIn("cbrtf(", unified)
        for m_ss in re.finditer(r"smoothstep\(\s*([+-]?\d+(?:\.\d+)?)f\s*,\s*([+-]?\d+(?:\.\d+)?)f", unified):
            self.assertLess(float(m_ss.group(1)), float(m_ss.group(2)), f"Reversed MSL smoothstep: {m_ss.group(0)}")
        for token in [
            "CVMetalTextureCacheCreateTextureFromImage",
            "kernel void unifiedCameraGradeYUV(",
            "kernel void unifiedCameraGradeBGRA(",
            ".rgba16Float",
            "evaluateOrganicLightLeak(",
            "public enum VintageDateStampRenderer",
            "public final class VintageCameraIconCache",
        ]:
            self.assertIn(token, unified)

        # 4. Verify Zero-Lag 60 FPS Architecture (non-blocking semaphore, background renderQueue, cached metal availability, zero-blur cursor)
        preview = source("Views/CameraPreviewView.swift")
        for token in [
            "mtk.preferredFramesPerSecond = 60",
            "DispatchSemaphore(value: 2)",
            "DispatchQueue(label: \"com.alignai.metal.preview\", qos: .userInteractive)",
            "UnifiedMetalColorEngine.shared.encodePreviewFrame(",
            "func pushLiveColorStateFast(",
            "lastSyncedDualActive",
        ]:
            self.assertIn(token, preview)

        self.assertIn("public static let isMetalAvailable: Bool =", source("Services/PhotographicStyleMetalKernel.swift"))
        self.assertIn("public static let isMetalAvailable: Bool =", source("Services/FilmicColorScienceKernel.swift"))
        pad = source("Views/PhotographicStylesPadView.swift")
        self.assertNotIn(".blur(radius: 7.0 + 6.5 * g)", pad)
        self.assertNotIn(".blur(radius: 3.5 + 3.8 * g)", pad)

        # 5. Verify Dazz-inspired Drawer UI, Sample Look, Viewfinder Date Stamp Overlay, Engine & ViewModel wiring
        drawer = source("Views/VintageCameraDrawerView.swift")
        for token in [
            "public struct VintageHardwareCameraCard: View",
            "public struct VintageCameraDrawerView: View",
            "public struct VintageSampleLookPreviewSheet: View",
            "public struct VintageDateStampViewfinderOverlay: View",
            "Light Leak Ngẫu Nhiên",
            "Dấu Thời Gian",
            "ẢNH MẪU",
        ]:
            self.assertIn(token, drawer)

        main_view = source("Views/CameraMainView.swift")
        self.assertIn("VintageDateStampViewfinderOverlay(viewModel: viewModel)", main_view)

        engine = source("Services/FilmFilterEngine.swift")
        self.assertIn("public var activeLightLeak: VintageLightLeakConfig", engine)
        self.assertIn("public var activeDateStampStyle: VintageDateStampStyle", engine)
        self.assertIn("UnifiedMetalColorEngine.shared.renderStillCGImage(", engine)

        vm = source("ViewModels/CameraViewModel.swift")
        for token in [
            "@Published public var vintageLightLeak: VintageLightLeakConfig = .off",
            "@Published public var vintageDateStampStyle: VintageDateStampStyle = .off",
            "public func setLightLeakIntensity(",
            "public func shuffleLightLeakPattern()",
            "public func selectVintageDateStampStyle(",
            "private func pushLiveColorStateFastToPreview()",
        ]:
            self.assertIn(token, vm)

        pbx = PBXPROJ.read_text(encoding="utf-8")
        for filename in [
            "VintageCameraModels.swift",
            "UnifiedMetalColorEngine.swift",
            "VintageCameraDrawerView.swift",
        ]:
            self.assertIn(f"/* {filename} */", pbx)
            self.assertIn(f"/* {filename} in Sources */", pbx)

    def test_20_full_width_9_16_video_viewfinder_zero_black_bars_and_gentle_05x(self):
        # 1. CameraMainView must size Video viewfinder to true full-width 9:16 (0 black bars, 1.000x exact FOV)
        main_view = source("Views/CameraMainView.swift")
        for token in [
            "var photoViewfinderSize: CGSize",
            "var videoViewfinderSize: CGSize",
            "let targetAspect: CGFloat = 9.0 / 16.0",
            "isVideo ? videoViewfinderSize : photoViewfinderSize",
            "var viewfinderTopY: CGFloat",
            "var viewfinderTopOverlayInset: CGFloat",
            "var viewfinderBottomOverlayInset: CGFloat",
            ".padding(.bottom, layout.viewfinderBottomOverlayInset)",
        ]:
            self.assertIn(token, main_view)
        self.assertNotIn("let isAspectFitVideo =", main_view)

        # 2. CameraPreviewView must never pillarbox Video inside 3:4 (.resizeAspect) or set isVideoMode aspect-fit
        preview = source("Views/CameraPreviewView.swift")
        self.assertIn("let targetGravity: AVLayerVideoGravity = .resizeAspectFill", preview)
        self.assertNotIn("? .resizeAspect : .resizeAspectFill", preview)
        self.assertIn("isVideoMode: false", preview)

        # 3. CameraControlsView leaves transparent background in Video mode so translucent scrim shows full 9:16 frame
        controls = source("Views/CameraControlsView.swift")
        self.assertIn("if viewModel.captureMode.isVideo", controls)

        # 4. UltraWideWarpEngine calibrates simulated 0.5x anti-distortion identically for Liveview & Still Photo
        uw = source("Services/UltraWideWarpEngine.swift")
        self.assertIn("private static func calibratedAntiDistortionZoom(for rawFactor: CGFloat) -> Float", uw)
        self.assertIn("let defaultRigidity: Float = 0.85", uw)
        self.assertIn("let rigidity = max(0.85, sceneMetrics.architecturalLineStrength)", uw)

    def test_21_photo_review_zoom_pan_and_photographic_styles_v3(self):
        # 1. Post-capture photo review uses fullScreenCover + interactiveDismissDisabled + stationary gesture space
        main_view = source("Views/CameraMainView.swift")
        gallery = source("Views/PhotoGallerySheetView.swift")
        preview_sheet = source("Views/CapturedPhotoPreviewView.swift")
        self.assertIn(".fullScreenCover(isPresented: $viewModel.isShowingPhotoDetail)", main_view)
        self.assertIn(".fullScreenCover(item: $selectedPreviewItem)", gallery)
        for token in [
            ".interactiveDismissDisabled(zoomScale > 1.02 || isSplitCompareMode)",
            ".coordinateSpace(name: \"capturedPhotoHeroSpace\")",
            "@State private var dismissDragOffsetY: CGFloat = 0.0",
            "if zoomScale > 1.02 {",
        ]:
            self.assertIn(token, preview_sheet)

        # 2. Full 16 Photographic Styles + Styles 3 Texture/Grain + Saved Custom Recipes
        models = source("Models/PhotographicStyleModels.swift")
        for preset_case in [
            "case coolMood", "case neutral", "case bright", "case softRose", "case gold", "case warmAmber",
            "case standard",
            "case vibrant", "case naturalMood", "case luminous", "case richContrast",
            "case quiet", "case cozy", "case ethereal", "case mutedBW", "case starkBW",
        ]:
            self.assertIn(preset_case, models)
        for token in [
            "public enum PhotographicTextureMode",
            "case softSkin", "case glow", "case film",
            "public struct PhotographicStyleCustomRecipe",
            "public enum PhotographicStyleRecipeStore",
            "if !preset.isMonochrome && palette < 0.005",
        ]:
            self.assertIn(token, models)

        # 3. Single-Pass Metal 4-Band Semantic OkLab + Live Styles 3 Soft Skin/Glow/Film/Grain + 1:1 Uniform Parity
        unified = source("Services/UnifiedMetalColorEngine.swift")
        kernel = source("Services/PhotographicStyleMetalKernel.swift")
        for token in [
            "computeSkyMaskOkLab",
            "computeFoliageMaskOkLab",
            "computeWarmRedMaskOkLab",
            "styleA_semantic",
            "styleB_semantic",
            "styleTexture",
            "thread float3& outSoftSkin",
            "bool computeSoftSkin",
        ]:
            self.assertIn(token, unified)

        for path_src, struct_name, expected_count in [
            (unified, "UnifiedColorUniforms", 41),
            (kernel, "PhotographicStyleUniforms", 10),
        ]:
            m_sw = re.search(rf"struct {struct_name}\s*\{{(.*?)\n\s*(?:init|\}})", path_src, re.S)
            m_msl = re.search(rf"struct {struct_name}\s*\{{(.*?)\n\s*\}};", path_src, re.S)
            self.assertIsNotNone(m_sw)
            self.assertIsNotNone(m_msl)
            sw_fields = re.findall(r"var\s+(\w+)\s*:\s*SIMD4<Float>", m_sw.group(1))
            msl_fields = re.findall(r"float4\s+(\w+)\s*;", m_msl.group(1))
            self.assertEqual(sw_fields, msl_fields)
            self.assertEqual(len(sw_fields), expected_count)

        # 4. Tight clipped cursor orb (no 70pt overflow fog) + Tap-to-Edit HUD + Hold-to-Compare + Texture Deck + Recipes
        pad = source("Views/PhotographicStylesPadView.swift")
        self.assertNotIn("34.0 + 36.0 * g", pad)
        for token in [
            "private enum PhotographicStyleNudgeMetric",
            "precisionNudgeBar(for:",
            "setPhotographicStyleHoldCompare(true)",
            "PhotographicStyleTextureDeckView",
            "PhotographicStyleRecipesSheet",
            "defaultTone: preset.defaultTone",
            "defaultColor: preset.defaultColor",
            "let outerAuraDiameter: CGFloat = coreDiameter + 5.0 + 4.5 * g",
            ".clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))",
        ]:
            self.assertIn(token, pad)

        # 5. CameraViewModel exposes Texture, Grain, Hold-to-Compare, Nudge, and Recipe actions
        vm = source("ViewModels/CameraViewModel.swift")
        for token in [
            "isHoldingCompareOriginalStyle",
            "savedPhotographicRecipes",
            "public func nudgePhotographicStyle(",
            "public func selectPhotographicTextureMode(",
            "public func togglePhotographicGrain()",
            "public func saveCurrentPhotographicRecipe(",
            "public func applyPhotographicRecipe(",
        ]:
            self.assertIn(token, vm)

    def test_22_photobooth_studio_and_mechanical_shutter_engine(self):
        # 1. Verify all 6 new Swift files exist and are registered in Xcode project.pbxproj
        pbx = PBXPROJ.read_text(encoding="utf-8")
        new_files = [
            "Services/MechanicalShutterEngine.swift",
            "Models/PhotoboothModels.swift",
            "Services/PhotoboothAssetManager.swift",
            "Services/PhotoboothStripRenderer.swift",
            "Views/PhotoboothCameraOverlayView.swift",
            "Views/PhotoboothEditorSheetView.swift",
        ]
        for rel in new_files:
            fname = rel.split("/")[-1]
            self.assertTrue((ROOT / rel).exists(), f"Missing {rel}")
            self.assertIn(f"/* {fname} */", pbx)
            self.assertIn(f"/* {fname} in Sources */", pbx)

        # 2. Verify all 24 bundled transparent PNG stickers exist + CI copies PhotoboothAssets/
        pb_dir = ROOT / "Resources" / "PhotoboothAssets"
        pngs = list(pb_dir.glob("pb_*.png"))
        self.assertEqual(len(pngs), 24, f"Expected 24 bundled stickers, found {len(pngs)}")
        for p in pngs:
            head = p.read_bytes()[:8]
            self.assertEqual(head, b"\x89PNG\r\n\x1a\n", f"Invalid PNG header in {p.name}")

        yml = (ROOT.parent / ".github" / "workflows" / "ios-build.yml").read_text(encoding="utf-8")
        self.assertIn("PhotoboothAssets", yml)

        # 3. Verify Mechanical Shutter Engine & CoreHaptics wiring
        shutter = source("Services/MechanicalShutterEngine.swift")
        for token in [
            "public enum MechanicalShutterProfile",
            "case autoMatch", "case leicaM", "case nikonFM2", "case contaxT2",
            "case hasselblad500", "case polaroidSX70", "case silentHaptic",
            "AVAudioEngine", "CHHapticEngine", "mixWithOthers",
            "public func fireShutter()",
            "public func fireShutterHalfPress()",
            "public func fireMechanicalDialTick()",
            "public func fireCountdownTick(",
        ]:
            self.assertIn(token, shutter)

        haptics = source("Services/HapticFeedbackService.swift")
        self.assertIn("MechanicalShutterEngine.shared.fireShutter()", haptics)
        self.assertIn("MechanicalShutterEngine.shared.fireShutterHalfPress()", haptics)

        # 4. Verify Photobooth Asset Manager (bundled + online + Gemini + Pollinations + Vision Cutout)
        assets_mgr = source("Services/PhotoboothAssetManager.swift")
        for token in [
            "VNGenerateForegroundInstanceMaskRequest",
            "gemini-2.5-flash-image",
            "gemini-nano-banana-2.1",
            "image.pollinations.ai/prompt",
            "downloadOnlinePack",
            "generateAISticker",
            "generateAIFrameTexture",
            "stylizeBoothPhotoWithAI",
            "renderOfflineProceduralSticker",
        ]:
            self.assertIn(token, assets_mgr)

        # 5. Verify Photobooth Layouts & 16 Editorial Frames + 300 DPI Compositor
        pb_models = source("Models/PhotoboothModels.swift")
        for layout_case in [
            "case strip4x1", "case grid2x2", "case strip3x1",
            "case couple2x1", "case mini6Cut", "case polaroidSingle",
        ]:
            self.assertIn(layout_case, pb_models)

        renderer = source("Services/PhotoboothStripRenderer.swift")
        for frame_tok in [
            ".kodak35mmSprocket", ".dailyNewspaper", ".vintageCinemaTicket",
            ".thermalReceipt", ".cafeGingham", ".y2kBrushedChrome",
            ".customAITexture", "drawEditorialFrameBackground",
        ]:
            self.assertIn(frame_tok, renderer)

        # 6. Verify CameraViewModel, Controls, MainView & Settings UI integration
        vm = source("ViewModels/CameraViewModel.swift")
        main_view = source("Views/CameraMainView.swift")
        overlay_view = source("Views/PhotoboothCameraOverlayView.swift")
        settings = source("Views/SettingsSheetView.swift")
        gate = source("Models/CameraFeatureGate.swift")

        self.assertIn("case photobooth", gate)
        for token in ["enterPhotoboothMode", "exitPhotoboothMode", "startPhotoboothCaptureOrSequence", "savePhotoboothStripToLibrary"]:
            self.assertIn(token, vm)
        self.assertIn("PhotoboothQuickTriggerButton", main_view)
        self.assertIn("struct PhotoboothQuickTriggerButton", overlay_view)
        self.assertIn("PhotoboothTopBar", main_view)
        self.assertIn("PhotoboothEditorSheetView", main_view)
        self.assertIn("mechanicalShutterCard", settings)


if __name__ == "__main__":
    unittest.main()
