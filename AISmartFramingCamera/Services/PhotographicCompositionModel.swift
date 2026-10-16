import Foundation
import CoreGraphics
import CoreML
import Accelerate

/// SAMP-Net (BMVC 2021), author checkpoint trained on expert CADB composition ratings.
/// One instance belongs to one still-image analysis; no inference runs on the camera queue.
final class PhotographicCompositionModel {
    struct Assessment: Sendable {
        let distribution: [Double]
        var mean: Double { zip(distribution, 1...5).reduce(0) { $0 + $1.0 * Double($1.1) } }
    }

    private let model: MLModel
    private let saliency = SpectralCompositionSaliency()
    private let input: MLMultiArray
    private let context: CGContext
    private let bitmap: UnsafeMutablePointer<UInt8>

    init(url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        input = try MLMultiArray(shape: [1, 1, 224, 224], dataType: .float32)
        bitmap = .allocate(capacity: 224 * 224 * 4)
        guard let canvas = CGContext(data: bitmap, width: 224, height: 224, bitsPerComponent: 8,
            bytesPerRow: 224 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            bitmap.deallocate()
            throw CocoaError(.coderInvalidValue)
        }
        context = canvas
    }

    deinit { bitmap.deallocate() }

    func assess(_ image: CGImage, cancellation: CompositionAnalysisCancellation) -> Assessment? {
        guard !cancellation.isCancelled, image.width >= 6, image.height >= 6,
              max(image.width, image.height) <= 1024,
              ProcessInfo.processInfo.thermalState != .critical,
              let map = saliency.map(image: image) else { return nil }
        let values = input.dataPointer.assumingMemoryBound(to: Float.self)
        for index in map.indices { values[index] = Float(map[index]) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 224, height: 224))
        guard let resized = context.makeImage(),
              let imageValue = try? MLFeatureValue(cgImage: resized, pixelsWide: 224, pixelsHigh: 224,
                  pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [
                "image": imageValue, "saliency": MLFeatureValue(multiArray: input)]),
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

/// Port of the author's spectral-residual preprocessing, not Vision saliency.
/// Arbitrary image dimensions use separable DFT matrices and Accelerate, avoiding
/// power-of-two padding that would change the checkpoint's expected input.
final class SpectralCompositionSaliency {
    private var bases: [Int: (cosine: [Double], sine: [Double])] = [:]

    func map(image: CGImage) -> [Double]? {
        let width = image.width, height = image.height
        guard width >= 6, height >= 6, max(width, height) <= 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let canvas = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let gray = (0..<(width * height)).map { index -> Double in
            let offset = index * 4
            let value = Int(bytes[offset]) * 4899 + Int(bytes[offset + 1]) * 9617 + Int(bytes[offset + 2]) * 1868
            return Double((value + 8192) >> 14)
        }
        let w = width / 6, h = height / 6
        let small = areaResize(gray, width: width, height: height, toWidth: w, toHeight: h)
        let spectrum = transform(small, [Double](repeating: 0, count: small.count), width: w, height: h, inverse: false)
        let amplitude = zip(spectrum.0, spectrum.1).map { log(hypot($0, $1) + 0.000001) }
        let smooth = blur(amplitude, width: w, height: h, kernel: [1 / 3.0, 1 / 3.0, 1 / 3.0])
        var real = [Double](repeating: 0, count: small.count), imaginary = real
        for index in real.indices {
            let magnitude = exp(amplitude[index] - smooth[index])
            let phase = atan2(spectrum.1[index], spectrum.0[index])
            real[index] = magnitude * cos(phase)
            imaginary[index] = magnitude * sin(phase)
        }
        let spatial = transform(real, imaginary, width: w, height: h, inverse: true)
        let power = zip(spatial.0, spatial.1).map { $0 * $0 + $1 * $1 }
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
        let result = resized.map { max(0, (min($0, threshold) - minimum) / threshold) }
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    private func basis(_ count: Int) -> (cosine: [Double], sine: [Double]) {
        if let stored = bases[count] { return stored }
        var cosine = [Double](repeating: 0, count: count * count), sine = cosine
        for row in 0..<count { for column in 0..<count {
            let angle = 2 * Double.pi * Double(row * column) / Double(count)
            cosine[row * count + column] = cos(angle)
            sine[row * count + column] = sin(angle)
        } }
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
        let `is` = multiply(imaginary, x.sine, rows: height, columns: width, inner: width)
        let rs = multiply(real, x.sine, rows: height, columns: width, inner: width)
        let ic = multiply(imaginary, x.cosine, rows: height, columns: width, inner: width)
        let rowReal = zip(rc, `is`).map { $0 - sign * $1 }
        let rowImaginary = zip(rs, ic).map { sign * $0 + $1 }
        let cr = multiply(y.cosine, rowReal, rows: height, columns: width, inner: height)
        let si = multiply(y.sine, rowImaginary, rows: height, columns: width, inner: height)
        let sr = multiply(y.sine, rowReal, rows: height, columns: width, inner: height)
        let ci = multiply(y.cosine, rowImaginary, rows: height, columns: width, inner: height)
        let scale = inverse ? 1 / Double(width * height) : 1
        return (zip(cr, si).map { ($0 - sign * $1) * scale },
                zip(sr, ci).map { (sign * $0 + $1) * scale })
    }

    private func reflected(_ index: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        let folded = (index % period + period) % period
        return folded < count ? folded : period - folded
    }

    private func blur(_ values: [Double], width: Int, height: Int, kernel: [Double]) -> [Double] {
        var horizontal = values, result = values
        let radius = kernel.count / 2
        for y in 0..<height { for x in 0..<width {
            horizontal[y * width + x] = kernel.indices.reduce(0) {
                $0 + kernel[$1] * values[y * width + reflected(x + $1 - radius, count: width)]
            }
        } }
        for y in 0..<height { for x in 0..<width {
            result[y * width + x] = kernel.indices.reduce(0) {
                $0 + kernel[$1] * horizontal[reflected(y + $1 - radius, count: height) * width + x]
            }
        } }
        return result
    }

    private func areaResize(_ values: [Double], width: Int, height: Int,
                            toWidth: Int, toHeight: Int) -> [Double] {
        var result = [Double](repeating: 0, count: toWidth * toHeight)
        let sx = Double(width) / Double(toWidth), sy = Double(height) / Double(toHeight)
        for y in 0..<toHeight { for x in 0..<toWidth {
            let x0 = Double(x) * sx, x1 = Double(x + 1) * sx
            let y0 = Double(y) * sy, y1 = Double(y + 1) * sy
            var sum = 0.0
            for row in Int(floor(y0))..<min(height, Int(ceil(y1))) {
                let wy = max(0, min(y1, Double(row + 1)) - max(y0, Double(row)))
                for column in Int(floor(x0))..<min(width, Int(ceil(x1))) {
                    let wx = max(0, min(x1, Double(column + 1)) - max(x0, Double(column)))
                    sum += values[row * width + column] * wx * wy
                }
            }
            result[y * toWidth + x] = (sum / (sx * sy)).rounded(.toNearestOrEven)
        } }
        return result
    }

    private func linearResize(_ values: [Double], width: Int, height: Int, side: Int) -> [Double] {
        var result = [Double](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side {
            let px = (Double(x) + 0.5) * Double(width) / Double(side) - 0.5
            let py = (Double(y) + 0.5) * Double(height) / Double(side) - 0.5
            let bx = Int(floor(px)), by = Int(floor(py))
            let dx = px - Double(bx), dy = py - Double(by)
            let x0 = max(0, min(width - 1, bx)), x1 = max(0, min(width - 1, bx + 1))
            let y0 = max(0, min(height - 1, by)), y1 = max(0, min(height - 1, by + 1))
            result[y * side + x] = (values[y0 * width + x0] * (1 - dx) + values[y0 * width + x1] * dx) * (1 - dy) +
                (values[y1 * width + x0] * (1 - dx) + values[y1 * width + x1] * dx) * dy
        } }
        return result
    }
}
