import Foundation
import CoreGraphics

/// Upright image coordinates, top-left origin, shared by display and saved media.
enum CaptureViewportGeometry {
    static func crop(focalLength: Double, baseZoom: CGFloat, sourceAspect: CGFloat,
                     outputAspect: CGFloat, center: CGPoint) -> CGRect? {
        guard [focalLength, Double(baseZoom), Double(sourceAspect), Double(outputAspect),
               Double(center.x), Double(center.y)].allSatisfy(\.isFinite),
              focalLength > 0, baseZoom > 0, sourceAspect > 0, outputAspect > 0 else { return nil }
        if focalLength <= 24.5 { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let scale = min(1, 24 * baseZoom / CGFloat(focalLength))
        let width = scale * min(1, outputAspect / sourceAspect)
        let height = scale * min(1, sourceAspect / outputAspect)
        let cx = min(1 - width / 2, max(width / 2, center.x))
        let cy = min(1 - height / 2, max(height / 2, center.y))
        return CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }

    static func draggedCenter(start: CGPoint, translation: CGSize, viewport: CGSize,
                              cropSize: CGSize) -> CGPoint? {
        guard [start.x, start.y, translation.width, translation.height, viewport.width,
               viewport.height, cropSize.width, cropSize.height].allSatisfy(\.isFinite),
              viewport.width > 0, viewport.height > 0,
              (0...1).contains(cropSize.width), (0...1).contains(cropSize.height) else { return nil }
        return CGPoint(x: min(1 - cropSize.width / 2, max(cropSize.width / 2,
                           start.x + translation.width / viewport.width)),
                       y: min(1 - cropSize.height / 2, max(cropSize.height / 2,
                           start.y + translation.height / viewport.height)))
    }

    static func pixels(_ normalized: CGRect, extent: CGRect, bottomLeft: Bool) -> CGRect? {
        guard [extent.minX, extent.minY, extent.width, extent.height, normalized.minX,
               normalized.minY, normalized.width, normalized.height].allSatisfy(\.isFinite),
              extent.width > 0, extent.height > 0, normalized.width > 0, normalized.height > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-8, dy: -1e-8).contains(normalized)
        else { return nil }
        return CGRect(x: extent.minX + normalized.minX * extent.width,
                      y: extent.minY + (bottomLeft ? 1 - normalized.maxY : normalized.minY) * extent.height,
                      width: normalized.width * extent.width, height: normalized.height * extent.height)
    }
}

enum VideoFormatGeometry {
    static func matches(width: Int32, height: Int32, targetWidth: Int32, targetHeight: Int32) -> Bool {
        // AVCaptureMovieFileOutput records the active format. A taller 4:3 sensor
        // format is not a substitute for a selected 16:9 recording format.
        min(width, height) == min(targetWidth, targetHeight) &&
            max(width, height) == max(targetWidth, targetHeight)
    }
}

/// A crop is meaningful only while its optical reference remains unchanged.
enum WindowedCapturePolicy {
    static func controlsLocked(recordingInFlight: Bool, wantsRecording: Bool,
                               photoInFlight: Bool) -> Bool {
        recordingInFlight || wantsRecording || photoInFlight
    }

    static func referenceReady(displayZoom: CGFloat, resetPending: Bool,
                               manualZoomPending: Bool, pinching: Bool) -> Bool {
        displayZoom.isFinite && abs(displayZoom - 1) <= 0.02 &&
            !resetPending && !manualZoomPending && !pinching
    }
}
