import CoreVideo
import CoreGraphics
import SwiftUI

public final class RealtimeHistogramEngine: @unchecked Sendable {
    public static let shared = RealtimeHistogramEngine()
    
    private var smoothedHeights: [CGFloat] = Array(repeating: 0.08, count: 32)
    
    // Palette chuẩn phổ màu như máy ảnh cao cấp (Xanh lam bóng tối -> Lục/Vàng vùng trung -> Cam/Đỏ vùng sáng gắt)
    private let barColors: [Color] = {
        var colors: [Color] = []
        for i in 0..<32 {
            let t = Double(i) / 31.0
            if t < 0.28 {
                // Shadows: Xanh lam sâu & Cyan
                let subT = t / 0.28
                colors.append(Color(red: 0.15 + 0.10 * subT, green: 0.35 + 0.45 * subT, blue: 0.92 + 0.08 * subT))
            } else if t < 0.72 {
                // Midtones: Lục bạc / Vàng chanh / Trắng sáng
                let subT = (t - 0.28) / 0.44
                if subT < 0.5 {
                    colors.append(Color(red: 0.25 + 0.55 * subT, green: 0.80 + 0.20 * subT, blue: 0.80 - 0.40 * subT))
                } else {
                    colors.append(Color(red: 0.80 + 0.20 * (subT - 0.5) * 2.0, green: 0.95 - 0.10 * (subT - 0.5) * 2.0, blue: 0.40 - 0.25 * (subT - 0.5) * 2.0))
                }
            } else {
                // Highlights: Cam ấm & Đỏ rực
                let subT = (t - 0.72) / 0.28
                colors.append(Color(red: 0.95 + 0.05 * subT, green: 0.60 - 0.45 * subT, blue: 0.15 - 0.10 * subT))
            }
        }
        return colors
    }()
    
    private init() {}
    
    public func computeHistogram(from pixelBuffer: CVPixelBuffer) -> [HistogramBarData] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return fallbackBars()
        }
        
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        var bins = Array(repeating: Float(0), count: 32)
        var maxBin: Float = 1.0
        
        // Lấy mẫu nhanh 120x90 điểm ảnh (Subsampling) -> CPU < 0.3%
        let stepX = max(2, width / 96)
        let stepY = max(2, height / 72)
        
        for y in stride(from: 0, to: height, by: stepY) {
            let rowOffset = y * bytesPerRow
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = rowOffset + x * 4
                let b = Float(data[offset])
                let g = Float(data[offset + 1])
                let r = Float(data[offset + 2])
                
                // Độ sáng theo chuẩn Rec.709
                let lum = r * 0.2126 + g * 0.7152 + b * 0.0722
                let binIndex = min(31, max(0, Int(lum / 8.0)))
                bins[binIndex] += 1
            }
        }
        
        for count in bins {
            if count > maxBin { maxBin = count }
        }
        
        var result: [HistogramBarData] = []
        for i in 0..<32 {
            let rawNormalized = CGFloat(bins[i] / maxBin)
            // Khử rung và làm mượt chuyển động (Exponential Moving Average)
            let smoothed = smoothedHeights[i] * 0.40 + rawNormalized * 0.60
            smoothedHeights[i] = smoothed
            
            result.append(HistogramBarData(
                id: i,
                height: max(0.06, min(1.0, smoothed)),
                color: barColors[i]
            ))
        }
        return result
    }
    
    private func fallbackBars() -> [HistogramBarData] {
        return (0..<32).map { i in
            HistogramBarData(id: i, height: 0.08, color: barColors[i])
        }
    }
}
