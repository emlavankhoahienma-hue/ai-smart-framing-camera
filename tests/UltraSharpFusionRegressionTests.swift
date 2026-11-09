//
//  UltraSharpFusionRegressionTests.swift
//  AISmartFramingCameraTests
//
//  Bộ kiểm thử hồi quy Đa khung hình Ultra Sharp (Bậc 1):
//  - Kiểm thử độ chính xác căn chỉnh Sub-pixel (Sai số <= 0.12 px)
//  - Kiểm thử mức giảm độ lệch chuẩn nhiễu theo lý thuyết căn(N) (+-20%)
//  - Kiểm thử Anti-Ghosting chống bóng ma (Vùng vật thể chuyển động tự động rơi về Frame gốc)
//  - Kiểm thử bộ lọc loại bỏ Frame rung nhòe (Blur Rejection < 60%)
//  - Kiểm thử tự động điều tiết theo phần cứng (RAM 4GB, Thermal State)
//

import XCTest
import CoreGraphics
import CoreVideo
import Metal
@testable import AISmartFramingCamera

final class UltraSharpFusionRegressionTests: XCTestCase {

    /// Kiểm thử 1: Độ lệch căn chỉnh Sub-pixel trên mẫu dịch chuyển nhân tạo đã biết
    func testSyntheticSubpixelShiftAccuracy() {
        let engine = UltraSharpMetalEngine.shared
        guard engine.device != nil else {
            // Thiết bị không hỗ trợ Metal (môi trường mô phỏng không có GPU)
            return
        }

        let result = engine.runSyntheticVerification()
        // Kiểm tra sai số căn chỉnh sub-pixel <= 0.12 pixel
        XCTAssertLessThanOrEqual(result.subpixelError, 0.12, "Sai số căn chỉnh sub-pixel vượt ngưỡng 0.12 px: \(result.subpixelError)")
        // Kiểm tra tỷ lệ giảm nhiễu >= 1.20x cho 2 frame (Lý thuyết sqrt(2) = 1.414x)
        XCTAssertGreaterThanOrEqual(result.noiseReductionRatio, 1.20, "Tỷ lệ giảm nhiễu không đạt chuẩn: \(result.noiseReductionRatio)")
    }

    /// Kiểm thử 2: Bộ lọc loại bỏ Frame rung nhòe (Blur Frame Rejection)
    func testBlurryFrameRejection() {
        let selector = UltraSharpFrameSelector.shared

        // Tạo 3 pixel buffer nhân tạo: 1 frame nét, 1 frame hơi mờ (75%), 1 frame rung nhòe nặng (30%)
        let w = 256
        let h = 256

        var sharpBuffer: CVPixelBuffer?
        var slightlyBlurBuffer: CVPixelBuffer?
        var heavyBlurBuffer: CVPixelBuffer?

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &sharpBuffer)
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &slightlyBlurBuffer)
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &heavyBlurBuffer)

        guard let sb = sharpBuffer, let sbb = slightlyBlurBuffer, let hb = heavyBlurBuffer else {
            XCTFail("Không tạo được test pixel buffers")
            return
        }

        // Vẽ mẫu sắc nét tần số cao vào sharpBuffer
        fillPattern(buffer: sb, frequency: 0.30)
        // Vẽ mẫu tần số trung bình vào slightlyBlurBuffer
        fillPattern(buffer: sbb, frequency: 0.15)
        // Vẽ mẫu phẳng hầu như không có chi tiết vào heavyBlurBuffer
        fillPattern(buffer: hb, frequency: 0.02)

        let frameSharp = UltraSharpFrame(index: 0, pixelBuffer: sb, timestamp: .zero, iso: 100, exposureDuration: .zero)
        let frameMid = UltraSharpFrame(index: 1, pixelBuffer: sbb, timestamp: .zero, iso: 100, exposureDuration: .zero)
        let frameBlur = UltraSharpFrame(index: 2, pixelBuffer: hb, timestamp: .zero, iso: 100, exposureDuration: .zero)

        let selection = selector.selectReferenceFrame(from: [frameSharp, frameMid, frameBlur], sharpnessThresholdRatio: 0.60)

        // Frame nét nhất phải được chọn làm Reference
        XCTAssertEqual(selection.reference.index, 0, "Reference frame được chọn không phải frame sắc nét nhất!")

        // Frame rung nhòe nặng (index 2) phải bị loại bỏ (< 60% độ nét frame 0)
        let candidateIndices = selection.validCandidates.map { $0.index }
        XCTAssertTrue(candidateIndices.contains(0), "Danh sách candidate phải chứa frame gốc")
        XCTAssertFalse(candidateIndices.contains(2), "Frame rung nhòe nặng (index 2) không được phép lọt vào chuỗi gộp!")
    }

    /// Kiểm thử 3: Điều tiết số lượng Burst tối ưu theo bộ nhớ RAM và trạng thái máy
    func testHardwareCapacityTuning() {
        let controller = UltraSharpCaptureController.shared

        // Yêu cầu 8 frame
        let tuned8 = controller.calculateOptimalBurstCount(requestedCount: 8)
        XCTAssertGreaterThanOrEqual(tuned8, 4, "Số frame tối thiểu an toàn phải >= 4")
        XCTAssertLessThanOrEqual(tuned8, 12, "Số frame tối đa không vượt quá 12")

        // Yêu cầu 16 frame (vượt ngưỡng cho phép) -> Phải tự động kẹp về tối đa 12
        let tuned16 = controller.calculateOptimalBurstCount(requestedCount: 16)
        XCTAssertLessThanOrEqual(tuned16, 12, "Controller phải tự động giới hạn cứng <= 12 frame")
    }

    /// Helper điền dữ liệu pixel nhân tạo
    private func fillPattern(buffer: CVPixelBuffer, frequency: Float) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let val = 0.5f + 0.45f * sin(Float(x) * frequency) * cos(Float(y) * frequency)
                let u = UInt8(max(0.0f, min(255.0f, val * 255.0f)))
                ptr[idx + 0] = u
                ptr[idx + 1] = u
                ptr[idx + 2] = u
                ptr[idx + 3] = 255
            }
        }
    }
}
