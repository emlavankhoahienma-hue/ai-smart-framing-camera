import Foundation
import Vision
import CoreVideo
import CoreGraphics
import QuartzCore
import simd

/// Optional short-baseline image registration candidate, not metric odometry
/// and not object identity. The fusion path deliberately does not promote a
/// whole-image homography to a .locked target observation.
public final class VisualOdometryEngine: @unchecked Sendable {
    public static let shared = VisualOdometryEngine()
    private let lock = NSLock()
    private var reference: (buffer: CVPixelBuffer, point: CGPoint, time: TimeInterval)?
    private var generation: UInt64 = 0
    private init() {}

    public func setReferenceFrame(_ buffer: CVPixelBuffer, atUIPoint point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lock.withLock {
            generation &+= 1
            reference = (buffer, point, CACurrentMediaTime())
        }
    }

    public func hasReference() -> Bool { lock.withLock { reference != nil } }
    public func clearReference() { lock.withLock { generation &+= 1; reference = nil } }

    public func estimateCurrentUIPoint(currentBuffer: CVPixelBuffer) -> CGPoint? {
        let snapshot = lock.withLock { (reference, generation) }
        guard let reference = snapshot.0, CACurrentMediaTime() - reference.time < 0.25 else { return nil }
        // Floating image = saved image; reference image = current handler image.
        // Vision's transform maps floating image pixels into reference pixels.
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: reference.buffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: currentBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let observation = request.results?.first,
              observation.confidence >= 0.5 else { return nil }
        let matrix = observation.warpTransform
        guard abs(simd_determinant(matrix)) > 1e-8 else { return nil }
        let width = Float(CVPixelBufferGetWidth(reference.buffer))
        let height = Float(CVPixelBufferGetHeight(reference.buffer))
        let p = SIMD3(Float(reference.point.x) * width, Float(1 - reference.point.y) * height, 1)
        let q = matrix * p
        guard q.x.isFinite, q.y.isFinite, q.z.isFinite, abs(q.z) > 1e-6 else { return nil }
        let result = CGPoint(x: CGFloat(q.x / q.z) / CGFloat(CVPixelBufferGetWidth(currentBuffer)),
                             y: 1 - CGFloat(q.y / q.z) / CGFloat(CVPixelBufferGetHeight(currentBuffer)))
        guard (-0.25...1.25).contains(result.x), (-0.25...1.25).contains(result.y),
              lock.withLock({ generation == snapshot.1 }) else { return nil }
        return result
    }
}
