import Foundation
import CoreGraphics
import CoreML
#if canImport(UIKit)
import UIKit
#endif

/// Charm-PARA (2025), the author's 21.5M-parameter DINOv2-small checkpoint.
/// Uses the released normal_flow for bounded previews, retaining aspect ratio.
///
/// NOTE: `CharmAesthetics.mlmodelc` is exported with `RangeDim(1..1024)` dynamic
/// sequence length. On iOS 17/18/26, forcing `.cpuAndNeuralEngine` triggers slow
/// ANE MIL dynamic-shape compilation stalls (15-45s) or CPU fallback on every load.
/// Running on `.cpuAndGPU` (Metal MPSGraph) compiles in ~0.15s and executes FP16
/// ViT self-attention in ~40-70ms with identical numerical accuracy.
final class CharmPhotographicModel {
    struct Assessment: Sendable {
        let distribution: [Double]
        var mean: Double {
            distribution.enumerated().reduce(0) { $0 + $1.element * (1 + Double($1.offset) * 0.5) }
        }
    }

    private final class ModelCache: @unchecked Sendable {
        static let shared = ModelCache()
        private let lock = NSLock()
        private var cachedURL: URL?
        private var cachedPositionURL: URL?
        private var cachedInstance: CharmPhotographicModel?

        private init() {
            CompositionMemoryBudget.registerCacheEvictor(id: "Charm", priority: 90) { [weak self] in
                self?.clear(includingPositions: false) ?? false
            }
            #if canImport(UIKit)
            _ = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                _ = self?.clear(includingPositions: true)
            }
            #endif
        }

        @discardableResult
        func clear(includingPositions: Bool = false) -> Bool {
            let evicted = lock.withLock { () -> Bool in
                let had = (cachedInstance != nil)
                cachedURL = nil
                cachedPositionURL = nil
                cachedInstance = nil
                return had
            }
            if includingPositions {
                SharedPositionCache.shared.clear()
            }
            if evicted {
                CompositionMemoryBudget.emitLifecycle("MODEL_UNLOAD", "CharmAesthetics")
            }
            return evicted
        }

        func getOrLoad(url: URL, positionURL: URL) -> CharmPhotographicModel? {
            if let existing = lock.withLock({
                (cachedURL == url && cachedPositionURL == positionURL) ? cachedInstance : nil
            }) {
                return existing
            }
            guard CompositionMemoryBudget.ensureHeadroom(
                minimumBytes: CompositionMemoryBudget.charmLoadHeadroomBytes,
                excluding: "Charm"
            ) else {
                CompositionMemoryBudget.emitTrace("Charm.SKIP_LOW_RAM", "avail=\(CompositionMemoryBudget.availableMB())MB")
                return nil
            }
            CompositionMemoryBudget.emitTrace("Charm.LOAD_BEGIN", url.lastPathComponent)
            let loaded: CharmPhotographicModel
            do {
                loaded = try CharmPhotographicModel(url: url, positionURL: positionURL)
            } catch {
                CompositionMemoryBudget.emitTrace("Charm.LOAD_FAIL", "\(error)")
                return nil
            }
            CompositionMemoryBudget.emitLifecycle("MODEL_LOAD", "CharmAesthetics (FP16 MPSGraph)")
            if CompositionMemoryBudget.shouldRetainModelCache(
                minimumAvailableBytes: CompositionMemoryBudget.charmRetainThresholdBytes
            ) {
                lock.withLock {
                    cachedURL = url
                    cachedPositionURL = positionURL
                    cachedInstance = loaded
                }
            }
            return loaded
        }
    }

    /// Persistent cross-instance cache for bicubic-interpolated DINOv2 position embeddings
    /// keyed by `(positionURL, rows, cols)`, avoiding 2.65M scalar iterations on repeat taps.
    private final class SharedPositionCache: @unchecked Sendable {
        static let shared = SharedPositionCache()
        private let lock = NSLock()
        private var storage: [String: MLMultiArray] = [:]

        func get(_ key: String) -> MLMultiArray? {
            lock.withLock { storage[key] }
        }

        func set(_ key: String, value: MLMultiArray) {
            lock.withLock {
                if storage.count >= 2 { storage.removeAll(keepingCapacity: true) }
                storage[key] = value
            }
        }

        func clear() {
            lock.withLock { storage.removeAll(keepingCapacity: false) }
        }
    }

    static func cachedOrLoad(url: URL, positionURL: URL) -> CharmPhotographicModel? {
        ModelCache.shared.getOrLoad(url: url, positionURL: positionURL)
    }

    static func clearCache() {
        ModelCache.shared.clear()
    }

    private let model: MLModel
    private let embedding: [Float]
    private let positionCachePrefix: String
    private var patchInput: MLMultiArray?

    init(url: URL, positionURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = true
        model = try MLModel(contentsOf: url, configuration: configuration)
        let data = try Data(contentsOf: positionURL)
        guard data.count == 1370 * 384 * MemoryLayout<Float>.size,
              model.modelDescription.inputDescriptionsByName["patches"]?.multiArrayConstraint?.shape.last?.intValue == 588 else {
            throw CocoaError(.coderInvalidValue)
        }
        embedding = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard embedding.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        positionCachePrefix = positionURL.path
    }

    func assess(_ image: CGImage, cancellation: CompositionAnalysisCancellation) -> Assessment? {
        guard !cancellation.isCancelled, ProcessInfo.processInfo.thermalState != .critical,
              let inputs = inputs(image) else { return nil }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "patches": MLFeatureValue(multiArray: inputs.patches),
                "positions": MLFeatureValue(multiArray: inputs.positions)]),
              !cancellation.isCancelled else { return nil }
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: provider)
        } catch {
            CompositionMemoryBudget.emitTrace("Charm.PREDICT_FAIL", "\(error)")
            return nil
        }
        guard !cancellation.isCancelled,
              let scores = result.featureValue(for: "aestheticDistribution")?.multiArrayValue, scores.count == 9 else { return nil }
        let values = (0..<9).map { Double(truncating: scores[$0]) }
        let sum = values.reduce(0, +)
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), abs(sum - 1) < 0.02 else { return nil }
        return Assessment(distribution: values.map { $0 / sum })
    }

    /// Trích xuất bản đồ Self-Attention cấp patch (nếu checkpoint có output `patchAttention`),
    /// chuẩn hóa về lưới 14x14 để hợp nhất vào S_sync; trả về nil nếu checkpoint chỉ xuất `aestheticDistribution`.
    func extractPatchAttention(_ image: CGImage, cancellation: CompositionAnalysisCancellation) -> [Double]? {
        guard !cancellation.isCancelled, ProcessInfo.processInfo.thermalState != .critical,
              model.modelDescription.outputDescriptionsByName["patchAttention"] != nil,
              let inputs = inputs(image),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [
                  "patches": MLFeatureValue(multiArray: inputs.patches),
                  "positions": MLFeatureValue(multiArray: inputs.positions)]),
              !cancellation.isCancelled,
              let result = try? model.prediction(from: provider),
              !cancellation.isCancelled,
              let attention = result.featureValue(for: "patchAttention")?.multiArrayValue,
              attention.count > 0 else { return nil }
        let count = attention.count
        let raw = (0..<count).map { Double(truncating: attention[$0]) }
        guard raw.allSatisfy(\.isFinite) else { return nil }
        let side = Int(sqrt(Double(count)).rounded())
        guard side > 0, side * side == count else { return nil }
        let low = raw.min() ?? 0.0
        let high = raw.max() ?? 1.0
        let span = high - low
        let normalized = span > 1e-6 ? raw.map { min(1.0, max(0.0, ($0 - low) / span)) } : [Double](repeating: 0.5, count: count)
        if side == 14 { return normalized }
        var grid14 = [Double](repeating: 0.0, count: 14 * 14)
        for y in 0..<14 {
            let sy = min(side - 1, y * side / 14)
            for x in 0..<14 {
                let sx = min(side - 1, x * side / 14)
                grid14[y * 14 + x] = normalized[sy * side + sx]
            }
        }
        return grid14
    }

    func inputs(_ image: CGImage) -> (patches: MLMultiArray, positions: MLMultiArray)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, 336 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let rgb = CompositionPhotoPixels.resizedRGB(image: image, width: width, height: height) else { return nil }
        let rows = (height + 13) / 14, cols = (width + 13) / 14, count = rows * cols
        guard count > 0, count <= 1024 else { return nil }
        if patchInput?.count != count * 588 {
            patchInput = try? MLMultiArray(shape: [1, NSNumber(value: count), 588], dataType: .float32)
        }
        guard let patches = patchInput, let positions = positions(rows: rows, cols: cols) else { return nil }
        let values = patches.dataPointer.assumingMemoryBound(to: Float.self)
        values.update(repeating: 0, count: patches.count)
        let inv255: Float = 1.0 / 255.0
        rgb.withUnsafeBufferPointer { rgbBuf in
            guard let src = rgbBuf.baseAddress else { return }
            for y in 0..<height {
                let py = y / 14
                let ly = (y % 14) * 14
                let rowPatchBase = py * cols
                let rowSrcBase = y * width * 3
                for x in 0..<width {
                    let patch = (rowPatchBase + x / 14) * 588
                    let pixel = ly + (x % 14)
                    let sIdx = rowSrcBase + x * 3
                    values[patch + pixel] = Float(src[sIdx]) * inv255
                    values[patch + 196 + pixel] = Float(src[sIdx + 1]) * inv255
                    values[patch + 392 + pixel] = Float(src[sIdx + 2]) * inv255
                }
            }
        }
        return (patches, positions)
    }

    private func positions(rows: Int, cols: Int) -> MLMultiArray? {
        let key = "\(positionCachePrefix)|\(rows)x\(cols)"
        if let cached = SharedPositionCache.shared.get(key) { return cached }
        guard let output = try? MLMultiArray(shape: [1, NSNumber(value: rows * cols + 1), 384], dataType: .float32) else { return nil }
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        embedding.withUnsafeBufferPointer { embBuf in
            guard let emb = embBuf.baseAddress else { return }
            for c in 0..<384 { values[c] = emb[c] }
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
            let xs = (0..<cols).map { coefficients($0, cols) }
            let ys = (0..<rows).map { coefficients($0, rows) }
            // Separable 2-pass bicubic interpolation: O(rows*37*384 + rows*cols*384)
            // mathematically identical to the 4x4 nested loop, ~4x fewer memory loads.
            var horiz = [Double](repeating: 0.0, count: 37 * cols * 384)
            horiz.withUnsafeMutableBufferPointer { hBuf in
                guard let hPtr = hBuf.baseAddress else { return }
                for sy in 0..<37 {
                    let syRowBase = (1 + sy * 37) * 384
                    let hSyBase = sy * cols * 384
                    for x in 0..<cols {
                        let cx = xs[x]
                        let sx0 = syRowBase + cx[0].0 * 384, w0 = cx[0].1
                        let sx1 = syRowBase + cx[1].0 * 384, w1 = cx[1].1
                        let sx2 = syRowBase + cx[2].0 * 384, w2 = cx[2].1
                        let sx3 = syRowBase + cx[3].0 * 384, w3 = cx[3].1
                        let dst = hSyBase + x * 384
                        for c in 0..<384 {
                            hPtr[dst + c] = Double(emb[sx0 + c]) * w0 +
                                Double(emb[sx1 + c]) * w1 +
                                Double(emb[sx2 + c]) * w2 +
                                Double(emb[sx3 + c]) * w3
                        }
                    }
                }
                for y in 0..<rows {
                    let cy = ys[y]
                    let h0 = cy[0].0 * cols * 384, wy0 = cy[0].1
                    let h1 = cy[1].0 * cols * 384, wy1 = cy[1].1
                    let h2 = cy[2].0 * cols * 384, wy2 = cy[2].1
                    let h3 = cy[3].0 * cols * 384, wy3 = cy[3].1
                    for x in 0..<cols {
                        let xOff = x * 384
                        let outBase = (1 + y * cols + x) * 384
                        let p0 = h0 + xOff, p1 = h1 + xOff, p2 = h2 + xOff, p3 = h3 + xOff
                        for c in 0..<384 {
                            let val = hPtr[p0 + c] * wy0 +
                                hPtr[p1 + c] * wy1 +
                                hPtr[p2 + c] * wy2 +
                                hPtr[p3 + c] * wy3
                            values[outBase + c] = Float(val)
                        }
                    }
                }
            }
        }
        SharedPositionCache.shared.set(key, value: output)
        return output
    }
}
