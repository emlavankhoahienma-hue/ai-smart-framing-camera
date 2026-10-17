import Foundation
import CoreGraphics
import CoreImage
import ImageIO

@main
enum FocalModelValidation {
    struct Failure: Error { let message: String }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw Failure(message: "Expected model, fixtures and report paths") }
        let modelURL = URL(fileURLWithPath: args[1])
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        let renderer = CompositionImageRenderer()
        var output: [[String: Any]] = []
        for fixture in fixtures {
            let file = fixture["file"] as! String
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Cannot decode \(file)") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = CGImagePropertyOrientation(rawValue: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
            guard let image = renderer.referenceImage(CIImage(cgImage: cg).oriented(orientation)) else { throw Failure(message: "Invalid source extent") }
            let regions = (fixture["regions"] as! [[Double]]).map {
                CGRect(x: $0[0], y: $0[1], width: $0[2] - $0[0], height: $0[3] - $0[1])
            }
            let model = try FocalCropModel(url: modelURL, image: image)
            guard let evidence = model.assess(regions, cancellation: CompositionAnalysisCancellation()) else {
                throw Failure(message: "Real crop inference failed: \(file)")
            }
            var row: [String: Any] = ["file": file, "preferences": evidence.preferences]
            if let expected = fixture["scores"] as? [Double], let map = fixture["importance"] as? [Double] {
                guard expected.count == evidence.preferences.count, map.count == evidence.importance.count else {
                    throw Failure(message: "Invalid reference output")
                }
                let scoreError = zip(expected, evidence.preferences).map { abs($0.0 - $0.1) }.max() ?? 0
                let mapError = zip(map, evidence.importance).map { abs($0.0 - $0.1) }.max() ?? 0
                guard scoreError < 0.08, mapError < 0.03 else {
                    throw Failure(message: "Swift crop preprocessing drift: \(file), score=\(scoreError), map=\(mapError)")
                }
                row["maxPreferenceError"] = scoreError
                row["maxImportanceError"] = mapError
            }
            output.append(row)
        }
        for value in [0.0, 0.02, 1.0] {
            guard let image = renderer.referenceImage(CIImage(color: CIColor(red: value, green: value, blue: value))
                .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 640))) else { throw Failure(message: "Invalid flat fixture") }
            let model = try FocalCropModel(url: modelURL, image: image)
            guard model.assess([CGRect(x: 0, y: 0, width: 1, height: 1)],
                cancellation: CompositionAnalysisCancellation()) != nil else { throw Failure(message: "Nonfinite flat-image output") }
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
        print("Native crop-model images: \(output.count); flat inputs: 3")
    }
}
