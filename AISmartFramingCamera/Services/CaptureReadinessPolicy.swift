import Foundation
import CoreGraphics

/// Admission uses capture timestamps, never completion time or gyro prediction.
enum CaptureReadinessPolicy {
    static func isFresh(_ timestamp: TimeInterval, now: TimeInterval) -> Bool {
        timestamp.isFinite && now.isFinite && (0...0.45).contains(now - timestamp)
    }

    static func hasOpticalLock(timestamp: TimeInterval, now: TimeInterval,
                               point: CGPoint?, calibrationValid: Bool,
                               manualZoomPending: Bool, settledAt: TimeInterval) -> Bool {
        guard !manualZoomPending, calibrationValid, isFresh(timestamp, now: now),
              settledAt == -.infinity || (settledAt.isFinite && timestamp > settledAt + 0.05),
              let point, point.x.isFinite, point.y.isFinite else { return false }
        return (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    static func hasSettledZoom(target: Double, hardware: Double, frameZoom: Double,
                               frameTimestamp: TimeInterval, opticalTimestamp: TimeInterval,
                               reachedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard [target, hardware, frameZoom, reachedAt].allSatisfy(\.isFinite),
              target > 0, hardware > 0, frameZoom > 0,
              abs(target - hardware) <= 0.08, abs(target - frameZoom) <= 0.08,
              isFresh(frameTimestamp, now: now), isFresh(opticalTimestamp, now: now) else { return false }
        return frameTimestamp > reachedAt + 0.05 && opticalTimestamp > reachedAt + 0.05 &&
            opticalTimestamp <= frameTimestamp + 0.05
    }

    static func preservesSubject(_ bounds: CGRect?) -> Bool {
        guard let bounds,
              [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return false }
        let visible = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull else { return false }
        // Tolerate subpixel tracking noise and existing edge contact. Never
        // authorize a crop that loses a meaningful portion of the protected ROI.
        return visible.width * visible.height / (bounds.width * bounds.height) >= 0.98
    }
}
