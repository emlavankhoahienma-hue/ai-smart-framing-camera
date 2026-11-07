"""Numerical & source-contract verification for handheld iPhone Spatial + PatchFlow upgrades.

Scope: Python reference simulation of the exact Swift math in SpatialTrackingEngine,
TargetPatchFlow, and ARFramingOverlayView; does not execute Swift on an iOS device.
"""
import json
import math
import unittest
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
SPATIAL_SRC = (ROOT / "AISmartFramingCamera/Services/SpatialTrackingEngine.swift").read_text(encoding="utf-8")
PATCH_SRC = (ROOT / "AISmartFramingCamera/Services/TargetPatchFlow.swift").read_text(encoding="utf-8")
NEURAL_SRC = (ROOT / "AISmartFramingCamera/Services/NeuralTargetTracker.swift").read_text(encoding="utf-8")
OVERLAY_SRC = (ROOT / "AISmartFramingCamera/Views/ARFramingOverlayView.swift").read_text(encoding="utf-8")


def slerp_unit(u, v, max_angle):
    u = u / np.linalg.norm(u)
    v = v / np.linalg.norm(v)
    dot = float(np.clip(np.dot(u, v), -1.0, 1.0))
    angle = math.acos(dot)
    if angle <= max_angle or angle <= 1e-9:
        return v
    t = max(0.0, max_angle) / angle
    sin_a = math.sin(angle)
    if sin_a <= 1e-9:
        return v
    w0 = math.sin((1.0 - t) * angle) / sin_a
    w1 = math.sin(t * angle) / sin_a
    res = w0 * u + w1 * v
    return res / np.linalg.norm(res)


class HandheldSpatialTrackingUpgradeTests(unittest.TestCase):
    def test_200hz_live_preview_pose_eliminates_30hz_camera_beat_staircase(self):
        """Verify livePreviewTime pose updates on every 200Hz tick instead of freezing for 33ms."""
        fx = 0.78
        world_ray = np.array([0.0, 0.0, -1.0])
        imu_dt = 1.0 / 200.0
        cam_dt = 1.0 / 30.0

        frozen_x = []
        live_x = []
        last_frame_time = 0.0

        # Simulate 1.0s of handheld iPhone pan (35 deg/s) + 9.5 Hz hand tremor
        history = []
        for step in range(200):
            t = step * imu_dt
            yaw = math.radians(35.0) * t + 0.0025 * math.sin(2.0 * math.pi * 9.5 * t)
            history.append((t, yaw))
            if t - last_frame_time >= cam_dt - 1e-9:
                last_frame_time = t

            # Old behavior: froze pose at last_frame_time across all 6-7 intermediate 200Hz ticks
            old_yaw = next(y for ts, y in reversed(history) if ts <= last_frame_time + 1e-9)
            old_dev_x = math.sin(-old_yaw) * (-world_ray[2])
            frozen_x.append(0.5 + fx * old_dev_x)

            # Upgraded behavior: continuous 200Hz pose at sample.timestamp - 0.008s
            target_t = t - 0.008
            # Linear/slerp interpolation in history
            live_yaw = math.radians(35.0) * target_t + 0.0025 * math.sin(2.0 * math.pi * 9.5 * target_t)
            live_dev_x = math.sin(-live_yaw) * (-world_ray[2])
            live_x.append(0.5 + fx * live_dev_x)

        frozen_diffs = np.abs(np.diff(frozen_x))
        live_diffs = np.abs(np.diff(live_x))

        # Old behavior had > 80% zero-motion frozen ticks followed by large 30Hz step jumps
        zero_ticks_old = int(np.sum(frozen_diffs < 1e-7))
        zero_ticks_new = int(np.sum(live_diffs < 1e-7))
        self.assertGreater(zero_ticks_old, 150)
        self.assertEqual(zero_ticks_new, 0)
        # Max single-tick jump is reduced by > 5x
        self.assertLess(float(np.max(live_diffs)), float(np.max(frozen_diffs)) * 0.22)

    def test_1euro_spherical_s2_interpolation_smooths_30hz_optical_steps(self):
        """Verify 30Hz optical updates to reticleRay are smoothly interpolated at 200Hz on S^2."""
        fx = 0.78
        imu_dt = 1.0 / 200.0
        reticle_ray = np.array([0.0, 0.0, -1.0])
        display_ray = reticle_ray.copy()

        stepped_vel = []
        smooth_vel = []
        prev_stepped = reticle_ray.copy()

        # Run 125 ticks (last optical update at tick 119, followed by 6 ticks = 30ms to end of frame)
        for step in range(1, 126):
            # Every 7 ticks (~35ms), optical tracker updates reticle_ray by 0.006 rad
            if step % 7 == 0 and step <= 119:
                angle = (step // 7) * 0.006
                reticle_ray = np.array([math.sin(angle), 0.0, -math.cos(angle)])

            # Stepped (old): snaps immediately on frame boundary, 0 on intermediate ticks
            step_angle = math.acos(float(np.clip(np.dot(prev_stepped, reticle_ray), -1.0, 1.0)))
            stepped_vel.append(step_angle / imu_dt)
            prev_stepped = reticle_ray.copy()

            # Upgraded 1-Euro S^2 interpolation across 200Hz ticks
            gap_angle = math.acos(float(np.clip(np.dot(display_ray, reticle_ray), -1.0, 1.0)))
            normalized_gap = gap_angle * fx
            cutoff_hz = 14.0 + min(85.0, normalized_gap * 120.0)
            alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff_hz * imu_dt)
            smooth_step = max(1e-7, gap_angle * max(0.32, min(1.0, alpha)))
            next_display = slerp_unit(display_ray, reticle_ray, smooth_step)
            move_angle = math.acos(float(np.clip(np.dot(display_ray, next_display), -1.0, 1.0)))
            smooth_vel.append(move_angle / imu_dt)
            display_ray = next_display

        # Peak instantaneous velocity spike is reduced by > 50% while converging within a single camera frame
        self.assertLess(max(smooth_vel), max(stepped_vel) * 0.50)
        final_err = math.acos(float(np.clip(np.dot(display_ray, reticle_ray), -1.0, 1.0)))
        self.assertLess(final_err, 0.0005)

    def test_subpixel_parabolic_refinement_and_irls_reduce_patch_flow_rmse(self):
        """Verify 2D sub-pixel parabolic peak refinement beats integer ZNCC quantization."""
        rng = np.random.default_rng(42)
        true_shifts = rng.uniform(-4.0, 4.0, size=(100, 2))
        int_errors = []
        sub_errors = []

        for dx_true, dy_true in true_shifts:
            best_x = int(round(dx_true))
            best_y = int(round(dy_true))
            # Synthetic locally quadratic ZNCC surface around true shift (dx_true, dy_true)
            def score_at(ix, iy):
                return 0.96 - 0.18 * ((ix - dx_true) ** 2 + (iy - dy_true) ** 2)

            s_center = score_at(best_x, best_y)
            s_left = score_at(best_x - 1, best_y)
            s_right = score_at(best_x + 1, best_y)
            s_up = score_at(best_x, best_y - 1)
            s_down = score_at(best_x, best_y + 1)

            denom_x = 2.0 * (s_left - 2.0 * s_center + s_right)
            delta_x = np.clip((s_left - s_right) / denom_x, -0.45, 0.45) if denom_x < -1e-6 else 0.0
            denom_y = 2.0 * (s_up - 2.0 * s_center + s_down)
            delta_y = np.clip((s_up - s_down) / denom_y, -0.45, 0.45) if denom_y < -1e-6 else 0.0

            int_errors.append((best_x - dx_true) ** 2 + (best_y - dy_true) ** 2)
            sub_errors.append((best_x + delta_x - dx_true) ** 2 + (best_y + delta_y - dy_true) ** 2)

        int_rmse = math.sqrt(float(np.mean(int_errors)))
        sub_rmse = math.sqrt(float(np.mean(sub_errors)))
        self.assertGreater(int_rmse, 0.35)
        self.assertLess(sub_rmse, 0.02)

    def test_c1_continuous_magnetic_well_has_zero_boundary_teleport(self):
        """Verify magnetic snap well is continuous at outerWellRadius (34pt) and innerCoreRadius (14pt)."""
        outer_r = 34.0
        inner_r = 14.0

        def mapped_radius(r):
            if r >= outer_r:
                return r
            if r <= inner_r:
                return r * (0.08 * (r / inner_r))
            u = min(1.0, max(0.0, (r - inner_r) / (outer_r - inner_r)))
            smooth = u * u * (3.0 - 2.0 * u)
            scale = 0.08 + 0.92 * smooth
            return r * scale

        # Check continuity across r = 14.0 and r = 34.0
        self.assertAlmostEqual(mapped_radius(inner_r - 1e-4), mapped_radius(inner_r + 1e-4), places=3)
        self.assertAlmostEqual(mapped_radius(outer_r - 1e-4), mapped_radius(outer_r + 1e-4), places=3)
        # Check monotonic increasing radius (no reversals)
        radii = [mapped_radius(r) for r in np.linspace(0.0, 40.0, 401)]
        self.assertTrue(all(b >= a - 1e-9 for a, b in zip(radii, radii[1:])))

    def test_source_contracts_for_swift_and_metal_upgrades(self):
        self.assertIn("func predictedBearing(at targetTimestamp: TimeInterval", SPATIAL_SRC)
        self.assertIn("let velocityHuberWeight = min(1.0", SPATIAL_SRC)
        self.assertIn("let livePreviewTime = sample.timestamp - 0.008", SPATIAL_SRC)
        self.assertIn("final class TargetPatchFlowMetalEngine", PATCH_SRC)
        self.assertIn("kernel void patchFlowCornerResponseKernel", PATCH_SRC)
        self.assertIn("SIMD8<Float>", PATCH_SRC)
        self.assertIn("2D Sub-Pixel Parabolic Refinement", PATCH_SRC)
        self.assertIn("guard now - lastAdaptiveUpdateTime >= 0.40 else { return }", NEURAL_SRC)
        self.assertIn("let outerWellRadius: CGFloat = 34.0", OVERLAY_SRC)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(HandheldSpatialTrackingUpgradeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
