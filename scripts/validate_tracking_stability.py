"""Deterministic reference scenarios + source contracts, NOT Swift/device execution.

Native capture-gate and image tests live in tests/CameraCaptureRegressionTests.swift
and require an Apple SDK. These reference checks do not execute Swift.
"""
from pathlib import Path
import json
import math
import unittest
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'AISmartFramingCamera'
SPATIAL = (SRC / 'Services/SpatialTrackingEngine.swift').read_text(encoding='utf-8')
VM = (SRC / 'ViewModels/CameraViewModel.swift').read_text(encoding='utf-8')
VISION = (SRC / 'Services/VisionFramingEngine.swift').read_text(encoding='utf-8')
OVERLAY = (SRC / 'Views/ARFramingOverlayView.swift').read_text(encoding='utf-8')
MOTION = (SRC / 'Services/DeviceMotionService.swift').read_text(encoding='utf-8')
COMPOSITION = (SRC / 'Services/CompositionCalculator.swift').read_text(encoding='utf-8')
FX = .5 / math.tan(math.radians(32.5))
FY = FX * .75
METRICS = {}

def ray(point):
    r = np.array([(point[0] - .5) / FX, - (point[1] - .5) / FY, -1.])
    return r / np.linalg.norm(r)

def project(r):
    return np.array([.5 + FX * r[0] / -r[2], .5 - FY * r[1] / -r[2]])

def angle(a, b):
    return math.atan2(np.linalg.norm(np.cross(a, b)), np.dot(a, b))

class Innovation:
    def __init__(self):
        self.candidate = None
        self.time = -math.inf
        self.count = 0

    def accepts(self, observed, predicted, timestamp, evidence='geometry'):
        immediate = (.012 if evidence == 'geometry' else .020) / FX
        if evidence == 'reidentified' or angle(observed, predicted) <= immediate:
            self.__init__()
            return True
        consistent = (self.candidate is not None and 0 < timestamp - self.time <= .20
                      and angle(self.candidate, observed) <= .035 / FX)
        self.count = self.count + 1 if consistent else 1
        self.candidate, self.time = observed, timestamp
        return self.count >= 3

def update(world, point, dt, gate, timestamp, evidence='geometry'):
    observed = ray(point)
    if not gate.accepts(observed, world, timestamp, evidence):
        return world
    if evidence == 'reidentified':
        return observed
    residual = np.linalg.norm(point - project(world))
    cutoff = .7 + min(6, residual * 40)
    ordinary = (1 - math.exp(-2 * math.pi * cutoff * min(.05, dt))) * .9
    weight = max(.45, 1 / (1 + (residual / .20) ** 2))
    fraction = min(1, max(0, (residual - .02) / .08))
    motion = fraction * fraction * (3 - 2 * fraction) * (.50 if evidence == 'geometry' else .65)
    nominal = max(ordinary * weight * (.70 if evidence == 'geometry' else 1), motion)
    speed = 1.1 if evidence == 'geometry' else 1.6
    gain = min(nominal, min(.035, speed * min(.05, dt)) / max(1e-12, residual), 1)
    result = world * (1 - gain) + observed * gain
    return result / np.linalg.norm(result)

class StabilityTests(unittest.TestCase):
    def test_single_frame_outlier_has_zero_correction(self):
        for evidence in ['geometry', 'verified', 'confirmed']:
            gate = Innovation()
            original = ray([.5, .5])
            for i in range(100):
                wrong = update(original, [.72, .48], 1/30, gate, i / 15, evidence)
                np.testing.assert_array_equal(wrong, original)
                update(original, [.5, .5], 1/30, gate, i / 15 + 1/30, evidence)

    def test_two_frame_burst_duplicate_and_gap_cannot_confirm(self):
        gate = Innovation()
        a, b = ray([.5, .5]), ray([.72, .5])
        for t in [1, 1, 1.03, 1.5, 1.53, 2]:
            self.assertFalse(gate.accepts(b, a, t))

    def test_persistent_translation_converges_at_multiple_frame_rates(self):
        for fps in [15, 30, 60]:
            gate = Innovation()
            world = ray([.5, .5])
            trajectory = [.5]
            for i in range(1, fps * 3 + 1):
                world = update(world, [.7, .5], 1/fps, gate, i/fps)
                trajectory.append(project(world)[0])
            self.assertLess(abs(trajectory[-1] - .7), .006)
            self.assertLessEqual(max(np.diff(trajectory)), min(.035, 1.1 * min(.05, 1/fps)) * 1.03)
            METRICS[f'translation_final_error_{fps}fps'] = float(abs(trajectory[-1] - .7))

    def test_static_noise_is_attenuated(self):
        rng = np.random.default_rng(226)
        gate, world = Innovation(), ray([.5, .5])
        raw, output = [], []
        for i in range(1800):
            p = np.array([.5, .5]) + rng.normal(0, .003, 2)
            world = update(world, p, 1/30, gate, i/30)
            raw.append(p); output.append(project(world))
        ratio = np.var(output[100:]) / np.var(raw[100:])
        METRICS['static_noise_variance_ratio_reference_only'] = float(ratio)
        self.assertLess(ratio, .20)

    def test_reidentification_display_is_bounded_and_reaches_target(self):
        # Slerp around the shortest bearing arc, as in TrackingBearingSlew.
        start, found = ray([.5, .5]), ray([.9, .1])
        total = angle(start, found)
        progressed = 0
        for _ in range(180):
            old = progressed
            progressed = min(total, progressed + .90 / 60 / FX)
            self.assertLessEqual(progressed - old, .90 / 60 / FX + 1e-12)
        self.assertEqual(progressed, total)
        self.assertIn('let reticleRay = subjectWorldRay ?? worldRay', SPATIAL)
        self.assertIn('TrackingBearingSlew.advance(from: $0, to: reticleRay', SPATIAL)
        self.assertIn('imagePose.inverse.act(rendered)', SPATIAL)

    def test_tremor_and_400_degree_pan_do_not_modify_world_anchor(self):
        original = ray([.65, .35])
        for rate in [0, 200, 400]:
            for t in np.arange(0, 3, 1/60):
                yaw = math.radians(rate) * t + .003 * math.sin(2 * math.pi * 9.5 * t)
                c, s = math.cos(yaw), math.sin(yaw)
                pose = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
                np.testing.assert_allclose(pose @ (pose.T @ original), original, atol=1e-12)
        self.assertNotIn('worldRay = nil', SPATIAL.split('private func publish()', 1)[1].split('public func stopTracking', 1)[0])

    def test_capture_never_uses_rejected_or_predicted_measurement(self):
        handler = VM.split('private func handleVisualTargetTracked', 1)[1].split('private var hasFreshOpticalLock', 1)[0]
        self.assertLess(handler.index('lastAcceptedOpticalTimestamp == measurement.frame.timestamp'),
                        handler.index('latestOpticalFrameTimestamp = measurement.frame.timestamp'))
        countdown = VM.split('private func startAutoCaptureCountdown', 1)[1].split('private func verifyZoomAfterRamp', 1)[0]
        for required in ['self.hasFreshOpticalLock',
                         '!self.zoomAwaitingVerification && self.zoomVerified',
                         'self.targetPinGeneration == pinGeneration']:
            self.assertIn(required, countdown)
        self.assertNotIn('trackingQuality != .lost', countdown)

    def test_plan_survives_pin_and_pending_zoom_is_retried_before_capture(self):
        pin = VM.split('private func pinTargetAndStartMotion', 1)[1].split('private func handleVisualTargetTracked', 1)[0]
        self.assertIn('if source == nil {', pin)
        self.assertNotIn('self.pendingSuggestedZoom = 3.0', pin)
        evaluate = VM.split('private func evaluateAlignment', 1)[1].split('private func startAutoCaptureCountdown', 1)[0]
        self.assertIn('if isAutoZoomEnabled && !hasExecutedAutoZoomForSession {', evaluate)
        self.assertLess(evaluate.index('applyAISuggestedZoom'), evaluate.index('startAutoCaptureCountdown'))
        self.assertIn('autoCaptureTask == nil', evaluate)
        self.assertIn('!hasExecutedAutoZoomForSession', evaluate)
        self.assertNotIn('([1.0, 2.0, 3.0, currentZoom] + availableOptions)', COMPOSITION)

    def test_zoom_timeout_cannot_become_verified(self):
        verify = VM.split('private func verifyZoomAfterRamp', 1)[1].split('private func verifyPostZoomFaces', 1)[0]
        timeout = verify.split('// A timeout is not proof', 1)[1]
        self.assertIn('zoomVerified = false', timeout)
        self.assertNotIn('zoomVerified = true', timeout)
        self.assertIn('pendingTargetZoomForReveal', verify)
        self.assertIn('guard await verifyPostZoomFaces', verify)

    def test_manual_zoom_cancels_both_delayed_ramp_and_shutter(self):
        manual = VM.split('private func prioritizeManualZoom()', 1)[1].split('public func setZoom', 1)[0]
        self.assertIn('cancelAIZoomForGesture()', manual)
        cancel = VM.split('public func cancelAIZoomForGesture()', 1)[1].split('private func setupCallbacks', 1)[0]
        for required in ['targetPinGeneration &+= 1', 'autoCaptureTask?.cancel()',
                         'zoomVerificationTask?.cancel()', 'cameraService.cancelZoomRamp()']:
            self.assertIn(required, cancel)

    def test_status_label_cannot_shift_reticle(self):
        ring = OVERLAY.split('struct TargetCircleView:', 1)[1].split('// MARK: - Guidance Ray', 1)[0]
        self.assertNotIn('VStack', ring.split('var body:', 1)[1].split('// Status is outside layout.', 1)[0])
        self.assertIn('.frame(width: 36, height: 36)', ring)
        self.assertIn('.overlay(alignment: .top)', ring)
        self.assertNotIn('Chạm để đặt lại mục tiêu', ring)

    def test_stream_epoch_and_appearance_ownership(self):
        self.assertIn('guard self.streamGeneration == epoch else', MOTION)
        self.assertNotIn('NeuralTargetTracker.shared.clearAnchor()', SPATIAL)
        self.assertIn('NeuralTargetTracker.shared.clearAnchor()', VISION)
        self.assertIn('anchorUV = selectedUV', VISION)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(StabilityTests))
    report = {'scope': 'Python reference scenarios and source contracts; not Swift execution',
              'tests_run': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
              'ios_compiled': False, 'device_tested': False, 'metrics': METRICS}
    (ROOT / 'tracking_stability_results.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(not result.wasSuccessful())
