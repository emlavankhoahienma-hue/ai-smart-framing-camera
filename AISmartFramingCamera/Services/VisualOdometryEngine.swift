import Foundation
import Vision
import CoreVideo
import CoreGraphics
import QuartzCore
import simd

/// Một phép đo image-registration kèm độ tin cậy hình học để EKF có thể gán
/// covariance đúng, thay vì coi mọi homography là ground truth.
public struct VisualOdometryMeasurement: Sendable {
    public let point: CGPoint
    public let confidence: Double
    public let localScale: CGFloat
    public let referenceAge: TimeInterval
}

/// Visual odometry nhẹ dùng homographic registration của Vision làm cầu nối khi
/// object tracker/KLT mất 1-15 frame. Tất cả tác vụ nặng phải được gọi từ
/// `VisionFramingEngine.visionQueue`; class này không bao giờ tự chặn MainActor.
public final class VisualOdometryEngine: @unchecked Sendable {
    public static let shared = VisualOdometryEngine()

    private let stateLock = NSLock()
    private var referenceBuffer: CVPixelBuffer?
    private var referencePointVisionSpace: CGPoint?
    private var referenceTimestamp: CFTimeInterval = 0

    private init() {}

    /// Lưu frame keyframe và điểm target cùng thời điểm. CVPixelBuffer được ARC
    /// retain; capture pool sẽ không tái sử dụng vùng nhớ cho đến khi keyframe đổi.
    public func setReferenceFrame(_ buffer: CVPixelBuffer, atUIPoint uiPoint: CGPoint) {
        stateLock.lock()
        referenceBuffer = buffer
        referencePointVisionSpace = CGPoint(x: uiPoint.x, y: 1.0 - uiPoint.y)
        referenceTimestamp = CACurrentMediaTime()
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
        referenceTimestamp = 0
        stateLock.unlock()
    }

    /// Giữ API cũ cho caller hiện hữu.
    public func estimateCurrentUIPoint(currentBuffer: CVPixelBuffer) -> CGPoint? {
        estimateMeasurement(currentBuffer: currentBuffer, expectedUIPoint: nil)?.point
    }

    /// Ước lượng vị trí và tự kiểm tra homography bằng scale, perspective, độ dịch
    /// và consistency với prediction. Homography lỗi thường vẫn trả một ma trận
    /// hữu hạn; các invariant này ngăn nó teleport mỏ neo.
    public func estimateMeasurement(
        currentBuffer: CVPixelBuffer,
        expectedUIPoint: CGPoint?
    ) -> VisualOdometryMeasurement? {
        stateLock.lock()
        let refBuffer = referenceBuffer
        let refPoint = referencePointVisionSpace
        let refTime = referenceTimestamp
        stateLock.unlock()

        guard let refBuffer, let refPoint, refBuffer !== currentBuffer else { return nil }

        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: currentBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: refBuffer, options: [:])

        do {
            try handler.perform([request])
            guard let result = request.results?.first as? VNImageHomographicAlignmentObservation else {
                return nil
            }

            let h = result.warpTransform
            guard h.columns.0.x.isFinite, h.columns.0.y.isFinite, h.columns.0.z.isFinite,
                  h.columns.1.x.isFinite, h.columns.1.y.isFinite, h.columns.1.z.isFinite,
                  h.columns.2.x.isFinite, h.columns.2.y.isFinite, h.columns.2.z.isFinite else {
                return nil
            }

            // Determinant của Jacobian affine xấp xỉ diện tích scale^2. Những giá
            // trị ngoài [0.55, 1.80] trong một keyframe ngắn là registration sai.
            let affineDeterminant = h.columns.0.x * h.columns.1.y - h.columns.1.x * h.columns.0.y
            let localScale = sqrt(abs(CGFloat(affineDeterminant)))
            guard localScale > 0.55, localScale < 1.80 else { return nil }

            let perspectiveEnergy = abs(Double(h.columns.0.z)) + abs(Double(h.columns.1.z))
            guard perspectiveEnergy < 0.80 else { return nil }

            guard let transformed = transform(refPoint, by: h),
                  transformed.x > -0.35, transformed.x < 1.35,
                  transformed.y > -0.35, transformed.y < 1.35 else {
                return nil
            }

            let uiPoint = CGPoint(x: transformed.x, y: 1.0 - transformed.y)
            let age = max(0, CACurrentMediaTime() - refTime)
            let displacement = expectedUIPoint.map { hypot(uiPoint.x - $0.x, uiPoint.y - $0.y) } ?? 0
            guard displacement < 0.20 else { return nil }

            let scalePenalty = min(1.0, abs(log(Double(localScale))) / log(1.8))
            let agePenalty = min(0.55, age * 0.20)
            let motionPenalty = min(0.65, Double(displacement) * 3.0)
            let confidence = max(0.22, min(0.68, 0.68 - 0.22 * scalePenalty - agePenalty - motionPenalty))
            return VisualOdometryMeasurement(
                point: uiPoint,
                confidence: confidence,
                localScale: localScale,
                referenceAge: age
            )
        } catch {
            CameraLogger.info("VisualOdometryEngine lỗi: \(error.localizedDescription)", category: .tracking)
            return nil
        }
    }

    /// Nhân điểm homogeneous `q = H p` và chia phối cảnh. Đây là phép chiếu vật
    /// lý từ keyframe sang frame hiện tại trong hệ Vision (gốc dưới-trái).
    private func transform(_ point: CGPoint, by matrix: simd_float3x3) -> CGPoint? {
        let homogeneous = SIMD3<Float>(Float(point.x), Float(point.y), 1)
        let q = matrix * homogeneous
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, abs(q.z) > 1.0e-5 else { return nil }
        return CGPoint(x: CGFloat(q.x / q.z), y: CGFloat(q.y / q.z))
    }
}
