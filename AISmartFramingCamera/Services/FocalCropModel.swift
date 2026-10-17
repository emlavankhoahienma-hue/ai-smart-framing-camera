import Foundation
import CoreGraphics
import CoreML
import Accelerate

/// Appwrite's released RepViT crop ranker, pretrained on CPC and fine-tuned on
/// GAICD preferences. Scores compare regions of one source image, not photos.
final class FocalCropModel {
    struct Evidence {
        let preferences: [Double]
        let importance: [Double]
    }

    private let model: MLModel
    let imageInput: MLMultiArray
    private let boxes: MLMultiArray
    private let content: MLMultiArray
    private let letterbox: CGRect
    private var importance: [Double]?

    init(url: URL, image: CGImage) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        let expected = ["image": [1, 3, 256, 256], "boxes": [1, 128, 4], "content": [1, 4]]
        for (name, shape) in expected {
            guard model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        imageInput = try MLMultiArray(shape: [1, 3, 256, 256], dataType: .float32)
        boxes = try MLMultiArray(shape: [1, 128, 4], dataType: .float32)
        content = try MLMultiArray(shape: [1, 4], dataType: .float32)
        let scale = min(256.0 / Double(image.width), 256.0 / Double(image.height))
        let width = max(1, min(256, Int(Double(image.width) * scale + 0.5)))
        let height = max(1, min(256, Int(Double(image.height) * scale + 0.5)))
        let left = (256 - width) / 2, top = (256 - height) / 2
        letterbox = CGRect(x: Double(left) / 256, y: Double(top) / 256,
                           width: Double(width) / 256, height: Double(height) / 256)
        guard let rgb = CompositionPhotoPixels.resizedRGB(image: image, width: width, height: height) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let input = imageInput.dataPointer.assumingMemoryBound(to: Float.self)
        vDSP_vclr(input, 1, vDSP_Length(imageInput.count))
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for y in 0..<height { for x in 0..<width { for channel in 0..<3 {
            input[channel * 256 * 256 + (top + y) * 256 + left + x] =
                (Float(rgb[(y * width + x) * 3 + channel]) / 255 - mean[channel]) / std[channel]
        } } }
        let c = content.dataPointer.assumingMemoryBound(to: Float.self)
        c[0] = Float(letterbox.minX); c[1] = Float(letterbox.minY)
        c[2] = Float(letterbox.maxX); c[3] = Float(letterbox.maxY)
    }

    func assess(_ regions: [CGRect], cancellation: CompositionAnalysisCancellation) -> Evidence? {
        guard !cancellation.isCancelled, !regions.isEmpty, regions.count <= 128,
              regions.allSatisfy({ CompositionViewSupport.validRegion($0) }) else { return nil }
        let values = boxes.dataPointer.assumingMemoryBound(to: Float.self)
        for index in 0..<128 {
            let box = index < regions.count ? regions[index] : CGRect(x: 0, y: 0, width: 1, height: 1)
            values[index * 4] = Float(box.minX); values[index * 4 + 1] = Float(box.minY)
            values[index * 4 + 2] = Float(box.maxX); values[index * 4 + 3] = Float(box.maxY)
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: imageInput), "boxes": MLFeatureValue(multiArray: boxes),
            "content": MLFeatureValue(multiArray: content)]), !cancellation.isCancelled,
              let result = try? model.prediction(from: provider), !cancellation.isCancelled,
              let scores = result.featureValue(for: "cropScores")?.multiArrayValue, scores.count == 128,
              let map = result.featureValue(for: "importance")?.multiArrayValue, map.count == 4096 else { return nil }
        let preferences = regions.indices.map { Double(truncating: scores[$0]) }
        let samples = (0..<4096).map { Double(truncating: map[$0]) }
        guard preferences.allSatisfy(\.isFinite), samples.allSatisfy({ $0.isFinite && (-0.0001...1.0001).contains($0) }) else { return nil }
        let bounded = samples.map { min(1, max(0, $0)) }
        importance = bounded
        return Evidence(preferences: preferences, importance: bounded)
    }

    /// Only composition evidence is enriched; detector identities/confidences and
    /// coherent groups remain those of the preserved recognition pipeline.
    func enriching(_ raster: CompositionRaster) -> CompositionRaster {
        guard let importance, raster.isValid,
              (importance.max() ?? 0) - (importance.min() ?? 0) > 0.01 else { return raster }
        func sample(_ point: CGPoint) -> Double {
            let x = min(63, max(0, Double(letterbox.minX + point.x * letterbox.width) * 64 - 0.5))
            let y = min(63, max(0, Double(letterbox.minY + point.y * letterbox.height) * 64 - 0.5))
            let x0 = Int(x), y0 = Int(y), x1 = min(63, Int(x) + 1), y1 = min(63, Int(y) + 1)
            let dx = x - Double(x0), dy = y - Double(y0)
            return (importance[y0 * 64 + x0] * (1 - dx) + importance[y0 * 64 + x1] * dx) * (1 - dy) +
                (importance[y1 * 64 + x0] * (1 - dx) + importance[y1 * 64 + x1] * dx) * dy
        }
        let attention = raster.attention.enumerated().map { index, value in
            let point = CGPoint(x: (Double(index % raster.side) + 0.5) / Double(raster.side),
                                y: (Double(index / raster.side) + 0.5) / Double(raster.side))
            return 0.5 * value + 0.5 * sample(point)
        }
        return CompositionRaster(side: raster.side, luminance: raster.luminance, attention: attention,
                                 edges: raster.edges, hasAttention: true)
    }
}

enum LearnedFramingPolicy {
    /// Full-image quality alone cannot veto correcting an undersized or poorly
    /// placed subject. Neural preference selects among near-optimal safe layouts.
    static func admissible(geometry: Double, best: Double) -> Bool {
        geometry.isFinite && best.isFinite && geometry >= best - 0.018
    }

    static func preferencePercentile(_ value: Double, among scores: [Double]) -> Double? {
        guard value.isFinite, !scores.isEmpty, scores.allSatisfy(\.isFinite) else { return nil }
        let epsilon = 0.0001
        let lower = scores.filter { $0 < value - epsilon }.count
        let tied = scores.filter { abs($0 - value) <= epsilon }.count
        return (Double(lower) + 0.5 * Double(tied)) / Double(scores.count)
    }

    static func score(preference: Double, peers: [Double], composition: Double,
                      aesthetics: Double, geometry: Double) -> Double? {
        guard let percentile = preferencePercentile(preference, among: peers),
              [composition, aesthetics, geometry].allSatisfy(\.isFinite),
              (1...5).contains(composition), (1...5).contains(aesthetics) else { return nil }
        return 0.70 * percentile + 0.10 * (composition - 1) / 4 +
            0.15 * (aesthetics - 1) / 4 + 0.05 * min(1, max(0, geometry))
    }
}
