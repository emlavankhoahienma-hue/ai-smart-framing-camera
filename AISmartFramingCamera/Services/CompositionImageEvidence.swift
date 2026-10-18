import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision
import Darwin
import os
#if canImport(UIKit)
import UIKit
#endif

enum CompositionInferenceResources {
    enum Failure: Error, CustomStringConvertible {
        case memoryPressure(UInt64)
        var description: String {
            switch self { case .memoryPressure(let bytes): return "Insufficient inference headroom: \(bytes) bytes" }
        }
    }

    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func requireHeadroom(_ bytes: UInt64 = 160 * 1024 * 1024) throws {
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        guard available >= bytes else { throw Failure.memoryPressure(available) }
        #endif
    }

    static func report(_ stage: String, error: Error? = nil) {
        let message = "\(stage); footprint=\(footprint); error=\(error.map { String(describing: $0) } ?? "none")"
        Logger(subsystem: "com.aismartframing.camera", category: "Inference").notice("\(message, privacy: .public)")
        // Synchronous, small checkpoint survives a jetsam kill, which cannot be
        // intercepted by an exception/signal handler. Never records image pixels.
        #if os(iOS)
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            try Data((ISO8601DateFormatter().string(from: Date()) + " " + message).utf8)
                .write(to: directory.appendingPathComponent("last_ai_stage.txt"), options: .atomic)
        } catch {
            Logger(subsystem: "com.aismartframing.camera", category: "Inference").error("Checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}

/// Cancellation reaches the active Vision request as well as the bounded search.
final class CompositionAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeRequest: VNRequest?
    private var warningObserver: NSObjectProtocol?
    private var reason: String?

    init() {
        #if canImport(UIKit)
        warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.cancel(reason: "Bộ nhớ đang thấp. Hãy đóng ứng dụng khác rồi bấm AI lại.")
                CompositionInferenceResources.report("Analysis cancelled by memory warning")
            }
        #endif
    }

    deinit { if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) } }

    var isCancelled: Bool { lock.withLock { cancelled } }
    var failureReason: String? { lock.withLock { reason } }

    func cancel(reason: String? = nil) {
        let request = lock.withLock { () -> VNRequest? in
            cancelled = true
            if let reason { self.reason = reason }
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

/// Apple Vision's learned image-aesthetics model introduced at WWDC 2024.
/// It assesses observed pixels; it does not invent unseen camera margins.
enum SystemPhotographicAssessment {
    struct Score: Sendable {
        let overall: Double
        let isUtility: Bool
    }

    static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true }
        return false
    }

    static func assess(_ image: CGImage, cancellation: CompositionAnalysisCancellation) throws -> Score? {
        guard isSupported, !cancellation.isCancelled else { return nil }
        if #available(iOS 18, macOS 15, *) {
            return try autoreleasepool {
                try CompositionInferenceResources.requireHeadroom()
                let request = VNCalculateImageAestheticsScoresRequest()
                try cancellation.perform(request, with: VNImageRequestHandler(cgImage: image, orientation: .up))
                guard let observation = request.results?.first,
                      observation.overallScore.isFinite,
                      (-1...1).contains(observation.overallScore) else { throw CocoaError(.coderInvalidValue) }
                return Score(overall: Double(observation.overallScore), isUtility: observation.isUtility)
            }
        }
        return nil
    }

    static func preservesQuality(candidate: Score, original: Score, zoomRatio: Double) -> Bool {
        guard [candidate.overall, original.overall, zoomRatio].allSatisfy(\.isFinite), zoomRatio > 0 else { return false }
        // A utility label alone is not bad quality. Compare scores of the same
        // scene and only veto a substantial, fully observed magnifying crop.
        return zoomRatio <= 1.12 || original.overall - candidate.overall < 0.20
    }
}

/// Used only by the serialized analysis worker. Outputs are immutable preview images.
final class CompositionImageRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func raster(image: CIImage, saliency: CVPixelBuffer?, objectness: CVPixelBuffer? = nil) -> CompositionRaster? {
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
        let foreground = objectness.flatMap { attentionMap($0, side: side) }
        let mean = luma.reduce(0, +) / Double(luma.count)
        let attention = luma.enumerated().map { index, value in
            if let measured, let foreground { return measured[index] * 0.7 + foreground[index] * 0.3 }
            if let measured { return measured[index] }
            if let foreground { return foreground[index] }
            return min(1, 0.7 * edges[index] + 0.3 * abs(value - mean))
        }
        return CompositionRaster(side: side, luminance: luma, attention: attention,
                                 edges: edges, hasAttention: measured != nil || foreground != nil)
    }

    func projectedFrame(image: CIImage, corners: [CGPoint], size: CGSize) -> CGImage? {
        guard corners.count == 4, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, max(size.width, size.height) <= 4096,
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
        return render(output, size: size)
    }

    func preview(image: CIImage, corners: [CGPoint], aspect: Double) -> CGImage? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        let height = min(288.0, 448 / max(1, aspect))
        return projectedFrame(image: image, corners: corners,
            size: CGSize(width: max(1, (height * aspect).rounded()), height: height))
    }

    func referenceImage(_ image: CIImage) -> CGImage? {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        guard extent.width * extent.height <= 20_000_000,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    func observedPreview(image: CIImage, corners: [CGPoint], aspect: Double) -> CGImage? {
        // A very thin outside triangle can have near-unit area support while
        // still crossing the source boundary. Test vertices before full rendering.
        if CompositionViewSupport.containsEntireView(corners) { return preview(image: image, corners: corners, aspect: aspect) }
        guard let region = CompositionViewSupport.region(corners) else { return nil }
        let observedCorners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                               CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
        return preview(image: image, corners: observedCorners, aspect: aspect * Double(region.width / region.height))
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
