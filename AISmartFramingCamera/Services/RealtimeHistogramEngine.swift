import CoreVideo
import CoreGraphics
import SwiftUI

/// Động cơ tính toán Histogram quang phổ thực tế Rec.709 (Luma + R/G/B 48 bins)
/// Tối ưu CPU: Fixed-point integer BT.709 matrix, tái sử dụng bộ đệm nội bộ, không cấp phát rác theo từng frame.
public final class RealtimeHistogramEngine: @unchecked Sendable {
    public static let shared = RealtimeHistogramEngine()

    private static let binCount = HistogramTelemetry.binCount // 48 bins

    private let stateLock = NSLock()
    private var smoothedLuma: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedRed: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedGreen: [Float] = Array(repeating: 0.06, count: binCount)
    private var smoothedBlue: [Float] = Array(repeating: 0.06, count: binCount)
    private var lastTelemetry: HistogramTelemetry = .neutral

    // Bộ đệm tạm tái sử dụng (giảm áp lực heap khi chạy 10–12 Hz)
    private var rawLuma = [Int32](repeating: 0, count: binCount)
    private var rawRed = [Int32](repeating: 0, count: binCount)
    private var rawGreen = [Int32](repeating: 0, count: binCount)
    private var rawBlue = [Int32](repeating: 0, count: binCount)
    private var scratchNorm = [Float](repeating: 0, count: binCount)
    private var scratchSorted = [Float](repeating: 0, count: binCount)

    private var _averageLuminance: Float = 0.5
    private var _highlightClipRatio: Float = 0.0
    private var _shadowClipRatio: Float = 0.0

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

    private init() {}

    /// Tính toán toàn bộ dữ liệu quang phổ thực tế Rec.709 (Luma + R/G/B + Clipping + EV Offset)
    public func computeTelemetry(from pixelBuffer: CVPixelBuffer) -> HistogramTelemetry {
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

        if isBGRA {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
                  width > 0, height > 0, bytesPerRow >= width * 4 else {
                return lastTelemetry
            }
            let data = baseAddress.assumingMemoryBound(to: UInt8.self)
            let stepX = max(2, width / 96)
            let stepY = max(2, height / 72)

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
                  lumaW > 0, lumaH > 0, lumaBPR >= lumaW else {
                return lastTelemetry
            }
            let lumaPlane = lumaBase.assumingMemoryBound(to: UInt8.self)
            let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
            let hasValidChroma = (chromaPlane != nil && chromaW > 0 && chromaH > 0 && chromaBPR >= chromaW * 2)

            let stepX = max(2, lumaW / 96)
            let stepY = max(2, lumaH / 72)

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

        _averageLuminance = _averageLuminance * 0.78 + rawAvg * 0.22
        _highlightClipRatio = _highlightClipRatio * 0.72 + rawHighlightClip * 0.28
        _shadowClipRatio = _shadowClipRatio * 0.72 + rawShadowClip * 0.28

        // Độ lệch phơi sáng thực theo stop so với xám chuẩn 18% (middle gray)
        let evRaw = log2f(max(0.015, _averageLuminance) / 0.18) * 0.65
        let clampedEV = max(-3.0, min(3.0, evRaw))

        // Chuẩn hóa cùng một thang tham chiếu P96 giữa 4 kênh để giữ đúng tỉ lệ tương đối giữa R, G, B và Luma
        let refPeak = max(
            robustPeak(rawLuma),
            max(robustPeak(rawRed), max(robustPeak(rawGreen), robustPeak(rawBlue)))
        )

        normalizeAndSmooth(raw: rawLuma, refPeak: refPeak, target: &smoothedLuma)
        normalizeAndSmooth(raw: rawRed, refPeak: refPeak, target: &smoothedRed)
        normalizeAndSmooth(raw: rawGreen, refPeak: refPeak, target: &smoothedGreen)
        normalizeAndSmooth(raw: rawBlue, refPeak: refPeak, target: &smoothedBlue)

        let telemetry = HistogramTelemetry(
            luma: smoothedLuma,
            red: smoothedRed,
            green: smoothedGreen,
            blue: smoothedBlue,
            shadowClipRatio: _shadowClipRatio,
            highlightClipRatio: _highlightClipRatio,
            averageLuminance: _averageLuminance,
            evOffset: clampedEV
        )
        lastTelemetry = telemetry
        return telemetry
    }

    /// Chuẩn hóa mạnh chống bẹt dải midtone: phối P96 với 0.35*max để 1 mảng tường trắng/đen không đè xẹp phần còn lại
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
        // Lọc không gian 3 điểm [0.18, 0.64, 0.18] + 1 lớp EMA bất đối xứng duy nhất
        for i in 0..<Self.binCount {
            let prevBin = i > 0 ? scratchNorm[i - 1] : scratchNorm[i]
            let currBin = scratchNorm[i]
            let nextBin = i + 1 < Self.binCount ? scratchNorm[i + 1] : scratchNorm[i]
            let spatial = prevBin * 0.18 + currBin * 0.64 + nextBin * 0.18

            let current = target[i]
            let alpha: Float = spatial > current ? 0.42 : 0.24
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
