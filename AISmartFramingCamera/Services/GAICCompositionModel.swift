import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import CoreML
#if canImport(UIKit)
import UIKit
#endif

/// Learned GAIC (Grid-Anchoring Image Cropping) CoreML scorer: evaluates up to 256
/// upright normalized crop windows per pass from a single shared 256x256 backbone forward.
final class GAICCompositionModel {
    static let maxBoxes = 256
    static let imageSide = 256
    static let bundleModelName = "GAICCompositionScorer"

    private final class ModelCache: @unchecked Sendable {
        static let shared = ModelCache()
        private let lock = NSLock()
        private var cachedURL: URL?
        private var cachedInstance: GAICCompositionModel?

        private init() {
            CompositionMemoryBudget.registerCacheEvictor(id: "GAIC", priority: 50) { [weak self] in
                self?.clear() ?? false
            }
            #if canImport(UIKit)
            _ = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                _ = self?.clear()
            }
            #endif
        }

        @discardableResult
        func clear() -> Bool {
            let evicted = lock.withLock { () -> Bool in
                let had = (cachedInstance != nil)
                cachedURL = nil
                cachedInstance = nil
                return had
            }
            CompositionImageRenderer.clearSharedCaches()
            if evicted {
                CompositionMemoryBudget.emitLifecycle("MODEL_UNLOAD", "GAICCompositionScorer")
            }
            return evicted
        }

        func getOrLoad(url: URL) -> GAICCompositionModel? {
            if let existing = lock.withLock({ cachedURL == url ? cachedInstance : nil }) {
                return existing
            }
            guard CompositionMemoryBudget.ensureHeadroom(
                minimumBytes: CompositionMemoryBudget.gaicLoadHeadroomBytes,
                excluding: "GAIC"
            ) else {
                CompositionMemoryBudget.emitTrace("GAIC.SKIP_LOW_RAM", "avail=\(CompositionMemoryBudget.availableMB())MB")
                return nil
            }
            CompositionMemoryBudget.emitTrace("GAIC.LOAD_BEGIN", url.lastPathComponent)
            let loaded: GAICCompositionModel
            do {
                loaded = try GAICCompositionModel(url: url)
            } catch {
                CompositionMemoryBudget.emitTrace("GAIC.LOAD_FAIL", "\(error)")
                return nil
            }
            CompositionMemoryBudget.emitLifecycle("MODEL_LOAD", "GAICCompositionScorer (FP16 ANE)")
            if CompositionMemoryBudget.shouldRetainModelCache(
                minimumAvailableBytes: CompositionMemoryBudget.gaicRetainThresholdBytes
            ) {
                lock.withLock {
                    cachedURL = url
                    cachedInstance = loaded
                }
            }
            return loaded
        }
    }

    static func cachedOrLoad(url: URL) -> GAICCompositionModel? {
        ModelCache.shared.getOrLoad(url: url)
    }

    static func clearCache() {
        ModelCache.shared.clear()
    }

    private let model: MLModel
    private var reusableBoxes: MLMultiArray?

    init(url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)

        guard model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint != nil,
              let boxDesc = model.modelDescription.inputDescriptionsByName["boxes"]?.multiArrayConstraint,
              boxDesc.shape.count == 3,
              boxDesc.shape[1].intValue == Self.maxBoxes,
              boxDesc.shape[2].intValue == 4,
              model.modelDescription.outputDescriptionsByName["scores"] != nil else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    static func defaultModelURL(near modelURL: URL? = nil) -> URL? {
        if let sibling = modelURL?.deletingLastPathComponent()
            .appendingPathComponent(bundleModelName)
            .appendingPathExtension("mlmodelc"),
           FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return CompositionResourceLocator.url(forResource: bundleModelName, withExtension: "mlmodelc")
    }

    /// Converts 4 upright normalized source corners into an axis-aligned [0, 1] box.
    static func normalizedBox(from corners: [CGPoint]) -> CGRect {
        guard !corners.isEmpty,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let minX = min(0.99, max(0.0, Double(corners.map(\.x).min() ?? 0.0)))
        let minY = min(0.99, max(0.0, Double(corners.map(\.y).min() ?? 0.0)))
        let maxX = min(1.0, max(minX + 0.01, Double(corners.map(\.x).max() ?? 1.0)))
        let maxY = min(1.0, max(minY + 0.01, Double(corners.map(\.y).max() ?? 1.0)))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Evaluates proposals against an upright full-frame CIImage and returns normalized [0, 1] GAIC scores.
    func evaluate(image: CIImage, proposals: [CompositionProposal],
                  cancellation: CompositionAnalysisCancellation) -> [Double]? {
        guard !proposals.isEmpty else { return [] }
        let boxes = proposals.map { Self.normalizedBox(from: $0.sourceCorners) }
        guard let mosScores = assessMOS(image: image, boxes: boxes, cancellation: cancellation),
              mosScores.count == proposals.count else { return nil }
        return mosScores.map { min(1.0, max(0.0, ($0 - 1.0) / 4.0)) }
    }

    /// Returns raw MOS predictions in [1.0, 5.0] for each upright normalized CGRect in [0, 1].
    func assessMOS(image: CIImage, boxes: [CGRect],
                   cancellation: CompositionAnalysisCancellation) -> [Double]? {
        guard !boxes.isEmpty,
              !cancellation.isCancelled,
              ProcessInfo.processInfo.thermalState != .critical else { return nil }
        guard let pixelBuffer = renderPixelBuffer(from: image) else { return nil }

        var outputScores: [Double] = []
        outputScores.reserveCapacity(boxes.count)
        let imageFeature = MLFeatureValue(pixelBuffer: pixelBuffer)

        var start = 0
        while start < boxes.count {
            if cancellation.isCancelled { return nil }
            let end = min(boxes.count, start + Self.maxBoxes)
            let chunk = Array(boxes[start..<end])
            let chunkScores: [Double]? = autoreleasepool {
                CompositionMemoryBudget.emitTrace("GAIC.PREDICT_BEGIN", "chunk=\(start)..<\(end)/\(boxes.count)")
                guard let boxArray = fillBoxArray(chunk),
                      let provider = try? MLDictionaryFeatureProvider(dictionary: [
                          "image": imageFeature,
                          "boxes": MLFeatureValue(multiArray: boxArray)
                      ]),
                      !cancellation.isCancelled else { return nil }
                let result: MLFeatureProvider
                do {
                    result = try model.prediction(from: provider)
                } catch {
                    CompositionMemoryBudget.emitTrace("GAIC.PREDICT_FAIL", "\(error)")
                    return nil
                }
                CompositionMemoryBudget.emitTrace("GAIC.PREDICT_END", "chunk=\(chunk.count)")
                guard !cancellation.isCancelled,
                      let scoreArray = result.featureValue(for: "scores")?.multiArrayValue,
                      scoreArray.count >= Self.maxBoxes else { return nil }

                var batch = [Double]()
                batch.reserveCapacity(chunk.count)
                for idx in 0..<chunk.count {
                    let v = Double(truncating: scoreArray[idx])
                    guard v.isFinite else { return nil }
                    batch.append(min(5.0, max(1.0, v)))
                }
                return batch
            }
            guard let chunkScores, chunkScores.count == chunk.count else { return nil }
            outputScores.append(contentsOf: chunkScores)
            start = end
        }
        return outputScores
    }

    private func renderPixelBuffer(from image: CIImage) -> CVPixelBuffer? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else { return nil }

        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.imageSide,
            Self.imageSide,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pb
        ) == kCVReturnSuccess, let buffer = pb else { return nil }

        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(
            scaleX: CGFloat(Self.imageSide) / extent.width,
            y: CGFloat(Self.imageSide) / extent.height
        ))
        CompositionImageRenderer.renderShared(
            scaled,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: Self.imageSide, height: Self.imageSide),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return buffer
    }

    private func fillBoxArray(_ boxes: [CGRect]) -> MLMultiArray? {
        if reusableBoxes == nil {
            reusableBoxes = try? MLMultiArray(
                shape: [1, NSNumber(value: Self.maxBoxes), 4],
                dataType: .float32
            )
        }
        guard let array = reusableBoxes, array.count >= Self.maxBoxes * 4 else { return nil }

        let boxStride = array.strides.count >= 2 ? array.strides[array.strides.count - 2].intValue : 4
        let coordStride = array.strides.count >= 1 ? array.strides[array.strides.count - 1].intValue : 1

        if array.dataType == .float32 {
            let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<Self.maxBoxes {
                let coords = clampedBoxCoords(i < boxes.count ? boxes[i] : nil)
                let base = i * boxStride
                ptr[base] = coords.0
                ptr[base + coordStride] = coords.1
                ptr[base + 2 * coordStride] = coords.2
                ptr[base + 3 * coordStride] = coords.3
            }
        } else {
            for i in 0..<Self.maxBoxes {
                let coords = clampedBoxCoords(i < boxes.count ? boxes[i] : nil)
                let iNum = NSNumber(value: i)
                array[[0, iNum, 0]] = NSNumber(value: coords.0)
                array[[0, iNum, 1]] = NSNumber(value: coords.1)
                array[[0, iNum, 2]] = NSNumber(value: coords.2)
                array[[0, iNum, 3]] = NSNumber(value: coords.3)
            }
        }
        return array
    }

    private func clampedBoxCoords(_ rect: CGRect?) -> (Float, Float, Float, Float) {
        guard let rect,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return (0, 0, 1, 1)
        }
        let x1 = min(0.99, max(0.0, Double(rect.minX)))
        let y1 = min(0.99, max(0.0, Double(rect.minY)))
        let x2 = min(1.0, max(x1 + 0.01, Double(rect.maxX)))
        let y2 = min(1.0, max(y1 + 0.01, Double(rect.maxY)))
        return (Float(x1), Float(y1), Float(x2), Float(y2))
    }
}
