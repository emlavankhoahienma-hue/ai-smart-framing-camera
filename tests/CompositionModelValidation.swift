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
            parity.append(["file": reference.file, "saliencyMAE": saliencyError, "meanScoreError": meanError])
            print("Swift parity: \(reference.file), saliency MAE \(saliencyError), rating error \(meanError)")
            if saliencyError > 0.01 || meanError > 0.08 {
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
            try autoreleasepool {
                let source = try image(file)
                let request = VNGenerateAttentionBasedSaliencyImageRequest()
                let people = VNDetectHumanRectanglesRequest()
                people.upperBodyOnly = false
                let handler = VNImageRequestHandler(cgImage: source, orientation: .up)
                try handler.perform([request, people])
                let ci = CIImage(cgImage: source)
                guard let raster = renderer.raster(image: ci, saliency: request.results?.first?.pixelBuffer) else {
                    throw Failure(message: "Missing raster")
                }
                let bodies = (people.results ?? []).filter { $0.confidence >= 0.4 }.map {
                    CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                           width: $0.boundingBox.width, height: $0.boundingBox.height)
                }
                let isGroup = bodies.count >= 2
                let bounds = bodies.dropFirst().reduce(bodies.first ?? CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) { $0.union($1) }
                let kind: CompositionSubjectKind = isGroup ? .group : (bodies.isEmpty ? .scenery : .person)
                let subject = CompositionSubject(index: 0, bounds: bounds,
                    anchor: CGPoint(x: bounds.midX, y: bounds.midY), kind: kind,
                    confidence: 0.9, importance: 1, gaze: 0)
                let intents: [LocalCompositionIntent] = isGroup ? [.group] : (bodies.isEmpty ? [.landscape] : [.portrait, .environmentalPortrait])
                let calibration = TrackingCalibration.fallback(aspect: Double(source.width) / Double(source.height))
                func proposals(_ seeds: [CompositionProposal] = []) -> [CompositionProposal] {
                    CompositionPlanner.proposals(subjects: [subject], intents: intents, raster: raster,
                        calibration: calibration, currentZoom: 1, allowedZooms: [1, 2, 3], protectedBounds: bodies,
                        proposalLimit: seeds.isEmpty ? 36 : 18, refining: seeds)
                }
                let started = ProcessInfo.processInfo.systemUptime
                guard let result = CompositionAestheticSearch(renderer: renderer).run(proposals: proposals(),
                    image: ci, aspect: calibration.aspect, preferences: [:], modelURL: modelURL,
                    cancellation: CompositionAnalysisCancellation(), progress: { _ in }, refine: { proposals($0) }),
                    !result.views.isEmpty, result.usedSpecialist else {
                    throw Failure(message: "Real-photo search failed: \(file.lastPathComponent)")
                }
                for view in result.views {
                    let future = TrackingCalibration(fx: calibration.fx * Double(view.proposal.zoom),
                        fy: calibration.fy * Double(view.proposal.zoom), cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
                    for body in bodies {
                        guard let projected = CompositionPlanner.project(body, from: calibration, to: future,
                            rotation: view.proposal.rotation), CompositionPlanner.visibleFraction(projected) > 0.98 else {
                            throw Failure(message: "Search cropped a protected person: \(file.lastPathComponent)")
                        }
                    }
                }
                let row: [String: Any] = ["file": file.lastPathComponent, "detectedPeople": bodies.count,
                    "modelAssessedCrops": result.assessedCount, "selectedZoom": Double(result.views[0].proposal.zoom),
                    "compositionRating": result.views[0].assessment?.mean ?? 0,
                    "secondsMac": ProcessInfo.processInfo.systemUptime - started,
                    "automaticSelectionAllowed": result.canAutoselect]
                searches.append(row)
                print("Search \(searches.count)/\(files.count): \(row)")
                let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(file.lastPathComponent) as CFURL,
                    "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, result.views[0].image, nil)
                guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot save preview") }
            }
        }
        let report: [String: Any] = ["images": searches.count, "searches": searches,
            "scope": "Production composition search and Core ML; Vision boxes provided by harness. Not a physical-iPhone FPS test or full YOLO pipeline benchmark."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("real-photo-search.json"))
        print("PASS: \(parity.count) author-to-Swift parity photos; \(searches.count) production composition searches")
    }
}
