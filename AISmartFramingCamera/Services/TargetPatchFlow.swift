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
                            let ix = abs(value(x + 1, y) - value(x - 1, y))
                            let iy = abs(value(x, y + 1) - value(x, y - 1))
                            let score = min(ix, iy)
                            if score > bestScore {
                                bestScore = score
                                bestPoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
                            }
                        }
                    }
                    if bestScore >= 12, let bestPoint { points.append(bestPoint) }
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

    func evaluate(buffer: CVPixelBuffer, box: CGRect, fallback: CGPoint) -> Evaluation? {
        guard let image = GrayImage(buffer: buffer) else { return nil }
        guard let previous, previous.width == image.width, previous.height == image.height,
              let anchor, let previousBox, points.count >= 5 else {
            return Evaluation(image: image, point: fallback, isReliable: false, inliers: 0)
        }
        let coarse = CGPoint(x: Double(box.midX - previousBox.midX) * Double(image.width),
                             y: Double(previousBox.midY - box.midY) * Double(image.height))
        var pairs: [(old: CGPoint, new: CGPoint)] = []
        for old in points {
            let center = CGPoint(x: old.x + coarse.x, y: old.y + coarse.y)
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
            hypot(Double($0.new.x - $0.old.x) - dx, Double($0.new.y - $0.old.y) - dy) <= 2.5
        }
        guard inliers.count >= 5 else {
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
        let sx = Int(source.x.rounded()), sy = Int(source.y.rounded())
        guard template.containsPatch(sx, sy) else { return nil }
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        var scores: [(Double, Int, Int)] = []
        for y in (cy - radius)...(cy + radius) {
            for x in (cx - radius)...(cx + radius) where target.containsPatch(x, y) {
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
