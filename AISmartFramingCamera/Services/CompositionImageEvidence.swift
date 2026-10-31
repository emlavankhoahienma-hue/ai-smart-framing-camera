import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// Cancellation reaches the active Vision request as well as the bounded search.
final class CompositionAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeRequest: VNRequest?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let request = lock.withLock { () -> VNRequest? in
            cancelled = true
            return activeRequest
        }
        request?.cancel()
    }

    func perform(_ request: VNRequest, with handler: VNImageRequestHandler) throws {
        let shouldRun = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            activeRequest = request
            return true
        }
        guard shouldRun else { throw CancellationError() }
        defer { lock.withLock { activeRequest = nil } }
        try handler.perform([request])
        if isCancelled { throw CancellationError() }
    }
}

/// Used only by the serialized analysis worker. Outputs are immutable preview images.
final class CompositionImageRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func clearCaches() {
        context.clearCaches()
    }

    /// Apple's pretrained aesthetic assessment complements geometry on iOS 18+.
    /// A model failure or unsupported OS simply contributes no ranking evidence.
    func aestheticScore(image: CGImage, cancellation: CompositionAnalysisCancellation) -> Double? {
        guard !cancellation.isCancelled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return nil }
        if #available(iOS 18.0, macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            guard (try? cancellation.perform(request, with: handler)) != nil,
                  let result = request.results?.first, result.overallScore.isFinite else { return nil }
            // Utility classification is not a reason to reject a deliberate
            // product/food photograph. Only compare actual aesthetic scores.
            return min(1, max(-1, Double(result.overallScore)))
        }
        return nil
    }

    func raster(image: CIImage, saliency: CVPixelBuffer?, objectness: CVPixelBuffer? = nil,
                foregroundMask: CVPixelBuffer? = nil,
                measuredHorizon: (y: CGFloat, confidence: Double)? = nil,
                measuredVanishingPoint: (point: CGPoint, confidence: Double, rayAngles: [Double])? = nil) -> CompositionRaster? {
        let side = 64
        guard let small = render(image, size: CGSize(width: side, height: side)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let canvas = CGContext(data: storage.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.draw(small, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var luma = [Double](repeating: 0, count: side * side)
        for i in luma.indices {
            let red = Double(bytes[i * 4]) * 0.2126
            let green = Double(bytes[i * 4 + 1]) * 0.7152
            let blue = Double(bytes[i * 4 + 2]) * 0.0722
            luma[i] = (red + green + blue) / 255.0
        }
        var edges = [Double](repeating: 0, count: side * side)
        var edgeAngles = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let left = luma[y * side + max(0, x - 1)]
                let right = luma[y * side + min(side - 1, x + 1)]
                let top = luma[max(0, y - 1) * side + x]
                let bottom = luma[min(side - 1, y + 1) * side + x]
                let dx = right - left
                let dy = bottom - top
                edges[y * side + x] = min(1, hypot(dx, dy) * 2)
                edgeAngles[y * side + x] = atan2(dy, dx)
            }
        }
        let measured = saliency.flatMap { attentionMap($0, side: side) }
        let foreground = objectness.flatMap { attentionMap($0, side: side) }
        let segMask = foregroundMask.flatMap { maskMap($0, side: side) }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let attention = luma.enumerated().map { index, value in
            if let measured, let foreground { return measured[index] * 0.7 + foreground[index] * 0.3 }
            if let measured { return measured[index] }
            if let foreground { return foreground[index] }
            return min(1, 0.7 * edges[index] + 0.3 * abs(value - mean))
        }
        var fgDepth = [Double](repeating: 0.5, count: side * side)
        for y in 0..<side {
            let perspectiveGround = min(1.0, max(0.0, (Double(y) + 0.5) / Double(side)))
            for x in 0..<side {
                let i = y * side + x
                let maskVal = segMask?[i] ?? (foreground?[i] ?? attention[i])
                let localSharpness = edges[i]
                fgDepth[i] = min(1.0, max(0.0, 0.52 * maskVal + 0.28 * localSharpness + 0.20 * perspectiveGround))
            }
        }
        var resultRaster = CompositionRaster(side: side, luminance: luma, attention: attention,
                                             edges: edges, edgeAngles: edgeAngles,
                                             hasAttention: measured != nil || foreground != nil,
                                             foregroundDepth: fgDepth)
        resultRaster.measuredHorizon = measuredHorizon
        resultRaster.measuredVanishingPoint = measuredVanishingPoint
        return resultRaster
    }

    /// Trích xuất Điểm Tụ (Vanishing Point) bằng RANSAC giao điểm các đường dẫn cấu trúc từ VNDetectContoursRequest
    func extractRANSACVanishingPoint(from observation: VNContoursObservation,
                                     foregroundMask: CVPixelBuffer? = nil) -> (point: CGPoint, confidence: Double, rayAngles: [Double])? {
        let mask64 = foregroundMask.flatMap { maskMap($0, side: 64) }
        struct LineSeg {
            let a: Double
            let b: Double
            let c: Double
            let angle: Double
            let weight: Double
        }
        var segments: [LineSeg] = []
        let topContours = observation.topLevelContours
        for contour in topContours.prefix(48) {
            let pts = contour.normalizedPoints
            guard pts.count >= 4 else { continue }
            let step = max(1, pts.count / 6)
            var idx = 0
            while idx + step < pts.count {
                let p0 = pts[idx]
                let p1 = pts[idx + step]
                idx += step
                // Chuyển từ hệ tọa độ Vision (bottom-left) sang Upright (top-left)
                let x0 = Double(p0.x), y0 = 1.0 - Double(p0.y)
                let x1 = Double(p1.x), y1 = 1.0 - Double(p1.y)
                let dx = x1 - x0, dy = y1 - y0
                let len = hypot(dx, dy)
                guard len >= 0.065 else { continue }
                let mx = (x0 + x1) * 0.5, my = (y0 + y1) * 0.5
                if let mask64 {
                    let gx = min(63, max(0, Int(mx * 64)))
                    let gy = min(63, max(0, Int(my * 64)))
                    // Loại bỏ đường viền thuộc chủ thể tiền cảnh để chỉ giữ đường dẫn kiến trúc/con đường/cạnh bàn
                    if mask64[gy * 64 + gx] > 0.72 { continue }
                }
                let angle = atan2(dy, dx)
                // Bỏ qua các đường thẳng đứng hoàn toàn (gần 90 độ) khi tìm điểm tụ phối cảnh
                if abs( abs(angle) - (.pi / 2.0) ) < 0.14 { continue }
                let nx = -dy / len
                let ny = dx / len
                let c = -(nx * x0 + ny * y0)
                segments.append(LineSeg(a: nx, b: ny, c: c, angle: angle, weight: min(0.35, len)))
                if segments.count >= 64 { break }
            }
            if segments.count >= 64 { break }
        }
        guard segments.count >= 4 else { return nil }
        let totalWeight = segments.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0.15 else { return nil }

        var bestPoint = CGPoint(x: 0.5, y: 0.5)
        var bestSupport = 0.0
        let inlierThreshold = 0.042
        let n = segments.count
        for i in 0..<min(n, 28) {
            for j in (i + 1)..<min(n, 32) {
                let l1 = segments[i], l2 = segments[j]
                let det = l1.a * l2.b - l2.a * l1.b
                guard abs(det) > 0.12 else { continue }
                let vx = (l1.b * l2.c - l2.b * l1.c) / det
                let vy = (l2.a * l1.c - l1.a * l2.c) / det
                guard (0.04...0.96).contains(vx), (0.04...0.96).contains(vy) else { continue }
                var support = 0.0
                for seg in segments {
                    let dist = abs(seg.a * vx + seg.b * vy + seg.c)
                    if dist < inlierThreshold {
                        support += seg.weight * (1.0 - dist / inlierThreshold)
                    }
                }
                if support > bestSupport {
                    bestSupport = support
                    bestPoint = CGPoint(x: vx, y: vy)
                }
            }
        }
        let confidence = min(1.0, bestSupport / max(0.25, totalWeight * 0.55))
        guard confidence >= 0.26 else { return nil }
        let angles = segments.prefix(24).map(\.angle)
        return (point: bestPoint, confidence: confidence, rayAngles: angles)
    }

    func preview(image: CIImage, corners: [CGPoint], aspect: Double) -> CGImage? {
        guard corners.count == 4, aspect.isFinite, aspect > 0,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (-0.42...1.42).contains($0.x) && (-0.42...1.42).contains($0.y) }) else { return nil }
        // Tránh vệt sọc clamped/mirror padding đánh lừa mạng DINOv2 (Charm) & SAMP-Net khi xoay 3D ở 1.0x:
        // Dịch nhẹ cửa sổ lấy mẫu preview vào trong miền pixel thật [0, 1] để đánh giá chất lượng hình ảnh thực
        // Cắt khung phẳng thẳng đứng 0° (Axis-Aligned Crop) theo Mục 4.2 để chống biến dạng
        // hình thang (keystoning 10°-18°) giúp mạng SAMP và Charm chấm điểm trung thực tỉ lệ hình học:
        let minX = max(0.0, min(1.0, corners.map(\.x).min() ?? 0.0))
        let maxX = max(0.0, min(1.0, corners.map(\.x).max() ?? 1.0))
        let minY = max(0.0, min(1.0, corners.map(\.y).min() ?? 0.0))
        let maxY = max(0.0, min(1.0, corners.map(\.y).max() ?? 1.0))
        let spanW = max(0.01, maxX - minX)
        let spanH = max(0.01, maxY - minY)
        let safeCorners = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: minX + spanW, y: minY),
            CGPoint(x: minX + spanW, y: minY + spanH),
            CGPoint(x: minX, y: minY + spanH)
        ]
        let extent = image.extent
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + normalized.x * extent.width,
                    y: extent.maxY - normalized.y * extent.height)
        }
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = image
        correction.topLeft = point(safeCorners[0]); correction.topRight = point(safeCorners[1])
        correction.bottomRight = point(safeCorners[2]); correction.bottomLeft = point(safeCorners[3])
        guard let output = correction.outputImage else { return nil }
        let height = min(288.0, 448 / max(1, aspect))
        return render(output, size: CGSize(width: max(1, (height * aspect).rounded()), height: height))
    }

    private func render(_ image: CIImage, size: CGSize) -> CGImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              extent.width.isFinite, extent.height.isFinite else { return nil }
        let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: size.width / extent.width,
                                                                   y: size.height / extent.height))
        return context.createCGImage(scaled, from: CGRect(origin: .zero, size: size),
                                     format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func attentionMap(_ buffer: CVPixelBuffer, side: Int) -> [Double]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= width * MemoryLayout<Float>.stride,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            let row = base.advanced(by: min(height - 1, y * height / side) * stride)
                .assumingMemoryBound(to: Float.self)
            for x in 0..<side {
                let value = Double(row[min(width - 1, x * width / side)])
                values[y * side + x] = value.isFinite ? min(1, max(0, value)) : 0
            }
        }
        guard let high = values.max(), high > 0.01 else { return nil }
        return values.map { $0 / high }
    }

    func maskMap(_ buffer: CVPixelBuffer, side: Int) -> [Double]? {
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        if fmt == kCVPixelFormatType_OneComponent32Float {
            return attentionMap(buffer, side: side)
        }
        guard fmt == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= width,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            let row = base.advanced(by: min(height - 1, y * height / side) * stride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<side {
                values[y * side + x] = Double(row[min(width - 1, x * width / side)]) / 255.0
            }
        }
        return values
    }
}
