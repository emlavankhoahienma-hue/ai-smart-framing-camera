//
//  UltraSharpFrameSelector.swift
//  AISmartFramingCamera
//
//  Bộ chọn Frame tham chiếu (Reference Frame Selector) và Loại bỏ Frame Mờ Nhòe (Blur Rejection)
//  Thuật toán: Năng lượng Gradient & Phương sai Laplacian (Variance of Laplacian) trên Luma hạ cấp
//

import Foundation
import CoreVideo
import CoreGraphics
import Accelerate

public final class UltraSharpFrameSelector: UltraSharpFrameSelectorProtocol, Sendable {
    public static let shared = UltraSharpFrameSelector()

    public init() {}

    /// Đo lường độ sắc nét thực tế của một frame CVPixelBuffer thông qua phương sai toán tử Laplacian
    public func evaluateSharpness(of pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Lấy mẫu nhanh trên lưới cách đều (stride 4x4) để tính toán dưới 1ms
        let step = 4
        var sumLaplacian: Double = 0.0
        var sumLaplacianSq: Double = 0.0
        var sampleCount: Double = 0.0

        let isBGRA = (pixelFormat == kCVPixelFormatType_32BGRA)
        let isBiPlanar = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        if isBiPlanar {
            // Đọc trực tiếp Plane 0 (Y Luma)
            guard let lumaAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0.0 }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = lumaAddress.assumingMemoryBound(to: UInt8.self)

            for y in stride(from: step, to: height - step, by: step) {
                let row = y * lumaStride
                let rowUp = (y - 1) * lumaStride
                let rowDown = (y + 1) * lumaStride

                for x in stride(from: step, to: width - step, by: step) {
                    let center = Double(ptr[row + x])
                    let left   = Double(ptr[row + x - 1])
                    let right  = Double(ptr[row + x + 1])
                    let up     = Double(ptr[rowUp + x])
                    let down   = Double(ptr[rowDown + x])

                    // Discrete Laplacian 2D: L = 4*Center - Left - Right - Up - Down
                    let lap = 4.0 * center - left - right - up - down
                    sumLaplacian += lap
                    sumLaplacianSq += lap * lap
                    sampleCount += 1.0
                }
            }
        } else if isBGRA {
            // Lấy mẫu kênh Green làm xấp xỉ Luma nhanh (Rec.709: Green chiếm 71.5% độ sáng)
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in stride(from: step, to: height - step, by: step) {
                let row = y * bytesPerRow
                let rowUp = (y - 1) * bytesPerRow
                let rowDown = (y + 1) * bytesPerRow

                for x in stride(from: step, to: width - step, by: step) {
                    let center = Double(ptr[row + x * 4 + 1])
                    let left   = Double(ptr[row + (x - 1) * 4 + 1])
                    let right  = Double(ptr[row + (x + 1) * 4 + 1])
                    let up     = Double(ptr[rowUp + x * 4 + 1])
                    let down   = Double(ptr[rowDown + x * 4 + 1])

                    let lap = 4.0 * center - left - right - up - down
                    sumLaplacian += lap
                    sumLaplacianSq += lap * lap
                    sampleCount += 1.0
                }
            }
        } else {
            return 100.0 // Mặc định an toàn cho các định dạng không xác định
        }

        guard sampleCount > 10.0 else { return 0.0 }
        let mean = sumLaplacian / sampleCount
        let variance = (sumLaplacianSq / sampleCount) - (mean * mean)
        return Float(max(0.0, variance))
    }

    /// Chọn frame nét nhất làm tham chiếu và loại bỏ các frame rung nhòe kém hơn thresholdRatio (~60%)
    public func selectReferenceFrame(
        from frames: [UltraSharpFrame],
        sharpnessThresholdRatio: Float = 0.60
    ) -> (reference: UltraSharpFrame, validCandidates: [UltraSharpFrame]) {
        guard !frames.isEmpty else {
            fatalError("selectReferenceFrame: Danh sách frame trống!")
        }

        if frames.count == 1 {
            return (frames[0], frames)
        }

        // Đánh giá điểm nét cho từng frame (nếu chưa có điểm tính sẵn)
        var scoredFrames = frames.map { frame -> UltraSharpFrame in
            if frame.sharpnessScore > 0.0 {
                return frame
            }
            let score = self.evaluateSharpness(of: frame.pixelBuffer)
            return UltraSharpFrame(
                index: frame.index,
                pixelBuffer: frame.pixelBuffer,
                timestamp: frame.timestamp,
                iso: frame.iso,
                exposureDuration: frame.exposureDuration,
                sharpnessScore: score,
                metadata: frame.metadata
            )
        }

        // Tìm frame có điểm nét cao nhất
        scoredFrames.sort { $0.sharpnessScore > $1.sharpnessScore }
        let reference = scoredFrames[0]
        let maxScore = reference.sharpnessScore

        let minAcceptableScore = maxScore * max(0.20, min(0.95, sharpnessThresholdRatio))

        // Lọc các frame có độ nét đạt chuẩn
        let validCandidates = scoredFrames.filter { $0.sharpnessScore >= minAcceptableScore }

        return (reference, validCandidates)
    }
}
