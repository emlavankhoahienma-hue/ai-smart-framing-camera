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

    func raster(image: CIImage, saliency: CVPixelBuffer?) -> CompositionRaster? {
        let side = 32
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
        for y in 0..<side {
            for x in 0..<side {
                let left = luma[y * side + max(0, x - 1)]
                let right = luma[y * side + min(side - 1, x + 1)]
                let top = luma[max(0, y - 1) * side + x]
                let bottom = luma[min(side - 1, y + 1) * side + x]
                edges[y * side + x] = min(1, hypot(right - left, bottom - top) * 2)
            }
        }
        let measured = saliency.flatMap { attentionMap($0, side: side) }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let attention = measured ?? luma.enumerated().map { index, value in
            min(1, 0.7 * edges[index] + 0.3 * abs(value - mean))
        }
        return CompositionRaster(side: side, luminance: luma, attention: attention,
                                 edges: edges, hasAttention: measured != nil)
    }

    func preview(image: CIImage, corners: [CGPoint], aspect: Double) -> CGImage? {
        guard corners.count == 4, aspect.isFinite, aspect > 0,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (-0.0001...1.0001).contains($0.x) && (-0.0001...1.0001).contains($0.y) }) else { return nil }
        let extent = image.extent
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + normalized.x * extent.width,
                    y: extent.maxY - normalized.y * extent.height)
        }
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = image
        correction.topLeft = point(corners[0]); correction.topRight = point(corners[1])
        correction.bottomRight = point(corners[2]); correction.bottomLeft = point(corners[3])
        guard let output = correction.outputImage else { return nil }
        let height = 288.0
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
}
