import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreML
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

    /// Sequential memory-safe DepthAnythingV2 CoreML loader & inference inside autoreleasepool.
    /// Gracefully returns nil when DepthAnythingV2*.mlmodelc is not bundled so multi-cue monocular depth runs instead.
    func estimateMonocularDepth(image: CIImage, side: Int = 64,
                                cancellation: CompositionAnalysisCancellation) -> [Double]? {
        guard !cancellation.isCancelled,
              side > 4, side <= 128,
              ProcessInfo.processInfo.physicalMemory >= 3_500_000_000,
              ProcessInfo.processInfo.thermalState != .critical,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return nil }
        let candidateNames = ["DepthAnythingV2SmallF16", "DepthAnythingV2Small", "DepthAnythingV2", "DepthAnything"]
        guard let url = candidateNames.compactMap({ Bundle.main.url(forResource: $0, withExtension: "mlmodelc") }).first else {
            return nil
        }
        return autoreleasepool {
            guard !cancellation.isCancelled else { return nil }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
            defer { _ = model }

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
                context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
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
                if let pb = val.imageBufferValue {
                    return maskMap(pb, side: side)
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

    private func readDepthArray(_ array: MLMultiArray, width: Int, height: Int, targetSide: Int) -> [Double] {
        var result = [Double](repeating: 0, count: targetSide * targetSide)
        let rowStride = array.strides.count >= 2 ? array.strides[array.strides.count - 2].intValue : width
        let colStride = array.strides.count >= 1 ? array.strides[array.strides.count - 1].intValue : 1
        let isFloat16 = array.dataType == .float16
        let ptrF32 = isFloat16 ? nil : array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let ptrU16 = isFloat16 ? array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count) : nil

        func float16ToDouble(_ bits: UInt16) -> Double {
            let sign = (bits & 0x8000) != 0 ? -1.0 : 1.0
            let exp = Int((bits >> 10) & 0x1F)
            let mant = Int(bits & 0x03FF)
            if exp == 0 {
                return mant == 0 ? 0.0 : sign * pow(2.0, -14.0) * (Double(mant) / 1024.0)
            } else if exp == 31 {
                return 0.0
            }
            return sign * pow(2.0, Double(exp - 15)) * (1.0 + Double(mant) / 1024.0)
        }

        for y in 0..<targetSide {
            let sy = min(height - 1, y * height / targetSide)
            for x in 0..<targetSide {
                let sx = min(width - 1, x * width / targetSide)
                let offset = sy * rowStride + sx * colStride
                let value: Double
                if let p32 = ptrF32 {
                    value = Double(p32[offset])
                } else if let p16 = ptrU16 {
                    value = float16ToDouble(p16[offset])
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
