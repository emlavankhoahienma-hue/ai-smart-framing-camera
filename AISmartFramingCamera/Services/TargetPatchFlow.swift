import CoreGraphics
import CoreVideo
import Foundation

/// Sparse, brightness-normalized patch correspondence inside the selected ROI.
/// It estimates motion of the selected point independently of Vision's box size.
/// All mutable state is owned by VisionFramingEngine's serial queue.
final class TargetPatchFlow {
    struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(buffer: CVPixelBuffer) {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let inputWidth = CVPixelBufferGetWidth(buffer)
            let inputHeight = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard inputWidth > 0, inputHeight > 0 else { return nil }
            let factor = max(1.0, Double(inputWidth) / 320.0)
            let outputWidth = max(1, Int(Double(inputWidth) / factor))
            let outputHeight = max(1, Int(Double(inputHeight) / factor))
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var gray = [UInt8](repeating: 0, count: outputWidth * outputHeight)
            for y in 0..<outputHeight {
                let sourceY = min(inputHeight - 1, Int((Double(y) + 0.5) * Double(inputHeight) / Double(outputHeight)))
                for x in 0..<outputWidth {
                    let sourceX = min(inputWidth - 1, Int((Double(x) + 0.5) * Double(inputWidth) / Double(outputWidth)))
                    let offset = sourceY * rowBytes + sourceX * 4
                    gray[y * outputWidth + x] = UInt8((29 * Int(bytes[offset]) +
                        150 * Int(bytes[offset + 1]) + 77 * Int(bytes[offset + 2])) >> 8)
                }
            }
            width = outputWidth; height = outputHeight; pixels = gray
        }

        func value(_ x: Int, _ y: Int) -> Double { Double(pixels[y * width + x]) }

        func containsPatch(_ x: Int, _ y: Int) -> Bool {
            x >= 4 && y >= 4 && x < width - 4 && y < height - 4
        }

        func texturePoints(in box: CGRect) -> [CGPoint] {
            let left = max(4, Int(Double(box.minX + 0.12 * box.width) * Double(width)))
            let right = min(width - 5, Int(Double(box.maxX - 0.12 * box.width) * Double(width)))
            let top = max(4, Int(Double(1 - box.maxY + 0.12 * box.height) * Double(height)))
            let bottom = min(height - 5, Int(Double(1 - box.minY - 0.12 * box.height) * Double(height)))
            guard right > left + 8, bottom > top + 8 else { return [] }
            var points: [CGPoint] = []
            for gy in 0..<4 {
                for gx in 0..<4 {
                    let x0 = left + (right - left) * gx / 4
                    let x1 = left + (right - left) * (gx + 1) / 4
                    let y0 = top + (bottom - top) * gy / 4
                    let y1 = top + (bottom - top) * (gy + 1) / 4
                    var bestScore = 0.0
                    var bestPoint: CGPoint?
                    for y in stride(from: y0, to: y1, by: 2) {
                        for x in stride(from: x0, to: x1, by: 2) where containsPatch(x, y) {
                            var sxx = 0.0, syy = 0.0, sxy = 0.0
                            for v in -1...1 {
                                for u in -1...1 {
                                    let ix = 0.5 * (value(x + u + 1, y + v) - value(x + u - 1, y + v))
                                    let iy = 0.5 * (value(x + u, y + v + 1) - value(x + u, y + v - 1))
                                    sxx += ix * ix
                                    syy += iy * iy
                                    sxy += ix * iy
                                }
                            }
                            let trace = sxx + syy
                            let diff = sxx - syy
                            let disc = sqrt(max(0.0, diff * diff + 4.0 * sxy * sxy))
                            let minEigenvalue = 0.5 * (trace - disc)
                            if minEigenvalue > bestScore {
                                bestScore = minEigenvalue
                                bestPoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
                            }
                        }
                    }
                    if bestScore >= 16.0, let bestPoint { points.append(bestPoint) }
                }
            }
            return points
        }
    }

    struct Evaluation {
        let image: GrayImage
        let point: CGPoint
        let isReliable: Bool
        let inliers: Int
    }

    private var previous: GrayImage?
    private var points: [CGPoint] = []
    private var anchor: CGPoint?
    private var previousBox: CGRect?

    func reset() {
        previous = nil; points = []; anchor = nil; previousBox = nil
    }

    func seed(buffer: CVPixelBuffer, box: CGRect, point: CGPoint) {
        reset()
        guard let image = GrayImage(buffer: buffer) else { return }
        previous = image
        points = image.texturePoints(in: box)
        anchor = point
        previousBox = box
    }

    func evaluate(buffer: CVPixelBuffer, box: CGRect, fallback: CGPoint, gyroNormalizedShift: CGPoint = .zero) -> Evaluation? {
        guard let image = GrayImage(buffer: buffer) else { return nil }
        guard let previous, previous.width == image.width, previous.height == image.height,
              let anchor, let previousBox, points.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: 0)
        }
        let visionDx = Double(box.midX - previousBox.midX) * Double(image.width)
        let visionDy = Double(previousBox.midY - box.midY) * Double(image.height)
        let coarseX: Double
        let coarseY: Double
        if gyroNormalizedShift != .zero,
           gyroNormalizedShift.x.isFinite, gyroNormalizedShift.y.isFinite {
            let gyroDx = Double(gyroNormalizedShift.x) * Double(image.width)
            let gyroDy = Double(gyroNormalizedShift.y) * Double(image.height)
            if visionDx.isFinite, visionDy.isFinite {
                let diff = hypot(visionDx - gyroDx, visionDy - gyroDy)
                if diff <= 20.0 {
                    coarseX = visionDx
                    coarseY = visionDy
                } else {
                    coarseX = gyroDx
                    coarseY = gyroDy
                }
            } else {
                coarseX = gyroDx
                coarseY = gyroDy
            }
        } else if visionDx.isFinite, visionDy.isFinite {
            coarseX = visionDx
            coarseY = visionDy
        } else {
            coarseX = 0.0
            coarseY = 0.0
        }
        var pairs: [(old: CGPoint, new: CGPoint)] = []
        for old in points {
            let targetX = Double(old.x) + coarseX
            let targetY = Double(old.y) + coarseY
            guard targetX.isFinite, targetY.isFinite else { continue }
            // Clamp search center within image bounds so the +/-10 search window
            // never collapses at image margins or causes integer overflow/underflow.
            let clampedCenterX = max(4.0, min(Double(image.width - 5), targetX))
            let clampedCenterY = max(4.0, min(Double(image.height - 5), targetY))
            let center = CGPoint(x: clampedCenterX, y: clampedCenterY)
            guard let new = match(template: previous, at: old, in: image,
                                  around: center, radius: 10, requireUnique: true),
                  let reverse = match(template: image, at: new, in: previous,
                                      around: old, radius: 4, requireUnique: false),
                  hypot(reverse.x - old.x, reverse.y - old.y) <= 1.5 else { continue }
            pairs.append((old, new))
        }
        guard pairs.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: pairs.count)
        }
        let dx = median(pairs.map { Double($0.new.x - $0.old.x) })
        let dy = median(pairs.map { Double($0.new.y - $0.old.y) })
        let inliers = pairs.filter {
            hypot(Double($0.new.x - $0.old.x) - dx, Double($0.new.y - $0.old.y) - dy) <= 2.2
        }
        guard inliers.count >= 6 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }
        let oldX = inliers.reduce(0.0) { $0 + Double($1.old.x) } / Double(inliers.count)
        let oldY = inliers.reduce(0.0) { $0 + Double($1.old.y) } / Double(inliers.count)
        let newX = inliers.reduce(0.0) { $0 + Double($1.new.x) } / Double(inliers.count)
        let newY = inliers.reduce(0.0) { $0 + Double($1.new.y) } / Double(inliers.count)
        var denominator = 0.0, numeratorA = 0.0, numeratorB = 0.0
        for pair in inliers {
            let x = Double(pair.old.x) - oldX, y = Double(pair.old.y) - oldY
            let u = Double(pair.new.x) - newX, v = Double(pair.new.y) - newY
            denominator += x * x + y * y
            numeratorA += x * u + y * v
            numeratorB += x * v - y * u
        }
        let a = denominator > 1 ? numeratorA / denominator : 1
        let b = denominator > 1 ? numeratorB / denominator : 0
        let scale = hypot(a, b)
        guard (0.80...1.25).contains(scale) else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }
        let oldAnchorX = Double(anchor.x) * Double(image.width) - oldX
        let oldAnchorY = Double(anchor.y) * Double(image.height) - oldY
        let result = CGPoint(x: (newX + a * oldAnchorX - b * oldAnchorY) / Double(image.width),
                             y: (newY + b * oldAnchorX + a * oldAnchorY) / Double(image.height))
        let expanded = box.insetBy(dx: -0.03, dy: -0.03)
        let visionResult = CGPoint(x: result.x, y: 1 - result.y)
        guard result.x.isFinite, result.y.isFinite, expanded.contains(visionResult),
              (0...1).contains(result.x), (0...1).contains(result.y) else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: inliers.count)
        }
        return Evaluation(image: image, point: result, isReliable: true, inliers: inliers.count)
    }

    func accept(_ evaluation: Evaluation, box: CGRect, point: CGPoint) {
        previous = evaluation.image
        points = evaluation.image.texturePoints(in: box)
        anchor = point
        previousBox = box
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func match(template: GrayImage, at source: CGPoint, in target: GrayImage,
                       around center: CGPoint, radius: Int, requireUnique: Bool) -> CGPoint? {
        guard source.x.isFinite, source.y.isFinite, center.x.isFinite, center.y.isFinite else { return nil }
        let sx = Int(source.x.rounded()), sy = Int(source.y.rounded())
        guard template.containsPatch(sx, sy) else { return nil }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let minX = max(4, min(target.width - 5, cx - radius))
        let maxX = min(target.width - 5, max(4, cx + radius))
        let minY = max(4, min(target.height - 5, cy - radius))
        let maxY = min(target.height - 5, max(4, cy + radius))
        guard minX <= maxX, minY <= maxY else { return nil }
        var scores: [(Double, Int, Int)] = []
        for y in minY...maxY {
            for x in minX...maxX where target.containsPatch(x, y) {
                var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                for offsetY in -3...3 {
                    for offsetX in -3...3 {
                        let a = template.value(sx + offsetX, sy + offsetY)
                        let b = target.value(x + offsetX, y + offsetY)
                        sumA += a; sumB += b; sumAA += a * a; sumBB += b * b; sumAB += a * b
                    }
                }
                let numerator = 49 * sumAB - sumA * sumB
                let variance = (49 * sumAA - sumA * sumA) * (49 * sumBB - sumB * sumB)
                if variance > 100 { scores.append((numerator / sqrt(variance), x, y)) }
            }
        }
        guard let best = scores.max(by: { $0.0 < $1.0 }), best.0 >= 0.78 else { return nil }
        if requireUnique,
           let rival = scores.filter({ abs($0.1 - best.1) > 2 || abs($0.2 - best.2) > 2 })
                .max(by: { $0.0 < $1.0 }), best.0 - rival.0 < 0.035 { return nil }
        return CGPoint(x: CGFloat(best.1), y: CGFloat(best.2))
    }
}
