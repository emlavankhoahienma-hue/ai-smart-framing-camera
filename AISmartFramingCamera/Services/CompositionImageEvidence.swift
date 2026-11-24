import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreML
import Vision
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import os
#endif

/// Real-time advisory iOS Jetsam headroom query and priority-ordered cache eviction manager.
/// Keeps compiled Core ML / MPSGraph singletons warm across repeated AI Compose taps when
/// `os_proc_available_memory()` is healthy (eliminating Apple CoreML/MPSGraph reload leaks
/// and stalls on Run #2/#3), while deterministically evicting heaviest models first under real pressure.
enum CompositionMemoryBudget {
    static let postRunPhotoCaptureReserveBytes = 360_000_000
    static let siglipRetainThresholdBytes = 460_000_000
    static let openWorldRetainThresholdBytes = 340_000_000
    static let depthRetainThresholdBytes = 280_000_000
    static let sampRetainThresholdBytes = 260_000_000
    static let gaicRetainThresholdBytes = 220_000_000
    static let charmRetainThresholdBytes = 200_000_000

    static let siglipLoadHeadroomBytes = 220_000_000
    static let openWorldLoadHeadroomBytes = 180_000_000
    static let foregroundMaskLoadHeadroomBytes = 150_000_000
    static let depthLoadHeadroomBytes = 160_000_000
    static let gaicLoadHeadroomBytes = 130_000_000
    static let sampLoadHeadroomBytes = 160_000_000
    static let charmLoadHeadroomBytes = 200_000_000

    private struct CacheEvictor: Sendable {
        let id: String
        let priority: Int // Lower value = evicted first; Charm MPSGraph uses 90 (evicted last)
        let evict: @Sendable () -> Bool
    }

    private final class EvictorRegistry: @unchecked Sendable {
        static let shared = EvictorRegistry()
        private let lock = NSLock()
        private var entries: [String: CacheEvictor] = [:]

        func register(id: String, priority: Int, evict: @escaping @Sendable () -> Bool) {
            lock.withLock {
                entries[id] = CacheEvictor(id: id, priority: priority, evict: evict)
            }
        }

        func sortedEvictors(excluding excludedID: String?) -> [CacheEvictor] {
            lock.withLock {
                entries.values
                    .filter { $0.id != excludedID }
                    .sorted { $0.priority < $1.priority }
            }
        }
    }

    static func registerCacheEvictor(id: String, priority: Int, evict: @escaping @Sendable () -> Bool) {
        EvictorRegistry.shared.register(id: id, priority: priority, evict: evict)
    }

    static func availableBytes() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return 0
        #endif
    }

    static func availableMB() -> Int {
        let bytes = availableBytes()
        return bytes > 0 ? bytes / (1024 * 1024) : -1
    }

    /// Returns true unless iOS explicitly reports Jetsam headroom below `minimumBytes`.
    static func hasHeadroom(minimumBytes: Int) -> Bool {
        let bytes = availableBytes()
        return bytes == 0 || bytes >= minimumBytes
    }

    /// Returns true when the current device can safely keep a compiled singleton model cached
    /// without approaching iOS Jetsam limits.
    static func shouldRetainModelCache(minimumAvailableBytes: Int) -> Bool {
        guard ProcessInfo.processInfo.thermalState != .critical else { return false }
        let bytes = availableBytes()
        if bytes == 0 {
            return ProcessInfo.processInfo.physicalMemory >= 8_000_000_000
        }
        return bytes >= minimumAvailableBytes
    }

    /// Ensures at least `minimumBytes` of iOS Jetsam headroom before loading a non-cached model.
    /// Evicts only the minimum number of other cached models in priority order (never thrashing
    /// unrelated warm singletons when headroom is already healthy).
    @discardableResult
    static func ensureHeadroom(minimumBytes: Int, excluding activeID: String? = nil) -> Bool {
        if hasHeadroom(minimumBytes: minimumBytes) { return true }
        CompositionImageRenderer.clearSharedCaches()
        if hasHeadroom(minimumBytes: minimumBytes) { return true }
        let candidates = EvictorRegistry.shared.sortedEvictors(excluding: activeID)
        for entry in candidates {
            _ = autoreleasepool { entry.evict() }
            if hasHeadroom(minimumBytes: minimumBytes) { return true }
        }
        return hasHeadroom(minimumBytes: minimumBytes)
    }

    /// Trims cached models in priority order ONLY when real-time Jetsam headroom falls below
    /// `minimumBytes` (leaving ample free memory for post-AI 12MP/48MP photo capture).
    @discardableResult
    static func trimForReserve(minimumBytes: Int = postRunPhotoCaptureReserveBytes) -> [String] {
        guard !hasHeadroom(minimumBytes: minimumBytes) else { return [] }
        CompositionImageRenderer.clearSharedCaches()
        guard !hasHeadroom(minimumBytes: minimumBytes) else { return [] }
        var evictedIDs: [String] = []
        let candidates = EvictorRegistry.shared.sortedEvictors(excluding: nil)
        for entry in candidates {
            // Preserve Charm MPSGraph unless headroom is critically low (< 200 MB) to avoid
            // repeated Metal MPSGraph recompilations across taps.
            if entry.id == "Charm" && hasHeadroom(minimumBytes: charmRetainThresholdBytes) {
                continue
            }
            let didEvict = autoreleasepool { entry.evict() }
            if didEvict { evictedIDs.append(entry.id) }
            if hasHeadroom(minimumBytes: minimumBytes) { break }
        }
        return evictedIDs
    }
}

/// Cancellation reaches every active Vision request as well as the bounded search.
/// Also supports an optional monotonic `softDeadline` so stages yield gracefully
/// instead of stalling into a hard user-facing timeout on cold ANE compilation.
final class CompositionAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var activeRequests: [ObjectIdentifier: VNRequest] = [:]
    private let softDeadlineUptime: TimeInterval?

    init(softTimeoutSeconds: TimeInterval? = nil) {
        if let timeout = softTimeoutSeconds, timeout.isFinite, timeout > 0 {
            self.softDeadlineUptime = ProcessInfo.processInfo.systemUptime + timeout
        } else {
            self.softDeadlineUptime = nil
        }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    var isSoftDeadlineReached: Bool {
        guard let deadline = softDeadlineUptime else { return false }
        return ProcessInfo.processInfo.systemUptime >= deadline
    }

    var remainingSoftBudget: TimeInterval {
        guard let deadline = softDeadlineUptime else { return .infinity }
        return max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    func cancel() {
        let requests = lock.withLock { () -> [VNRequest] in
            cancelled = true
            let current = Array(activeRequests.values)
            activeRequests.removeAll()
            return current
        }
        for request in requests {
            request.cancel()
        }
    }

    func perform(_ request: VNRequest, with handler: VNImageRequestHandler) throws {
        let key = ObjectIdentifier(request)
        let shouldRun = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            activeRequests[key] = request
            return true
        }
        guard shouldRun else { throw CancellationError() }
        defer { lock.withLock { _ = activeRequests.removeValue(forKey: key) } }
        try handler.perform([request])
        if isCancelled { throw CancellationError() }
    }
}

/// Used only by the serialized analysis worker. Outputs are immutable preview images.
final class CompositionImageRenderer: @unchecked Sendable {
    /// Single shared low-priority, non-caching CIContext for ALL Local AI preprocessing
    /// (DepthAnythingV2, OpenWorldYOLOE, GAIC, preview crops). Sharing one locked context avoids
    /// creating/leaking per-model Metal CIContexts (~30-60MB each) and keeps GPU priority below
    /// the 60fps MTKView live camera preview.
    private static let sharedRenderLock = NSLock()
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    static func renderShared(
        _ image: CIImage,
        to pixelBuffer: CVPixelBuffer,
        bounds: CGRect,
        colorSpace: CGColorSpace
    ) {
        sharedRenderLock.withLock {
            context.render(image, to: pixelBuffer, bounds: bounds, colorSpace: colorSpace)
        }
    }

    static func createSharedCGImage(
        _ image: CIImage,
        from rect: CGRect,
        format: CIFormat = .RGBA8,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        sharedRenderLock.withLock {
            context.createCGImage(image, from: rect, format: format, colorSpace: colorSpace)
        }
    }

    static func clearSharedCaches() {
        sharedRenderLock.withLock {
            context.clearCaches()
        }
    }

    private let depthModelLock = NSLock()
    private var cachedDepthModel: MLModel?

    init() {
        CompositionMemoryBudget.registerCacheEvictor(id: "DepthAnythingV2", priority: 30) { [weak self] in
            self?.releaseDepthModel() ?? false
        }
        #if canImport(UIKit)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            _ = self?.releaseDepthModel()
            Self.clearSharedCaches()
        }
        #endif
    }

    @discardableResult
    func releaseDepthModel() -> Bool {
        depthModelLock.withLock {
            let hadModel = (cachedDepthModel != nil)
            cachedDepthModel = nil
            return hadModel
        }
    }

    func clearCaches() {
        Self.clearSharedCaches()
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

    /// Sequential memory-safe DepthAnythingV2 CoreML loader & inference inside autoreleasepool.
    /// Gracefully returns nil when DepthAnythingV2*.mlmodelc is not bundled so multi-cue monocular depth runs instead.
    func estimateMonocularDepth(image: CIImage, side: Int = 64,
                                cancellation: CompositionAnalysisCancellation) -> [Double]? {
        guard !cancellation.isCancelled,
              side > 4, side <= 128,
              ProcessInfo.processInfo.physicalMemory >= 3_500_000_000,
              ProcessInfo.processInfo.thermalState != .critical,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return nil }
        let candidateNames = [
            "DepthAnythingV2SmallF16INT8",
            "DepthAnythingV2SmallF16",
            "DepthAnythingV2Small",
            "DepthAnythingV2",
            "DepthAnything",
        ]
        guard let url = candidateNames.compactMap({ Bundle.main.url(forResource: $0, withExtension: "mlmodelc") }).first else {
            return nil
        }
        return autoreleasepool {
            guard !cancellation.isCancelled else { return nil }
            let model: MLModel? = {
                if let cached = depthModelLock.withLock({ cachedDepthModel }) {
                    return cached
                }
                guard CompositionMemoryBudget.ensureHeadroom(
                    minimumBytes: CompositionMemoryBudget.depthLoadHeadroomBytes,
                    excluding: "DepthAnythingV2"
                ) else {
                    return nil
                }
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                guard let loaded = try? MLModel(contentsOf: url, configuration: config) else { return nil }
                if CompositionMemoryBudget.shouldRetainModelCache(
                    minimumAvailableBytes: CompositionMemoryBudget.depthRetainThresholdBytes
                ) {
                    depthModelLock.withLock { cachedDepthModel = loaded }
                }
                return loaded
            }()
            guard let model else { return nil }

            let inputEntries = model.modelDescription.inputDescriptionsByName
            guard let (inputName, inputDesc) = inputEntries.first else { return nil }
            let inputFeature: MLFeatureValue
            if let imageConstraint = inputDesc.imageConstraint,
               imageConstraint.pixelsWide > 0, imageConstraint.pixelsHigh > 0 {
                let w = imageConstraint.pixelsWide
                let h = imageConstraint.pixelsHigh
                var pb: CVPixelBuffer?
                let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
                      let buffer = pb else { return nil }
                let extent = image.extent
                guard !extent.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
                let translated = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
                Self.renderShared(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                  colorSpace: CGColorSpaceCreateDeviceRGB())
                inputFeature = MLFeatureValue(pixelBuffer: buffer)
            } else if let arrayConstraint = inputDesc.multiArrayConstraint,
                      arrayConstraint.shape.count == 4 {
                let h = arrayConstraint.shape[2].intValue
                let w = arrayConstraint.shape[3].intValue
                guard h > 0, w > 0, let small = render(image, size: CGSize(width: w, height: h)) else { return nil }
                var rgba = [UInt8](repeating: 0, count: w * h * 4)
                let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
                    guard let cg = CGContext(data: ptr.baseAddress, width: w, height: h,
                                             bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    cg.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return true
                }
                guard ok, let mlArray = try? MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32) else {
                    return nil
                }
                let mean: [Float] = [0.485, 0.456, 0.406]
                let std: [Float] = [0.229, 0.224, 0.225]
                let dst = mlArray.dataPointer.assumingMemoryBound(to: Float.self)
                let plane = w * h
                for i in 0..<plane {
                    for c in 0..<3 {
                        let v = Float(rgba[i * 4 + c]) / 255.0
                        dst[c * plane + i] = (v - mean[c]) / std[c]
                    }
                }
                inputFeature = MLFeatureValue(multiArray: mlArray)
            } else {
                return nil
            }

            guard !cancellation.isCancelled,
                  let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature]),
                  let output = try? model.prediction(from: provider),
                  !cancellation.isCancelled else { return nil }

            let preferredOutputs = ["depth", "predicted_depth", "inverse_depth"] + Array(output.featureNames)
            for outName in preferredOutputs {
                guard let val = output.featureValue(for: outName) else { continue }
                if let pb = val.imageBufferValue,
                   let raw = depthBufferMap(pb, side: side),
                   let normalized = percentileNormalize(raw) {
                    return normalized
                }
                if let arr = val.multiArrayValue, arr.shape.count >= 2 {
                    let h = arr.shape[arr.shape.count - 2].intValue
                    let w = arr.shape[arr.shape.count - 1].intValue
                    guard w > 0, h > 0, arr.count >= w * h else { continue }
                    let raw = readDepthArray(arr, width: w, height: h, targetSide: side)
                    return percentileNormalize(raw)
                }
            }
            return nil
        }
    }

    @inline(__always)
    private static func float16ToDouble(_ bits: UInt16) -> Double {
        #if arch(arm64)
        let f16 = Float16(bitPattern: bits)
        return f16.isFinite ? Double(f16) : 0.0
        #else
        let sign = (bits & 0x8000) != 0 ? -1.0 : 1.0
        let exp = Int((bits >> 10) & 0x1F)
        let mant = Int(bits & 0x03FF)
        if exp == 0 {
            return mant == 0 ? 0.0 : sign * pow(2.0, -14.0) * (Double(mant) / 1024.0)
        } else if exp == 31 {
            return 0.0
        }
        return sign * pow(2.0, Double(exp - 15)) * (1.0 + Double(mant) / 1024.0)
        #endif
    }

    /// Reads raw unclipped monocular disparity values from Apple Core ML DepthAnythingV2 output buffers
    /// (supports OneComponent16Half, OneComponent32Float, OneComponent8, and CoreImage RGBA8 fallback).
    private func depthBufferMap(_ buffer: CVPixelBuffer, side: Int) -> [Double]? {
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        if fmt == kCVPixelFormatType_OneComponent16Half ||
            fmt == kCVPixelFormatType_OneComponent32Float ||
            fmt == kCVPixelFormatType_OneComponent8 {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            var values = [Double](repeating: 0, count: side * side)
            if fmt == kCVPixelFormatType_OneComponent16Half {
                guard stride >= width * MemoryLayout<UInt16>.stride else { return nil }
                for y in 0..<side {
                    let row = base.advanced(by: min(height - 1, y * height / side) * stride)
                        .assumingMemoryBound(to: UInt16.self)
                    for x in 0..<side {
                        let v = Self.float16ToDouble(row[min(width - 1, x * width / side)])
                        values[y * side + x] = v.isFinite ? v : 0.0
                    }
                }
                return values
            } else if fmt == kCVPixelFormatType_OneComponent32Float {
                guard stride >= width * MemoryLayout<Float>.stride else { return nil }
                for y in 0..<side {
                    let row = base.advanced(by: min(height - 1, y * height / side) * stride)
                        .assumingMemoryBound(to: Float.self)
                    for x in 0..<side {
                        let v = Double(row[min(width - 1, x * width / side)])
                        values[y * side + x] = v.isFinite ? v : 0.0
                    }
                }
                return values
            } else {
                guard stride >= width else { return nil }
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
        guard let cg = render(CIImage(cvPixelBuffer: buffer), size: CGSize(width: side, height: side)) else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        return (0..<(side * side)).map { Double(rgba[$0 * 4]) / 255.0 }
    }

    private func readDepthArray(_ array: MLMultiArray, width: Int, height: Int, targetSide: Int) -> [Double] {
        var result = [Double](repeating: 0, count: targetSide * targetSide)
        let rowStride = array.strides.count >= 2 ? array.strides[array.strides.count - 2].intValue : width
        let colStride = array.strides.count >= 1 ? array.strides[array.strides.count - 1].intValue : 1
        let isFloat16 = array.dataType == .float16
        let ptrF32 = isFloat16 ? nil : array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let ptrU16 = isFloat16 ? array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count) : nil

        for y in 0..<targetSide {
            let sy = min(height - 1, y * height / targetSide)
            for x in 0..<targetSide {
                let sx = min(width - 1, x * width / targetSide)
                let offset = sy * rowStride + sx * colStride
                let value: Double
                if let p32 = ptrF32 {
                    value = Double(p32[offset])
                } else if let p16 = ptrU16 {
                    value = Self.float16ToDouble(p16[offset])
                } else {
                    value = 0.0
                }
                result[y * targetSide + x] = value.isFinite ? value : 0.0
            }
        }
        return result
    }

    private func percentileNormalize(_ values: [Double]) -> [Double]? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.02)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let span = high - low
        guard span.isFinite, span > 1e-5 else { return nil }
        return values.map { min(1.0, max(0.0, ($0 - low) / span)) }
    }

    /// 14x14 multi-scale patch self-similarity & contrast attention map upsampled bilinearly to `side x side`.
    private func extractPatchSelfAttention(rgba: [UInt8], luma: [Double], edges: [Double], side: Int) -> [Double] {
        let grid = 14
        let count = side * side
        guard rgba.count == count * 4, luma.count == count, edges.count == count else {
            return [Double](repeating: 0, count: count)
        }
        var pLuma = [Double](repeating: 0, count: grid * grid)
        var pRG = [Double](repeating: 0, count: grid * grid)
        var pBY = [Double](repeating: 0, count: grid * grid)
        var pEdge = [Double](repeating: 0, count: grid * grid)

        for py in 0..<grid {
            let y0 = py * side / grid
            let y1 = max(y0 + 1, (py + 1) * side / grid)
            for px in 0..<grid {
                let x0 = px * side / grid
                let x1 = max(x0 + 1, (px + 1) * side / grid)
                var sumL = 0.0, sumRG = 0.0, sumBY = 0.0, sumE = 0.0, n = 0.0
                for y in y0..<min(side, y1) {
                    for x in x0..<min(side, x1) {
                        let idx = y * side + x
                        let r = Double(rgba[idx * 4]) / 255.0
                        let g = Double(rgba[idx * 4 + 1]) / 255.0
                        let b = Double(rgba[idx * 4 + 2]) / 255.0
                        sumL += luma[idx]
                        sumRG += (r - g)
                        sumBY += (b - 0.5 * (r + g))
                        sumE += edges[idx]
                        n += 1.0
                    }
                }
                let pIdx = py * grid + px
                let invN = n > 0 ? 1.0 / n : 1.0
                pLuma[pIdx] = sumL * invN
                pRG[pIdx] = sumRG * invN
                pBY[pIdx] = sumBY * invN
                pEdge[pIdx] = sumE * invN
            }
        }

        var patchAttn = [Double](repeating: 0, count: grid * grid)
        var maxPatch = 0.0
        for y in 0..<grid {
            let ny = (Double(y) + 0.5) / Double(grid)
            for x in 0..<grid {
                let nx = (Double(x) + 0.5) / Double(grid)
                let i = y * grid + x
                var distinctiveness = 0.0
                for v in 0..<grid {
                    let dy = (Double(v) + 0.5) / Double(grid) - ny
                    for u in 0..<grid {
                        let dx = (Double(u) + 0.5) / Double(grid) - nx
                        let j = v * grid + u
                        let featDist = abs(pLuma[i] - pLuma[j]) * 1.1 +
                                       abs(pRG[i] - pRG[j]) * 0.9 +
                                       abs(pBY[i] - pBY[j]) * 0.8 +
                                       abs(pEdge[i] - pEdge[j]) * 0.6
                        let spatialWeight = exp(-(dx * dx + dy * dy) / (2.0 * 0.42 * 0.42))
                        distinctiveness += featDist * spatialWeight
                    }
                }
                let val = (distinctiveness / Double(grid * grid)) * (0.65 + 0.35 * min(1.0, pEdge[i] * 1.5))
                patchAttn[i] = val
                if val > maxPatch { maxPatch = val }
            }
        }
        guard maxPatch > 0.015 else { return [Double](repeating: 0, count: count) }
        for i in patchAttn.indices { patchAttn[i] = min(1.0, patchAttn[i] / maxPatch) }

        var upsampled = [Double](repeating: 0, count: count)
        for y in 0..<side {
            let fy = max(0.0, min(Double(grid - 1), (Double(y) + 0.5) * Double(grid) / Double(side) - 0.5))
            let y0 = Int(floor(fy)), y1 = min(grid - 1, y0 + 1)
            let wy = fy - Double(y0)
            for x in 0..<side {
                let fx = max(0.0, min(Double(grid - 1), (Double(x) + 0.5) * Double(grid) / Double(side) - 0.5))
                let x0 = Int(floor(fx)), x1 = min(grid - 1, x0 + 1)
                let wx = fx - Double(x0)
                let top = patchAttn[y0 * grid + x0] * (1.0 - wx) + patchAttn[y0 * grid + x1] * wx
                let bot = patchAttn[y1 * grid + x0] * (1.0 - wx) + patchAttn[y1 * grid + x1] * wx
                upsampled[y * side + x] = min(1.0, max(0.0, top * (1.0 - wy) + bot * wy))
            }
        }
        return upsampled
    }

    /// Multi-cue monocular inverse depth estimation combining focus sharpness, border-background geodesic
    /// separation, Vision objectness/segmentation masks, and upper-sky perspective suppression.
    private func buildMonocularDepthGrid(rgba: [UInt8], luma: [Double], edges: [Double],
                                         attention: [Double], segMask: [Double]?,
                                         foreground: [Double]?, side: Int) -> [Double] {
        let count = side * side
        var borderBarrier = [Double](repeating: 1.0, count: count)
        for y in 0..<side {
            for x in 0..<side {
                if x == 0 || x == side - 1 || y == 0 {
                    borderBarrier[y * side + x] = 0.0
                }
            }
        }
        // 4-sweep forward/backward geodesic contrast distance from frame borders
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for pass in 0..<4 {
            let ys = (pass % 2 == 0) ? Array(0..<side) : Array((0..<side).reversed())
            let xs = (pass % 2 == 0) ? Array(0..<side) : Array((0..<side).reversed())
            for y in ys {
                for x in xs {
                    let i = y * side + x
                    var best = borderBarrier[i]
                    let r1 = Double(rgba[i * 4]) / 255.0
                    let g1 = Double(rgba[i * 4 + 1]) / 255.0
                    let b1 = Double(rgba[i * 4 + 2]) / 255.0
                    for (dx, dy) in offsets {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                        let ni = ny * side + nx
                        let r2 = Double(rgba[ni * 4]) / 255.0
                        let g2 = Double(rgba[ni * 4 + 1]) / 255.0
                        let b2 = Double(rgba[ni * 4 + 2]) / 255.0
                        let stepCost = (abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2)) * 0.45 + edges[i] * 0.25
                        let cand = min(1.0, borderBarrier[ni] + stepCost)
                        if cand < best { best = cand }
                    }
                    borderBarrier[i] = best
                }
            }
        }

        var rawDepth = [Double](repeating: 0.5, count: count)
        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            let perspectiveGround = min(1.0, max(0.0, py))
            let isTopHalf = py < 0.42
            for x in 0..<side {
                let i = y * side + x
                let skySuppression = (isTopHalf && luma[i] > 0.68 && edges[i] < 0.08) ? 0.30 : 1.0
                let maskCue = segMask?[i] ?? (foreground?[i] ?? attention[i])
                let focusSharpness = edges[i]
                let combined = (0.36 * maskCue + 0.26 * borderBarrier[i] + 0.22 * focusSharpness + 0.16 * perspectiveGround) * skySuppression
                rawDepth[i] = min(1.0, max(0.0, combined))
            }
        }

        // Edge-preserving 3x3 cross-bilateral smoothing
        var smoothed = rawDepth
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let cL = luma[i]
                var acc = 0.0, wSum = 0.0
                for dy in -1...1 {
                    let ny = min(side - 1, max(0, y + dy))
                    for dx in -1...1 {
                        let nx = min(side - 1, max(0, x + dx))
                        let ni = ny * side + nx
                        let lDiff = cL - luma[ni]
                        let w = exp(-(lDiff * lDiff) / (2.0 * 0.12 * 0.12))
                        acc += rawDepth[ni] * w
                        wSum += w
                    }
                }
                smoothed[i] = wSum > 0 ? min(1.0, max(0.0, acc / wSum)) : rawDepth[i]
            }
        }
        return smoothed
    }

    /// Warp the 64x64 synchronized saliency S_sync field inside crop corners into a 224x224 saliency hint for SAMP-Net.
    func synchronizedSaliencyCrop(from raster: CompositionRaster, corners: [CGPoint], side: Int = 224) -> [Double]? {
        guard raster.isValid, raster.hasAttention, corners.count == 4 else { return nil }
        let minX = max(0.0, min(1.0, corners.map(\.x).min() ?? 0.0))
        let maxX = max(0.0, min(1.0, corners.map(\.x).max() ?? 1.0))
        let minY = max(0.0, min(1.0, corners.map(\.y).min() ?? 0.0))
        let maxY = max(0.0, min(1.0, corners.map(\.y).max() ?? 1.0))
        let spanW = max(0.01, maxX - minX)
        let spanH = max(0.01, maxY - minY)
        var out = [Double](repeating: 0, count: side * side)
        let srcSide = raster.side
        for y in 0..<side {
            let v = minY + ((Double(y) + 0.5) / Double(side)) * spanH
            let sy = v * Double(srcSide) - 0.5
            let y0 = min(srcSide - 1, max(0, Int(floor(sy))))
            let y1 = min(srcSide - 1, y0 + 1)
            let wy = max(0.0, min(1.0, sy - Double(y0)))
            for x in 0..<side {
                let u = minX + ((Double(x) + 0.5) / Double(side)) * spanW
                let sx = u * Double(srcSide) - 0.5
                let x0 = min(srcSide - 1, max(0, Int(floor(sx))))
                let x1 = min(srcSide - 1, x0 + 1)
                let wx = max(0.0, min(1.0, sx - Double(x0)))
                let top = raster.synchronizedSaliency[y0 * srcSide + x0] * (1.0 - wx) +
                          raster.synchronizedSaliency[y0 * srcSide + x1] * wx
                let bot = raster.synchronizedSaliency[y1 * srcSide + x0] * (1.0 - wx) +
                          raster.synchronizedSaliency[y1 * srcSide + x1] * wx
                out[y * side + x] = min(1.0, max(0.0, top * (1.0 - wy) + bot * wy))
            }
        }
        return out
    }

    func raster(image: CIImage, saliency: CVPixelBuffer?, objectness: CVPixelBuffer? = nil,
                foregroundMask: CVPixelBuffer? = nil,
                measuredDepth: [Double]? = nil,
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
        let patchAttention = extractPatchSelfAttention(rgba: bytes, luma: luma, edges: edges, side: side)
        let mean = luma.reduce(0, +) / Double(luma.count)
        let attention = luma.enumerated().map { index, value in
            if let measured, let foreground {
                return min(1.0, measured[index] * 0.56 + foreground[index] * 0.26 + patchAttention[index] * 0.18)
            }
            if let measured {
                return min(1.0, measured[index] * 0.80 + patchAttention[index] * 0.20)
            }
            if let foreground {
                return min(1.0, foreground[index] * 0.80 + patchAttention[index] * 0.20)
            }
            return min(1.0, 0.55 * edges[index] + 0.25 * abs(value - mean) + 0.20 * patchAttention[index])
        }
        let hasCoreMLDepth = (measuredDepth?.count == side * side)
        let fgDepth: [Double]
        if let measuredDepth, measuredDepth.count == side * side {
            fgDepth = measuredDepth.enumerated().map { idx, d in
                let dVal = d.isFinite ? min(1.0, max(0.0, d)) : 0.5
                if let mask = segMask?[idx] {
                    return min(1.0, max(0.0, 0.78 * dVal + 0.22 * mask))
                }
                return dVal
            }
        } else {
            fgDepth = buildMonocularDepthGrid(rgba: bytes, luma: luma, edges: edges,
                                              attention: attention, segMask: segMask,
                                              foreground: foreground, side: side)
        }
        var resultRaster = CompositionRaster(side: side, luminance: luma, attention: attention,
                                             edges: edges, edgeAngles: edgeAngles,
                                             hasAttention: measured != nil || foreground != nil,
                                             foregroundDepth: fgDepth,
                                             hasCoreMLDepth: hasCoreMLDepth)
        resultRaster.measuredHorizon = measuredHorizon
        resultRaster.measuredVanishingPoint = measuredVanishingPoint
        populateStructuralEvidence(&resultRaster, rgba: bytes)
        return resultRaster
    }

    /// Trích xuất bản đồ cấu trúc ảnh (trời & đỉnh mái nhà, tường trống, vật cản rìa ảnh, dây tường, thanh ban công, điểm nhấn màu sắc)
    private func populateStructuralEvidence(_ raster: inout CompositionRaster, rgba: [UInt8]) {
        let side = raster.side
        let count = side * side
        guard side > 4, rgba.count >= count * 4,
              raster.luminance.count == count,
              raster.edges.count == count,
              raster.foregroundDepth.count == count else { return }

        let luma = raster.luminance
        let edges = raster.edges
        let depth = raster.foregroundDepth

        var sat = [Double](repeating: 0.0, count: count)
        var skyPix = [Bool](repeating: false, count: count)
        var accentRaw = [Double](repeating: 0.0, count: count)

        for i in 0..<count {
            let r = Double(rgba[i * 4]) / 255.0
            let g = Double(rgba[i * 4 + 1]) / 255.0
            let b = Double(rgba[i * 4 + 2]) / 255.0
            let cmax = max(r, max(g, b))
            let cmin = min(r, min(g, b))
            let s = cmax > 1e-4 ? (cmax - cmin) / cmax : 0.0
            sat[i] = s
            let isGreen = (g > r + 0.03) && (g > b + 0.02) && (s > 0.14)
            skyPix[i] = (edges[i] < 0.09) && (luma[i] > 0.42) && (s < 0.38)
            let warmRed = max(0.0, r - 0.5 * (g + b)) * 2.2
            let nonGreenSat = isGreen ? s * 0.18 : s
            accentRaw[i] = 0.55 * nonGreenSat + 0.45 * warmRed
        }

        // 1. Sky column extent & roofline peak + horizon estimate
        var skyColBottom = [Double](repeating: 0.0, count: side)
        var skyMask = [Double](repeating: 0.0, count: count)
        let yMaxSky = Int(Double(side) * 0.72)
        for x in 0..<side {
            var yEnd = 0
            var gaps = 0
            for y in 0..<side {
                if skyPix[y * side + x] {
                    yEnd = y + 1
                    gaps = 0
                } else {
                    gaps += 1
                    if gaps >= 2 || y > yMaxSky { break }
                }
            }
            skyColBottom[x] = Double(yEnd) / Double(side)
            for y in 0..<min(side, yEnd) {
                skyMask[y * side + x] = 1.0
            }
        }
        raster.structuralSkyFraction = skyColBottom.reduce(0.0, +) / Double(side)
        raster.structuralSkyMask = skyMask

        let midX0 = Int(Double(side) * 0.08)
        let midX1 = max(midX0 + 1, Int(Double(side) * 0.92))
        let nonFullSky = skyColBottom[midX0..<min(side, midX1)].filter { $0 > 0.06 && $0 < 0.75 }.sorted()
        if nonFullSky.count >= 6 {
            let p10Idx = min(nonFullSky.count - 1, Int(Double(nonFullSky.count - 1) * 0.10))
            raster.structuralArchRoofTopY = nonFullSky[p10Idx]
        }
        let validSkyCols = skyColBottom.filter { $0 > 0.08 }.sorted()
        if Double(validSkyCols.count) >= Double(side) * 0.35 {
            raster.structuralEstimatedHorizonY = validSkyCols[validSkyCols.count / 2]
        }

        // 2. Local smoothness (5x5 std) + 7x7 ring isolated wall anomaly detector
        var blankSurface = [Double](repeating: 0.0, count: count)
        var isolatedWallBlip = [Double](repeating: 0.0, count: count)
        var bottomRailMask = [Double](repeating: 0.0, count: count)

        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                var sumL = 0.0, sqL = 0.0
                for dy in -2...2 {
                    let ny = min(side - 1, max(0, y + dy))
                    for dx in -2...2 {
                        let nx = min(side - 1, max(0, x + dx))
                        let lv = luma[ny * side + nx]
                        sumL += lv
                        sqL += lv * lv
                    }
                }
                let meanL = sumL / 25.0
                let stdL = sqrt(max(0.0, sqL / 25.0 - meanL * meanL))
                if stdL < 0.032 && edges[i] < 0.075 && sat[i] < 0.25 {
                    blankSurface[i] = 1.0
                }

                var sumE7 = 0.0
                var ringCnt = 0
                for dy in -3...3 {
                    let ny = min(side - 1, max(0, y + dy))
                    for dx in -3...3 {
                        if (-1...1).contains(dy) && (-1...1).contains(dx) { continue }
                        let nx = min(side - 1, max(0, x + dx))
                        sumE7 += edges[ny * side + nx]
                        ringCnt += 1
                    }
                }
                let meanE7 = sumE7 / Double(max(1, ringCnt))
                if meanE7 < 0.055 && edges[i] > 0.14 && sat[i] < 0.28 {
                    isolatedWallBlip[i] = 1.0
                }

                if edges[i] > 0.12 && sat[i] < 0.16 && luma[i] > 0.58 {
                    bottomRailMask[i] = 1.0
                }

                // Attenuate outer corners/borders for focal accent map
                var borderScale = 1.0
                if y < Int(Double(side) * 0.12) { borderScale *= 0.25 }
                if y >= Int(Double(side) * 0.90) { borderScale *= 0.25 }
                if x < Int(Double(side) * 0.10) { borderScale *= 0.25 }
                if x >= Int(Double(side) * 0.90) { borderScale *= 0.25 }
                accentRaw[i] *= borderScale
            }
        }
        raster.structuralBlankSurface = blankSurface
        raster.structuralIsolatedWallBlip = isolatedWallBlip
        raster.structuralBottomRailMask = bottomRailMask
        raster.structuralChromaticAccentMap = accentRaw

        // 3. Geometric continuous vertical dark/foreground edge pillar detection
        let colLimit = Int(Double(side) * 0.27)
        let graceCols = Int(Double(side) * 0.04)
        var maxDarkLeft = 0
        for gx in 0..<colLimit {
            var darkHits = 0, edgeHits = 0, depthSum = 0.0
            for gy in 0..<side {
                let idx = gy * side + gx
                if luma[idx] < 0.25 { darkHits += 1 }
                if edges[idx] > 0.10 { edgeHits += 1 }
                depthSum += depth[idx]
            }
            let darkFrac = Double(darkHits) / Double(side)
            let edgeFrac = Double(edgeHits) / Double(side)
            let meanDepth = depthSum / Double(side)
            if darkFrac > 0.58 || (edgeFrac > 0.58 && meanDepth > 0.55) {
                maxDarkLeft = gx + 1
            } else if gx > graceCols {
                break
            }
        }

        var maxDarkRight = 0
        for dist in 0..<colLimit {
            let gx = side - 1 - dist
            var darkHits = 0, edgeHits = 0, depthSum = 0.0
            for gy in 0..<side {
                let idx = gy * side + gx
                if luma[idx] < 0.25 { darkHits += 1 }
                if edges[idx] > 0.10 { edgeHits += 1 }
                depthSum += depth[idx]
            }
            let darkFrac = Double(darkHits) / Double(side)
            let edgeFrac = Double(edgeHits) / Double(side)
            let meanDepth = depthSum / Double(side)
            if darkFrac > 0.58 || (edgeFrac > 0.58 && meanDepth > 0.55) {
                maxDarkRight = dist + 1
            } else if dist > graceCols {
                break
            }
        }

        var geomAvoid = EdgeAvoidanceHints.zero
        let pillarThresh = Int(Double(side) * 0.12)
        let narrowOpp = Int(Double(side) * 0.06)
        if maxDarkLeft >= pillarThresh && maxDarkRight < narrowOpp {
            geomAvoid.left = min(1.0, Double(maxDarkLeft) / (Double(side) * 0.22))
        }
        if maxDarkRight >= pillarThresh && maxDarkLeft < narrowOpp {
            geomAvoid.right = min(1.0, Double(maxDarkRight) / (Double(side) * 0.22))
        }
        raster.structuralEdgePillarColsLeft = maxDarkLeft
        raster.structuralEdgePillarColsRight = maxDarkRight
        raster.structuralGeometricAvoidance = geomAvoid
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
        return Self.createSharedCGImage(scaled, from: CGRect(origin: .zero, size: size),
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
