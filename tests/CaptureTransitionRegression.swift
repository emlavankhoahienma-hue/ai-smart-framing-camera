import Foundation
import CoreGraphics

/// Execute production alignment and recovery policies on the macOS CI runner.
@main
enum CaptureTransitionRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(_ name: String, _ body: () throws -> Void) throws {
        try body()
        passed += 1
        print("PASS: \(name)")
    }

    static func main() throws {
        try run("a stationary aligned target unlocks at every supported delivery rate") {
            for fps in [15.0, 30, 60, 120] {
                var gate = AlignmentCaptureGate()
                var readyAt: Double?
                for i in 0...Int(fps) {
                    let time = Double(i) / fps
                    let distance = 0.009 + 0.006 * abs(sin(2 * .pi * 9.5 * time))
                    if gate.update(time: time, distance: distance, radius: 0.038,
                                   freshEvidence: true) == .ready, readyAt == nil { readyAt = time }
                }
                try require((readyAt ?? .infinity) <= 0.40, "Aligned target remained blocked at \(fps) Hz")
            }
        }
        try run("crossing the target briefly never triggers capture") {
            var gate = AlignmentCaptureGate()
            for i in 0...60 {
                let time = Double(i) / 60
                try require(gate.update(time: time, distance: abs(time - 0.5) * 0.8,
                    radius: 0.038, freshEvidence: true) != .ready, "Fast pass triggered capture")
            }
        }
        try run("predicted alignment without optical evidence never unlocks") {
            var gate = AlignmentCaptureGate()
            for i in 0...300 {
                try require(gate.update(time: Double(i) / 60, distance: 0,
                    radius: 0.038, freshEvidence: false) == .outside, "Prediction became capture evidence")
            }
        }
        try run("one dropped observation pauses a hold instead of stranding it") {
            var gate = AlignmentCaptureGate()
            var ready = false
            for i in 0...30 {
                let state = gate.update(time: Double(i) / 60, distance: 0.01,
                    radius: 0.038, freshEvidence: i != 11)
                ready = ready || state == .ready
            }
            try require(ready, "A single missed observation prevented capture")
        }
        try run("persistent unsafe zoom requests recovery while a transient failure does not") {
            var policy = PostZoomRecoveryPolicy()
            try require(!policy.shouldRestoreOriginal(afterFailedCheckAt: 10), "Restored too early")
            try require(!policy.shouldRestoreOriginal(afterFailedCheckAt: 10.6), "Restored before repeated failures")
            try require(policy.shouldRestoreOriginal(afterFailedCheckAt: 11.3), "Repeated failure stayed stuck")
            policy.reset()
            try require(!policy.shouldRestoreOriginal(afterFailedCheckAt: 20), "New session inherited a failure budget")
            policy.reset()
            try require(!policy.shouldRestoreOriginal(afterFailedCheckAt: 30), "Success did not reset failures")
        }
        try run("recovery requires both actual zoom and a fresh restored image") {
            func restored(hardware: Double = 1, frame: Double = 1,
                          time: Double = 10.2, now: Double = 10.3) -> Bool {
                PostZoomRecoveryPolicy.hasRestoredFrame(originalZoom: 1,
                    hardwareZoom: hardware, frameZoom: frame, frameTime: time,
                    recoveryBegan: 10, now: now)
            }
            try require(!restored(hardware: 2), "Zoom command was mistaken for hardware completion")
            try require(!restored(frame: 2), "Pre-recovery cropped image unlocked shutter")
            try require(!restored(time: 9.9), "Old image unlocked shutter")
            try require(!restored(time: 10.2, now: 11), "Stale image unlocked shutter")
            try require(!restored(time: 11), "Future timestamp unlocked shutter")
            try require(!restored(hardware: .nan), "Invalid hardware sample unlocked shutter")
            try require(restored(), "Fresh restored image failed to recover")
        }
        try run("restored zoom requires a new stable hold before capture") {
            var gate = AlignmentCaptureGate()
            for i in 0...30 {
                _ = gate.update(time: Double(i) / 60, distance: 0, radius: 0.038, freshEvidence: true)
            }
            gate.reset()
            try require(gate.update(time: 3, distance: 0, radius: 0.038,
                freshEvidence: true) == .holding, "Recovery reused the pre-zoom hold")
            var state = AlignmentCaptureGate.State.holding
            for i in 1...20 {
                state = gate.update(time: 3 + Double(i) / 60, distance: 0,
                                    radius: 0.038, freshEvidence: true)
            }
            try require(state == .ready, "Restored target never resumed capture")
        }
        try run("fresh optical evidence is required even if gyro prediction is centered") {
            func locked(time: Double = 10, now: Double = 10.1, point: CGPoint? = CGPoint(x: 0.5, y: 0.5),
                        calibration: Bool = true) -> Bool {
                CaptureReadinessPolicy.hasOpticalLock(timestamp: time, now: now, point: point,
                    calibrationValid: calibration, manualZoomPending: false, settledAt: -.infinity)
            }
            try require(locked(), "Fresh accepted subject failed admission")
            try require(!locked(time: 9), "Stale subject unlocked shutter")
            try require(!locked(time: -.infinity), "A gyro-only target unlocked shutter")
            try require(!locked(time: 11), "Future observation unlocked shutter")
            try require(!locked(time: .nan), "Invalid timestamp unlocked shutter")
            try require(!locked(point: nil), "Missing subject unlocked shutter")
            try require(!locked(point: CGPoint(x: -0.1, y: 0.5)), "Offscreen subject unlocked shutter")
            try require(!locked(point: CGPoint(x: CGFloat.nan, y: 0.5)), "Invalid point unlocked shutter")
            try require(!locked(calibration: false), "Invalid intrinsics unlocked shutter")
        }
        try run("manual zoom requires an observation after hardware settles") {
            func locked(time: Double, pending: Bool = false) -> Bool {
                CaptureReadinessPolicy.hasOpticalLock(timestamp: time, now: 10.3,
                    point: CGPoint(x: 0.5, y: 0.5), calibrationValid: true,
                    manualZoomPending: pending, settledAt: 10)
            }
            try require(!locked(time: 10.2, pending: true), "Gesture unlocked shutter")
            try require(!locked(time: 10.01), "Pre-settle observation unlocked shutter")
            try require(locked(time: 10.2), "Post-settle observation failed admission")
        }
        try run("zoom verification cannot synthesize evidence after a timer") {
            func settled(hardware: Double = 2, frame: Double = 2, image: Double = 10.2,
                         optical: Double = 10.2, now: Double = 10.3) -> Bool {
                CaptureReadinessPolicy.hasSettledZoom(target: 2, hardware: hardware, frameZoom: frame,
                    frameTimestamp: image, opticalTimestamp: optical, reachedAt: 10, now: now)
            }
            try require(settled(), "Measured settled zoom was blocked")
            try require(!settled(hardware: 1), "Zoom command was treated as actual zoom")
            try require(!settled(frame: 1), "Wrong lens frame verified zoom")
            try require(!settled(image: 9.9), "Old camera frame verified zoom")
            try require(!settled(optical: 9.9), "Old tracking sample verified zoom")
            try require(!settled(optical: -.infinity, now: 12), "Elapsed time fabricated optical evidence")
            try require(!settled(image: 10.2, now: 11), "Stale frame verified zoom")
            try require(!settled(frame: .nan), "Invalid frame zoom verified zoom")
        }
        try run("capture protects the measured subject without rejecting original edge contact") {
            try require(CaptureReadinessPolicy.preservesSubject(CGRect(x: 0, y: 0, width: 1, height: 1)),
                        "Original edge contact was stranded")
            try require(CaptureReadinessPolicy.preservesSubject(CGRect(x: -0.001, y: 0.2, width: 0.3, height: 0.5)),
                        "Subpixel noise blocked capture")
            try require(!CaptureReadinessPolicy.preservesSubject(CGRect(x: -0.1, y: 0.2, width: 0.3, height: 0.5)),
                        "Cropped subject authorized capture")
            try require(!CaptureReadinessPolicy.preservesSubject(nil), "Missing subject extent authorized capture")
            try require(!CaptureReadinessPolicy.preservesSubject(.zero), "Zero area authorized capture")
            try require(!CaptureReadinessPolicy.preservesSubject(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)),
                        "Invalid extent authorized capture")
        }
        try run("no-zoom alignment reaches capture with real accepted optical observations") {
            var gate = AlignmentCaptureGate()
            var ready = false
            for i in 0...30 {
                let now = 20 + Double(i) / 60
                let fresh = CaptureReadinessPolicy.hasOpticalLock(timestamp: now - 0.025, now: now,
                    point: CGPoint(x: 0.35, y: 0.4), calibrationValid: true,
                    manualZoomPending: false, settledAt: -.infinity)
                ready = gate.update(time: now, distance: 0.005, radius: 0.038, freshEvidence: fresh) == .ready
            }
            try require(ready, "No-zoom path remained stuck with valid observations")
        }
        try run("zoom path reacquires real evidence and a new hold before capture") {
            var gate = AlignmentCaptureGate()
            for i in 0...30 {
                _ = gate.update(time: 20 + Double(i) / 60, distance: 0, radius: 0.038, freshEvidence: true)
            }
            gate.reset()
            try require(!CaptureReadinessPolicy.hasSettledZoom(target: 2, hardware: 2, frameZoom: 1,
                frameTimestamp: 21.1, opticalTimestamp: 20.5, reachedAt: 21, now: 21.2), "Ramp reused old evidence")
            try require(CaptureReadinessPolicy.hasSettledZoom(target: 2, hardware: 2, frameZoom: 2,
                frameTimestamp: 21.2, opticalTimestamp: 21.19, reachedAt: 21, now: 21.25), "Zoom never verified")
            try require(gate.update(time: 21.25, distance: 0.005, radius: 0.038, freshEvidence: true) == .holding,
                        "Zoom reused the old hold")
            var ready = false
            for i in 1...30 {
                ready = gate.update(time: 21.25 + Double(i) / 60, distance: 0.005,
                                    radius: 0.038, freshEvidence: true) == .ready
            }
            try require(ready, "Verified zoom never reached capture")
        }
        print("Capture transition regressions: \(passed) passed")
    }
}
