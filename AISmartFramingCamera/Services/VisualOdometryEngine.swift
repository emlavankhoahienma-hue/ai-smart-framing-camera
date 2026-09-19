import Foundation
import Vision
import CoreVideo
import CoreGraphics
import simd

/// Định vị chuyển động camera (xoay + dịch chuyển) bằng cách so sánh trực tiếp 
/// nội dung hình ảnh giữa khung hình mốc (lúc còn bám tốt) và khung hình hiện 
/// tại — không cần ARKit, không cần IMU đo vị trí.
public final class VisualOdometryEngine: @unchecked Sendable {
    public static let shared = VisualOdometryEngine()

    private let stateLock = NSLock()
    private var referenceBuffer: CVPixelBuffer?
    private var referencePointVisionSpace: CGPoint?
    
    private init() {}
    
    /// Lưu lại khung hình mốc mới + điểm target tương ứng (hệ tọa độ UI: gốc trên-trái)
    public func setReferenceFrame(_ buffer: CVPixelBuffer, atUIPoint uiPoint: CGPoint) {
        stateLock.lock()
        referenceBuffer = buffer
        // Vision dùng hệ gốc dưới-trái, cần lật trục Y để khớp chuẩn Vision
        referencePointVisionSpace = CGPoint(x: uiPoint.x, y: 1.0 - uiPoint.y)
        stateLock.unlock()
    }
    
    public func hasReference() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return referenceBuffer != nil
    }
    
    public func clearReference() {
        stateLock.lock()
        referenceBuffer = nil
        referencePointVisionSpace = nil
        stateLock.unlock()
    }
    
    /// Ước lượng vị trí hiện tại của target dựa trên biến đổi hình ảnh thật 
    /// giữa khung hình mốc và khung hình hiện tại. Trả về nil nếu không tính 
    /// được (chưa có khung mốc, hoặc ảnh quá khác biệt để so khớp).
    public func estimateCurrentUIPoint(currentBuffer: CVPixelBuffer) -> CGPoint? {
        // Chụp snapshot dưới lock rồi nhả ngay; Vision registration có thể tốn vài
        // ms và không được phép chặn start/stop/reset của tracking session.
        stateLock.lock()
        let refBuffer = referenceBuffer
        let refPoint = referencePointVisionSpace
        stateLock.unlock()
        guard let refBuffer, let refPoint else {
            return nil
        }
        
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: currentBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: refBuffer, options: [:])
        
        do {
            try handler.perform([request])
            guard let result = request.results?.first as? VNImageHomographicAlignmentObservation else {
                return nil
            }
            
            let warp = result.warpTransform
            let homogeneous = simd_float3(Float(refPoint.x), Float(refPoint.y), 1.0)
            let transformed = warp * homogeneous
            
            guard abs(transformed.z) > 0.0001 else { return nil }
            
            let visionResultX = CGFloat(transformed.x / transformed.z)
            let visionResultY = CGFloat(transformed.y / transformed.z)
            
            // Loại kết quả vô lý (ra ngoài khung hình quá xa - homography lỗi/không khớp được)
            guard visionResultX > -0.5 && visionResultX < 1.5 && visionResultY > -0.5 && visionResultY < 1.5 else {
                return nil
            }
            
            // Chuyển ngược lại hệ UI (gốc trên-trái)
            return CGPoint(x: visionResultX, y: 1.0 - visionResultY)
        } catch {
            CameraLogger.info("VisualOdometryEngine lỗi: \(error.localizedDescription)", category: .tracking)
            return nil
        }
    }
}
