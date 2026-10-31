import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import CoreVideo
import Vision
import simd

/// Executes production Swift preprocessing and Core ML predictions on held-out
/// photographs, then exercises production view search with real Vision evidence.
@main
enum CompositionModelValidation {
    struct Reference: Decodable { let file: String; let distribution: [Double] }
    struct Failure: Error { let message: String }

    static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "Cannot read \(url.lastPathComponent)")
        }
        return image
    }

    static func main() throws {
        if CommandLine.arguments.contains("--eval-dir") { try evalMain(); return }
        let photos = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try PhotographicCompositionModel(url: modelURL)
        let modelDirectory = modelURL.deletingLastPathComponent()
        let charm = try CharmPhotographicModel(url: modelDirectory.appendingPathComponent("CharmAesthetics.mlmodelc"),
            positionURL: modelDirectory.appendingPathComponent("CharmPositionEmbedding.bin"))
        let charmReferences = try JSONDecoder().decode([Reference].self,
            from: Data(contentsOf: photos.appendingPathComponent("charm-references.json")))
        var modernParity: [[String: Any]] = []
        for reference in charmReferences {
            let source = try image(photos.appendingPathComponent(reference.file))
            guard let inputs = charm.inputs(source),
                  let assessment = charm.assess(source, cancellation: CompositionAnalysisCancellation()) else {
                throw Failure(message: "Charm failed to score a real photograph")
            }
            let expected = try Data(contentsOf: photos.appendingPathComponent(reference.file)
                .deletingPathExtension().appendingPathExtension("charm-position.f32"))
            guard expected.count == inputs.positions.count * MemoryLayout<Float>.size else {
                throw Failure(message: "Charm position shape differs from author: \(reference.file), expected bytes \(expected.count), Swift \(inputs.positions.count * 4)")
            }
            let positions = inputs.positions.dataPointer.assumingMemoryBound(to: Float.self)
            let positionError = expected.withUnsafeBytes { data -> Double in
                let values = data.bindMemory(to: Float.self)
                return (0..<values.count).reduce(0.0) { max($0, abs(Double(values[$1] - positions[$1]))) }
            }
            let expectedMean = reference.distribution.enumerated().reduce(0.0) { $0 + $1.element * (1 + Double($1.offset) * 0.5) }
            let error = abs(expectedMean - assessment.mean)
            modernParity.append(["file": reference.file, "meanScoreError": error, "maxPositionError": positionError])
            guard error < 0.06, positionError < 0.0001 else {
                throw Failure(message: "Charm Swift preprocessing/parity failed: \(reference.file), score \(error), position \(positionError)")
            }
        }
        try JSONSerialization.data(withJSONObject: modernParity, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("swift-charm-parity.json"))
        let spectral = SpectralCompositionSaliency()
        let references = try JSONDecoder().decode([Reference].self,
            from: Data(contentsOf: photos.appendingPathComponent("parity-references.json")))
        var parity: [[String: Any]] = []
        for reference in references {
            let source = try image(photos.appendingPathComponent(reference.file))
            let expected = try Data(contentsOf: photos.appendingPathComponent(reference.file)
                .deletingPathExtension().appendingPathExtension("saliency.f32"))
            guard let map = spectral.map(image: source),
                  let assessment = model.assess(source, cancellation: CompositionAnalysisCancellation()),
                  expected.count == map.count * MemoryLayout<Float>.size else {
                throw Failure(message: "Missing numerical evidence: \(reference.file)")
            }
            let saliencyError = expected.withUnsafeBytes { bytes -> Double in
                let values = bytes.bindMemory(to: Float.self)
                return map.indices.reduce(0) { $0 + abs(map[$1] - Double(values[$1])) } / Double(map.count)
            }
            let targetMean = zip(reference.distribution, 1...5).reduce(0) { $0 + $1.0 * Double($1.1) }
            let meanError = abs(assessment.mean - targetMean)
            let expectedRGB = try Data(contentsOf: photos.appendingPathComponent(reference.file)
                .deletingPathExtension().appendingPathExtension("rgb.u8"))
            guard let rgb = CompositionPhotoPixels.resizedRGB(image: source, side: 224), rgb.count == expectedRGB.count else {
                throw Failure(message: "Missing RGB preprocessing evidence")
            }
            let rgbError = zip(rgb, expectedRGB).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(rgb.count)
            parity.append(["file": reference.file, "saliencyMAE": saliencyError, "meanScoreError": meanError, "rgbMAE255": rgbError])
            print("Swift parity: \(reference.file), RGB MAE \(rgbError), saliency MAE \(saliencyError), rating error \(meanError)")
            fflush(stdout)
            if saliencyError > 0.01 || meanError > 0.08 || rgbError > 1.2 {
                let failureData = try JSONSerialization.data(withJSONObject: parity, options: [.prettyPrinted, .sortedKeys])
                try failureData.write(to: output.appendingPathComponent("swift-parity.json"))
                throw Failure(message: "Swift preprocessing differs from author input: \(reference.file)")
            }
        }
        try JSONSerialization.data(withJSONObject: parity, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("swift-parity.json"))
        if CommandLine.arguments.contains("--parity-only") {
            print("PASS: 32 SAMP and 32 Charm production Swift parity photos")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let renderer = CompositionImageRenderer()
        var searches: [[String: Any]] = []
        for file in files {
            let row: [String: Any] = try autoreleasepool {
                try searchPhoto(file: file, photos: photos, modelURL: modelURL,
                                output: output, renderer: renderer)
            }
            searches.append(row)
            print("Search \(searches.count)/\(files.count): \(row)")
            fflush(stdout)
        }
        let report: [String: Any] = ["images": searches.count, "searches": searches,
            "input": "Original full-resolution source files; only candidate previews are resized",
            "scope": "Production YOLO/Vision/SigLIP recognition, hero/group selection and composition search compiled from app source. macOS data adapters omit iOS UI/filter properties; camera/motion/capture and physical-phone performance are not exercised."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("real-photo-search.json"))
        print("PASS: \(parity.count) author-to-Swift parity photos; \(searches.count) production composition searches")
    }

    static func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure(message: "Cannot allocate photograph buffer") }
        CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image), to: buffer,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    static func save(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw Failure(message: "Cannot create preview destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot save preview") }
    }

    static func searchPhoto(file: URL, photos: URL, modelURL: URL, output: URL,
                            renderer: CompositionImageRenderer) throws -> [String: Any] {
        let source = try image(photos.appendingPathComponent("source").appendingPathComponent(file.lastPathComponent))
        let pixels = try pixelBuffer(source)
        let analyzer = NativeSubjectAnalysis(renderer: renderer)
        guard let detected = analyzer.analyze(pixels) else { throw Failure(message: "Production recognition failed") }
        guard let hero = detected.allCandidates.first, let raster = detected.compositionRaster else {
            try save(source, to: output.appendingPathComponent(file.lastPathComponent))
            return ["file": file.lastPathComponent, "result": "manual-no-subject",
                    "modelAssessedCrops": 0, "charmAssessedCrops": 0, "poseSupportsTorsoPortrait": false,
                    "selectedZoom": 1.0, "automaticSelectionAllowed": false,
                    "detectedPeople": 0, "detectedAnimals": 0]
        }
        let bounds = hero.boundingBox
        let kind = analyzer.subjectKind(hero)
        let intents = analyzer.intents(detected, hero: hero)
        let ownFaces = hero.faceBounds
        let incidentalPets = detected.allCandidates.filter { $0.category == .animal && $0.id != hero.id }.map(\.boundingBox)
        let incidentalFaces = detected.allFaceRects.filter { !ownFaces.contains($0) }
        var portraitBounds: CGRect?
        if hero.category == .human, !hero.isGroup, !ownFaces.isEmpty {
            let pose = VNDetectHumanBodyPoseRequest()
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([pose])
            portraitBounds = PortraitFramingEvidence.bounds(body: bounds, faces: ownFaces, observations: pose.results ?? [])
        }
        var subject = CompositionSubject(index: 0, bounds: bounds,
            anchor: hero.eyePosition ?? hero.center, kind: kind,
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze)
        subject.allowsAttentionCrop = hero.isAttentionRegion && raster.hasAttention && bounds.width * bounds.height > 0.45
        let ci = CIImage(cvPixelBuffer: pixels)
        let calibration = TrackingCalibration.fallback(aspect: Double(source.width) / Double(source.height))
        func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents, portraitBounds: portraitBounds,
                raster: raster, calibration: calibration, currentZoom: 1, allowedZooms: [1, 2, 3],
                protectedBounds: hero.companionBounds, incidentalBounds: incidentalPets + incidentalFaces,
                proposalLimit: seeds.isEmpty ? 36 : 18, refining: seeds)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let broad = proposals()
        guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: broad,
            image: ci, aspect: calibration.aspect, preferences: [:], modelURL: modelURL,
            aestheticModelURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmAesthetics.mlmodelc"),
            positionURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmPositionEmbedding.bin"),
            requiresModernModel: true,
            cancellation: CompositionAnalysisCancellation(), progress: { _ in }, refine: { proposals($0) }),
            !result.views.isEmpty, result.usedSpecialist,
            let best = result.views.first, let bestAssessment = best.assessment, let bestAesthetics = best.aesthetics else {
            throw Failure(message: "Real-photo search failed: \(file.lastPathComponent), proposals \(broad.count), hero \(hero.label), bounds \(bounds)")
        }
        for view in result.views {
            let future = TrackingCalibration(fx: calibration.fx * Double(view.proposal.zoom),
                fy: calibration.fy * Double(view.proposal.zoom), cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
            let protection = CompositionCropProtection.bounds(body: bounds, portrait: portraitBounds,
                intent: view.proposal.intent, anchor: subject.anchor, attentionRegion: subject.allowsAttentionCrop)
            let required = [protection] + hero.companionBounds
            if subject.allowsAttentionCrop, !view.proposal.isUnchangedView, view.proposal.retainedAttention < 0.82 {
                throw Failure(message: "Crop discarded measured attention")
            }
            for bound in required {
                guard let projected = CompositionPlanner.project(bound, from: calibration, to: future,
                    rotation: view.proposal.rotation), CompositionPlanner.visibleFraction(projected) > 0.98 else {
                    throw Failure(message: "Search cropped a protected subject: \(file.lastPathComponent), \(hero.label)")
                }
            }
            for bound in incidentalPets + incidentalFaces {
                guard let projected = CompositionPlanner.project(bound, from: calibration, to: future,
                    rotation: view.proposal.rotation) else { continue }
                let fraction = CompositionPlanner.visibleFraction(projected)
                guard fraction <= 0.02 || fraction >= 0.98 else {
                    throw Failure(message: "Search bisected an incidental subject: \(file.lastPathComponent)")
                }
            }
        }
        let row: [String: Any] = ["file": file.lastPathComponent, "hero": hero.label,
            "heroBounds": [bounds.minX, bounds.minY, bounds.width, bounds.height].map { Double($0) },
            "primaryFaces": ownFaces.count,
            "attentionRegion": subject.allowsAttentionCrop,
            "heroConfidence": Double(hero.confidence), "group": hero.isGroup,
            "detectedPeople": detected.allCandidates.filter { $0.category == .human && !$0.isGroup }.count,
            "detectedAnimals": detected.allCandidates.filter { $0.category == .animal }.count,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "modelAssessedCrops": result.assessedCount, "selectedZoom": Double(best.proposal.zoom),
            "charmAssessedCrops": result.modernAssessmentCount, "aestheticRating": bestAesthetics.mean,
            "poseSupportsTorsoPortrait": portraitBounds != nil, "selectedIntent": best.proposal.intent.rawValue,
            "compositionRating": bestAssessment.mean, "secondsMac": ProcessInfo.processInfo.systemUptime - started,
            "automaticSelectionAllowed": result.canAutoselect]
        var detailed = row
        detailed["choices"] = try result.views.map { view -> [String: Any] in
            guard let composition = view.assessment, let aesthetics = view.aesthetics else {
                throw Failure(message: "Missing completed specialist scores")
            }
            return ["zoom": Double(view.proposal.zoom), "original": view.proposal.isUnchangedView,
             "intent": view.proposal.intent.rawValue, "score": view.proposal.score,
             "composition": composition.mean, "aesthetics": aesthetics.mean,
             "retainedAttention": view.proposal.retainedAttention,
             "sourceCorners": view.proposal.sourceCorners.map { [Double($0.x), Double($0.y)] }]
        }
        try save(best.image, to: output.appendingPathComponent(file.lastPathComponent))
        return detailed
    }
}

// MARK: - EVAL_MODE: offline evaluation runner (docs/eval). Not used by the app or by the existing validation modes.
// The pipeline calls below mirror `searchPhoto` (same recognition -> proposals -> aesthetic search sequence and
// arguments) but record results instead of asserting crop-protection invariants. No production file is touched.
extension CompositionModelValidation {
    /// Edge-tilt threshold (degrees) above which the proposal quad is flagged `is_rotated`.
    /// 1.0 deg: over a full frame width the quad's edge drifts ~1.7% of its length, which already inflates the
    /// axis-aligned bounding box enough to lower IoU against upright GAICD crops; smaller tilts are indistinguishable
    /// from rounding. The raw tilt is also exported (`max_edge_tilt_deg`) so other thresholds can be applied offline.
    static let evalRotationThresholdDegrees = 1.0

    static func evalArgument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func evalNumber(_ value: Double) -> Any {
        if value.isFinite { return value }
        return NSNull()
    }

    static func evalOptional(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return evalNumber(value)
    }

    static func evalNumbers(_ values: [Double]) -> Any {
        if values.allSatisfy({ $0.isFinite }) { return values }
        return NSNull()
    }

    static func evalDeviceDescription() -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let info = ProcessInfo.processInfo
        return "\(info.operatingSystemVersionString) \(architecture) cpus=\(info.processorCount)"
    }

    static func evalMain() throws {
        guard let directoryPath = evalArgument("--eval-dir"), let outputPath = evalArgument("--eval-out"),
              CommandLine.arguments.count > 2 else {
            throw Failure(message: "Eval mode needs --eval-dir and --eval-out; positional argument 2 must be SAMPComposition.mlmodelc")
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let limit = evalArgument("--limit").flatMap { Int($0) }
        var expectedSizes: [String: [Int]] = [:]
        if let evalSetPath = evalArgument("--eval-set") {
            let data = try Data(contentsOf: URL(fileURLWithPath: evalSetPath))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = root["images"] as? [[String: Any]] else {
                throw Failure(message: "Cannot parse --eval-set")
            }
            for item in images {
                if let name = item["image"] as? String, let width = item["w"] as? Int, let height = item["h"] as? Int {
                    expectedSizes[name] = [width, height]
                }
            }
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        var files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let limit, limit >= 0 { files = Array(files.prefix(limit)) }
        let renderer = CompositionImageRenderer()
        let device = evalDeviceDescription()
        var records: [[String: Any]] = []
        var okCount = 0
        for (position, file) in files.enumerated() {
            let record: [String: Any] = autoreleasepool {
                evalPhoto(file: file, expectedSize: expectedSizes[file.lastPathComponent], modelURL: modelURL,
                          renderer: renderer, device: device)
            }
            let succeeded = (record["ok"] as? Bool) == true
            if succeeded { okCount += 1 }
            records.append(record)
            print("Eval \(position + 1)/\(files.count): ok=\(succeeded)")
            fflush(stdout)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL)
        print("EVAL DONE: \(records.count) images, \(okCount) ok")
    }

    static func evalPhoto(file: URL, expectedSize: [Int]?, modelURL: URL, renderer: CompositionImageRenderer,
                          device: String) -> [String: Any] {
        var record: [String: Any] = [
            "image": file.lastPathComponent, "image_w": NSNull(), "image_h": NSNull(), "ok": false, "error": NSNull(),
            "hero_subject_box": NSNull(), "scene_intent": NSNull(), "target_P": NSNull(),
            "zoom_current": NSNull(), "zoom_ideal": NSNull(), "zoom_final": NSNull(),
            "crop_rect": NSNull(), "source_corners_raw": NSNull(), "is_rotated": NSNull(), "max_edge_tilt_deg": NSNull(),
            "scores": ["samp": NSNull(), "charm": NSNull(), "geom": NSNull(), "final": NSNull()] as [String: Any],
            "num_candidates": NSNull(), "timing_ms": NSNull(), "device": device, "impl": "swift_ci_macos"]
        let started = ProcessInfo.processInfo.systemUptime
        func milliseconds(_ from: TimeInterval, _ to: TimeInterval) -> Double { (to - from) * 1000 }
        do {
            let source = try image(file)
            record["image_w"] = source.width
            record["image_h"] = source.height
            if let expectedSize, expectedSize != [source.width, source.height] {
                throw Failure(message: "Image size mismatch: read \(source.width)x\(source.height), eval_set \(expectedSize[0])x\(expectedSize[1])")
            }
            let pixels = try pixelBuffer(source)
            let analyzer = NativeSubjectAnalysis(renderer: renderer)
            let detectionStart = ProcessInfo.processInfo.systemUptime
            guard let detected = analyzer.analyze(pixels) else { throw Failure(message: "Production recognition failed") }
            let detectionEnd = ProcessInfo.processInfo.systemUptime
            guard let hero = detected.allCandidates.first, let raster = detected.compositionRaster else {
                throw Failure(message: "no_subject: production recognition returned no hero subject or raster")
            }
            let bounds = hero.boundingBox
            let kind = analyzer.subjectKind(hero)
            let intents = analyzer.intents(detected, hero: hero)
            let ownFaces = hero.faceBounds
            let incidentalPets = detected.allCandidates.filter { $0.category == .animal && $0.id != hero.id }.map(\.boundingBox)
            let incidentalFaces = detected.allFaceRects.filter { !ownFaces.contains($0) }
            var portraitBounds: CGRect?
            if hero.category == .human, !hero.isGroup, !ownFaces.isEmpty {
                let pose = VNDetectHumanBodyPoseRequest()
                try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([pose])
                portraitBounds = PortraitFramingEvidence.bounds(body: bounds, faces: ownFaces, observations: pose.results ?? [])
            }
            var subject = CompositionSubject(index: 0, bounds: bounds,
                anchor: hero.eyePosition ?? hero.center, kind: kind,
                confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze)
            subject.allowsAttentionCrop = hero.isAttentionRegion && raster.hasAttention && bounds.width * bounds.height > 0.45
            let ci = CIImage(cvPixelBuffer: pixels)
            let fov = evalArgument("--eval-fov").flatMap(Double.init) ?? CompositionTuning.defaultCameraFOVWide
            let calibration = TrackingCalibration.fallback(fovLongDegrees: fov, aspect: Double(source.width) / Double(source.height))
            func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
                CompositionPlanner.photographicProposals(subject: subject, intents: intents, portraitBounds: portraitBounds,
                    raster: raster, calibration: calibration, currentZoom: 1, allowedZooms: [1, 2, 3],
                    protectedBounds: hero.companionBounds, incidentalBounds: incidentalPets + incidentalFaces,
                    proposalLimit: seeds.isEmpty ? 36 : 18, refining: seeds)
            }
            let planningStart = ProcessInfo.processInfo.systemUptime
            let broad = proposals()
            let planningEnd = ProcessInfo.processInfo.systemUptime
            guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: broad,
                image: ci, aspect: calibration.aspect, preferences: [:], modelURL: modelURL,
                aestheticModelURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmAesthetics.mlmodelc"),
                positionURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmPositionEmbedding.bin"),
                requiresModernModel: true,
                cancellation: CompositionAnalysisCancellation(), progress: { _ in }, refine: { proposals($0) }),
                let best = result.views.first else {
                throw Failure(message: "search_failed: no composition views (proposals \(broad.count))")
            }
            let searchEnd = ProcessInfo.processInfo.systemUptime

            let corners = best.proposal.sourceCorners
            let width = Double(source.width), height = Double(source.height)
            if corners.count == 4 {
                let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
                record["source_corners_raw"] = evalNumbers(corners.flatMap { [Double($0.x), Double($0.y)] })
                // Axis-aligned bounding box of sourceCorners clamped to [0,1]; an APPROXIMATION of the quad (see SCHEMA.md).
                let minX = max(0.0, xs.min() ?? 0.0), maxX = min(1.0, xs.max() ?? 1.0)
                let minY = max(0.0, ys.min() ?? 0.0), maxY = min(1.0, ys.max() ?? 1.0)
                if maxX > minX, maxY > minY {
                    record["crop_rect"] = evalNumbers([minX, minY, maxX - minX, maxY - minY])
                }
                var maxTilt = 0.0
                for index in 0..<4 {
                    let from = corners[index], to = corners[(index + 1) % 4]
                    let angle = abs(atan2((Double(to.y) - Double(from.y)) * height, (Double(to.x) - Double(from.x)) * width)) * 180 / Double.pi
                    maxTilt = max(maxTilt, min(angle, abs(angle - 90), abs(angle - 180)))
                }
                record["max_edge_tilt_deg"] = evalNumber(maxTilt)
                record["is_rotated"] = maxTilt > evalRotationThresholdDegrees
            }
            record["hero_subject_box"] = evalNumbers([Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)])
            record["scene_intent"] = best.proposal.intent.rawValue
            record["zoom_current"] = 1.0
            record["zoom_final"] = evalNumber(Double(best.proposal.zoom))
            record["eval_fov"] = evalNumber(fov)
            record["scores"] = ["samp": evalOptional(best.assessment?.mean), "charm": evalOptional(best.aesthetics?.mean),
                                "geom": evalNumber(best.geometryScore), "final": evalNumber(best.proposal.score)] as [String: Any]
            record["num_candidates"] = result.assessedCount
            var candList: [[String: Any]] = []
            for v in result.allEvaluatedViews {
                var cRec: [String: Any] = [:]
                let vCorners = v.proposal.sourceCorners
                cRec["zoom"] = evalNumber(Double(v.proposal.zoom))
                cRec["intent"] = v.proposal.intent.rawValue
                cRec["is_unchanged"] = v.proposal.isUnchangedView
                cRec["is_selected"] = (vCorners == best.proposal.sourceCorners &&
                                       v.proposal.zoom == best.proposal.zoom &&
                                       v.proposal.intent == best.proposal.intent)
                if vCorners.count == 4 {
                    cRec["source_corners_raw"] = evalNumbers(vCorners.flatMap { [Double($0.x), Double($0.y)] })
                    let cXs = vCorners.map { Double($0.x) }, cYs = vCorners.map { Double($0.y) }
                    let cMinX = max(0.0, cXs.min() ?? 0.0), cMaxX = min(1.0, cXs.max() ?? 1.0)
                    let cMinY = max(0.0, cYs.min() ?? 0.0), cMaxY = min(1.0, cYs.max() ?? 1.0)
                    if cMaxX > cMinX, cMaxY > cMinY {
                        cRec["crop_rect"] = evalNumbers([cMinX, cMinY, cMaxX - cMinX, cMaxY - cMinY])
                    }
                }
                cRec["scores"] = [
                    "samp": evalOptional(v.assessment?.mean),
                    "charm": evalOptional(v.aesthetics?.mean),
                    "geom": evalNumber(v.geometryScore),
                    "final": evalNumber(v.proposal.score)
                ] as [String: Any]
                candList.append(cRec)
            }
            record["candidates"] = candList
            record["timing_ms"] = ["detection": milliseconds(detectionStart, detectionEnd),
                                   "planning": milliseconds(planningStart, planningEnd),
                                   "scoring": milliseconds(planningEnd, searchEnd),
                                   "total": milliseconds(started, searchEnd)] as [String: Any]
            record["ok"] = true
        } catch let failure as Failure {
            record["error"] = failure.message
            record["timing_ms"] = ["total": milliseconds(started, ProcessInfo.processInfo.systemUptime)] as [String: Any]
        } catch {
            record["error"] = "\(error)"
            record["timing_ms"] = ["total": milliseconds(started, ProcessInfo.processInfo.systemUptime)] as [String: Any]
        }
        return record
    }
}
