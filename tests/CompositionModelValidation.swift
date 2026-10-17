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
        let budget = CompositionSearchBudget(complexScene: CompositionSearchBudget.isComplex(
            group: hero.isGroup, intents: intents), constrained: false)
        func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents, portraitBounds: portraitBounds,
                raster: raster, calibration: calibration, currentZoom: 1, allowedZooms: [1, 2, 3],
                protectedBounds: hero.companionBounds, incidentalBounds: incidentalPets + incidentalFaces,
                proposalLimit: seeds.isEmpty ? budget.coarse : budget.refinement, refining: seeds)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let broad = proposals()
        guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: broad,
            image: ci, aspect: calibration.aspect, preferences: [:], modelURL: modelURL,
            aestheticModelURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmAesthetics.mlmodelc"),
            positionURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmPositionEmbedding.bin"),
            requiresModernModel: true, aestheticLimit: budget.aesthetics,
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
