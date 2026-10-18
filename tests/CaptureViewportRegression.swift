import Foundation
import CoreGraphics

@main
enum CaptureViewportRegression {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
        checks += 1
    }

    static func main() throws {
        let aspects: [CGFloat] = [3.0 / 4, 9.0 / 16, 1]
        for source in aspects {
            for target in aspects {
                for focal in [28.0, 35, 50, 85, 135] {
                    for center in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] {
                        guard let crop = CaptureViewportGeometry.crop(focalLength: focal, baseZoom: 1,
                            sourceAspect: source, outputAspect: target, center: center) else { throw Failure(message: "Valid crop rejected") }
                        try check(abs(crop.width * source / crop.height - target) < 1e-8, "Wrong physical aspect")
                        try check(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -1e-8, dy: -1e-8).contains(crop), "Crop escapes source")
                        let extent = CGRect(x: 17, y: -23, width: 1920 * source, height: 1920)
                        let top = CaptureViewportGeometry.pixels(crop, extent: extent, bottomLeft: false)!
                        let bottom = CaptureViewportGeometry.pixels(crop, extent: extent, bottomLeft: true)!
                        try check(abs(top.minY + bottom.maxY - 2 * extent.minY - extent.height) < 1e-8, "Y conversion mirrored the wrong edge")
                    }
                }
            }
        }
        let start = CGPoint(x: 0.4, y: 0.7), viewport = CGSize(width: 300, height: 400)
        let size = CGSize(width: 0.5, height: 0.5)
        try check(CaptureViewportGeometry.draggedCenter(start: start, translation: .zero,
            viewport: viewport, cropSize: size) == start, "Touching a corner recenters the window")
        let dragged = CaptureViewportGeometry.draggedCenter(start: start, translation: CGSize(width: 30, height: -40),
            viewport: viewport, cropSize: size)!
        try check(abs(dragged.x - 0.5) < 1e-8 && abs(dragged.y - 0.6) < 1e-8, "Drag translation changed coordinate origin")
        try check(CaptureViewportGeometry.draggedCenter(start: start, translation: .zero,
            viewport: .zero, cropSize: size) == nil, "Empty viewport divided by zero")
        try check(CaptureViewportGeometry.crop(focalLength: .nan, baseZoom: 1, sourceAspect: 0.75,
            outputAspect: 1, center: start) == nil, "NaN crop accepted")
        try check(!VideoFormatGeometry.matches(width: 4032, height: 3024, targetWidth: 3840, targetHeight: 2160), "4:3 sensor admitted as 4K video")
        try check(VideoFormatGeometry.matches(width: 1920, height: 1080, targetWidth: 1920, targetHeight: 1080), "1080p rejected")
        try check(VideoFormatGeometry.matches(width: 2160, height: 3840, targetWidth: 3840, targetHeight: 2160), "Portrait 4K rejected")
        try check(WindowedCapturePolicy.referenceReady(displayZoom: 1, resetPending: false,
            manualZoomPending: false, pinching: false), "Stable wide reference cannot capture")
        try check(!WindowedCapturePolicy.referenceReady(displayZoom: 2, resetPending: false,
            manualZoomPending: false, pinching: false), "Telephoto accepted as the wide crop reference")
        try check(!WindowedCapturePolicy.referenceReady(displayZoom: 1, resetPending: true,
            manualZoomPending: false, pinching: false), "Stale 1x feedback bypassed reset acknowledgement")
        try check(!WindowedCapturePolicy.referenceReady(displayZoom: 1, resetPending: false,
            manualZoomPending: true, pinching: false), "Queued zoom can change optics after the crop snapshot")
        try check(!WindowedCapturePolicy.referenceReady(displayZoom: 1, resetPending: false,
            manualZoomPending: false, pinching: true), "A moving pinch can change the captured crop reference")
        try check(!WindowedCapturePolicy.referenceReady(displayZoom: .nan, resetPending: false,
            manualZoomPending: false, pinching: false), "Nonfinite crop reference accepted")
        let captureTransitions: [(String, Bool, Bool, Bool, Bool)] = [
            ("Idle", false, false, false, false),
            ("Record request before hardware callback", false, true, false, true),
            ("Starting or recording", true, true, false, true),
            ("Stop requested before file finishes", true, false, false, true),
            ("Photo exposure and processing", false, false, true, true),
            ("Capture completed", false, false, false, false)
        ]
        for (phase, recording, wantsRecording, photo, expected) in captureTransitions {
            try check(WindowedCapturePolicy.controlsLocked(recordingInFlight: recording,
                wantsRecording: wantsRecording, photoInFlight: photo) == expected,
                "Window edit admission changed during \(phase)")
        }
        print("Capture viewport regressions: \(checks) assertions passed")
    }
}
