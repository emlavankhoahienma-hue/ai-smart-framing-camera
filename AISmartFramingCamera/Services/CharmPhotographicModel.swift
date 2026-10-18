import Foundation
import CoreGraphics
import CoreML

/// Charm-PARA (2025), the author's 21.5M-parameter DINOv2-small checkpoint.
/// Uses the released normal_flow for bounded previews, retaining aspect ratio.
final class CharmPhotographicModel {
    struct Assessment: Sendable {
        let distribution: [Double]
        var mean: Double {
            distribution.enumerated().reduce(0) { $0 + $1.element * (1 + Double($1.offset) * 0.5) }
        }
    }

    private let model: MLModel
    private let embedding: [Float]
    private var positionCache: [Int: MLMultiArray] = [:]
    private var patchInput: MLMultiArray?

    init(url: URL, positionURL: URL, computeUnits: MLComputeUnits? = nil) throws {
        try CompositionInferenceResources.requireHeadroom()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits ?? (ProcessInfo.processInfo.physicalMemory < 6_000_000_000 ? .cpuOnly : .cpuAndNeuralEngine)
        model = try MLModel(contentsOf: url, configuration: configuration)
        let data = try Data(contentsOf: positionURL)
        guard data.count == 1370 * 384 * MemoryLayout<Float>.size,
              model.modelDescription.inputDescriptionsByName["patches"]?.multiArrayConstraint?.shape.last?.intValue == 588 else {
            throw CocoaError(.coderInvalidValue)
        }
        embedding = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard embedding.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
    }

    func assess(_ image: CGImage, cancellation: CompositionAnalysisCancellation) -> Assessment? {
        return autoreleasepool {

            guard !cancellation.isCancelled, ProcessInfo.processInfo.thermalState != .critical,
                  let inputs = inputs(image) else { return nil }
            let result: MLFeatureProvider
            do {
                try CompositionInferenceResources.requireHeadroom()
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    "patches": MLFeatureValue(multiArray: inputs.patches),
                    "positions": MLFeatureValue(multiArray: inputs.positions)])
                guard !cancellation.isCancelled else { return nil }
                result = try model.prediction(from: provider)
            } catch {
                CompositionInferenceResources.report("Charm prediction", error: error)
                return nil
            }
            guard !cancellation.isCancelled,
                  let scores = result.featureValue(for: "aestheticDistribution")?.multiArrayValue, scores.count == 9 else { return nil }
            let values = (0..<9).map { Double(truncating: scores[$0]) }
            let sum = values.reduce(0, +)
            guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), abs(sum - 1) < 0.02 else { return nil }
            return Assessment(distribution: values.map { $0 / sum })
        }
    }

    func inputs(_ image: CGImage) -> (patches: MLMultiArray, positions: MLMultiArray)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, 336 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let rgb = CompositionPhotoPixels.resizedRGB(image: image, width: width, height: height) else { return nil }
        let rows = (height + 13) / 14, cols = (width + 13) / 14, count = rows * cols
        guard count > 0, count <= 1024 else { return nil }
        if patchInput?.count != count * 588 {
            do { patchInput = try MLMultiArray(shape: [1, NSNumber(value: count), 588], dataType: .float32) }
            catch { CompositionInferenceResources.report("Charm input allocation", error: error); return nil }
        }
        guard let patches = patchInput, let positions = positions(rows: rows, cols: cols) else { return nil }
        let values = patches.dataPointer.assumingMemoryBound(to: Float.self)
        values.update(repeating: 0, count: patches.count)
        for y in 0..<height { for x in 0..<width {
            let patch = (y / 14 * cols + x / 14) * 588
            let pixel = y % 14 * 14 + x % 14
            for c in 0..<3 { values[patch + c * 196 + pixel] = Float(rgb[(y * width + x) * 3 + c]) / 255 }
        } }
        return (patches, positions)
    }

    private func positions(rows: Int, cols: Int) -> MLMultiArray? {
        let key = rows * 2048 + cols
        if let cached = positionCache[key] { return cached }
        let output: MLMultiArray
        do { output = try MLMultiArray(shape: [1, NSNumber(value: rows * cols + 1), 384], dataType: .float32) }
        catch { CompositionInferenceResources.report("Charm position allocation", error: error); return nil }
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        for c in 0..<384 { values[c] = embedding[c] }
        func coefficients(_ index: Int, _ length: Int) -> [(Int, Double)] {
            let source = (Double(index) + 0.5) * 37 / (Double(length) + 0.1) - 0.5
            let base = Int(floor(source))
            return (-1...2).map { d in
                let distance = abs(source - Double(base + d)), a = -0.75
                let weight = distance <= 1 ? (a + 2) * pow(distance, 3) - (a + 3) * pow(distance, 2) + 1 :
                    a * pow(distance, 3) - 5 * a * pow(distance, 2) + 8 * a * distance - 4 * a
                return (min(36, max(0, base + d)), weight)
            }
        }
        let xs = (0..<cols).map { coefficients($0, cols) }, ys = (0..<rows).map { coefficients($0, rows) }
        for y in 0..<rows { for x in 0..<cols { for c in 0..<384 {
            var result = 0.0
            for (sy, wy) in ys[y] {
                var horizontal = 0.0
                for (sx, wx) in xs[x] { horizontal += Double(embedding[(1 + sy * 37 + sx) * 384 + c]) * wx }
                result += horizontal * wy
            }
            values[(1 + y * cols + x) * 384 + c] = Float(result)
        } } }
        if positionCache.count >= 4 { positionCache.removeAll(keepingCapacity: true) }
        positionCache[key] = output
        return output
    }
}
