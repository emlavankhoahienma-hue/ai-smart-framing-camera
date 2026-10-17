import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

/// Executes the unchanged production YOLO loader and decoder on real photos.
/// Counts are observations, not accuracy against hand-labelled object boxes.
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
        let detector = YOLODetectionEngine()
        guard detector.hasYOLOModel, detector.activeModelName == expectedModel else {
            throw Failure(message: "Production loader did not load bundled \(expectedModel)")
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 160 else { throw Failure(message: "Not enough real detection photos") }
        var records: [[String: Any]] = []
        var detectedCount = 0
        for file in files {
            let row: [String: Any] = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1280] as CFDictionary) else {
                    throw Failure(message: "Cannot decode real detection photo")
                }
                let pixels = try buffer(CIImage(cgImage: image), context: context)
                let started = ProcessInfo.processInfo.systemUptime
                let detections = detector.detectPhotographicObjects(pixelBuffer: pixels, orientation: .up,
                    cancellation: CompositionAnalysisCancellation())
                detectedCount += detections.count
                let boxes: [[String: Any]] = try detections.map { candidate in
                    let rect = candidate.boundingBox
                    guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                          CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect),
                          candidate.confidence.isFinite, candidate.confidence >= 0.45 else {
                        throw Failure(message: "Production decoder emitted an invalid observation")
                    }
                    return ["label": candidate.label, "category": candidate.category.rawValue,
                            "confidence": Double(candidate.confidence),
                            "box": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]]
                }
                return ["file": file.lastPathComponent, "detections": boxes,
                        "secondsMac": ProcessInfo.processInfo.systemUptime - started]
            }
            records.append(row)
        }
        let blank = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        let blankBuffer = try buffer(blank, context: context)
        let blankResults = detector.detectPhotographicObjects(pixelBuffer: blankBuffer, orientation: .up,
            cancellation: CompositionAnalysisCancellation())
        guard blankResults.isEmpty, detectedCount > 0 else { throw Failure(message: "Blank/real-photo detector smoke check failed") }
        let cancelled = CompositionAnalysisCancellation()
        cancelled.cancel()
        guard detector.detectPhotographicObjects(pixelBuffer: blankBuffer, orientation: .up, cancellation: cancelled).isEmpty else {
            throw Failure(message: "Cancelled detector request produced observations")
        }
        let result: [String: Any] = ["model": expectedModel, "images": records.count, "records": records,
            "observations": detectedCount, "blankDetections": blankResults.count,
            "scope": "Unchanged production YOLO photographic loader/decoder on macOS; no object-box accuracy or physical iPhone claim"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("PASS: \(expectedModel), \(records.count) real-photo detection checks, blank and cancellation")
    }
}
