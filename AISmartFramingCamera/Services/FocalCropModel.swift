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

    private var model: MLModel?
    /// Reused feature buffers; validation replays these exact values in PyTorch.
    let imageInput: MLMultiArray
    let boxes: MLMultiArray
    let content: MLMultiArray
    private let letterbox: CGRect
    private var importance: [Double]?

    init(url: URL, image: CGImage) throws {
        try CompositionInferenceResources.requireHeadroom()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        let expected = ["image": [1, 3, 256, 256], "boxes": [1, 128, 4], "content": [1, 4]]
        for (name, shape) in expected {
            guard loaded.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape.map(\.intValue) == shape else {
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
        return autoreleasepool {

            guard let model, !cancellation.isCancelled, !regions.isEmpty, regions.count <= 128,
                  regions.allSatisfy({ CompositionViewSupport.validRegion($0) }) else { return nil }
            let values = boxes.dataPointer.assumingMemoryBound(to: Float.self)
            for index in 0..<128 {
                let box = index < regions.count ? regions[index] : CGRect(x: 0, y: 0, width: 1, height: 1)
                values[index * 4] = Float(box.minX); values[index * 4 + 1] = Float(box.minY)
                values[index * 4 + 2] = Float(box.maxX); values[index * 4 + 3] = Float(box.maxY)
            }
            let result: MLFeatureProvider
            do {
                try CompositionInferenceResources.requireHeadroom()
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(multiArray: imageInput), "boxes": MLFeatureValue(multiArray: boxes),
                    "content": MLFeatureValue(multiArray: content)])
                guard !cancellation.isCancelled else { return nil }
                result = try model.prediction(from: provider)
            } catch {
                CompositionInferenceResources.report("Focal prediction", error: error)
                return nil
            }
            guard !cancellation.isCancelled,
                  let scores = result.featureValue(for: "cropScores")?.multiArrayValue, scores.count == 128,
                  let map = result.featureValue(for: "importance")?.multiArrayValue, map.count == 4096 else { return nil }
            let preferences = regions.indices.map { Double(truncating: scores[$0]) }
            let samples = (0..<4096).map { Double(truncating: map[$0]) }
            guard preferences.allSatisfy(\.isFinite), samples.allSatisfy({ $0.isFinite && (-0.0001...1.0001).contains($0) }) else { return nil }
            let bounded = samples.map { min(1, max(0, $0)) }
            importance = bounded
            return Evidence(preferences: preferences, importance: bounded)
        }
    }

    /// Only composition evidence is enriched; detector identities/confidences and
    /// coherent groups remain those of the preserved recognition pipeline.
    func releaseInferenceWeights() { model = nil }

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
    private static let compositionWeight = 0.10
    private static let aestheticsWeight = 0.15

    /// Intent supplies safe layout candidates. Relative neural preference orders
    /// them, with independent quality audits for substantial crop regressions.
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

    /// A stronger size/layout fit cannot authorize a deep crop when independent
    /// learned assessments show substantial context or image-quality loss.
    /// These margins exceed measured preprocessing/model numerical variation;
    /// preference logits remain relative evidence, never calibrated confidence.
    static func passesQualityAudit(zoomRatio: Double, preference: Double, originalPreference: Double,
        composition: Double, originalComposition: Double, aesthetics: Double, originalAesthetics: Double) -> Bool {
        guard [zoomRatio, preference, originalPreference, composition, originalComposition,
               aesthetics, originalAesthetics].allSatisfy(\.isFinite), zoomRatio > 0,
              [composition, originalComposition, aesthetics, originalAesthetics].allSatisfy({ (1...5).contains($0) }) else { return false }
        // Whole-photo quality and an incomplete same-focal pan are not comparable.
        guard zoomRatio > 1.12 else { return true }
        let preferenceLoss = originalPreference - preference
        let aestheticLoss = originalAesthetics - aesthetics
        let noLearnedImprovement = preferenceLoss >= 0.15 &&
            composition - originalComposition < 0.10 && aesthetics - originalAesthetics < 0.10
        let losesLearnedContext = preferenceLoss >= 0.6 && aestheticLoss >= 0.15
        // Use the same relative quality weights as final ranking. A small SAMP
        // increase must not hide a much larger Charm decrease at another zoom.
        let qualityLoss = (compositionWeight * (originalComposition - composition) +
            aestheticsWeight * aestheticLoss) / (compositionWeight + aestheticsWeight)
        let losesCombinedQuality = preferenceLoss >= 0.15 && qualityLoss >= 0.15
        let losesBothQualityRatings = originalComposition - composition >= 0.30 && aestheticLoss >= 0.20
        return !noLearnedImprovement && !losesLearnedContext && !losesCombinedQuality && !losesBothQualityRatings
    }

    static func score(preference: Double, peers: [Double], composition: Double,
                      aesthetics: Double, geometry: Double) -> Double? {
        guard let percentile = preferencePercentile(preference, among: peers),
              [composition, aesthetics, geometry].allSatisfy(\.isFinite),
              (1...5).contains(composition), (1...5).contains(aesthetics) else { return nil }
        return 0.70 * percentile + compositionWeight * (composition - 1) / 4 +
            aestheticsWeight * (aesthetics - 1) / 4 + 0.05 * min(1, max(0, geometry))
    }
}
