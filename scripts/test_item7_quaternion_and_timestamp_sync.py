import math
import sys
from pathlib import Path
import numpy as np

def rotation_matrix(axis, angle_rad):
    axis = np.asarray(axis, dtype=float)
    norm = np.linalg.norm(axis)
    if norm < 1e-9:
        return np.eye(3)
    axis = axis / norm
    x, y, z = axis
    c = math.cos(angle_rad)
    s = math.sin(angle_rad)
    C = 1.0 - c
    return np.array([
        [x * x * C + c,     x * y * C - z * s, x * z * C + y * s],
        [y * x * C + z * s, y * y * C + c,     y * z * C - x * s],
        [z * x * C - y * s, z * y * C + x * s, z * z * C + c    ]
    ])

def quat_from_axis_angle(axis, angle_rad):
    axis = np.asarray(axis, dtype=float)
    norm = np.linalg.norm(axis)
    if norm < 1e-9:
        return np.array([0.0, 0.0, 0.0, 1.0]) # x, y, z, w
    axis = axis / norm
    half = angle_rad / 2.0
    s = math.sin(half)
    return np.array([axis[0] * s, axis[1] * s, axis[2] * s, math.cos(half)])

def quat_slerp(q0, q1, t):
    # q0, q1 are [x, y, z, w]
    t = max(0.0, min(1.0, float(t)))
    dot = np.dot(q0, q1)
    if dot < 0.0:
        q1 = -q1
        dot = -dot
    if dot > 0.9995:
        res = q0 + t * (q1 - q0)
        return res / np.linalg.norm(res)
    theta_0 = math.acos(dot)
    sin_theta_0 = math.sin(theta_0)
    theta = theta_0 * t
    sin_theta = math.sin(theta)
    s0 = math.cos(theta) - dot * sin_theta / sin_theta_0
    s1 = sin_theta / sin_theta_0
    return (s0 * q0) + (s1 * q1)

def interpolate_pose(time, samples, min_dt=1e-6, max_dt=0.10, margin=0.02):
    if not samples:
        return None
    first = samples[0]
    last = samples[-1]
    if time < first[0] - margin or time > last[0] + margin:
        return None
    if time <= first[0]:
        return first[1]
    if time >= last[0]:
        return last[1]
    for i in range(1, len(samples)):
        if samples[i][0] >= time:
            t_a, q_a = samples[i - 1]
            t_b, q_b = samples[i]
            dt = t_b - t_a
            if dt <= min_dt or dt >= max_dt:
                if abs(time - t_a) <= min_dt:
                    return q_a
                return None
            t = (time - t_a) / dt
            return quat_slerp(q_a, q_b, t)
    return None

def test_quaternion_slerp_and_division_by_zero():
    q0 = quat_from_axis_angle([0, 1, 0], 0.0)
    q1 = quat_from_axis_angle([0, 1, 0], 0.02)
    
    # 1. Exact midpoint interpolation
    samples = [(1.0, q0), (1.02, q1)]
    mid = interpolate_pose(1.01, samples)
    assert mid is not None, "Interpolation at midpoint returned None"
    expected_mid = quat_from_axis_angle([0, 1, 0], 0.01)
    np.testing.assert_allclose(mid, expected_mid, atol=1e-6)
    
    # 2. Out of bounds rejection
    assert interpolate_pose(0.5, samples) is None
    assert interpolate_pose(2.0, samples) is None
    
    # 3. Gap larger than max_dt (0.1s) rejection
    wide_samples = [(1.0, q0), (1.15, q1)]
    assert interpolate_pose(1.05, wide_samples) is None
    
    # 4. Zero division safety: duplicate timestamps
    dup_samples = [(1.0, q0), (1.0, q1)]
    # Must not raise ZeroDivisionError and must not return NaN
    res_dup = interpolate_pose(1.0, dup_samples)
    assert res_dup is not None
    assert not np.isnan(res_dup).any()
    np.testing.assert_allclose(res_dup, q0, atol=1e-6)
    
    # 5. Near-zero timestamp delta (< 1e-6)
    near_dup = [(1.0, q0), (1.0 + 1e-8, q1)]
    res_near = interpolate_pose(1.0, near_dup)
    assert res_near is not None
    assert not np.isnan(res_near).any()
    np.testing.assert_allclose(res_near, q0, atol=1e-6)

def test_pan_tilt_signs_and_reprojection():
    # Camera model with 69 deg FOV
    fov_rad = math.radians(69.0)
    fy = 0.5 / math.tan(fov_rad / 2.0)
    fx = fy / 0.75
    
    # Center ray in device coordinates is [0, 0, -1]
    center_ray = np.array([0.0, 0.0, -1.0])
    
    # Right pan: device rotates -20 deg around Y
    # R_deviceToWorld transforms device vector to world vector
    R_right = rotation_matrix([0, 1, 0], math.radians(-20))
    # When device rotates right, an anchored world point at center_ray is observed in new device frame as R.T @ world
    world_anchor = center_ray.copy()
    device_ray = R_right.T @ world_anchor
    
    # Project to screen: px = 0.5 + fx * (x / -z)
    px = 0.5 + fx * (device_ray[0] / (-device_ray[2]))
    assert px < 0.5, f"Right pan should move target left (px < 0.5), got {px}"
    
    # Up tilt: device rotates +20 deg around X
    R_up = rotation_matrix([1, 0, 0], math.radians(20))
    device_ray_up = R_up.T @ world_anchor
    py = 0.5 - fy * (device_ray_up[1] / (-device_ray_up[2]))
    assert py > 0.5, f"Up tilt should move target down (py > 0.5), got {py}"

def test_source_code_contracts():
    root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
    
    # Check CompositionTuning.swift
    tuning = (root / 'Services/CompositionTuning.swift').read_text(encoding='utf-8')
    assert "motionInterpolationMinDt" in tuning, "CompositionTuning must declare motionInterpolationMinDt"
    assert "motionInterpolationMaxDt" in tuning, "CompositionTuning must declare motionInterpolationMaxDt"
    assert "motionInterpolationMargin" in tuning, "CompositionTuning must declare motionInterpolationMargin"
    assert "maxFrameToMotionLatency" in tuning, "CompositionTuning must declare maxFrameToMotionLatency"
    
    # Check CompositionPureCalculations.swift
    pure = (root / 'Services/CompositionPureCalculations.swift').read_text(encoding='utf-8')
    assert "interpolateHistoricalPose" in pure, "CompositionPureCalculations must implement interpolateHistoricalPose"
    assert "slerpPose" in pure, "CompositionPureCalculations must implement slerpPose"
    
    # Check TrackingGeometry.swift
    geom = (root / 'Services/TrackingGeometry.swift').read_text(encoding='utf-8')
    assert "interpolateHistoricalPose" in geom or "minDt" in geom, "TrackingGeometry.pose must protect against zero division"
    
    # Check SpatialTrackingEngine.swift
    engine = (root / 'Services/SpatialTrackingEngine.swift').read_text(encoding='utf-8')
    assert "maxFrameToMotionLatency" in engine, "SpatialTrackingEngine must use CompositionTuning.maxFrameToMotionLatency"

if __name__ == '__main__':
    test_quaternion_slerp_and_division_by_zero()
    test_pan_tilt_signs_and_reprojection()
    print("PASS: Pure mathematical assertions for Item #7 passed.")
    try:
        test_source_code_contracts()
        print("PASS: Source code contracts for Item #7 passed.")
    except AssertionError as e:
        print(f"EXPECTED FAILURE (pre-fix): {e}")
        sys.exit(1)
