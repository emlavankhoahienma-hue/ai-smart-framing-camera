import Foundation
import CoreGraphics
import CoreImage
import CoreML
import ImageIO

@main
enum InferenceLifetimeRegression {
    struct Failure: Error { let message: String }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let photos = root.appendingPathComponent("tests/fixtures/fcdb")
        let files = try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count >= 12 else { throw Failure(message: "Missing real photograph inputs") }
        let renderer = CompositionImageRenderer()
        var rows: [[String: Any]] = [], settled: [UInt64] = []
        for cycle in 0..<12 {
            let peaks: [UInt64] = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(files[cycle] as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Cannot decode real photo") }
                let token = CompositionAnalysisCancellation()
                let ci = CIImage(cgImage: image)
                let aspect = Double(image.width) / Double(image.height)
                var views: [CGImage] = []
                for scale in [CGFloat(1), 0.9, 0.8, 0.7, 0.6, 0.5] {
                    let r = CGRect(x: (1 - scale) / 2, y: (1 - scale) / 2, width: scale, height: scale)
                    let corners = [r.origin, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                    guard let preview = renderer.preview(image: ci, corners: corners, aspect: aspect) else { throw Failure(message: "Preview failed") }
                    views.append(preview)
                }
                var peaks: [UInt64] = []
                try autoreleasepool {
                    let crop = try FocalCropModel(url: root.appendingPathComponent("FocalCrop.mlmodelc"), image: image)
                    guard crop.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: token) != nil else { throw Failure(message: "Focal failed") }
                    peaks.append(CompositionInferenceResources.footprint)
                    crop.releaseInferenceWeights()
                }
                try autoreleasepool {
                    let model = try PhotographicCompositionModel(url: root.appendingPathComponent("SAMPComposition.mlmodelc"))
                    for view in views {
                        guard model.assess(view, cancellation: token) != nil else { throw Failure(message: "SAMP failed") }
                        peaks.append(CompositionInferenceResources.footprint)
                    }
                }
                try autoreleasepool {
                    let model = try CharmPhotographicModel(url: root.appendingPathComponent("CharmAesthetics.mlmodelc"),
                        positionURL: root.appendingPathComponent("CharmPositionEmbedding.bin"), computeUnits: .cpuOnly)
                    for view in views {
                        guard model.assess(view, cancellation: token) != nil else { throw Failure(message: "Charm failed") }
                        peaks.append(CompositionInferenceResources.footprint)
                    }
                    token.cancel()
                    guard model.assess(views[0], cancellation: token) == nil else { throw Failure(message: "Cancellation ignored") }
                }
                return peaks
            }
            let after = CompositionInferenceResources.footprint
            settled.append(after)
            rows.append(["cycle": cycle, "photo": files[cycle].lastPathComponent,
                "footprintAfterRelease": after, "peakObservedFootprint": peaks.max() ?? after])
            print("Inference lifetime cycle \(cycle): \(after) bytes after release")
            fflush(stdout)
        }
        let baseline = settled[2...4].reduce(0, +) / 3
        let final = settled.suffix(3).reduce(0, +) / 3
        let report: [String: Any] = ["scope": "macOS production model wrappers, 12 real photos; not iPhone jetsam reproduction",
            "photos": 12, "focalPredictions": 12, "sampPredictions": 72, "charmCPUOnlyPredictions": 72,
            "warmFootprint": baseline, "finalFootprint": final, "cycles": rows]
        let output = root.appendingPathComponent("validation/swift/inference-lifetime.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        guard final <= baseline + 160 * 1024 * 1024 else { throw Failure(message: "Sustained memory growth across released analyses") }
        print("PASS: repeated real-image inference, CPU-only Charm, cancellation and bounded post-warmup memory")
    }
}
