import Foundation

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
        try run("focus is requested once per target and zoom and never re-armed by per-frame alignment updates") {
            var policy = AutoFocusCapturePolicy()
            try require(policy.needsRequest(pinGeneration: 3, zoom: 1), "first aligned frame skipped focus")
            policy.markRequested(pinGeneration: 3, zoom: 1, at: 10)
            for _ in 1...120 {
                try require(!policy.needsRequest(pinGeneration: 3, zoom: 1), "a per-frame update re-armed focus")
            }
            try require(policy.needsRequest(pinGeneration: 4, zoom: 1), "a new target skipped focus")
            try require(policy.needsRequest(pinGeneration: 3, zoom: 2), "a zoom change skipped focus")
            try require(!policy.needsRequest(pinGeneration: 3, zoom: 1.05), "zoom jitter refocused")
            try require(!policy.needsRequest(pinGeneration: 3, zoom: .nan), "invalid zoom requested focus")
        }
        try run("capture waits for the lens but never longer than the timeout") {
            var policy = AutoFocusCapturePolicy()
            policy.markRequested(pinGeneration: 1, zoom: 1, at: 10)
            try require(!policy.isReadyForCapture(now: 10.05, lensSettled: true), "captured before the focus command took effect")
            try require(!policy.isReadyForCapture(now: 10.4, lensSettled: false), "captured while the lens was still hunting")
            try require(policy.isReadyForCapture(now: 10.2, lensSettled: true), "a settled lens still blocked capture")
            try require(policy.isReadyForCapture(now: 10.95, lensSettled: false), "a lens that never settles blocked capture forever")
            try require(!policy.isReadyForCapture(now: .nan, lensSettled: true), "an invalid clock authorized capture")
        }
        try run("aligned frames at camera rate reach capture quickly after autofocus") {
            for fps in [30.0, 60.0] {
                var policy = AutoFocusCapturePolicy()
                var captureAt: Double?
                let settledFrame = Int(fps * 0.2)
                for i in 0...Int(fps * 3) {
                    let time = 20 + Double(i) / fps
                    if policy.needsRequest(pinGeneration: 1, zoom: 1) {
                        policy.markRequested(pinGeneration: 1, zoom: 1, at: time)
                    }
                    if captureAt == nil, policy.isReadyForCapture(now: time, lensSettled: i >= settledFrame) {
                        captureAt = time
                    }
                }
                try require((captureAt ?? .infinity) - 20 <= 0.35, "capture starved at \(fps) fps")
            }
        }
        print("Capture transition regressions: \(passed) passed")
    }
}
