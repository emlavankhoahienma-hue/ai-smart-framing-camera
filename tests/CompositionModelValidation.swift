import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import CoreVideo
import Vision
import simd

/// Executes production Swift preprocessing and Core ML predictions on author-test
/// photographs and app regression cases, with real Vision evidence.
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
        var regressions: [(source: URL, optical: CGFloat?)] = ["3433.jpg", "10034.jpg", "113.jpg", "321.jpg"].map {
            (photos.appendingPathComponent("source").appendingPathComponent($0), nil)
        }
        if let option = CommandLine.arguments.firstIndex(of: "--people"), option + 1 < CommandLine.arguments.count {
            regressions.insert((URL(fileURLWithPath: CommandLine.arguments[option + 1]).appendingPathComponent("1565.jpg"), nil), at: 0)
            regressions.insert((URL(fileURLWithPath: CommandLine.arguments[option + 1]).appendingPathComponent("724.jpg"), nil), at: 0)
        }
        for optical in [CGFloat(4), CGFloat(5)] {
            regressions.append((photos.appendingPathComponent("source/321.jpg"), optical))
        }
        let regressionDirectory = output.appendingPathComponent("critical-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: regressionDirectory, withIntermediateDirectories: true)
        var regressionRows: [[String: Any]] = []
        for regression in regressions {
            let file = regression.optical.map { URL(fileURLWithPath: "optical\(Int($0))_" + regression.source.lastPathComponent) } ?? regression.source
            let row: [String: Any] = try autoreleasepool {
                try searchPhoto(file: file, photos: photos, modelURL: modelURL, output: regressionDirectory,
                                renderer: renderer, sourceOverride: image(regression.source), maximumOpticalZoom: regression.optical)
            }
            regressionRows.append(row)
            print("Critical photo regression: \(file.lastPathComponent), adjusted anchor: \(row["framingAnchorWasAdjusted"] as? Bool ?? false)")
            fflush(stdout)
        }
        try JSONSerialization.data(withJSONObject: ["images": regressionRows.count,
            "uniqueSourceImages": Set(regressions.map { $0.source.lastPathComponent }).count,
            "searches": regressionRows], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("critical-photo-regressions.json"))
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
            "scope": "Production YOLO/Vision/SigLIP recognition and composition search on author-test photos also used as app regression cases; not an untouched aesthetic-quality benchmark. macOS adapters omit iOS UI/filter properties; camera/motion/capture and physical-phone performance are not exercised."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("real-photo-search.json"))
        var humanFiles: [URL] = []
        if let option = CommandLine.arguments.firstIndex(of: "--people"), option + 1 < CommandLine.arguments.count {
            humanFiles = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: CommandLine.arguments[option + 1]),
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard humanFiles.count == 342 else { throw Failure(message: "Human-scene author test split is incomplete") }
            let humanDirectory = output.appendingPathComponent("human-scenes", isDirectory: true)
            try FileManager.default.createDirectory(at: humanDirectory, withIntermediateDirectories: true)
            let alreadyTested = Set(files.map { $0.lastPathComponent })
            var humanRows: [[String: Any]] = []
            for file in humanFiles where !alreadyTested.contains(file.lastPathComponent) {
                let row: [String: Any] = try autoreleasepool {
                    try searchPhoto(file: file, photos: photos, modelURL: modelURL, output: humanDirectory,
                        renderer: renderer, sourceOverride: image(file))
                }
                humanRows.append(row)
                print("Human composition \(humanRows.count)/326: \(file.lastPathComponent)")
                fflush(stdout)
            }
            guard humanRows.count == 326 else { throw Failure(message: "Unexpected human-scene overlap") }
            let humanReport: [String: Any] = ["humanPhotos": 342, "alreadyInMainSweep": 16,
                "additionalPhotos": humanRows.count, "scope": "All human-scene source files in the official CADB author test split, excluding repeat work for the main sweep; not bounding-box ground truth or physical-phone testing.", "searches": humanRows]
            try JSONSerialization.data(withJSONObject: humanReport, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("human-scene-composition.json"))
        }
        let profileParents = searches.compactMap { row -> (String, Double)? in
            guard row["attentionRegion"] as? Bool == false, let confidence = row["heroConfidence"] as? Double,
                  confidence >= 0.72, let bounds = row["heroBounds"] as? [Double], bounds.count == 4,
                  let file = row["file"] as? String else { return nil }
            return (file, bounds[2] * bounds[3])
        }.sorted { $0.1 < $1.1 }.prefix(12)
        guard profileParents.count == 12 else { throw Failure(message: "Insufficient physical subjects for optical-profile validation") }
        let opticalDirectory = output.appendingPathComponent("optical-profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: opticalDirectory, withIntermediateDirectories: true)
        var opticalRows: [[String: Any]] = []
        for optical in [CGFloat(4), CGFloat(5)] {
            for parent in profileParents {
                let file = photos.appendingPathComponent("source").appendingPathComponent(parent.0)
                let row: [String: Any] = try autoreleasepool {
                    try searchPhoto(file: URL(fileURLWithPath: "optical\(Int(optical))_" + parent.0),
                        photos: photos, modelURL: modelURL, output: opticalDirectory, renderer: renderer,
                        sourceOverride: image(file), maximumOpticalZoom: optical)
                }
                opticalRows.append(row)
                print("Optical profile \(opticalRows.count)/24: \(parent.0), lens \(optical)")
                fflush(stdout)
            }
        }
        let opticalReport: [String: Any] = ["views": opticalRows.count, "sourcePhotos": 12,
            "opticalProfiles": [4, 5], "scope": "Production search on real photos with advertised 4x/5x optical metadata; not a physical lens test.",
            "searches": opticalRows]
        try JSONSerialization.data(withJSONObject: opticalReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("optical-zoom-profiles.json"))
        let replayDirectory = output.appendingPathComponent("camera-replay", isDirectory: true)
        try FileManager.default.createDirectory(at: replayDirectory, withIntermediateDirectories: true)
        var replay: [[String: Any]] = []
        let baseParents = Array(files.prefix(humanFiles.isEmpty ? 12 : 6)).map {
            photos.appendingPathComponent("source").appendingPathComponent($0.lastPathComponent)
        }
        let baseNames = Set(baseParents.map { $0.lastPathComponent })
        let replayParents = baseParents + Array(humanFiles.filter { !baseNames.contains($0.lastPathComponent) }.prefix(6))
        guard Set(replayParents.map { $0.lastPathComponent }).count == 12 else {
            throw Failure(message: "Camera replay must cover twelve distinct parent photographs")
        }
        for file in replayParents {
            let parent = try image(file)
            for (index, offset) in [0.05, 0.18, 0.31].enumerated() {
                try autoreleasepool {
                    let window = CGRect(x: (Double(parent.width) * offset).rounded(.down),
                        y: (Double(parent.height) * 0.18).rounded(.down),
                        width: (Double(parent.width) * 0.64).rounded(.down),
                        height: (Double(parent.height) * 0.64).rounded(.down))
                    guard let input = parent.cropping(to: window) else { throw Failure(message: "Invalid real replay window") }
                    let name = "view\(index)_" + file.lastPathComponent
                    try save(input, to: replayDirectory.appendingPathComponent("input_" + name))
                    let row = try searchPhoto(file: URL(fileURLWithPath: name), photos: photos, modelURL: modelURL,
                        output: replayDirectory, renderer: renderer, sourceOverride: input,
                        replayParent: parent, replayWindow: window, constrained: true)
                    replay.append(row)
                }
            }
        }
        let meaningful = replay.filter { row in
            guard let aim = row["aim"] as? [Double] else { return false }
            return hypot(aim[0] - 0.5, aim[1] - 0.5) > 0.025
        }.count
        let completeFinalViews = replay.filter { $0["replayHasRealFinalPixels"] as? Bool == true }.count
        guard meaningful >= 2, completeFinalViews >= 12 else {
            throw Failure(message: "Camera replay did not exercise real noncentral views: \(meaningful), full final views: \(completeFinalViews)")
        }
        let replayReport: [String: Any] = ["views": replay.count, "nonCentralTargets": meaningful,
            "realFinalViews": completeFinalViews, "scope": "Virtual camera windows within real parent photos; full revealed margins come from real parent pixels. Not a physical iPhone test.", "searches": replay]
        try JSONSerialization.data(withJSONObject: replayReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("camera-reframing-replay.json"))
        print("PASS: \(replay.count) real-image camera views; \(meaningful) noncentral targets; \(completeFinalViews) real final images")
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
                            renderer: CompositionImageRenderer, sourceOverride: CGImage? = nil,
                            replayParent: CGImage? = nil, replayWindow: CGRect? = nil,
                            constrained: Bool = false, maximumOpticalZoom: CGFloat? = nil) throws -> [String: Any] {
        let source: CGImage
        if let sourceOverride { source = sourceOverride }
        else { source = try image(photos.appendingPathComponent("source").appendingPathComponent(file.lastPathComponent)) }
        let totalStarted = ProcessInfo.processInfo.systemUptime
        let pixels = try pixelBuffer(source)
        let analyzer = NativeSubjectAnalysis(renderer: renderer)
        guard let detected = analyzer.analyze(pixels) else { throw Failure(message: "Production recognition failed") }
        guard let hero = detected.allCandidates.first, let baseRaster = detected.compositionRaster else {
            try save(source, to: output.appendingPathComponent(file.lastPathComponent))
            return ["file": file.lastPathComponent, "result": "manual-no-subject",
                    "modelAssessedCrops": 0, "charmAssessedCrops": 0, "poseSupportsTorsoPortrait": false,
                    "selectedZoom": 1.0, "automaticSelectionAllowed": false,
                    "detectedPeople": 0, "detectedAnimals": 0]
        }
        let started = ProcessInfo.processInfo.systemUptime
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let reference = renderer.referenceImage(ci) else { throw Failure(message: "Invalid source frame") }
        let cropModel = try FocalCropModel(url: modelURL.deletingLastPathComponent().appendingPathComponent("FocalCrop.mlmodelc"), image: reference)
        guard cropModel.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: CompositionAnalysisCancellation()) != nil else {
            throw Failure(message: "Crop importance failed")
        }
        let raster = cropModel.enriching(baseRaster)
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
            anchor: CompositionSubject.framingAnchor(bounds: bounds, preferred: hero.eyePosition), kind: kind,
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze)
        subject.allowsAttentionCrop = hero.isAttentionRegion && raster.hasAttention && bounds.width * bounds.height > 0.45
        let calibration = TrackingCalibration.fallback(aspect: Double(source.width) / Double(source.height))
        let budget = CompositionSearchBudget(complexScene: CompositionSearchBudget.isComplex(
            group: hero.isGroup, intents: intents), constrained: constrained)
        let zooms: [CGFloat] = [1, 2, 3] + (maximumOpticalZoom.map { [$0] } ?? [])
        func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents, portraitBounds: portraitBounds,
                raster: raster, calibration: calibration, currentZoom: 1, allowedZooms: zooms,
                protectedBounds: hero.companionBounds, incidentalBounds: incidentalPets + incidentalFaces,
                proposalLimit: seeds.isEmpty ? budget.coarse : budget.refinement, refining: seeds, allowsCameraPan: true,
                maximumOpticalZoom: maximumOpticalZoom)
        }
        let broad = proposals()
        if broad.isEmpty {
            print("No camera proposals \(file.lastPathComponent): eye=\(String(describing: hero.eyePosition)), anchor=\(subject.anchor), bounds=\(bounds), faces=\(ownFaces), companions=\(hero.companionBounds), intents=\(intents)")
            fflush(stdout)
        }
        guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: broad,
            image: ci, aspect: calibration.aspect, preferences: [:], modelURL: modelURL,
            aestheticModelURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmAesthetics.mlmodelc"),
            positionURL: modelURL.deletingLastPathComponent().appendingPathComponent("CharmPositionEmbedding.bin"),
            aestheticLimit: budget.aesthetics, cropModel: cropModel,
            cancellation: CompositionAnalysisCancellation(), progress: { _ in },
            diagnostic: { print("Photo search diagnostic \(file.lastPathComponent): \($0)"); fflush(stdout) },
            refine: { proposals($0) }),
            !result.views.isEmpty, result.usedSpecialist,
            let best = result.views.first, let bestAssessment = best.assessment, let bestAesthetics = best.aesthetics else {
            throw Failure(message: "Real-photo search failed: \(file.lastPathComponent), proposals \(broad.count), hero \(hero.label), bounds \(bounds)")
        }
        for view in result.views {
            guard view.proposal.observedFraction >= 0.78 else { throw Failure(message: "Unobserved scene exceeded the camera-pan budget") }
            guard let observed = CompositionViewSupport.region(view.proposal.sourceCorners),
                  CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.00000001, dy: -0.00000001).contains(observed) else {
                throw Failure(message: "A quality preview included unobserved source pixels")
            }
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
            "framingAnchorWasAdjusted": hero.eyePosition.map { $0 != subject.anchor } ?? false,
            "framingAnchor": [Double(subject.anchor.x), Double(subject.anchor.y)],
            "detectedPeople": detected.allCandidates.filter { $0.category == .human && !$0.isGroup }.count,
            "detectedAnimals": detected.allCandidates.filter { $0.category == .animal }.count,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "modelAssessedCrops": result.assessedCount, "selectedZoom": Double(best.proposal.zoom),
            "charmAssessedCrops": result.modernAssessmentCount, "aestheticRating": bestAesthetics.mean,
            "cropRankAssessments": result.cropAssessmentCount,
            "qualityVetoedCount": result.qualityVetoedCount, "needsQualityReview": result.needsQualityReview,
            "constrainedSearchBudget": constrained,
            "observedFraction": best.proposal.observedFraction,
            "requiresSceneVerification": !best.proposal.isEntirelyObserved,
            "aim": [Double(best.proposal.aimPoint.x), Double(best.proposal.aimPoint.y)],
            "poseSupportsTorsoPortrait": portraitBounds != nil, "selectedIntent": best.proposal.intent.rawValue,
            "compositionRating": bestAssessment.mean, "secondsMac": ProcessInfo.processInfo.systemUptime - started,
            "totalAnalysisSecondsMac": ProcessInfo.processInfo.systemUptime - totalStarted,
            "automaticSelectionAllowed": result.canAutoselect]
        var detailed = row
        if let eye = hero.eyePosition { detailed["rawEyePoint"] = [Double(eye.x), Double(eye.y)] }
        if let maximumOpticalZoom { detailed["maximumOpticalZoom"] = Double(maximumOpticalZoom) }
        detailed["choices"] = try result.views.map { view -> [String: Any] in
            guard let composition = view.assessment, let aesthetics = view.aesthetics else {
                throw Failure(message: "Missing completed specialist scores")
            }
            return ["zoom": Double(view.proposal.zoom), "original": view.proposal.isUnchangedView,
             "intent": view.proposal.intent.rawValue, "score": view.proposal.score,
             "composition": composition.mean, "aesthetics": aesthetics.mean,
             "retainedAttention": view.proposal.retainedAttention,
             "cropPreference": view.cropPreference, "geometryScore": view.geometryScore,
             "satisfiesFramingGoal": view.satisfiesFramingGoal,
             "passesQualityAudit": view.passesQualityAudit,
             "observedFraction": view.proposal.observedFraction,
             "aim": [Double(view.proposal.aimPoint.x), Double(view.proposal.aimPoint.y)],
             "sourceCorners": view.proposal.sourceCorners.map { [Double($0.x), Double($0.y)] }]
        }
        if let parent = replayParent, let window = replayWindow {
            let corners = best.proposal.sourceCorners.map {
                CGPoint(x: (window.minX + $0.x * window.width) / CGFloat(parent.width),
                        y: (window.minY + $0.y * window.height) / CGFloat(parent.height))
            }
            let allObservedInParent = corners.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
            detailed["replayHasRealFinalPixels"] = allObservedInParent
            if allObservedInParent,
               let finalImage = renderer.projectedFrame(image: CIImage(cgImage: parent), corners: corners,
                    size: CGSize(width: CGFloat(source.width), height: CGFloat(source.height))),
               let observed = analyzer.analyze(try pixelBuffer(finalImage)) {
                let future = TrackingCalibration(fx: calibration.fx * Double(best.proposal.zoom),
                    fy: calibration.fy * Double(best.proposal.zoom), cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
                let protectedBounds = CompositionCropProtection.bounds(body: bounds, portrait: portraitBounds,
                    intent: best.proposal.intent, anchor: subject.anchor, attentionRegion: subject.allowsAttentionCrop)
                guard let projected = CompositionPlanner.project(protectedBounds, from: calibration, to: future,
                    rotation: best.proposal.rotation) else { throw Failure(message: "Replay lost its protected subject") }
                let measured = observed.allCandidates.map {
                    CompositionSubject(index: 0, bounds: $0.boundingBox,
                        anchor: CompositionSubject.framingAnchor(bounds: $0.boundingBox, preferred: $0.eyePosition),
                        kind: analyzer.subjectKind($0), confidence: Double($0.confidence), importance: $0.prominenceScore, gaze: $0.gaze)
                }
                let expectedPeople = hero.isGroup ? hero.companionBounds.filter { !hero.faceBounds.contains($0) }.count :
                    (subject.kind == .person ? 1 : 0)
                detailed["replayFinalSubjectAccepted"] = FinalFramingEvidence.accepts(protectedBounds: projected,
                    expectedKind: subject.kind, minimumFaces: hero.faceBounds.count, minimumPeople: expectedPeople,
                    subjects: measured, faces: observed.allFaceRects)
                let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
                let trackedPoint = hero.trackingPoint ?? best.proposal.subjectPoint
                guard let aim = CompositionAimGeometry(subject: trackedPoint, calibration: calibration,
                    sourcePose: identity, aimWorldRay: best.proposal.rotation.act(SIMD3(0, 0, -1))),
                      let projectedAim = aim.projection(subject: future.project(deviceRay: best.proposal.rotation.inverse.act(
                        calibration.deviceRay(at: trackedPoint))).point, calibration: future, pose: best.proposal.rotation),
                      hypot(projectedAim.point.x - 0.5, projectedAim.point.y - 0.5) < 0.00001 else {
                    throw Failure(message: "Visible aim and simulated final camera disagree")
                }
                try save(finalImage, to: output.appendingPathComponent("final_" + file.lastPathComponent))
            }
        }
        try save(best.image, to: output.appendingPathComponent(file.lastPathComponent))
        return detailed
    }
}
