import Foundation
import CoreGraphics

/// Presentation of the optical field of view, driven only by camera feedback.
/// This type neither predicts zoom completion nor changes tracking/capture state.
struct ZoomRevealGeometry {
    let startZoom: CGFloat
    let targetZoom: CGFloat

    init?(startZoom: CGFloat, targetZoom: CGFloat) {
        guard startZoom.isFinite, targetZoom.isFinite, startZoom > 0, targetZoom > 0,
              abs(log(Double(targetZoom)) - log(Double(startZoom))) > 0.000001 else { return nil }
        self.startZoom = startZoom
        self.targetZoom = targetZoom
    }

    var isZoomingOut: Bool { targetZoom < startZoom }

    func normalizedRect(actualZoom: CGFloat) -> CGRect? {
        guard actualZoom.isFinite, actualZoom > 0 else { return nil }
        // Zoom in: outline the final photograph inside the current optical view.
        // Zoom out: outline the original field as more surroundings become visible.
        // Unseen surroundings cannot be previewed before the lens widens.
        let scale = min(1, actualZoom / (isZoomingOut ? startZoom : targetZoom))
        guard scale.isFinite, scale > 0 else { return nil }
        return CGRect(x: (1 - scale) / 2, y: (1 - scale) / 2, width: scale, height: scale)
    }

    static func screenRect(_ rect: CGRect, size: CGSize, bufferAspect: CGFloat) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, bufferAspect.isFinite, bufferAspect > 0 else { return nil }
        let a = TrackingGeometry.screenPoint(rect.origin, size: size, aspect: bufferAspect)
        let b = TrackingGeometry.screenPoint(CGPoint(x: rect.maxX, y: rect.maxY), size: size, aspect: bufferAspect)
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

enum ViewfinderGuideGeometry {
    /// Leave clear space around the fixed ring and the moving target dot.
    static func segment(from: CGPoint, to: CGPoint) -> (start: CGPoint, end: CGPoint)? {
        guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite else { return nil }
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 32 else { return nil }
        return (CGPoint(x: from.x + dx * 21 / length, y: from.y + dy * 21 / length),
                CGPoint(x: to.x - dx * 10 / length, y: to.y - dy * 10 / length))
    }
}
