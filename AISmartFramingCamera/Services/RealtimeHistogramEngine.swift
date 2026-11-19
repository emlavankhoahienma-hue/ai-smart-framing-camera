import CoreVideo
import CoreGraphics
import SwiftUI

/// Động cơ tính toán Histogram quang phổ thực tế Rec.709 (Luma + R/G/B 48 bins) + Đo nhiễu cảm biến thực (Spatial Noise & ISO)
/// Tối ưu CPU: Fixed-point integer BT.709 matrix, làm mượt đỉnh P96 chống giật biên độ, tái sử dụng bộ đệm nội bộ.
public final class RealtimeHistogramEngine: @unchecked Sendable {
    public static let shared = RealtimeHistogramEngine()

    private static let binCount = HistogramTelemetry.binCount // 48 bins

    private let stateLock = NSLock()
    private var smoothedLuma: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedRed: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedGreen: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedBlue: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedRefPeak: Float = 0.0
    private var lastTelemetry: HistogramTelemetry = .neutral

    // Bộ đệm tạm tái sử dụng (giảm áp lực heap khi chạy ~15 Hz)
    private var rawLuma = [Int32](repeating: 0, count: binCount)
    private var rawRed = [Int32](repeating: 0, count: binCount)
    private var rawGreen = [Int32](repeating: 0, count: binCount)
    private var rawBlue = [Int32](repeating: 0, count: binCount)
    private var scratchNorm = [Float](repeating: 0, count: binCount)
    private var scratchSorted = [Float](repeating: 0, count: binCount)

    private var _averageLuminance: Float = 0.5
    private var _highlightClipRatio: Float = 0.0
    private var _shadowClipRatio: Float = 0.0
    private var _noiseLevel: Float = 0.0
    private var _sensorISO: Float = 0.0

    /// Độ sáng trung bình chuẩn hóa (0.0 = tối hoàn toàn, 1.0 = sáng trắng hoàn toàn)
    public var averageLuminance: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _averageLuminance
    }

    /// Tỷ lệ điểm ảnh vùng cháy sáng (Y >= 248/255)
    public var highlightClipRatio: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _highlightClipRatio
    }

    /// Tỷ lệ điểm ảnh vùng bết tối (Y <= 5/255)
    public var shadowClipRatio: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _shadowClipRatio
    }

    /// Mức nhiễu cảm biến chuẩn hóa (0.0 = sạch, 1.0 = nhiễu rất cao)
    public var noiseLevel: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _noiseLevel
    }

    private init() {}

    /// Giữ nguyên chữ ký công khai cho mọi caller cũ (và hợp đồng kiểm thử)
    public func computeTelemetry(from pixelBuffer: CVPixelBuffer) -> HistogramTelemetry {
        computeTelemetry(from: pixelBuffer, sensorISO: 0)
    }

    /// Tính toán toàn bộ dữ liệu quang phổ thực tế Rec.709 (Luma + R/G/B + Clipping + EV + Nhiễu thực)
    public func computeTelemetry(from pixelBuffer: CVPixelBuffer, sensorISO: Float) -> HistogramTelemetry {
        let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isBGRA = (formatType == kCVPixelFormatType_32BGRA)
        let isBiPlanarFull = (formatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isBiPlanarVideo = (formatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        guard isBGRA || isBiPlanarFull || isBiPlanarVideo,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            stateLock.lock()
            let fallback = lastTelemetry
            stateLock.unlock()
            return fallback
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        stateLock.lock()
        defer { stateLock.unlock() }

        for i in 0..<Self.binCount {
            rawLuma[i] = 0
            rawRed[i] = 0
            rawGreen[i] = 0
            rawBlue[i] = 0
        }

        var totalLum: Int64 = 0
        var shadowClipCount: Int32 = 0
        var highlightClipCount: Int32 = 0
        var sampleCount: Int32 = 0
        var flatNoiseSum: Int64 = 0
        var flatNoiseSamples: Int32 = 0

        if isBGRA {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
                  width > 1, height > 0, bytesPerRow >= width * 4 else {
                return lastTelemetry
            }
            let data = baseAddress.assumingMemoryBound(to: UInt8.self)
            let stepX = max(2, width / 80)
            let stepY = max(2, height / 60)

            var y = 0
            while y < height {
                let rowOffset = y * bytesPerRow
                var x = 0
                while x < width {
                    let offset = rowOffset + x * 4
                    let b = Int32(data[offset])
                    let g = Int32(data[offset + 1])
                    let r = Int32(data[offset + 2])
                    // BT.709 Luma fixed-point: 0.2126*256=54, 0.7152*256=183, 0.0722*256=19 (sum=256)
                    let lum = (r * 54 + g * 183 + b * 19) >> 8

                    totalLum += Int64(lum)
                    sampleCount += 1
                    if lum <= 5 { shadowClipCount += 1 }
                    else if lum >= 248 { highlightClipCount += 1 }

                    // Đo nhiễu hạt thật trên cặp điểm ảnh liền kề thuộc vùng phẳng (bỏ qua cạnh cấu trúc > 24)
                    if x + 1 < width && lum < 220 {
                        let offR = offset + 4
                        let lumR = (Int32(data[offR + 2]) * 54 + Int32(data[offR + 1]) * 183 + Int32(data[offR]) * 19) >> 8
                        let diff = abs(lum - lumR)
                        if diff <= 24 {
                            flatNoiseSum += Int64(diff)
                            flatNoiseSamples += 1
                        }
                    }

                    rawLuma[Int((lum * 48) >> 8)] += 1
                    rawRed[Int((r * 48) >> 8)] += 1
                    rawGreen[Int((g * 48) >> 8)] += 1
                    rawBlue[Int((b * 48) >> 8)] += 1

                    x += stepX
                }
                y += stepY
            }
        } else {
            let lumaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let lumaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let lumaBPR = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let chromaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let chromaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let chromaBPR = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

            guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                  lumaW > 1, lumaH > 0, lumaBPR >= lumaW else {
                return lastTelemetry
            }
            let lumaPlane = lumaBase.assumingMemoryBound(to: UInt8.self)
            let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
            let hasValidChroma = (chromaPlane != nil && chromaW > 0 && chromaH > 0 && chromaBPR >= chromaW * 2)

            let stepX = max(2, lumaW / 80)
            let stepY = max(2, lumaH / 60)

            var y = 0
            while y < lumaH {
                let lumaRow = y * lumaBPR
                let cy = min(chromaH - 1, y >> 1)
                let chromaRow = cy * chromaBPR

                var x = 0
                while x < lumaW {
                    let rawY = Int32(lumaPlane[lumaRow + x])
                    let lum: Int32
                    if isBiPlanarVideo {
                        let scaled = ((rawY - 16) * 298) >> 8
                        lum = scaled < 0 ? 0 : (scaled > 255 ? 255 : scaled)
                    } else {
                        lum = rawY
                    }

                    // Đo nhiễu hạt thật trên kênh Y liền kề ở vùng phẳng (chi phí ~0 ms)
                    if x + 1 < lumaW && lum < 220 {
                        let rawYR = Int32(lumaPlane[lumaRow + x + 1])
                        let diff = abs(rawY - rawYR)
                        if diff <= 24 {
                            flatNoiseSum += Int64(diff)
                            flatNoiseSamples += 1
                        }
                    }

                    let r: Int32
                    let g: Int32
                    let b: Int32
                    if hasValidChroma, let uv = chromaPlane {
                        let cx = min(chromaW - 1, x >> 1)
                        let uvIdx = chromaRow + (cx << 1)
                        let cb = Int32(uv[uvIdx]) - 128
                        let cr = Int32(uv[uvIdx + 1]) - 128

                        if isBiPlanarVideo {
                            // Studio-range BT.709 YCbCr -> Full-range RGB
                            let rr = lum + ((459 * cr) >> 8)
                            let gg = lum - ((55 * cb + 136 * cr) >> 8)
                            let bb = lum + ((541 * cb) >> 8)
                            r = rr < 0 ? 0 : (rr > 255 ? 255 : rr)
                            g = gg < 0 ? 0 : (gg > 255 ? 255 : gg)
                            b = bb < 0 ? 0 : (bb > 255 ? 255 : bb)
                        } else {
                            // Full-range BT.709 YCbCr -> Full-range RGB
                            let rr = lum + ((403 * cr) >> 8)
                            let gg = lum - ((48 * cb + 120 * cr) >> 8)
                            let bb = lum + ((475 * cb) >> 8)
                            r = rr < 0 ? 0 : (rr > 255 ? 255 : rr)
                            g = gg < 0 ? 0 : (gg > 255 ? 255 : gg)
                            b = bb < 0 ? 0 : (bb > 255 ? 255 : bb)
                        }
                    } else {
                        r = lum; g = lum; b = lum
                    }

                    totalLum += Int64(lum)
                    sampleCount += 1
                    if lum <= 5 { shadowClipCount += 1 }
                    else if lum >= 248 { highlightClipCount += 1 }

                    rawLuma[Int((lum * 48) >> 8)] += 1
                    rawRed[Int((r * 48) >> 8)] += 1
                    rawGreen[Int((g * 48) >> 8)] += 1
                    rawBlue[Int((b * 48) >> 8)] += 1

                    x += stepX
                }
                y += stepY
            }
        }

        guard sampleCount > 0 else { return lastTelemetry }

        let invSamples = 1.0 / Float(sampleCount)
        let rawAvg = (Float(totalLum) * invSamples) / 255.0
        let rawHighlightClip = Float(highlightClipCount) * invSamples
        let rawShadowClip = Float(shadowClipCount) * invSamples

        let meanFlatDiff = flatNoiseSamples > 0 ? Float(flatNoiseSum) / Float(flatNoiseSamples) : 0.0
        // Ảnh đủ sáng sạch thường có độ lệch điểm ảnh liền kề ~0.8..2.2; thiếu sáng ISO cao tăng lên 4.5..9.0+
        let spatialNoise = min(1.0, max(0.0, (meanFlatDiff - 1.2) / 6.8))
        let validISO = sensorISO.isFinite && sensorISO > 0 ? sensorISO : 0.0
        let rawNoise: Float
        if validISO > 0 {
            let isoNorm = min(1.0, max(0.0, log2f(max(1.0, validISO / 200.0)) / 3.8))
            rawNoise = min(1.0, 0.56 * spatialNoise + 0.44 * isoNorm)
            _sensorISO = _sensorISO > 0 ? (_sensorISO * 0.78 + validISO * 0.22) : validISO
        } else {
            rawNoise = spatialNoise
        }

        _averageLuminance = _averageLuminance * 0.84 + rawAvg * 0.16
        _highlightClipRatio = _highlightClipRatio * 0.78 + rawHighlightClip * 0.22
        _shadowClipRatio = _shadowClipRatio * 0.78 + rawShadowClip * 0.22
        _noiseLevel = _noiseLevel * 0.82 + rawNoise * 0.18

        // Độ lệch phơi sáng thực theo stop so với xám chuẩn 18% (middle gray)
        let evRaw = log2f(max(0.015, _averageLuminance) / 0.18) * 0.65
        let clampedEV = max(-3.0, min(3.0, evRaw))

        // Làm mượt đỉnh tham chiếu P96 theo thời gian: triệt tiêu hiện tượng toàn bộ biểu đồ bật lên/tụt xuống giật cục
        let instantRefPeak = max(
            robustPeak(rawLuma),
            max(robustPeak(rawRed), max(robustPeak(rawGreen), robustPeak(rawBlue)))
        )
        if smoothedRefPeak <= 1.0 {
            smoothedRefPeak = instantRefPeak
        } else {
            let peakAlpha: Float = instantRefPeak > smoothedRefPeak ? 0.18 : 0.12
            smoothedRefPeak = smoothedRefPeak * (1.0 - peakAlpha) + instantRefPeak * peakAlpha
        }

        normalizeAndSmooth(raw: rawLuma, refPeak: smoothedRefPeak, target: &smoothedLuma)
        normalizeAndSmooth(raw: rawRed, refPeak: smoothedRefPeak, target: &smoothedRed)
        normalizeAndSmooth(raw: rawGreen, refPeak: smoothedRefPeak, target: &smoothedGreen)
        normalizeAndSmooth(raw: rawBlue, refPeak: smoothedRefPeak, target: &smoothedBlue)

        let telemetry = HistogramTelemetry(
            luma: smoothedLuma,
            red: smoothedRed,
            green: smoothedGreen,
            blue: smoothedBlue,
            shadowClipRatio: _shadowClipRatio,
            highlightClipRatio: _highlightClipRatio,
            averageLuminance: _averageLuminance,
            evOffset: clampedEV,
            noiseLevel: _noiseLevel,
            sensorISO: _sensorISO
        )
        lastTelemetry = telemetry
        return telemetry
    }

    /// Chuẩn hóa mạnh chống bẹt dải midtone: phối P96 với 0.42*max để 1 mảng tường trắng/đen không đè xẹp phần còn lại
    private func robustPeak(_ bins: [Int32]) -> Float {
        var maxVal: Float = 1.0
        for i in 0..<Self.binCount {
            let v = Float(bins[i])
            scratchSorted[i] = v
            if v > maxVal { maxVal = v }
        }
        scratchSorted.sort()
        let p96 = scratchSorted[Self.binCount - 3] // ~96th percentile
        return max(1.0, max(p96 * 1.15, maxVal * 0.42))
    }

    private func normalizeAndSmooth(raw: [Int32], refPeak: Float, target: inout [Float]) {
        let invPeak = 1.0 / max(1.0, refPeak)
        for i in 0..<Self.binCount {
            let linear = min(1.0, Float(raw[i]) * invPeak)
            // Nâng nhẹ dải midtone để biểu đồ rõ chi tiết như scope máy ảnh chuyên nghiệp
            scratchNorm[i] = powf(linear, 0.72)
        }
        // Lọc không gian 5 điểm dịu [0.08, 0.22, 0.40, 0.22, 0.08] + EMA êm triệt tiêu cà giật nhưng vẫn bám sát ánh sáng thật
        for i in 0..<Self.binCount {
            let b0 = scratchNorm[max(0, i - 2)]
            let b1 = scratchNorm[max(0, i - 1)]
            let b2 = scratchNorm[i]
            let b3 = scratchNorm[min(Self.binCount - 1, i + 1)]
            let b4 = scratchNorm[min(Self.binCount - 1, i + 2)]
            let spatial = b0 * 0.08 + b1 * 0.22 + b2 * 0.40 + b3 * 0.22 + b4 * 0.08

            let current = target[i]
            let alpha: Float = spatial > current ? 0.24 : 0.16
            let next = current * (1.0 - alpha) + spatial * alpha
            target[i] = max(0.02, min(1.0, next))
        }
    }

    /// Giữ tương thích ngược cho các lời gọi cũ cần mảng 32 cột
    public func computeHistogram(from pixelBuffer: CVPixelBuffer) -> [HistogramBarData] {
        let telemetry = computeTelemetry(from: pixelBuffer)
        return (0..<32).map { i in
            let srcIdx = min(telemetry.luma.count - 1, Int(Float(i) * Float(telemetry.luma.count - 1) / 31.0))
            return HistogramBarData(id: i, height: CGFloat(telemetry.luma[srcIdx]), color: .white)
        }
    }
}
