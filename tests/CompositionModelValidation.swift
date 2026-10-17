import Foundation
import CoreGraphics
import ImageIO
import CoreImage
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
                throw Failure(message: "Charm position shape differs from author")
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
            "scope": "Production composition search and Core ML; Vision person/animal boxes provided by harness. Not a physical-iPhone FPS test or full YOLO pipeline benchmark."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("real-photo-search.json"))
        print("PASS: \(parity.count) author-to-Swift parity photos; \(searches.count) production composition searches")
    }

    static func boundedBox(_ box: CGRect) -> CGRect? {
        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return !rect.isNull && !rect.isEmpty && rect.width > 0.01 && rect.height > 0.01 ? rect : nil
    }

    static func searchPhoto(file: URL, photos: URL, modelURL: URL, output: URL,
                            renderer: CompositionImageRenderer) throws -> [String: Any] {
        let source = try image(photos.appendingPathComponent("source").appendingPathComponent(file.lastPathComponent))
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let people = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        people.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up)
        try handler.perform([request, people, animals])
        let ci = CIImage(cgImage: source)
        guard let raster = renderer.raster(image: ci, saliency: request.results?.first?.pixelBuffer) else {
            throw Failure(message: "Missing raster")
        }
        let bodies: [CGRect] = (people.results ?? []).filter { $0.confidence >= 0.4 }.compactMap { boundedBox($0.boundingBox) }
        let petBoxes: [CGRect] = (animals.results ?? []).filter { $0.confidence >= 0.4 }.compactMap { boundedBox($0.boundingBox) }
        let pets: [CGRect] = petBoxes.sorted { lhs, rhs in lhs.width * lhs.height > rhs.width * rhs.height }
        let isGroup = bodies.count >= 2
        let initialBounds = bodies.first ?? pets.first ?? CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let bounds = bodies.dropFirst().reduce(initialBounds) { $0.union($1) }
        let kind: CompositionSubjectKind
        let intents: [LocalCompositionIntent]
        if isGroup { kind = .group; intents = [.group] }
        else if !bodies.isEmpty { kind = .person; intents = [.portrait, .environmentalPortrait] }
        else if !pets.isEmpty { kind = .animal; intents = [.animal] }
        else { kind = .scenery; intents = [.landscape] }
        let incidentalPets = bodies.isEmpty ? Array(pets.dropFirst()) : pets
        let primaryBounds = bodies.isEmpty ? Array(pets.prefix(1)) : bodies
        let subject = CompositionSubject(index: 0, bounds: bounds,
            anchor: CGPoint(x: bounds.midX, y: bounds.midY), kind: kind,
            confidence: 0.9, importance: 1, gaze: 0)
        let calibration = TrackingCalibration.fallback(aspect: Double(source.width) / Double(source.height))
        func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.proposals(subjects: [subject], intents: intents, raster: raster,
                calibration: calibration, currentZoom: 1, allowedZooms: [1, 2, 3], protectedBounds: primaryBounds,
                incidentalBounds: incidentalPets,
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
            throw Failure(message: "Real-photo search failed: \(file.lastPathComponent), proposals \(broad.count), bounds \(bounds), people \(bodies)")
        }
        for view in result.views {
            let future = TrackingCalibration(fx: calibration.fx * Double(view.proposal.zoom),
                fy: calibration.fy * Double(view.proposal.zoom), cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
            for body in primaryBounds {
                guard let projected = CompositionPlanner.project(body, from: calibration, to: future,
                    rotation: view.proposal.rotation), CompositionPlanner.visibleFraction(projected) > 0.98 else {
                    throw Failure(message: "Search cropped a protected person: \(file.lastPathComponent)")
                }
            }
            for pet in incidentalPets {
                guard let projected = CompositionPlanner.project(pet, from: calibration, to: future,
                    rotation: view.proposal.rotation) else { continue }
                let fraction = CompositionPlanner.visibleFraction(projected)
                guard fraction <= 0.02 || fraction >= 0.98 else {
                    throw Failure(message: "Search bisected a background animal: \(file.lastPathComponent)")
                }
            }
        }
        let row: [String: Any] = ["file": file.lastPathComponent, "detectedPeople": bodies.count,
            "detectedAnimals": pets.count,
            "sourceWidth": source.width, "sourceHeight": source.height,
            "modelAssessedCrops": result.assessedCount, "selectedZoom": Double(best.proposal.zoom),
            "charmAssessedCrops": result.modernAssessmentCount,
            "aestheticRating": bestAesthetics.mean,
            "compositionRating": bestAssessment.mean,
            "secondsMac": ProcessInfo.processInfo.systemUptime - started,
            "automaticSelectionAllowed": result.canAutoselect]
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(file.lastPathComponent) as CFURL,
            "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, result.views[0].image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot save preview") }
        return row
    }
}
