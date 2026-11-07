import Foundation
import CoreML
import Vision
import CoreVideo
import CoreGraphics
import QuartzCore

/// Optional CNN verifier. Requires the CoreML export with preprocessing embedded
/// in its graph. Raw .bin MLP weights and random weights are never accepted.
public final class NeuralTargetTracker: @unchecked Sendable {
    public static let shared = NeuralTargetTracker()
    private let lock = NSRecursiveLock()
    private var model: VNCoreMLModel?
    private var anchor: [Double]?
    private var adaptive: [Double]?
    private var lastAdaptiveUpdateTime: TimeInterval = -Double.infinity

    public var hasActiveTrainedModel: Bool { lock.withLock { model != nil } }
    public init() { loadModelWeights() }

    public func loadModelWeights() {
        lock.withLock {
            model = nil; anchor = nil; adaptive = nil
            lastAdaptiveUpdateTime = -Double.infinity
            guard let url = Bundle.main.url(forResource: "RobustTargetEmbedder", withExtension: "mlmodelc"),
                  let core = try? MLModel(contentsOf: url),
                  let metadata = core.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
                  metadata["tracking_schema"] == "rgb128_imagenet_in_graph_l2_128_v1",
                  let input = core.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
                  input.pixelsWide == 128, input.pixelsHigh == 128 else { return }
            model = try? VNCoreMLModel(for: core)
        }
    }

    public func setAnchorTemplate(from pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) {
        lock.withLock {
            let vec = embedding(pixelBuffer, at: targetPoint)
            anchor = vec
            adaptive = vec
            lastAdaptiveUpdateTime = CACurrentMediaTime()
        }
    }

    public func clearAnchor() {
        lock.withLock {
            anchor = nil
            adaptive = nil
            lastAdaptiveUpdateTime = -Double.infinity
        }
    }

    public func updateAdaptiveTemplate(from pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint, alpha: Double = 0.15) {
        lock.withLock {
            let now = CACurrentMediaTime()
            guard now - lastAdaptiveUpdateTime >= 0.40 else { return }
            guard let anchor, let current = embedding(pixelBuffer, at: targetPoint) else { return }
            lastAdaptiveUpdateTime = now
            let anchorSimilarity = zip(anchor, current).reduce(0.0) { $0 + $1.0 * $1.1 }
            // Anti-drift check: observation must remain sufficiently similar to original anchor T0
            guard anchorSimilarity >= 0.60 else { return }
            if let prevAdaptive = adaptive {
                var updated = [Double](repeating: 0, count: 128)
                for i in 0..<128 {
                    updated[i] = (1.0 - alpha) * prevAdaptive[i] + alpha * current[i]
                }
                let norm = sqrt(updated.reduce(0.0) { $0 + $1 * $1 })
                adaptive = norm > 1e-9 ? updated.map { $0 / norm } : current
            } else {
                adaptive = current
            }
        }
    }

    public func verifyTarget(in pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) -> Double {
        lock.withLock {
            guard let anchor, let vector = embedding(pixelBuffer, at: targetPoint) else { return 0 }
            let score0 = zip(anchor, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
            guard score0 >= 0.40 else { return min(1, max(-1, score0)) }
            if let adaptive {
                let scoreAdaptive = zip(adaptive, vector).reduce(0.0) { $0 + $1.0 * $1.1 }
                return min(1, max(-1, max(score0, scoreAdaptive)))
            }
            return min(1, max(-1, score0))
        }
    }

    public func findBestMatchingPoint(in pixelBuffer: CVPixelBuffer, around centerPoint: CGPoint,
                                     searchRadius: CGFloat = 0.04) -> (CGPoint, Double) {
        lock.withLock {
            guard model != nil, anchor != nil else { return (centerPoint, 0) }
            var result = (centerPoint, verifyTarget(in: pixelBuffer, at: centerPoint))
            for y in [-searchRadius, 0, searchRadius] {
                for x in [-searchRadius, 0, searchRadius] where x != 0 || y != 0 {
                    let point = CGPoint(x: centerPoint.x + x, y: centerPoint.y + y)
                    let score = verifyTarget(in: pixelBuffer, at: point)
                    if score > result.1 { result = (point, score) }
                }
            }
            return result
        }
    }

    private func embedding(_ buffer: CVPixelBuffer, at point: CGPoint) -> [Double]? {
        guard let model, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let clampedX = min(0.92, max(0.08, point.x))
        let clampedY = min(0.92, max(0.08, point.y))
        let roi = CGRect(x: clampedX - 0.08, y: 1 - clampedY - 0.08, width: 0.16, height: 0.16)
        guard roi.minX >= 0, roi.minY >= 0, roi.maxX <= 1, roi.maxY <= 1 else { return nil }
        let req = VNCoreMLRequest(model: model)
        req.regionOfInterest = roi
        req.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([req])) != nil,
              let values = (req.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              values.count == 128 else { return nil }
        let vector = (0..<128).map { values[$0].doubleValue }
        guard vector.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-9 else { return nil }
        return vector.map { $0 / norm }
    }
}
