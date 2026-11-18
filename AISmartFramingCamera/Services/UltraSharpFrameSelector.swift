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

    /// Đo lường độ sắc nét quang học thực tế bằng C++20 NEON (Center-Weighted Sobel Tenengrad + Laplacian)
    public func evaluateSharpness(of pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        let isBGRA = (pixelFormat == kCVPixelFormatType_32BGRA)
        let isBiPlanar = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                          pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        if isBiPlanar {
            guard let lumaAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0.0 }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = lumaAddress.assumingMemoryBound(to: UInt8.self)
            return noc_us_evaluate_sharpness_luma(ptr, Int32(width), Int32(height), Int32(lumaStride))
        } else if isBGRA {
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0.0 }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            return noc_us_evaluate_sharpness_bgra(ptr, Int32(width), Int32(height), Int32(bytesPerRow))
        } else {
            return 100.0
        }
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
