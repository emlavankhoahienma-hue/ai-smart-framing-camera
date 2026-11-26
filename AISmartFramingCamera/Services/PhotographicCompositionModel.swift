import Foundation
import CoreGraphics
import CoreML
import Accelerate
#if canImport(UIKit)
import UIKit
#endif

/// SAMP-Net (BMVC 2021), author checkpoint trained on expert CADB composition ratings.
/// One instance belongs to serialized still-image analysis; no inference runs on the camera queue.
final class PhotographicCompositionModel {
    struct Assessment: Sendable {
        let distribution: [Double]
        var mean: Double { zip(distribution, 1...5).reduce(0) { $0 + $1.0 * Double($1.1) } }
    }

    private final class ModelCache: @unchecked Sendable {
        static let shared = ModelCache()
        private let lock = NSLock()
        private var cachedURL: URL?
        private var cachedInstance: PhotographicCompositionModel?

        private init() {
            CompositionMemoryBudget.registerCacheEvictor(id: "SAMP", priority: 40) { [weak self] in
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
            if evicted {
                CompositionMemoryBudget.emitLifecycle("MODEL_UNLOAD", "SAMPComposition")
            }
            return evicted
        }

        func getOrLoad(url: URL) -> PhotographicCompositionModel? {
            if let existing = lock.withLock({ cachedURL == url ? cachedInstance : nil }) {
                return existing
            }
            guard CompositionMemoryBudget.ensureHeadroom(
                minimumBytes: CompositionMemoryBudget.sampLoadHeadroomBytes,
                excluding: "SAMP"
            ) else {
                return nil
            }
            guard let loaded = try? PhotographicCompositionModel(url: url) else { return nil }
            CompositionMemoryBudget.emitLifecycle("MODEL_LOAD", "SAMPComposition (FP16)")
            if CompositionMemoryBudget.shouldRetainModelCache(
                minimumAvailableBytes: CompositionMemoryBudget.sampRetainThresholdBytes
            ) {
                lock.withLock {
                    cachedURL = url
                    cachedInstance = loaded
                }
            }
            return loaded
        }
    }

    static func cachedOrLoad(url: URL) -> PhotographicCompositionModel? {
        ModelCache.shared.getOrLoad(url: url)
    }

    static func clearCache() {
        ModelCache.shared.clear()
    }

    private let model: MLModel
    private let saliency = SpectralCompositionSaliency()
    private let input: MLMultiArray
    private let imageInput: MLMultiArray

    init(url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        configuration.allowLowPrecisionAccumulationOnGPU = true
        model = try MLModel(contentsOf: url, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, 224, 224] else {
            throw CocoaError(.coderInvalidValue)
        }
        input = try MLMultiArray(shape: [1, 1, 224, 224], dataType: .float32)
        imageInput = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
    }

    func assess(_ image: CGImage, cancellation: CompositionAnalysisCancellation) -> Assessment? {
        assess(image, synchronizedSaliencyCrop: nil, cancellation: cancellation)
    }

    func assess(_ image: CGImage, synchronizedSaliencyCrop: [Double]?,
                cancellation: CompositionAnalysisCancellation) -> Assessment? {
        guard !cancellation.isCancelled, image.width >= 6, image.height >= 6,
              max(image.width, image.height) <= 1024,
              ProcessInfo.processInfo.thermalState != .critical,
              let map = saliency.map(image: image),
              let rgb = CompositionPhotoPixels.resizedRGB(image: image, side: 224) else { return nil }
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        let mapCount = map.count
        if let sync = synchronizedSaliencyCrop, sync.count == mapCount {
            map.withUnsafeBufferPointer { mBuf in
                sync.withUnsafeBufferPointer { sBuf in
                    guard let mPtr = mBuf.baseAddress, let sPtr = sBuf.baseAddress else { return }
                    for index in 0..<mapCount {
                        let sv = min(1.0, max(0.0, sPtr[index]))
                        let fused = 0.72 * mPtr[index] + 0.28 * sv
                        values[index] = Float(min(1.0, max(0.0, fused)))
                    }
                }
            }
        } else {
            map.withUnsafeBufferPointer { mBuf in
                guard let mPtr = mBuf.baseAddress else { return }
                for index in 0..<mapCount { values[index] = Float(mPtr[index]) }
            }
        }
        let pixels = imageInput.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = 224 * 224
        let inv255: Float = 1.0 / 255.0
        rgb.withUnsafeBufferPointer { rgbBuf in
            guard let src = rgbBuf.baseAddress else { return }
            for index in 0..<plane {
                let s = index * 3
                pixels[index] = Float(src[s]) * inv255
                pixels[plane + index] = Float(src[s + 1]) * inv255
                pixels[2 * plane + index] = Float(src[s + 2]) * inv255
            }
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: imageInput), "saliency": MLFeatureValue(multiArray: input)]),
              !cancellation.isCancelled,
              let result = try? model.prediction(from: provider),
              !cancellation.isCancelled,
              let scores = result.featureValue(for: "compositionDistribution")?.multiArrayValue,
              scores.count == 5 else { return nil }
        let distribution = (0..<5).map { Double(truncating: scores[$0]) }
        let total = distribution.reduce(0, +)
        guard distribution.allSatisfy({ $0.isFinite && $0 >= 0 }),
              total.isFinite, abs(total - 1) < 0.02 else { return nil }
        return Assessment(distribution: distribution.map { $0 / total })
    }
}

/// Pillow-compatible bilinear antialiasing with an 8-bit intermediate pass.
/// Supplying RGB tensors also avoids Core ML image-feature colour conversions.
enum CompositionPhotoPixels {
    static func rgba(image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    static func resizedRGB(image: CGImage, side: Int) -> [UInt8]? {
        resizedRGB(image: image, width: side, height: side)
    }

    static func resizedRGB(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        guard let bytes = rgba(image: image) else { return nil }
        let srcW = image.width, srcH = image.height
        func weights(source: Int, target: Int) -> [[(Int, Int)]] {
            let scale = Double(source) / Double(target), filter = max(1, scale)
            return (0..<target).map { destination in
                let center = (Double(destination) + 0.5) * scale
                let start = max(0, Int(center - filter + 0.5))
                let end = min(source, Int(center + filter + 0.5))
                let coefficients = (start..<end).map { max(0, 1 - abs((Double($0) - center + 0.5) / filter)) }
                let total = coefficients.reduce(0, +)
                return coefficients.enumerated().map { (start + $0.offset, Int(($0.element / total * 4_194_304 + 0.5).rounded(.down))) }
            }
        }
        let horizontalWeights = weights(source: srcW, target: width)
        let verticalWeights = weights(source: srcH, target: height)
        var horizontal = [UInt8](repeating: 0, count: width * srcH * 3)
        var output = [UInt8](repeating: 0, count: width * height * 3)

        bytes.withUnsafeBufferPointer { srcBuf in
            horizontal.withUnsafeMutableBufferPointer { hBuf in
                guard let src = srcBuf.baseAddress, let hDst = hBuf.baseAddress else { return }
                for y in 0..<srcH {
                    let srcRow = y * srcW * 4
                    let hRow = y * width * 3
                    for x in 0..<width {
                        let hw = horizontalWeights[x]
                        var t0 = 2_097_152, t1 = 2_097_152, t2 = 2_097_152
                        for (sx, w) in hw {
                            let off = srcRow + sx * 4
                            t0 += Int(src[off]) * w
                            t1 += Int(src[off + 1]) * w
                            t2 += Int(src[off + 2]) * w
                        }
                        let dst = hRow + x * 3
                        hDst[dst] = UInt8(clamping: t0 >> 22)
                        hDst[dst + 1] = UInt8(clamping: t1 >> 22)
                        hDst[dst + 2] = UInt8(clamping: t2 >> 22)
                    }
                }
                output.withUnsafeMutableBufferPointer { oBuf in
                    guard let oDst = oBuf.baseAddress else { return }
                    let rowStride = width * 3
                    for y in 0..<height {
                        let vw = verticalWeights[y]
                        let oRow = y * rowStride
                        for x in 0..<width {
                            let xOff = x * 3
                            var t0 = 2_097_152, t1 = 2_097_152, t2 = 2_097_152
                            for (sy, w) in vw {
                                let off = sy * rowStride + xOff
                                t0 += Int(hDst[off]) * w
                                t1 += Int(hDst[off + 1]) * w
                                t2 += Int(hDst[off + 2]) * w
                            }
                            let dst = oRow + xOff
                            oDst[dst] = UInt8(clamping: t0 >> 22)
                            oDst[dst + 1] = UInt8(clamping: t1 >> 22)
                            oDst[dst + 2] = UInt8(clamping: t2 >> 22)
                        }
                    }
                }
            }
        }
        return output
    }
}

/// Port of the author's spectral-residual preprocessing, not Vision saliency.
/// Arbitrary image dimensions use separable DFT matrices and Accelerate, avoiding
/// power-of-two padding that would change the checkpoint's expected input.
final class SpectralCompositionSaliency {
    private var bases: [Int: (cosine: [Double], sine: [Double])] = [:]

    func map(image: CGImage) -> [Double]? {
        let width = image.width, height = image.height
        guard width >= 6, height >= 6, max(width, height) <= 1024 else { return nil }
        guard let bytes = CompositionPhotoPixels.rgba(image: image) else { return nil }
        let pixelCount = width * height
        var gray = [Double](repeating: 0.0, count: pixelCount)
        bytes.withUnsafeBufferPointer { bBuf in
            gray.withUnsafeMutableBufferPointer { gBuf in
                guard let src = bBuf.baseAddress, let dst = gBuf.baseAddress else { return }
                for index in 0..<pixelCount {
                    let offset = index * 4
                    let value = Int(src[offset]) * 4899 + Int(src[offset + 1]) * 9617 + Int(src[offset + 2]) * 1868
                    dst[index] = Double((value + 8192) >> 14)
                }
            }
        }
        let w = width / 6, h = height / 6
        let small = areaResize(gray, width: width, height: height, toWidth: w, toHeight: h)
        let spectrum = transform(small, [Double](repeating: 0, count: small.count), width: w, height: h, inverse: false)
        let smallCount = small.count
        var amplitude = [Double](repeating: 0, count: smallCount)
        for i in 0..<smallCount {
            amplitude[i] = log(hypot(spectrum.0[i], spectrum.1[i]) + 0.000001)
        }
        let smooth = blur(amplitude, width: w, height: h, kernel: [1 / 3.0, 1 / 3.0, 1 / 3.0])
        var real = [Double](repeating: 0, count: smallCount), imaginary = [Double](repeating: 0, count: smallCount)
        for index in 0..<smallCount {
            let magnitude = exp(amplitude[index] - smooth[index])
            let phase = atan2(spectrum.1[index], spectrum.0[index])
            real[index] = magnitude * cos(phase)
            imaginary[index] = magnitude * sin(phase)
        }
        let spatial = transform(real, imaginary, width: w, height: h, inverse: true)
        var power = [Double](repeating: 0, count: smallCount)
        for i in 0..<smallCount {
            let r = spatial.0[i], im = spatial.1[i]
            power[i] = r * r + im * im
        }
        var kernel = (-4...4).map { exp(-Double($0 * $0) / (2 * 2.5 * 2.5)) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        let smoothed = blur(power, width: w, height: h, kernel: kernel)
        let resized = linearResize(smoothed, width: w, height: h, side: 224)
        let sorted = resized.sorted()
        let location = Double(sorted.count - 1) * 0.95
        let low = Int(location), fraction = location - Double(low)
        let threshold = sorted[low] * (1 - fraction) + sorted[min(low + 1, sorted.count - 1)] * fraction
        let minimum = sorted[0]
        guard threshold.isFinite, threshold > 0 else { return [Double](repeating: 0, count: 224 * 224) }
        let invThreshold = 1.0 / threshold
        let result = resized.map { max(0, (min($0, threshold) - minimum) * invThreshold) }
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    private func basis(_ count: Int) -> (cosine: [Double], sine: [Double]) {
        if let stored = bases[count] { return stored }
        var cosine = [Double](repeating: 0, count: count * count), sine = cosine
        let step = 2 * Double.pi / Double(count)
        for row in 0..<count {
            let base = row * count
            let rowAngle = step * Double(row)
            for column in 0..<count {
                let angle = rowAngle * Double(column)
                cosine[base + column] = cos(angle)
                sine[base + column] = sin(angle)
            }
        }
        // Analyses normally share one preview size. Bound the cache for tests
        // or exceptional callers that supply many different aspect ratios.
        if bases.count >= 4 { bases.removeAll(keepingCapacity: true) }
        bases[count] = (cosine, sine)
        return (cosine, sine)
    }

    private func multiply(_ lhs: [Double], _ rhs: [Double], rows: Int, columns: Int, inner: Int) -> [Double] {
        var result = [Double](repeating: 0, count: rows * columns)
        vDSP_mmulD(lhs, 1, rhs, 1, &result, 1,
                   vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
        return result
    }

    private func transform(_ real: [Double], _ imaginary: [Double], width: Int, height: Int,
                           inverse: Bool) -> ([Double], [Double]) {
        let x = basis(width), y = basis(height)
        let sign = inverse ? 1.0 : -1.0
        let rc = multiply(real, x.cosine, rows: height, columns: width, inner: width)
        let imaginarySine = multiply(imaginary, x.sine, rows: height, columns: width, inner: width)
        let rs = multiply(real, x.sine, rows: height, columns: width, inner: width)
        let ic = multiply(imaginary, x.cosine, rows: height, columns: width, inner: width)
        let n = width * height
        var rowReal = [Double](repeating: 0, count: n)
        var rowImaginary = [Double](repeating: 0, count: n)
        for i in 0..<n {
            rowReal[i] = rc[i] - sign * imaginarySine[i]
            rowImaginary[i] = sign * rs[i] + ic[i]
        }
        let cr = multiply(y.cosine, rowReal, rows: height, columns: width, inner: height)
        let si = multiply(y.sine, rowImaginary, rows: height, columns: width, inner: height)
        let sr = multiply(y.sine, rowReal, rows: height, columns: width, inner: height)
        let ci = multiply(y.cosine, rowImaginary, rows: height, columns: width, inner: height)
        let scale = inverse ? 1 / Double(n) : 1
        var outReal = [Double](repeating: 0, count: n)
        var outImag = [Double](repeating: 0, count: n)
        for i in 0..<n {
            outReal[i] = (cr[i] - sign * si[i]) * scale
            outImag[i] = (sign * sr[i] + ci[i]) * scale
        }
        return (outReal, outImag)
    }

    @inline(__always)
    private func reflected(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        let folded = (index % period + period) % period
        return folded < count ? folded : period - folded
    }

    private func blur(_ values: [Double], width: Int, height: Int, kernel: [Double]) -> [Double] {
        var horizontal = values, result = values
        let radius = kernel.count / 2
        let kCount = kernel.count
        for y in 0..<height {
            let rowOff = y * width
            for x in 0..<width {
                var acc = 0.0
                for k in 0..<kCount {
                    acc += kernel[k] * values[rowOff + reflected(x + k - radius, count: width)]
                }
                horizontal[rowOff + x] = acc
            }
        }
        for y in 0..<height {
            let rowOff = y * width
            for x in 0..<width {
                var acc = 0.0
                for k in 0..<kCount {
                    acc += kernel[k] * horizontal[reflected(y + k - radius, count: height) * width + x]
                }
                result[rowOff + x] = acc
            }
        }
        return result
    }

    private func areaResize(_ values: [Double], width: Int, height: Int,
                            toWidth: Int, toHeight: Int) -> [Double] {
        var result = [Double](repeating: 0, count: toWidth * toHeight)
        let sx = Double(width) / Double(toWidth), sy = Double(height) / Double(toHeight)
        let invArea = 1.0 / (sx * sy)
        values.withUnsafeBufferPointer { vBuf in
            guard let src = vBuf.baseAddress else { return }
            for y in 0..<toHeight {
                let y0 = Double(y) * sy, y1 = Double(y + 1) * sy
                let rStart = Int(floor(y0)), rEnd = min(height, Int(ceil(y1)))
                let dstRow = y * toWidth
                for x in 0..<toWidth {
                    let x0 = Double(x) * sx, x1 = Double(x + 1) * sx
                    let cStart = Int(floor(x0)), cEnd = min(width, Int(ceil(x1)))
                    var sum = 0.0
                    for row in rStart..<rEnd {
                        let wy = max(0, min(y1, Double(row + 1)) - max(y0, Double(row)))
                        let srcRow = row * width
                        var rowSum = 0.0
                        for column in cStart..<cEnd {
                            let wx = max(0, min(x1, Double(column + 1)) - max(x0, Double(column)))
                            rowSum += src[srcRow + column] * wx
                        }
                        sum += rowSum * wy
                    }
                    result[dstRow + x] = (sum * invArea).rounded(.toNearestOrEven)
                }
            }
        }
        return result
    }

    private func linearResize(_ values: [Double], width: Int, height: Int, side: Int) -> [Double] {
        var result = [Double](repeating: 0, count: side * side)
        let scaleX = Double(width) / Double(side)
        let scaleY = Double(height) / Double(side)
        values.withUnsafeBufferPointer { vBuf in
            guard let src = vBuf.baseAddress else { return }
            for y in 0..<side {
                let py = (Double(y) + 0.5) * scaleY - 0.5
                let by = Int(floor(py)), dy = py - Double(by)
                let y0 = max(0, min(height - 1, by)), y1 = max(0, min(height - 1, by + 1))
                let r0 = y0 * width, r1 = y1 * width
                let dstRow = y * side
                for x in 0..<side {
                    let px = (Double(x) + 0.5) * scaleX - 0.5
                    let bx = Int(floor(px)), dx = px - Double(bx)
                    let x0 = max(0, min(width - 1, bx)), x1 = max(0, min(width - 1, bx + 1))
                    let top = src[r0 + x0] * (1 - dx) + src[r0 + x1] * dx
                    let bot = src[r1 + x0] * (1 - dx) + src[r1 + x1] * dx
                    result[dstRow + x] = top * (1 - dy) + bot * dy
                }
            }
        }
        return result
    }
}
