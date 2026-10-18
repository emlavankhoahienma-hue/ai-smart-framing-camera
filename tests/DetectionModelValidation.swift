import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

/// Executes production YOLO loaders and decoders on real photos. Raw predictions
/// are retained for comparison against the separate author COCO annotations.
@main
enum DetectionModelValidation {
    struct Failure: Error { let message: String }

    static func buffer(_ image: CIImage, context: CIContext) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height),
            kCVPixelFormatType_32BGRA, attributes, &output) == kCVReturnSuccess, let output else {
            throw Failure(message: "Cannot allocate validation pixel buffer")
        }
        context.render(image, to: output, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return output
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedModel = CommandLine.arguments[3]
        var minimumImages = 160
        if CommandLine.arguments.count > 4 {
            guard let value = Int(CommandLine.arguments[4]), value >= 80 else {
                throw Failure(message: "Invalid minimum labelled-photo count")
            }
            minimumImages = value
        }
        var classes: [String: String] = [:]
        if CommandLine.arguments.count > 5 {
            classes = try JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5])))
        }
        let detector = YOLODetectionEngine()
        guard detector.hasYOLOModel else {
            throw Failure(message: "Production optical recovery model did not load")
        }
        let mappings: [(String, NeuralSubjectCategory)] = [("person", .human), ("cat", .animal), ("dog", .animal),
            ("mouse", .foregroundObject), ("hot dog", .foregroundObject), ("teddy bear", .foregroundObject),
            ("cup", .foregroundObject)]
        for (label, expected) in mappings {
            guard detector.photographicCategory(forCOCOLabel: label) == expected else {
                throw Failure(message: "Incorrect photographic COCO category: \(label)")
            }
        }
        let tracking = expectedModel == "yolo12n"
        func detect(_ pixels: CVPixelBuffer, cancellation: CompositionAnalysisCancellation) throws -> [NeuralSubjectCandidate] {
            let result = tracking
                ? detector.detectObjects(pixelBuffer: pixels, orientation: .up, cancellation: cancellation)
                : detector.detectPhotographicObjects(pixelBuffer: pixels, orientation: .up, cancellation: cancellation)
            if !cancellation.isCancelled {
                let actual = tracking ? detector.activeModelName : detector.activePhotographicModelName
                guard actual == expectedModel else {
                    throw Failure(message: "Requested \(expectedModel) but executed \(actual ?? "none")")
                }
            }
            return result
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= minimumImages else { throw Failure(message: "Not enough real detection photos") }
        var records: [[String: Any]] = []
        var detectedCount = 0
        for file in files {
            let row: [String: Any] = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary) else {
                    throw Failure(message: "Cannot decode real detection photo")
                }
                let pixels = try buffer(CIImage(cgImage: image), context: context)
                let started = ProcessInfo.processInfo.systemUptime
                let detections = try detect(pixels, cancellation: CompositionAnalysisCancellation())
                detectedCount += detections.count
                let boxes: [[String: Any]] = try detections.map { candidate in
                    let rect = candidate.boundingBox
                    guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                          CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect),
                          candidate.confidence.isFinite, candidate.confidence >= 0.45 else {
                        throw Failure(message: "Production decoder emitted an invalid observation")
                    }
                    var box: [String: Any] = ["label": candidate.label, "category": candidate.category.rawValue,
                            "confidence": Double(candidate.confidence),
                            "box": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]]
                    if !classes.isEmpty {
                        let identifiers = classes.filter { detector.localizeYOLOLabel($0.value) == candidate.label }.map(\.key)
                        guard identifiers.count == 1, let identifier = identifiers.first, let classID = Int(identifier) else {
                            throw Failure(message: "COCO class could not be uniquely recovered from production label")
                        }
                        box["classID"] = classID
                    }
                    return box
                }
                return ["file": file.lastPathComponent, "detections": boxes, "executedModel": expectedModel,
                        "secondsMac": ProcessInfo.processInfo.systemUptime - started]
            }
            records.append(row)
        }
        let blank = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        let blankBuffer = try buffer(blank, context: context)
        let blankResults = try detect(blankBuffer, cancellation: CompositionAnalysisCancellation())
        guard blankResults.isEmpty, detectedCount > 0 else { throw Failure(message: "Blank/real-photo detector smoke check failed") }
        let cancelled = CompositionAnalysisCancellation()
        cancelled.cancel()
        guard try detect(blankBuffer, cancellation: cancelled).isEmpty else {
            throw Failure(message: "Cancelled detector request produced observations")
        }
        let result: [String: Any] = ["model": expectedModel, "images": records.count, "records": records,
            "semanticMappingChecks": mappings.count,
            "observations": detectedCount, "blankDetections": blankResults.count,
            "preprocessing": tracking ? "Vision scaleFill" : "Vision scaleFit",
            "scope": "Production Swift/Core ML detector on macOS. CADB records are functional checks; COCO predictions are evaluated separately against author boxes. No physical iPhone performance claim."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS: \(expectedModel), \(records.count) real-photo detection checks, blank and cancellation")
    }
}
