"""Deterministic geometry/reference-model regression, NOT an iOS runtime benchmark.

Run: python validate_tracking_geometry.py --output validation_results.json
Requires numpy. Source-contract checks additionally detect the original failure
modes. XCTest in tests/ exercises the actual Swift geometry on an Apple SDK.
"""
import argparse
import json
import math
import re
from pathlib import Path
import unittest
import numpy as np


def rotation(axis, angle):
    x, y, z = np.asarray(axis) / np.linalg.norm(axis)
    skew = np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])
    return np.eye(3) + math.sin(angle) * skew + (1 - math.cos(angle)) * skew @ skew


class Camera:
    def __init__(self, zoom=1, aspect=.75):
        self.fx = .5 / math.tan(math.radians(65) / 2) * zoom
        self.fy = self.fx * aspect

    def ray(self, point):
        ray = np.array([(point[0] - .5) / self.fx, -(point[1] - .5) / self.fy, -1.])
        return ray / np.linalg.norm(ray)

    def project(self, ray):
        forward = -ray[2]
        if forward > 1e-6:
            return np.array([.5 + self.fx * ray[0] / forward, .5 - self.fy * ray[1] / forward]), True
        dx = math.atan2(ray[0], forward)
        dy = -math.atan2(ray[1], math.hypot(ray[0], forward))
        if abs(dx) + abs(dy) < 1e-8:
            dx = math.pi
        scale = 2 / max(abs(dx), abs(dy), 1e-8)
        return np.array([.5 + dx * scale, .5 + dy * scale]), False


def screen(point, size, aspect):
    scale = max(size[0] / aspect, size[1])
    return (np.array(point) - .5) * np.array([scale * aspect, scale]) + np.array(size) / 2


def dock(point, size, inset=30):
    half = np.maximum(1, np.array(size) / 2 - inset)
    delta = np.array(point) - np.array(size) / 2
    return np.array(size) / 2 + delta / max(1, *np.abs(delta / half))


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.camera = Camera()
        self.anchor = self.camera.ray([.5, .5])

    def test_pan_right_moves_target_left(self):
        # Rear lens is -Z, so a right pan is a negative right-handed Y rotation.
        pose = rotation([0, 1, 0], math.radians(-20))
        point, front = self.camera.project(pose.T @ self.anchor)
        self.assertTrue(front)
        self.assertLess(point[0], .5)
        self.assertAlmostEqual(point[0], .5 - self.camera.fx * math.tan(math.radians(20)))

    def test_tilt_up_moves_target_down(self):
        pose = rotation([1, 0, 0], math.radians(20))
        point, _ = self.camera.project(pose.T @ self.anchor)
        self.assertGreater(point[1], .5)

    def test_roll_and_projection_round_trip(self):
        rng = np.random.default_rng(17)
        for _ in range(1000):
            pin = rng.uniform(.01, .99, 2)
            pose = rotation(rng.normal(size=3), rng.uniform(-math.pi, math.pi))
            world = pose @ self.camera.ray(pin)
            result, front = self.camera.project(pose.T @ world)
            self.assertTrue(front)
            np.testing.assert_allclose(result, pin, atol=1e-12)

    def test_full_turn_and_long_offscreen_does_not_forget(self):
        world = self.camera.ray([.71, .29])
        for angle in np.linspace(0, 2 * math.pi, 3601):
            p, front = self.camera.project(rotation([0, 1, 0], angle).T @ world)
            self.assertTrue(np.isfinite(p).all())
            q = dock(screen(p, (390, 844), .75), (390, 844))
            self.assertTrue((q >= np.array([30, 30]) - 1e-10).all())
            self.assertTrue((q <= np.array([360, 814]) + 1e-10).all())
        np.testing.assert_allclose(p, [.71, .29], atol=1e-12)

    def test_behind_camera_is_direction_not_false_center(self):
        p, front = self.camera.project(np.array([0., 0., 1.]))
        self.assertFalse(front)
        self.assertGreater(np.linalg.norm(p - .5), 1)

    def test_delayed_vision_corrected_at_capture_time(self):
        errors, wrong_errors = [], []
        for latency in [.016, .05, .1, .2]:
            for t in np.arange(.25, 2, 1 / 60):
                captured_pose = rotation([0, 1, 0], -.8 * (t - latency))
                live_pose = rotation([0, 1, 0], -.8 * t)
                observed, front = self.camera.project(captured_pose.T @ self.anchor)
                if not front:
                    continue
                corrected = captured_pose @ self.camera.ray(observed)
                wrong = live_pose @ self.camera.ray(observed)
                errors.append(np.linalg.norm(corrected - self.anchor))
                wrong_errors.append(np.linalg.norm(wrong - self.anchor))
        self.assertLess(max(errors), 1e-12)
        self.assertGreater(max(wrong_errors), .1)

        # A cloud target returned later still belongs to its captured image.
        captured_pose = rotation([0, 1, 0], -.15)
        current_pose = rotation([0, 1, 0], -.55)
        captured_point = np.array([.68, .42])
        bearing = captured_pose @ self.camera.ray(captured_point)
        current_point, front = self.camera.project(current_pose.T @ bearing)
        self.assertTrue(front)
        self.assertGreater(np.linalg.norm(current_point - captured_point), .1)
        np.testing.assert_allclose(current_pose @ self.camera.ray(current_point), bearing, atol=1e-12)

    def test_aspect_fill_round_trip_and_docking_collinearity(self):
        for size in [(390, 844), (390, 520), (844, 390)]:
            for point in [[.1, .9], [-3, 2], [.5, .5]]:
                projected = screen(point, size, .75)
                scale = max(size[0] / .75, size[1])
                back = (projected - np.array(size) / 2) / [scale * .75, scale] + .5
                np.testing.assert_allclose(back, point, atol=1e-12)
                a = projected - np.array(size) / 2
                b = dock(projected, size) - np.array(size) / 2
                self.assertAlmostEqual(a[0] * b[1] - a[1] * b[0], 0, places=8)

    def test_zoom_reprojects_same_bearing(self):
        world = self.camera.ray([.6, .7])
        point, _ = Camera(zoom=2).project(world)
        np.testing.assert_allclose(point, [.7, .9], atol=1e-12)

    def test_static_noisy_innovation_is_attenuated(self):
        rng = np.random.default_rng(226)
        world = self.anchor.copy()
        raw, filtered = [], []
        def update(world, point):
            predicted, _ = self.camera.project(world)
            residual = np.linalg.norm(point - predicted)
            cutoff = .7 + min(6, residual * 40)
            ordinary_gain = (1 - math.exp(-2 * math.pi * cutoff / 30)) * .9
            residual_weight = max(.45, 1 / (1 + (residual / .20) ** 2))
            gain = ordinary_gain * residual_weight * .70  # geometry continuation
            world = world * (1 - gain) + self.camera.ray(point) * gain
            return world / np.linalg.norm(world)
        for _ in range(1800):
            point = np.array([.5, .5]) + rng.normal(0, .003, 2)
            world = update(world, point)
            raw.append(point)
            filtered.append(self.camera.project(world)[0])
        ratio = np.var(np.array(filtered)[100:] - .5) / np.var(np.array(raw)[100:] - .5)
        self.assertLess(ratio, .2)
        METRICS['static_noise_variance_ratio_reference_model'] = float(ratio)

        # A consistent optical offset must converge without a one-frame snap.
        world = self.camera.ray([.5, .5])
        shifted = np.array([.75, .5])
        first = self.camera.project(update(world, shifted))[0]
        self.assertLess(np.linalg.norm(first - [.5, .5]), .10)
        for _ in range(30):
            world = update(world, shifted)
        self.assertLess(np.linalg.norm(self.camera.project(world)[0] - shifted), .02)

    def test_tremor_tracks_image_instead_of_freezing_screen(self):
        errors = []
        for t in np.arange(0, 5, 1 / 60):
            yaw = .003 * math.sin(2 * math.pi * 9.5 * t)
            pose = rotation([0, 1, 0], yaw)
            p, _ = self.camera.project(pose.T @ self.anchor)
            truth = [.5 + self.camera.fx * math.tan(yaw), .5]
            errors.append(np.linalg.norm(p - truth))
        self.assertLess(max(errors), 1e-12)

    def test_translation_requires_depth_and_position(self):
        # Two objects on the same initial ray become different bearings after
        # the same lateral translation. Gyro alone cannot distinguish these.
        camera_position = np.array([.25, 0, 0])
        near, _ = self.camera.project(np.array([0, 0, -1]) - camera_position)
        far, _ = self.camera.project(np.array([0, 0, -10]) - camera_position)
        self.assertGreater(abs(near[0] - far[0]), .1)

    def test_source_regressions_removed(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        spatial = (root / 'Services/SpatialTrackingEngine.swift').read_text(encoding='utf-8')
        vision = (root / 'Services/VisionFramingEngine.swift').read_text(encoding='utf-8')
        vm = (root / 'ViewModels/CameraViewModel.swift').read_text(encoding='utf-8')
        self.assertNotIn('timeSinceOptical > 0.12', spatial)
        self.assertNotIn('min(0.98', spatial)
        self.assertNotIn('outlierStreak', spatial)
        self.assertNotIn('extractSaliencyCentroid', vision)
        self.assertNotIn('consecutiveLostFrames <= 150', vision)
        self.assertIn('visionEngine.onTargetMeasurement', vm)
        self.assertIn('guard !Task.isCancelled else { return }', vm)

    def test_vision_continuation_uses_returned_observation_only(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        source = (root / 'Services/VisionFramingEngine.swift').read_text(encoding='utf-8')
        assignments = re.findall(r'\binputObservation\s*=\s*([^\n;]+)', source)
        self.assertEqual(assignments, ['observation'])
        self.assertEqual(source.count('VNDetectedObjectObservation(boundingBox:'), 1)
        self.assertIn('let observation = request.results?.first', source)
        self.assertIn('guard continuity.reject() else { return nil }', source)
        self.assertNotIn('request.inputObservation = VNDetectedObjectObservation', source)
        self.assertNotIn('refineAnchorBox(around: seedPoint', source)

    def test_zoom_projection_changes_only_on_hardware_feedback(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        vm = (root / 'ViewModels/CameraViewModel.swift').read_text(encoding='utf-8')
        arguments = re.findall(r'updateZoomFactor\(([^\n)]+)\)', vm)
        self.assertEqual(arguments, ['self.displayZoom', 'disp', 'self.displayZoom'])
        self.assertIn('hasExecutedAutoZoomForSession = isManualRePin', vm)
        self.assertIn('if isManualRePin { cameraService.cancelZoomRamp() }', vm)
        self.assertIn('!isManualRePin && !self.hasExecutedAutoZoomForSession', vm)
        self.assertEqual(vm.count('self.targetPinGeneration == pinGeneration'), 3)
        self.assertEqual(vm.count('        prioritizeManualZoom()'), 4)
        camera = (root / 'Services/CameraService.swift').read_text(encoding='utf-8')
        self.assertNotIn('didChangeZoomFactor: clampedZoom', camera)
        self.assertEqual(camera.count('didChangeZoomFactor: actualZoom'), 2)
        self.assertEqual(camera.count('let actualZoom = camera.videoZoomFactor'), 2)

    def test_overlay_redraw_does_not_destroy_tracking_session(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        overlay = (root / 'Views/ARFramingOverlayView.swift').read_text(encoding='utf-8')
        self.assertNotIn('.onDisappear { viewModel.suspendSpatialTracking() }', overlay)
        self.assertNotIn('UIApplication.willResignActiveNotification', overlay)
        self.assertIn('UIApplication.didEnterBackgroundNotification', overlay)

    def test_camera_config_and_xcode_membership(self):
        root = Path(__file__).resolve().parents[1]
        camera = (root / 'AISmartFramingCamera/Services/CameraService.swift').read_text(encoding='utf-8')
        project = (root / 'AISmartFramingCamera.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
        self.assertIn('connection.isCameraIntrinsicMatrixDeliveryEnabled = true', camera)
        self.assertIn('!captureSession.isRunning && connection.isCameraIntrinsicMatrixDeliverySupported', camera)
        self.assertEqual(camera.count('self.configureTrackingConnection(connection)'), 2)
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET', project)
        for name in ['TrackingGeometry.swift', 'NeuralTargetTracker.swift', 'TargetPatchFlow.swift', 'WindowedZoomOverlayView.swift']:
            self.assertIn(f'/* {name} in Sources */ =', project)
            self.assertIn(f'path = {name};', project)
            # Ensure fileRef in Sources matches the exact fileRef in PBXFileReference and PBXGroup
            import re
            build_match = re.search(r'fileRef = ([A-F0-9]+) /\* ' + re.escape(name), project)
            file_match = re.search(r'([A-F0-9]+) /\* ' + re.escape(name) + r' \*/ = \{isa = PBXFileReference', project)
            group_match = re.search(r'([A-F0-9]+) /\* ' + re.escape(name) + r' \*/,', project)
            self.assertIsNotNone(build_match, f'Missing build fileRef for {name}')
            self.assertIsNotNone(file_match, f'Missing fileRef definition for {name}')
            self.assertIsNotNone(group_match, f'Missing group entry for {name}')
            self.assertEqual(build_match.group(1), file_match.group(1), f'ID mismatch between build and file for {name}')
            self.assertEqual(file_match.group(1), group_match.group(1), f'ID mismatch between file and group for {name}')

    def test_reidentification_can_correct_a_large_world_bearing_error(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        spatial = (root / 'Services/SpatialTrackingEngine.swift').read_text(encoding='utf-8')
        vision = (root / 'Services/VisionFramingEngine.swift').read_text(encoding='utf-8')
        vm = (root / 'ViewModels/CameraViewModel.swift').read_text(encoding='utf-8')
        self.assertIn('if evidence == .reidentified { return residual.isFinite }', spatial)
        self.assertIn('if evidence == .reidentified {\n                    worldRay = observed', spatial)
        self.assertIn('guard length.isFinite, length > 1e-9', spatial)
        self.assertIn('return (confirmedPoint, min(recovered.1, Double(observation.confidence)), .reidentified)', vision)
        self.assertIn('pendingTargetDelivery?.4 == .reidentified && evidence != .reidentified', vision)
        self.assertIn('evidence: measurement.evidence', vm)

    def test_frame_context_is_shared_between_vision_and_pin_snapshot(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        vm = (root / 'ViewModels/CameraViewModel.swift').read_text(encoding='utf-8')
        vision = (root / 'Services/VisionFramingEngine.swift').read_text(encoding='utf-8')
        self.assertIn('orientation: .up, frameContext: frame', vm)
        self.assertIn('latestFrameContext = frame', vm)
        self.assertIn('let frame = orientation == .up && frameContext?.orientation == .up && matchesSize', vision)


METRICS = {}
if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GeometryTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {'kind': 'Python reference geometry and source-contract tests',
              'ios_compiled': False, 'device_tested': False,
              'tests_run': result.testsRun, 'failures': len(result.failures),
              'errors': len(result.errors), 'metrics': METRICS,
              'limits': ['Does not execute Swift, CoreMotion, Vision, UI, or concurrency.',
                         'Does not establish real-world accuracy, latency, or Re-ID performance.']}
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(not result.wasSuccessful())
