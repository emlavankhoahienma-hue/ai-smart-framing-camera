import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import simd

/// All image points are normalized, top-left origin, in the upright portrait
/// rear-camera image BEFORE preview aspect-fill. Device axes: right, up, toward user.
public struct TrackingCalibration: Sendable {
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let aspect: Double
    public let isMeasured: Bool

    public init(fx: Double, fy: Double, cx: Double, cy: Double,
                aspect: Double, isMeasured: Bool = true) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.aspect = aspect; self.isMeasured = isMeasured
    }

    public static func fallback(zoom: Double = 1, aspect: Double = 0.75) -> Self {
        let fx = 0.5 / tan(65 * .pi / 360) * max(0.1, zoom)
        return Self(fx: fx, fy: fx * aspect, cx: 0.5, cy: 0.5,
                    aspect: aspect, isMeasured: false)
    }

    public var isValid: Bool {
        [fx, fy, cx, cy, aspect].allSatisfy { $0.isFinite } &&
        fx > 0 && fy > 0 && aspect > 0 && (0...1).contains(cx) && (0...1).contains(cy)
    }

    public func deviceRay(at point: CGPoint) -> SIMD3<Double> {
        simd_normalize(SIMD3((Double(point.x) - cx) / fx,
                             -(Double(point.y) - cy) / fy, -1))
    }

    public func project(deviceRay ray: SIMD3<Double>) -> TrackingProjection {
        let forward = -ray.z
        if forward > 1e-6 {
            let p = CGPoint(x: cx + fx * ray.x / forward,
                            y: cy - fy * ray.y / forward)
            return TrackingProjection(point: p, isInFront: true)
        }
        // Behind the camera, use angular guidance; perspective division would
        // reverse the arrow. Exactly antipodal has no unique shortest direction.
        var dx = atan2(ray.x, forward)
        let dy = -atan2(ray.y, hypot(ray.x, forward))
        if abs(dx) + abs(dy) < 1e-8 { dx = .pi }
        let scale = 2 / max(abs(dx), abs(dy), 1e-8)
        return TrackingProjection(point: CGPoint(x: 0.5 + dx * scale,
                                                  y: 0.5 + dy * scale), isInFront: false)
    }
}

public struct TrackingProjection: Sendable {
    /// Unclamped for front-facing rays; a direction-only point for rear-facing rays.
    public let point: CGPoint
    public let isInFront: Bool
    public var isInsideImage: Bool {
        isInFront && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}

public struct TrackingFrameContext: Sendable {
    /// Capture PTS expressed in the host clock, never Vision completion time.
    public let timestamp: TimeInterval
    public let calibration: TrackingCalibration
    public let orientation: CGImagePropertyOrientation
    public let imageSize: CGSize
    public let displayZoom: Double

    public init(timestamp: TimeInterval, calibration: TrackingCalibration,
                orientation: CGImagePropertyOrientation = .up, imageSize: CGSize = .zero,
                displayZoom: Double = 1.0) {
        self.timestamp = timestamp; self.calibration = calibration
        self.orientation = orientation; self.imageSize = imageSize
        self.displayZoom = displayZoom
    }

    static func read(_ sample: CMSampleBuffer, zoom: Double) -> Self? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let width = Double(CVPixelBufferGetWidth(buffer))
        let height = Double(CVPixelBufferGetHeight(buffer))
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        // The supplied CameraService uses portrait-rotated buffers + .up.
        // Reject another clock domain instead of silently treating arrival as PTS.
        guard width > 0, height >= width, timestamp.isFinite,
              now - timestamp >= -0.05, now - timestamp < 2 else { return nil }
        var k = TrackingCalibration.fallback(zoom: zoom, aspect: width / height)
        if let data = CMGetAttachment(sample,
                    key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                    attachmentModeOut: nil) as? Data,
           data.count == MemoryLayout<simd_float3x3>.size {
            let m = data.withUnsafeBytes { $0.loadUnaligned(as: simd_float3x3.self) }
            let measured = TrackingCalibration(fx: Double(m.columns.0.x) / width,
                 fy: Double(m.columns.1.y) / height, cx: Double(m.columns.2.x) / width,
                 cy: Double(m.columns.2.y) / height, aspect: width / height)
            // Reject an unrotated landscape attachment attached to a rotated
            // portrait image. CameraService must supply matching image geometry.
            if measured.isValid, abs(measured.cx - 0.5) < 0.1, abs(measured.cy - 0.5) < 0.1 {
                k = measured
            }
        }
        return Self(timestamp: timestamp, calibration: k, orientation: .up,
                    imageSize: CGSize(width: width, height: height), displayZoom: zoom)
    }
}

struct TrackingMotionSample: Sendable {
    let timestamp: TimeInterval
    /// Rotation from device coordinates to the CoreMotion reference frame.
    let deviceToWorld: simd_quatd
}

enum TrackingGeometry {
    static func pose(at time: TimeInterval, in history: [TrackingMotionSample]) -> simd_quatd? {
        guard let first = history.first, let last = history.last,
              time >= first.timestamp - 0.02, time <= last.timestamp + 0.02 else { return nil }
        if time <= first.timestamp { return first.deviceToWorld }
        if time >= last.timestamp { return last.deviceToWorld }
        for i in 1..<history.count where history[i].timestamp >= time {
            let a = history[i - 1], b = history[i]
            guard b.timestamp - a.timestamp < 0.1 else { return nil }
            let t = (time - a.timestamp) / (b.timestamp - a.timestamp)
            return simd_slerp(a.deviceToWorld, b.deviceToWorld, t)
        }
        return nil
    }

    static func screenPoint(_ point: CGPoint, size: CGSize, aspect: CGFloat) -> CGPoint {
        let scale = max(size.width / aspect, size.height)
        return CGPoint(x: (point.x - 0.5) * scale * aspect + size.width / 2,
                       y: (point.y - 0.5) * scale + size.height / 2)
    }

    static func bufferPoint(_ point: CGPoint, size: CGSize, aspect: CGFloat) -> CGPoint {
        let scale = max(size.width / aspect, size.height, 1)
        return CGPoint(x: (point.x - size.width / 2) / (scale * aspect) + 0.5,
                       y: (point.y - size.height / 2) / scale + 0.5)
    }

    /// Intersect the center-to-target ray with the inset viewport rectangle.
    /// This function is for presentation only; its result must never be fused.
    static func dock(_ point: CGPoint, size: CGSize, inset: CGFloat = 30) -> CGPoint {
        let halfX = max(1, size.width / 2 - inset), halfY = max(1, size.height / 2 - inset)
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let factor = max(abs(dx) / halfX, abs(dy) / halfY, 1)
        return CGPoint(x: size.width / 2 + dx / factor, y: size.height / 2 + dy / factor)
    }
}
