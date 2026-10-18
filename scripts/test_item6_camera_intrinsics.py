import math
import sys
from pathlib import Path

def calculate_intrinsics_pure(fov_long_degrees: float, aspect: float = 0.75, zoom: float = 1.0):
    fov_rad = math.radians(fov_long_degrees)
    effective_zoom = max(0.1, zoom)
    fy = (0.5 / math.tan(fov_rad / 2.0)) * effective_zoom
    fx = fy / max(0.001, aspect)
    return fx, fy, 0.5, 0.5

def test_math_intrinsics():
    # 1. Main camera 1x on iPhone 15 Pro: FOV = 69 degrees, aspect = 0.75
    fx, fy, cx, cy = calculate_intrinsics_pure(69.0, aspect=0.75, zoom=1.0)
    expected_fy = 0.5 / math.tan(math.radians(34.5))
    expected_fx = expected_fy / 0.75
    assert abs(fy - expected_fy) < 1e-6, f"fy {fy} != {expected_fy}"
    assert abs(fx - expected_fx) < 1e-6, f"fx {fx} != {expected_fx}"
    assert abs(cx - 0.5) < 1e-6
    assert abs(cy - 0.5) < 1e-6
    # Tỉ lệ fx / fy phải bằng 1 / aspect = 4 / 3
    ratio = fx / fy
    assert abs(ratio - 4.0 / 3.0) < 1e-6, f"fx/fy ratio {ratio} != 4/3"

    # 2. Main camera 2x zoom:
    fx_2x, fy_2x, _, _ = calculate_intrinsics_pure(69.0, aspect=0.75, zoom=2.0)
    assert abs(fy_2x - 2.0 * fy) < 1e-6
    assert abs(fx_2x - 2.0 * fx) < 1e-6

    # 3. Ultra wide camera (0.5x): FOV = 120 degrees
    fx_uw, fy_uw, _, _ = calculate_intrinsics_pure(120.0, aspect=0.75, zoom=1.0)
    expected_fy_uw = 0.5 / math.tan(math.radians(60.0))
    expected_fx_uw = expected_fy_uw / 0.75
    assert abs(fy_uw - expected_fy_uw) < 1e-6
    assert abs(fx_uw - expected_fx_uw) < 1e-6

    # 4. Telephoto camera (3x): FOV = 30 degrees
    fx_tele, fy_tele, _, _ = calculate_intrinsics_pure(30.0, aspect=0.75, zoom=1.0)
    expected_fy_tele = 0.5 / math.tan(math.radians(15.0))
    expected_fx_tele = expected_fy_tele / 0.75
    assert abs(fy_tele - expected_fy_tele) < 1e-6
    assert abs(fx_tele - expected_fx_tele) < 1e-6

def test_source_code_contracts():
    root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
    
    # Check TrackingGeometry.swift
    geom_code = (root / 'Services/TrackingGeometry.swift').read_text(encoding='utf-8')
    assert "tan(65 * .pi / 360)" not in geom_code, "TrackingGeometry.swift still hardcodes 65 degrees"
    assert "fy: fx * aspect" not in geom_code, "TrackingGeometry.swift still inverts fx/fy aspect formula"
    assert "calculateIntrinsics" in geom_code, "TrackingGeometry.swift must delegate to calculateIntrinsics"
    
    # Check CameraService.swift
    camera_code = (root / 'Services/CameraService.swift').read_text(encoding='utf-8')
    assert "effectiveVideoFieldOfView" in camera_code, "CameraService must expose effectiveVideoFieldOfView"
    assert "videoFieldOfView" in camera_code, "CameraService must read device.activeFormat.videoFieldOfView"
    
    # Check CompositionTuning.swift
    tuning_code = (root / 'Services/CompositionTuning.swift').read_text(encoding='utf-8')
    assert "defaultCameraFOVWide" in tuning_code, "CompositionTuning must define defaultCameraFOVWide"
    assert "defaultCameraFOVRearUltraWide" in tuning_code, "CompositionTuning must define defaultCameraFOVRearUltraWide"
    assert "defaultCameraFOVTelephoto" in tuning_code, "CompositionTuning must define defaultCameraFOVTelephoto"

    # Check SpatialTrackingEngine.swift
    spatial_code = (root / 'Services/SpatialTrackingEngine.swift').read_text(encoding='utf-8')
    assert "updateCameraFieldOfView" in spatial_code, "SpatialTrackingEngine must provide updateCameraFieldOfView"

def main():
    print("Testing math intrinsics...")
    test_math_intrinsics()
    print("Math intrinsics tests PASSED.")
    
    print("Testing source code contracts for Item #6...")
    try:
        test_source_code_contracts()
        print("Source code contracts PASSED.")
    except AssertionError as e:
        print(f"FAILED CONTRACT (expected before fix): {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
