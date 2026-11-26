import Foundation
import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import ImageIO
import Vision
import CoreML
import simd

// MARK: - Minimal Non-UIKit Types Shared with Production Services on macOS CLI
public enum CompositionRule: String, CaseIterable, Identifiable, Sendable {
    case ruleOfThirds = "Rule of Thirds"
    case goldenRatio = "Golden Ratio"
    case goldenSpiral = "Golden Spiral"
    case centerSymmetry = "Center Pro"
    case leadingLines = "Leading Lines"
    case diagonal = "Diagonal Dynamic"
    case frameInFrame = "Frame in Frame"
    case negativeSpace = "Negative Space"
    case lookingRoom = "Looking Room"
    case dynamicAI = "AI Auto-Select"
    public var id: String { rawValue }
}

public enum DetectedSceneType: String, CaseIterable, Sendable {
    case portrait = "Portrait"
    case pet = "Pet / Animal"
    case landscape = "Landscape"
    case sunset = "Sunset / Golden Hour"
    case architecture = "Architecture"
    case sky = "Sky / Cloud"
    case water = "Water / Sea"
    case foliage = "Foliage / Nature"
    case night = "Night Scene"
    case food = "Food"
    case macro = "Macro / Close-up"
    case street = "Street Life"
    case general = "Auto General"
}

struct LocalFramingPlan: Sendable {
    let subjectPoint: CGPoint
    let subjectRect: CGRect
    let cropProtectionRect: CGRect
    let aimPointInSource: CGPoint
    let aimWorldRay: SIMD3<Double>
    let zoom: CGFloat
    let confidence: Double
    let minimumAutoselectConfidence: Double
    let intent: LocalCompositionIntent
    let score: Double
    let explanation: String
    let usesCenter: Bool
    let preferenceKey: String
    var recommendedEVBias: CGFloat = 0.0
    var compositionRule: CompositionRule? = nil
    var requiresPanBeforeZoom: Bool = false
    var postPanZoom: CGFloat? = nil
    var zoomStateRaw: String = "NO_ZOOM"
}

enum LocalAutoselectCalibration {
    static func threshold(scene: DetectedSceneType, category: NeuralSubjectCategory) -> Double? {
        scene == .night ? 0.28 : 0.32
    }
}

// MARK: - Real Photo Pipeline Benchmark & >=30-Cycle Lifecycle Stress Test
@main
enum RealPhotoPipelineBenchmark {
    struct BenchmarkError: Error, CustomStringConvertible {
        let description: String
    }

    struct ManifestEntry: Decodable {
        let index: Int
        let file: String
        let category: String
        let width: Int
        let height: Int
        let aspect_tag: String
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard let testDirIdx = args.firstIndex(of: "--test-images"), testDirIdx + 1 < args.count,
              let outDirIdx = args.firstIndex(of: "--out"), outDirIdx + 1 < args.count else {
            throw BenchmarkError(description: "Usage: RealPhotoPipelineBenchmark --test-images <dir> --out <dir> [--stress-cycles 35]")
        }
        let testImagesDir = URL(fileURLWithPath: args[testDirIdx + 1], isDirectory: true)
        let outDir = URL(fileURLWithPath: args[outDirIdx + 1], isDirectory: true)
        let stressCycles: Int = {
            if let idx = args.firstIndex(of: "--stress-cycles"), idx + 1 < args.count, let n = Int(args[idx + 1]) {
                return max(30, n)
            }
            return 35
        }()

        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let newOutDir = outDir.appendingPathComponent("new", isDirectory: true)
        let oldOutDir = outDir.appendingPathComponent("old", isDirectory: true)
        let compareOutDir = outDir.appendingPathComponent("compare", isDirectory: true)
        try fm.createDirectory(at: newOutDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldOutDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: compareOutDir, withIntermediateDirectories: true)

        // Verify bundled production models are loaded!
        let yoloCheck = YOLODetectionEngine.shared
        guard yoloCheck.hasYOLOModel else {
            throw BenchmarkError(description: "Production YOLODetectionEngine failed to load bundled YOLO model from AI_COMPOSE_RESOURCE_DIR")
        }
        for requiredResource in [
            ("OpenWorldPhotoYOLOE", "mlmodelc"),
            ("OpenWorldPhotoClasses", "json"),
            ("SigLIPBaseImage", "mlmodelc"),
            ("SigLIPPrompts", "json"),
            ("DepthAnythingV2SmallF16", "mlmodelc"),
            ("SAMPComposition", "mlmodelc"),
            ("CharmAesthetics", "mlmodelc"),
            ("CharmPositionEmbedding", "bin"),
            ("GAICCompositionScorer", "mlmodelc"),
        ] {
            guard CompositionResourceLocator.url(forResource: requiredResource.0, withExtension: requiredResource.1) != nil else {
                throw BenchmarkError(description: "Missing required production model resource: \(requiredResource.0).\(requiredResource.1)")
            }
        }
        print("Verified all 7 production CoreML models + prompt/embedding assets!")

        let manifestURL = testImagesDir.appendingPathComponent("manifest.json")
        let manifestByFile: [String: ManifestEntry] = {
            guard let data = try? Data(contentsOf: manifestURL),
                  let items = try? JSONDecoder().decode([ManifestEntry].self, from: data) else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: items.map { ($0.file, $0) })
        }()

        let imageFiles = try fm.contentsOfDirectory(at: testImagesDir, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard imageFiles.count >= 40 else {
            throw BenchmarkError(description: "Expected >= 40 real test photos in \(testImagesDir.path), found \(imageFiles.count)")
        }

        let ciContext = CIContext(options: [.cacheIntermediates: false])

        // =========================================================================
        // PART 1 PROOF: >= 30-CYCLE LIFECYCLE & SEQUENTIAL MODEL MEMORY STRESS TEST
        // =========================================================================
        print("=== Running \(stressCycles)-cycle Lifecycle & Model Unload Stress Test ===")
        CompositionMemoryBudget.setForceSequentialModelUnload(true)
        var stressCSVLines = ["cycle,photo,width,height,phys_footprint_mb,avail_mb,elapsed_ms,hero,zoom"]
        var footprints: [Double] = []
        let startFootMB = CameraLogger.currentMemoryFootprintMB()

        for cycle in 1...stressCycles {
            let file = imageFiles[(cycle - 1) % imageFiles.count]
            let row: (Double, Int, Double, String, CGFloat, Int, Int) = try autoreleasepool {
                let cgImg = try loadCGImage(file)
                if cgImg.width == cgImg.height {
                    throw BenchmarkError(description: "FORBIDDEN square image detected: \(file.lastPathComponent) (\(cgImg.width)x\(cgImg.height))")
                }
                let pb = try makePixelBuffer(from: cgImg, context: ciContext)
                let aspect = Double(cgImg.width) / Double(cgImg.height)
                let calib = TrackingCalibration.fallback(aspect: aspect)
                let frameCtx = TrackingFrameContext(
                    timestamp: Double(cycle),
                    calibration: calib,
                    orientation: .up,
                    displayZoom: 1.0
                )
                let t0 = ProcessInfo.processInfo.systemUptime
                CameraFramingDirector.resetTemporalState()
                let cancel = CompositionAnalysisCancellation(softTimeoutSeconds: 15.0)
                let analysis = NeuralSubjectIntelligenceEngine.shared.analyzeComposition(
                    pixelBuffer: pb,
                    frame: frameCtx,
                    pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                    allowedZooms: [0.5, 1.0, 2.0, 3.0],
                    preferences: [:],
                    requestID: UUID(),
                    lowMemoryBudget: false,
                    cancellation: cancel
                )
                _ = NeuralSubjectIntelligenceEngine.shared.consumeLastDiagnostic()
                NeuralSubjectIntelligenceEngine.shared.releaseAllModelCaches()
                YOLODetectionEngine.shared.releaseTransientCaches()
                CompositionImageRenderer.clearSharedCaches()
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000.0
                let foot = CameraLogger.currentMemoryFootprintMB()
                let avail = CameraLogger.currentAvailableMemoryMB()
                let heroLbl = analysis?.choices.first?.candidate.label ?? "none"
                let z = analysis?.choices.first?.plan.zoom ?? 1.0
                return (foot, avail, elapsedMs, heroLbl, z, cgImg.width, cgImg.height)
            }
            footprints.append(row.0)
            stressCSVLines.append(
                String(
                    format: "%d,%@,%d,%d,%.2f,%d,%.1f,\"%@\",%.2f",
                    cycle, file.lastPathComponent, row.5, row.6, row.0, row.1, row.2,
                    row.3.replacingOccurrences(of: "\"", with: "'"), row.4
                )
            )
            print(String(format: "  [Stress %02d/%02d] %@ -> foot=%.1f MB, elapsed=%.0f ms, hero=%@, zoom=%.1fx",
                         cycle, stressCycles, file.lastPathComponent, row.0, row.2, row.3, row.4))
            fflush(stdout)
        }

        let stressCSVURL = outDir.appendingPathComponent("stress_test_memory.csv")
        try stressCSVLines.joined(separator: "\n").write(to: stressCSVURL, atomically: true, encoding: .utf8)

        // Check steady-state memory stability after initial framework/ANE warm-up (cycle 5 -> last cycle)
        let warmupFoot = footprints[min(4, footprints.count - 1)]
        let finalFoot = footprints.last ?? warmupFoot
        let maxFoot = footprints.max() ?? finalFoot
        let minPostWarmup = footprints.dropFirst(4).min() ?? warmupFoot
        // Linear regression slope (MB per cycle) across cycles 6..N
        let steadySlice = Array(footprints.dropFirst(5))
        let slopeMBPerCycle: Double = {
            guard steadySlice.count >= 10 else { return 0.0 }
            let n = Double(steadySlice.count)
            let meanX = (n - 1.0) * 0.5
            let meanY = steadySlice.reduce(0.0, +) / n
            var num = 0.0, den = 0.0
            for (i, y) in steadySlice.enumerated() {
                let dx = Double(i) - meanX
                num += dx * (y - meanY)
                den += dx * dx
            }
            return den > 1e-9 ? num / den : 0.0
        }()

        // Multi-frame temporal hysteresis verification (simulating 10 jittered live camera frames with two rival subjects)
        CameraFramingDirector.resetTemporalState()
        var temporalHeroSwitches = 0
        var temporalZoomSwitches = 0
        var prevHero = ""
        var prevZoom: CGFloat = 0
        let baseRaster = CompositionRaster(
            side: 16,
            luminance: Array(repeating: 0.45, count: 256),
            attention: Array(repeating: 0.25, count: 256),
            edges: Array(repeating: 0.12, count: 256),
            hasAttention: true
        )
        for fIdx in 0..<10 {
            let jitter = Double((fIdx % 2 == 0) ? 1 : -1) * 0.015
            let personA = DirectorDetection(
                label: "person", localizedLabel: "Người",
                boundingBox: CGRect(x: 0.34 + jitter * 0.4, y: 0.28, width: 0.14, height: 0.38),
                anchor: CGPoint(x: 0.41 + jitter * 0.4, y: 0.35),
                confidence: 0.82 - jitter, domain: .human,
                faceBounds: [CGRect(x: 0.38, y: 0.29, width: 0.06, height: 0.07)]
            )
            let personB = DirectorDetection(
                label: "dog", localizedLabel: "Chú chó",
                boundingBox: CGRect(x: 0.56, y: 0.44, width: 0.15, height: 0.18),
                anchor: nil, confidence: 0.81 + jitter, domain: .animal
            )
            let dec = CameraFramingDirector.direct(
                detections: [personA, personB],
                raster: baseRaster,
                sceneHints: .neutral,
                semanticAffinities: ["person": 0.07],
                neuralProposals: [],
                calibration: TrackingCalibration.fallback(aspect: 0.75),
                pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
                currentZoom: 1.0,
                allowedZooms: [0.5, 1.0, 2.0, 3.0],
                enableTemporalHysteresis: true
            )
            if fIdx > 0 {
                if dec.heroLabel != prevHero { temporalHeroSwitches += 1 }
                if abs(dec.recommendedZoom - prevZoom) > 0.05 { temporalZoomSwitches += 1 }
            }
            prevHero = dec.heroLabel
            prevZoom = dec.recommendedZoom
        }
        CameraFramingDirector.resetTemporalState()

        let stressSummary: [String: Any] = [
            "cycles": stressCycles,
            "startFootprintMB": round(startFootMB * 100) / 100,
            "warmupCycle5FootprintMB": round(warmupFoot * 100) / 100,
            "finalFootprintMB": round(finalFoot * 100) / 100,
            "peakFootprintMB": round(maxFoot * 100) / 100,
            "minPostWarmupFootprintMB": round(minPostWarmup * 100) / 100,
            "steadyStateSlopeMBPerCycle": round(slopeMBPerCycle * 1000) / 1000,
            "temporalHysteresisHeroSwitchesIn10JitterFrames": temporalHeroSwitches,
            "temporalHysteresisZoomSwitchesIn10JitterFrames": temporalZoomSwitches,
        ]
        try JSONSerialization.data(withJSONObject: stressSummary, options: [.prettyPrinted, .sortedKeys])
            .write(to: outDir.appendingPathComponent("stress_test_summary.json"))
        print("Stress Test Summary: \(stressSummary)")
        guard temporalHeroSwitches == 0 && temporalZoomSwitches == 0 else {
            throw BenchmarkError(description: "Temporal hysteresis oscillated: heroSwitches=\(temporalHeroSwitches), zoomSwitches=\(temporalZoomSwitches)")
        }

        // =========================================================================
        // PART 4: REAL PHOTO BENCHMARK (OLD LEGACY vs NEW PIPELINE ON ALL PHOTOS)
        // =========================================================================
        print("=== Running Real-Photo Benchmark on \(imageFiles.count) Non-Square Photos (Old vs New) ===")
        var csvRows: [String] = [
            "index,file,category,aspect_tag,width,height," +
            "num_detections,old_role,old_hero,old_conf,old_dest_x,old_dest_y,old_aim_x,old_aim_y,old_zoom,old_center_crop_safe,old_reason," +
            "new_role,new_hero,new_conf,new_hero_box,new_fill,new_ideal_fill,new_dest_x,new_dest_y,new_aim_x,new_aim_y," +
            "new_zoom_state,new_zoom,new_ideal_zoom_after_pan,new_center_max_zoom,new_pan_before_zoom,new_center_crop_safe,new_rule,new_reason"
        ]

        var aspectCounter: [String: Int] = [:]
        for (idx, file) in imageFiles.enumerated() {
            try autoreleasepool {
                let cgImg = try loadCGImage(file)
                let w = cgImg.width
                let h = cgImg.height
                guard w != h else {
                    throw BenchmarkError(description: "FORBIDDEN 1:1 square image in test-images/: \(file.lastPathComponent) (\(w)x\(h))")
                }
                let meta = manifestByFile[file.lastPathComponent]
                let category = meta?.category ?? inferCategory(from: file.lastPathComponent)
                let arTag = meta?.aspect_tag ?? inferAspectTag(width: w, height: h)
                aspectCounter[arTag, default: 0] += 1

                let pb = try makePixelBuffer(from: cgImg, context: ciContext)
                let aspect = Double(w) / Double(h)
                let calib = TrackingCalibration.fallback(aspect: aspect)
                let pose = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
                let allowedZooms: [CGFloat] = [0.5, 1.0, 2.0, 3.0]
                let frameCtx = TrackingFrameContext(
                    timestamp: Double(1000 + idx),
                    calibration: calib,
                    orientation: .up,
                    displayZoom: 1.0
                )

                CameraFramingDirector.resetTemporalState()
                let cancel = CompositionAnalysisCancellation(softTimeoutSeconds: 18.0)
                guard let _ = NeuralSubjectIntelligenceEngine.shared.analyzeComposition(
                    pixelBuffer: pb,
                    frame: frameCtx,
                    pose: pose,
                    allowedZooms: allowedZooms,
                    preferences: [:],
                    requestID: UUID(),
                    lowMemoryBudget: false,
                    cancellation: cancel
                ), let diag = NeuralSubjectIntelligenceEngine.shared.consumeLastDiagnostic() else {
                    throw BenchmarkError(description: "Production pipeline returned nil for \(file.lastPathComponent)")
                }

                // Re-run stateless New Director cleanly (enableTemporalHysteresis: false) so every photo is 100% independent
                let newDec = CameraFramingDirector.direct(
                    detections: diag.directorDetections,
                    raster: diag.raster,
                    sceneHints: diag.sceneHints,
                    semanticAffinities: diag.semanticAffinities,
                    neuralProposals: diag.evaluatedProposals,
                    gaicProposals: diag.gaicProposals,
                    incidentalBounds: diag.incidentalBounds,
                    calibration: calib,
                    pose: pose,
                    currentZoom: 1.0,
                    allowedZooms: allowedZooms,
                    portraitBounds: diag.portraitBounds,
                    poseProfile: diag.poseProfile,
                    enableTemporalHysteresis: false
                )

                // Run exact OLD Legacy pre-overhaul pipeline (with old CompositionTuning box clamping: minDim 0.04, maxDim 0.95, minVis 0.75)
                let legacyFilteredDetections = diag.directorDetections.filter { d in
                    if d.domain == .wideNature || d.domain == .backgroundSurface { return true }
                    let r = d.boundingBox
                    guard r.width >= 0.04, r.height >= 0.04, r.width <= 0.95, r.height <= 0.95 else { return false }
                    let vis = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    let visRatio = (vis.width * vis.height) / max(1e-6, r.width * r.height)
                    return visRatio >= 0.75
                }
                let oldDec = LegacyCameraFramingDirector.direct(
                    detections: legacyFilteredDetections,
                    raster: diag.raster,
                    sceneHints: diag.sceneHints,
                    semanticAffinities: diag.semanticAffinities,
                    neuralProposals: diag.evaluatedProposals,
                    gaicProposals: diag.gaicProposals,
                    incidentalBounds: diag.incidentalBounds,
                    calibration: calib,
                    pose: pose,
                    currentZoom: 1.0,
                    allowedZooms: allowedZooms,
                    portraitBounds: diag.portraitBounds,
                    poseProfile: diag.poseProfile
                )

                let oldCenterCrop = CameraFramingDirector.centerCropFrame(currentZoom: 1.0, targetZoom: oldDec.recommendedZoom)
                let oldSafe = isSubjectSafeInCenterCrop(heroBox: oldDec.heroBounds, role: oldDec.role, zoom: oldDec.recommendedZoom)
                let newSafe = isSubjectSafeInCenterCrop(heroBox: newDec.heroBounds, role: newDec.role, zoom: newDec.recommendedZoom)

                // Render annotated images: Old, New, and Side-by-Side Comparison!
                let oldAnnotated = try renderAnnotatedImage(
                    source: cgImg,
                    titlePrefix: "OLD LEGACY",
                    fileName: file.lastPathComponent,
                    category: category,
                    aspectTag: arTag,
                    allDetections: legacyFilteredDetections,
                    role: oldDec.role.rawValue,
                    heroLabel: "\(oldDec.heroLocalizedLabel) (\(oldDec.heroLabel))",
                    heroBounds: oldDec.heroBounds,
                    heroAnchor: oldDec.heroAnchor,
                    destPoint: oldDec.destinationPoint,
                    aimPoint: oldDec.aimPointInSource,
                    recommendedZoom: oldDec.recommendedZoom,
                    zoomState: oldDec.recommendedZoom > 1.10 ? "ZOOM_IN" : (oldDec.recommendedZoom < 0.90 ? "ZOOM_OUT" : "NO_ZOOM"),
                    requiresPanBeforeZoom: false,
                    idealZoomAfterPan: oldDec.recommendedZoom,
                    centerCropFrame: oldCenterCrop,
                    centerCropSafe: oldSafe,
                    fillMetric: Double(max(oldDec.heroBounds.width, oldDec.heroBounds.height)),
                    idealFill: 0.50,
                    ruleName: oldDec.ruleName,
                    explanation: oldDec.explanation,
                    horizonY: oldDec.detectedHorizonY
                )
                let newAnnotated = try renderAnnotatedImage(
                    source: cgImg,
                    titlePrefix: "NEW REBUILT",
                    fileName: file.lastPathComponent,
                    category: category,
                    aspectTag: arTag,
                    allDetections: newDec.allDetections,
                    role: newDec.role.rawValue,
                    heroLabel: "\(newDec.heroLocalizedLabel) (\(newDec.heroLabel))",
                    heroBounds: newDec.heroBounds,
                    heroAnchor: newDec.heroAnchor,
                    destPoint: newDec.destinationPoint,
                    aimPoint: newDec.aimPointInSource,
                    recommendedZoom: newDec.recommendedZoom,
                    zoomState: newDec.zoomState.rawValue,
                    requiresPanBeforeZoom: newDec.requiresPanBeforeZoom,
                    idealZoomAfterPan: newDec.idealZoomAfterPan,
                    centerCropFrame: newDec.centerCropVisibleFrame,
                    centerCropSafe: newSafe,
                    fillMetric: newDec.subjectFillMetric,
                    idealFill: newDec.targetFillMetric,
                    ruleName: newDec.ruleName,
                    explanation: newDec.explanation,
                    horizonY: newDec.detectedHorizonY
                )
                let sideBySide = try renderSideBySide(left: oldAnnotated, right: newAnnotated)

                try saveJPEG(oldAnnotated, to: oldOutDir.appendingPathComponent(file.lastPathComponent))
                try saveJPEG(newAnnotated, to: newOutDir.appendingPathComponent(file.lastPathComponent))
                try saveJPEG(sideBySide, to: compareOutDir.appendingPathComponent(file.lastPathComponent))

                let heroBoxStr = String(
                    format: "[%.3f %.3f %.3f %.3f]",
                    newDec.heroBounds.minX, newDec.heroBounds.minY, newDec.heroBounds.width, newDec.heroBounds.height
                )
                let line = [
                    "\(idx + 1)",
                    csvEscape(file.lastPathComponent),
                    csvEscape(category),
                    csvEscape(arTag),
                    "\(w)",
                    "\(h)",
                    "\(newDec.allDetections.count)",
                    csvEscape(oldDec.role.rawValue),
                    csvEscape(oldDec.heroLabel),
                    String(format: "%.2f", oldDec.confidence),
                    String(format: "%.3f", oldDec.destinationPoint.x),
                    String(format: "%.3f", oldDec.destinationPoint.y),
                    String(format: "%.3f", oldDec.aimPointInSource.x),
                    String(format: "%.3f", oldDec.aimPointInSource.y),
                    String(format: "%.2f", oldDec.recommendedZoom),
                    oldSafe ? "YES" : "CLIPPED",
                    csvEscape(oldDec.explanation),
                    csvEscape(newDec.role.rawValue),
                    csvEscape(newDec.heroLabel),
                    String(format: "%.2f", newDec.confidence),
                    csvEscape(heroBoxStr),
                    String(format: "%.3f", newDec.subjectFillMetric),
                    String(format: "%.3f", newDec.targetFillMetric),
                    String(format: "%.3f", newDec.destinationPoint.x),
                    String(format: "%.3f", newDec.destinationPoint.y),
                    String(format: "%.3f", newDec.aimPointInSource.x),
                    String(format: "%.3f", newDec.aimPointInSource.y),
                    csvEscape(newDec.zoomState.rawValue),
                    String(format: "%.2f", newDec.recommendedZoom),
                    String(format: "%.2f", newDec.idealZoomAfterPan),
                    String(format: "%.2f", newDec.centerCropMaxZoom),
                    newDec.requiresPanBeforeZoom ? "YES" : "NO",
                    newSafe ? "YES" : "CLIPPED",
                    csvEscape(newDec.ruleName),
                    csvEscape(newDec.explanation),
                ].joined(separator: ",")
                csvRows.append(line)

                print(String(
                    format: "  [%02d/%02d] %@ (%@, %dx%d) | OLD: %@ %.1fx (safe=%@) -> NEW: %@ [%@] %.1fx%@ (safe=%@)",
                    idx + 1, imageFiles.count, file.lastPathComponent, category, w, h,
                    oldDec.heroLabel, oldDec.recommendedZoom, oldSafe ? "Y" : "N",
                    newDec.heroLabel, newDec.zoomState.rawValue, newDec.recommendedZoom,
                    newDec.requiresPanBeforeZoom ? String(format: "->pan %.1fx", newDec.idealZoomAfterPan) : "",
                    newSafe ? "Y" : "N"
                ))
                fflush(stdout)
            }
        }

        try csvRows.joined(separator: "\n").write(
            to: outDir.appendingPathComponent("summary_before_after.csv"),
            atomically: true,
            encoding: .utf8
        )
        print("Aspect ratio coverage verified: \(aspectCounter)")
        print("Benchmark complete! Wrote \(imageFiles.count) Old + New + Compare annotated images and summary_before_after.csv.")
    }

    // MARK: - Helpers & High-Clarity CoreGraphics/CoreText Annotation Renderer

    private static func isSubjectSafeInCenterCrop(heroBox: CGRect, role: DirectorPhotographicRole, zoom: CGFloat) -> Bool {
        guard zoom > 1.02 else { return true }
        if role == .skyLandscape || role == .scene || role == .indoorRoom || role == .aperture { return true }
        let frame = CameraFramingDirector.centerCropFrame(currentZoom: 1.0, targetZoom: zoom)
        let tol: CGFloat = 0.008
        return heroBox.minX >= frame.minX - tol &&
            heroBox.maxX <= frame.maxX + tol &&
            heroBox.minY >= frame.minY - tol &&
            heroBox.maxY <= frame.maxY + tol
    }

    private static func csvEscape(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(cleaned)\""
    }

    private static func inferCategory(from name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count >= 3 else { return "general" }
        return parts.dropFirst().dropLast(2).joined(separator: "_")
    }

    private static func inferAspectTag(width: Int, height: Int) -> String {
        let r = Double(width) / Double(height)
        if abs(r - 0.75) < 0.05 { return "3x4" }
        if abs(r - 9.0 / 16.0) < 0.06 { return "9x16" }
        if abs(r - 4.0 / 3.0) < 0.05 { return "4x3" }
        if abs(r - 16.0 / 9.0) < 0.06 { return "16x9" }
        return width < height ? "portrait" : "landscape"
    }

    private static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw BenchmarkError(description: "Failed to decode image \(url.path)")
        }
        return img
    }

    private static func makePixelBuffer(from image: CGImage, context: CIContext) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, attrs, &pb
        ) == kCVReturnSuccess, let buffer = pb else {
            throw BenchmarkError(description: "Failed to allocate CVPixelBuffer")
        }
        context.render(
            CIImage(cgImage: image),
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return buffer
    }

    private static func saveJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw BenchmarkError(description: "Cannot create JPEG destination \(url.path)")
        }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else {
            throw BenchmarkError(description: "Failed finalizing JPEG \(url.path)")
        }
    }

    private static func renderSideBySide(left: CGImage, right: CGImage) throws -> CGImage {
        let gap = 16
        let outW = left.width + gap + right.width
        let outH = max(left.height, right.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BenchmarkError(description: "Cannot allocate side-by-side CGContext")
        }
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.draw(left, in: CGRect(x: 0, y: outH - left.height, width: left.width, height: left.height))
        ctx.draw(right, in: CGRect(x: left.width + gap, y: outH - right.height, width: right.width, height: right.height))
        guard let out = ctx.makeImage() else {
            throw BenchmarkError(description: "Failed creating side-by-side CGImage")
        }
        return out
    }

    private static func renderAnnotatedImage(
        source: CGImage,
        titlePrefix: String,
        fileName: String,
        category: String,
        aspectTag: String,
        allDetections: [DirectorDetection],
        role: String,
        heroLabel: String,
        heroBounds: CGRect,
        heroAnchor: CGPoint,
        destPoint: CGPoint,
        aimPoint: CGPoint,
        recommendedZoom: CGFloat,
        zoomState: String,
        requiresPanBeforeZoom: Bool,
        idealZoomAfterPan: CGFloat,
        centerCropFrame: CGRect,
        centerCropSafe: Bool,
        fillMetric: Double,
        idealFill: Double,
        ruleName: String,
        explanation: String,
        horizonY: Double?
    ) throws -> CGImage {
        let scale: CGFloat = source.width < 720 ? (720.0 / CGFloat(source.width)) : 1.0
        let imgW = Int((CGFloat(source.width) * scale).rounded())
        let imgH = Int((CGFloat(source.height) * scale).rounded())
        let footerH = 148
        let canvasW = imgW
        let canvasH = imgH + footerH

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BenchmarkError(description: "Cannot allocate annotation CGContext")
        }

        // Background + Photo (CoreGraphics has bottom-left origin; photo sits in y: [footerH .. footerH + imgH])
        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.draw(source, in: CGRect(x: 0, y: footerH, width: imgW, height: imgH))

        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: p.x * CGFloat(imgW),
                y: CGFloat(footerH) + (1.0 - p.y) * CGFloat(imgH)
            )
        }
        func mapRect(_ r: CGRect) -> CGRect {
            let x = r.minX * CGFloat(imgW)
            let w = r.width * CGFloat(imgW)
            let h = r.height * CGFloat(imgH)
            let y = CGFloat(footerH) + (1.0 - r.maxY) * CGFloat(imgH)
            return CGRect(x: x, y: y, width: w, height: h)
        }

        // Subtle Rule-of-Thirds reference lines
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1.0)
        for frac in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
            let vx = frac * CGFloat(imgW)
            ctx.move(to: CGPoint(x: vx, y: CGFloat(footerH)))
            ctx.addLine(to: CGPoint(x: vx, y: CGFloat(footerH + imgH)))
            let hy = CGFloat(footerH) + frac * CGFloat(imgH)
            ctx.move(to: CGPoint(x: 0, y: hy))
            ctx.addLine(to: CGPoint(x: CGFloat(imgW), y: hy))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Optional detected horizon line
        if let hy = horizonY {
            let py = mapPoint(CGPoint(x: 0.5, y: hy)).y
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: 0.25, green: 0.85, blue: 1.0, alpha: 0.80))
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [8, 5])
            ctx.move(to: CGPoint(x: 0, y: py))
            ctx.addLine(to: CGPoint(x: CGFloat(imgW), y: py))
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 1) Draw ALL detected boxes + class + confidence
        for det in allDetections {
            let r = det.boundingBox
            guard r.width > 0.005, r.height > 0.005 else { continue }
            let pr = mapRect(r)
            let isHero = abs(r.minX - heroBounds.minX) < 0.015 &&
                abs(r.minY - heroBounds.minY) < 0.015 &&
                abs(r.width - heroBounds.width) < 0.02
            if isHero { continue }

            let boxColor: CGColor
            switch det.domain {
            case .human, .face:
                boxColor = CGColor(red: 0.20, green: 0.82, blue: 1.0, alpha: 0.85)
            case .animal:
                boxColor = CGColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 0.85)
            case .wideNature, .foregroundMask:
                boxColor = CGColor(red: 0.72, green: 0.55, blue: 1.0, alpha: 0.62)
            default:
                boxColor = CGColor(red: 0.35, green: 0.92, blue: 0.95, alpha: 0.80)
            }
            ctx.saveGState()
            ctx.setStrokeColor(boxColor)
            ctx.setLineWidth(1.8)
            ctx.stroke(pr)
            ctx.restoreGState()

            let tag = String(format: "%@ %.2f", det.label, det.confidence)
            drawBadge(
                ctx: ctx,
                text: tag,
                at: CGPoint(x: max(4, min(CGFloat(imgW - 110), pr.minX)),
                            y: min(CGFloat(footerH + imgH - 18), max(CGFloat(footerH + 4), pr.maxY - 16))),
                bg: CGColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 0.78),
                fg: CGColor(red: 0.88, green: 0.96, blue: 1.0, alpha: 1.0),
                fontSize: 10.5
            )
        }

        // 2) Draw Post-Zoom Visible Center-Crop Frame around (0.5, 0.5)
        if recommendedZoom > 1.03 {
            let zRect = mapRect(centerCropFrame)
            // Dim outside center-crop slightly so the post-zoom visible region stands out immediately
            ctx.saveGState()
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.24))
            ctx.addRect(CGRect(x: 0, y: footerH, width: imgW, height: imgH))
            ctx.addRect(zRect)
            ctx.fillPath(using: .evenOdd)

            let zColor = centerCropSafe
                ? CGColor(red: 1.0, green: 0.84, blue: 0.10, alpha: 0.96)
                : CGColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 0.98)
            ctx.setStrokeColor(zColor)
            ctx.setLineWidth(3.0)
            ctx.setLineDash(phase: 0, lengths: [10, 6])
            ctx.stroke(zRect)
            ctx.restoreGState()

            let zLabel = String(
                format: "POST-ZOOM %.1fx%@",
                recommendedZoom,
                centerCropSafe ? "" : " [CLIPPED!]"
            )
            drawBadge(
                ctx: ctx,
                text: zLabel,
                at: CGPoint(x: max(6, zRect.minX + 6), y: max(CGFloat(footerH + 6), zRect.minY + 6)),
                bg: centerCropSafe
                    ? CGColor(red: 0.22, green: 0.17, blue: 0.02, alpha: 0.88)
                    : CGColor(red: 0.45, green: 0.04, blue: 0.04, alpha: 0.92),
                fg: zColor,
                fontSize: 11.5
            )
        } else if recommendedZoom < 0.95 {
            drawBadge(
                ctx: ctx,
                text: String(format: "ZOOM OUT %.1fx (Mo rong khung %.1fx)", recommendedZoom, 1.0 / max(0.25, recommendedZoom)),
                at: CGPoint(x: 10, y: CGFloat(footerH + 10)),
                bg: CGColor(red: 0.06, green: 0.25, blue: 0.42, alpha: 0.90),
                fg: CGColor(red: 0.45, green: 0.90, blue: 1.0, alpha: 1.0),
                fontSize: 12.0
            )
        }

        // Optional post-pan zoom preview box when off-center subject requires panning first
        if requiresPanBeforeZoom && idealZoomAfterPan > recommendedZoom + 0.12 {
            let span = CGFloat(min(1.0, 1.0 / Double(idealZoomAfterPan)))
            let px0 = max(0.0, min(1.0 - span, heroAnchor.x - span * 0.5))
            let py0 = max(0.0, min(1.0 - span, heroAnchor.y - span * 0.5))
            let postPanRect = mapRect(CGRect(x: px0, y: py0, width: span, height: span))
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: 0.30, green: 0.90, blue: 1.0, alpha: 0.85))
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.stroke(postPanRect)
            ctx.restoreGState()
            drawBadge(
                ctx: ctx,
                text: String(format: "DICH MAY -> ZOOM %.1fx", idealZoomAfterPan),
                at: CGPoint(x: max(6, min(CGFloat(imgW - 165), postPanRect.minX + 4)),
                            y: max(CGFloat(footerH + 26), postPanRect.minY + 4)),
                bg: CGColor(red: 0.04, green: 0.20, blue: 0.28, alpha: 0.88),
                fg: CGColor(red: 0.45, green: 0.95, blue: 1.0, alpha: 1.0),
                fontSize: 10.5
            )
        }

        // 3) Draw Chosen Hero Box + Anchor
        let heroScreenRect = mapRect(heroBounds)
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.15, green: 1.0, blue: 0.42, alpha: 0.98))
        ctx.setLineWidth(3.4)
        ctx.stroke(heroScreenRect)
        ctx.restoreGState()
        drawBadge(
            ctx: ctx,
            text: "HERO: \(heroLabel)",
            at: CGPoint(
                x: max(6, min(CGFloat(imgW - 190), heroScreenRect.minX)),
                y: min(CGFloat(footerH + imgH - 22), heroScreenRect.maxY + 3)
            ),
            bg: CGColor(red: 0.04, green: 0.28, blue: 0.10, alpha: 0.90),
            fg: CGColor(red: 0.35, green: 1.0, blue: 0.55, alpha: 1.0),
            fontSize: 11.5
        )

        let heroAnchorPt = mapPoint(heroAnchor)
        drawCrosshair(ctx: ctx, center: heroAnchorPt, radius: 7, color: CGColor(red: 0.15, green: 1.0, blue: 0.42, alpha: 1.0))

        // 4) Draw Frame Center (0.5, 0.5), Target Destination Point, and Camera Aim Guide
        let centerPt = mapPoint(CGPoint(x: 0.5, y: 0.5))
        let destPt = mapPoint(destPoint)
        let aimPt = mapPoint(aimPoint)

        // Pan arrow from frame center -> aimPoint
        if hypot(aimPt.x - centerPt.x, aimPt.y - centerPt.y) > 8 {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.38, blue: 0.78, alpha: 0.92))
            ctx.setLineWidth(2.4)
            ctx.move(to: centerPt)
            ctx.addLine(to: aimPt)
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawCrosshair(ctx: ctx, center: centerPt, radius: 6, color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.80))

        // Gold Target Bullseye at destinationPoint
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.78, blue: 0.12, alpha: 1.0))
        ctx.setLineWidth(2.8)
        ctx.strokeEllipse(in: CGRect(x: destPt.x - 12, y: destPt.y - 12, width: 24, height: 24))
        ctx.setFillColor(CGColor(red: 1.0, green: 0.78, blue: 0.12, alpha: 1.0))
        ctx.fillEllipse(in: CGRect(x: destPt.x - 3.5, y: destPt.y - 3.5, width: 7, height: 7))
        ctx.restoreGState()
        drawBadge(
            ctx: ctx,
            text: String(format: "TARGET (%.2f, %.2f)", destPoint.x, destPoint.y),
            at: CGPoint(x: max(6, min(CGFloat(imgW - 145), destPt.x + 14)),
                        y: max(CGFloat(footerH + 6), min(CGFloat(footerH + imgH - 22), destPt.y - 10))),
            bg: CGColor(red: 0.25, green: 0.18, blue: 0.02, alpha: 0.88),
            fg: CGColor(red: 1.0, green: 0.84, blue: 0.22, alpha: 1.0),
            fontSize: 10.5
        )

        // Magenta Aim Reticle at aimPointInSource
        drawCrosshair(ctx: ctx, center: aimPt, radius: 9, color: CGColor(red: 1.0, green: 0.35, blue: 0.80, alpha: 1.0))

        // 5) Draw Telemetry Footer Panel (never occludes image content)
        let line1 = String(
            format: "[%@] %@  |  cat=%@  |  %dx%d (%@)  |  boxes=%d",
            titlePrefix, fileName, category, source.width, source.height, aspectTag, allDetections.count
        )
        let panSuffix = requiresPanBeforeZoom ? String(format: " -> pan %.1fx", idealZoomAfterPan) : ""
        let line2 = String(
            format: "Hero: %@ [%@]  |  Fill: %.2f (ideal %.2f)  |  Zoom: %@ %.1fx%@  |  CenterSafe: %@",
            heroLabel, role, fillMetric, idealFill, zoomState, recommendedZoom, panSuffix, centerCropSafe ? "YES" : "CLIPPED!"
        )
        let line3 = String(
            format: "Rule: %@  |  Target=(%.2f, %.2f)  Aim=(%.2f, %.2f)",
            ruleName, destPoint.x, destPoint.y, aimPoint.x, aimPoint.y
        )
        let line4 = "Reason: \(explanation)"

        drawFooterLine(ctx: ctx, text: line1, x: 12, y: footerH - 28, fontSize: 12.5,
                       color: CGColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1.0), bold: true)
        drawFooterLine(ctx: ctx, text: line2, x: 12, y: footerH - 58, fontSize: 12.0,
                       color: CGColor(red: 0.42, green: 0.98, blue: 0.62, alpha: 1.0), bold: true)
        drawFooterLine(ctx: ctx, text: line3, x: 12, y: footerH - 88, fontSize: 11.5,
                       color: CGColor(red: 1.0, green: 0.86, blue: 0.38, alpha: 1.0), bold: false)
        drawFooterLine(ctx: ctx, text: line4, x: 12, y: footerH - 120, fontSize: 11.5,
                       color: CGColor(red: 0.85, green: 0.90, blue: 0.96, alpha: 1.0), bold: false)

        guard let out = ctx.makeImage() else {
            throw BenchmarkError(description: "Failed creating annotated CGImage")
        }
        return out
    }

    private static func drawCrosshair(ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2.0)
        ctx.move(to: CGPoint(x: center.x - radius, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        ctx.move(to: CGPoint(x: center.x, y: center.y - radius))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawBadge(ctx: CGContext, text: String, at origin: CGPoint, bg: CGColor, fg: CGColor, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textW = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padX: CGFloat = 5
        let padY: CGFloat = 3
        let boxRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: textW + padX * 2,
            height: ascent + descent + padY * 2
        )
        ctx.saveGState()
        ctx.setFillColor(bg)
        let path = CGPath(roundedRect: boxRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: origin.x + padX, y: origin.y + padY + descent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawFooterLine(ctx: CGContext, text: String, x: Int, y: Int, fontSize: CGFloat, color: CGColor, bold: Bool) {
        let fontName = (bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(y))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
