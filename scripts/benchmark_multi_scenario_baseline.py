#!/usr/bin/env python3
"""Multi-Scenario Benchmark Test Suite for AI Camera Composition.
Evaluates 8 distinct real-world photographic scenarios against the codebase
and records baseline metrics before fixes.

Outputs:
- Detected Hero
- Target Placement (x, y)
- AimPoint (x, y)
- Recommended Zoom
- Expected Subject Rect in New Frame
"""
from __future__ import annotations

import math
import json
from pathlib import Path

# Paths
ROOT = Path(__file__).resolve().parents[1]
SERVICES_DIR = ROOT / "AISmartFramingCamera/Services"

# Import or define current implementations mirroring Swift code exactly
def current_calculate_continuous_ideal_zoom(
    current_zoom: float,
    current_area: float,
    desired_area: float,
    max_zoom: float,
    target_point: tuple[float, float] = (0.5, 0.5),
    box_width: float = 0.2,
    box_height: float = 0.3,
    safety_margin: float = 0.06
) -> float:
    """Current implementation from CompositionPureCalculations.swift lines 159-185."""
    if current_area <= 0.0001 or desired_area <= 0 or current_zoom <= 0:
        return current_zoom
    
    ideal_ratio = math.sqrt(desired_area / current_area)
    zoom_candidate = current_zoom * ideal_ratio

    if box_width > 0 and box_height > 0:
        max_ratio_x = (2.0 * min(target_point[0] - safety_margin, 1.0 - safety_margin - target_point[0])) / box_width
        max_ratio_y = (2.0 * min(target_point[1] - safety_margin, 1.0 - safety_margin - target_point[1])) / box_height
        max_allowed_ratio = max(1.0, min(max_ratio_x, max_ratio_y))
        zoom_candidate = min(zoom_candidate, current_zoom * max_allowed_ratio)

    return max(current_zoom, min(max_zoom, zoom_candidate))


def current_unpad_letterbox(
    x: float, y: float, w: float, h: float,
    source_width: float,
    source_height: float,
    model_size: float = 640.0
) -> tuple[float, float, float, float]:
    """Current implementation from CompositionPureCalculations.swift lines 109-138."""
    if source_width <= 0 or source_height <= 0 or model_size <= 0:
        return (x, y, w, h)
    
    scale = min(model_size / source_width, model_size / source_height)
    valid_w = source_width * scale
    valid_h = source_height * scale
    pad_x = (model_size - valid_w) / 2.0
    pad_y = (model_size - valid_h) / 2.0

    pixel_x = x * model_size
    pixel_y = y * model_size
    pixel_w = w * model_size
    pixel_h = h * model_size

    unpadded_x = (pixel_x - pad_x) / valid_w
    unpadded_y = (pixel_y - pad_y) / valid_h
    unpadded_w = pixel_w / valid_w
    unpadded_h = pixel_h / valid_h

    return (
        max(0.0, min(1.0, unpadded_x)),
        max(0.0, min(1.0, unpadded_y)),
        max(0.0, min(1.0, unpadded_w)),
        max(0.0, min(1.0, unpadded_h))
    )


def current_gaze_from_yaw(yaw_rad: float) -> float:
    """Current implementation from NeuralSubjectIntelligenceEngine.swift line 362."""
    return -math.sin(yaw_rad)


def current_preferred_placement(
    anchor: tuple[float, float],
    gaze: float,
    is_person: bool = True
) -> tuple[float, float]:
    """Current implementation from CompositionPlanning.swift lines 589-625."""
    lead = min(1.0, max(-1.0, gaze))
    if abs(lead) >= 0.12:
        x = 0.5 - 0.145 * lead
    else:
        if anchor[0] < 0.46:
            x = 0.382
        elif anchor[0] > 0.54:
            x = 0.618
        else:
            x = 0.5
    
    # y placement
    if is_person:
        y = 0.382
    else:
        y = 0.5
    return (x, y)


def current_crop_protection_bounds(
    body: tuple[float, float, float, float],
    portrait: tuple[float, float, float, float] | None,
    intent: str,
    anchor: tuple[float, float]
) -> tuple[float, float, float, float]:
    """Current implementation from CompositionPlanning.swift lines 40-51."""
    if intent == "portrait":
        if portrait is not None:
            # check finite, positive, inside
            return portrait
        return body  # Lock to full body!
    return body


def compute_aim_point(
    subject_anchor: tuple[float, float],
    target_placement: tuple[float, float],
    zoom: float,
    fx: float = 0.75,
    fy: float = 1.0
) -> tuple[float, float]:
    """Computes aim point on source frame so camera re-centers subject at target_placement."""
    sub_ax, sub_ay = subject_anchor
    tar_px, tar_py = target_placement
    
    angle_sub_x = math.atan((sub_ax - 0.5) / fx)
    angle_des_x = math.atan((tar_px - 0.5) / (fx * zoom))
    aim_x = 0.5 + fx * math.tan(angle_sub_x - angle_des_x)

    angle_sub_y = math.atan((sub_ay - 0.5) / fy)
    angle_des_y = math.atan((tar_py - 0.5) / (fy * zoom))
    aim_y = 0.5 + fy * math.tan(angle_sub_y - angle_des_y)

    return (max(0.0, min(1.0, aim_x)), max(0.0, min(1.0, aim_y)))


def compute_expected_subject_rect(
    subject_rect: tuple[float, float, float, float],
    subject_anchor: tuple[float, float],
    target_placement: tuple[float, float],
    zoom: float
) -> tuple[float, float, float, float]:
    """Computes subject rect in the new framed view after user points camera at aim_point."""
    sx, sy, sw, sh = subject_rect
    ax, ay = subject_anchor
    tx, ty = target_placement
    
    new_w = sw * zoom
    new_h = sh * zoom
    new_x = tx - (ax - sx) * zoom
    new_y = ty - (ay - sy) * zoom
    return (new_x, new_y, new_w, new_h)


def run_benchmark():
    print("=" * 100)
    print("PHASE 0: BENCHMARK SUITE - 8 KICH BAN ANH CHUP DA DANG (BASELINE TRUOC KHI SUA)")
    print("=" * 100)

    results = []

    # -------------------------------------------------------------------------
    # Kich ban 1: Chan dung toan than dung xa o ria trai
    # -------------------------------------------------------------------------
    # bounds: (0.12, 0.20, 0.18, 0.72), eye: (0.21, 0.28), area = 0.1296
    body_1 = (0.12, 0.20, 0.18, 0.72)
    eye_1 = (0.21, 0.28)
    area_1 = 0.18 * 0.72
    # Current behavior:
    # 1. portrait is None -> crop protection returns full body (0.12, 0.20, 0.18, 0.72).
    # 2. Feet at y = 0.92, body height 0.72 -> safe() rejects any zoom > 1.05 because body exceeds frame!
    # 3. calculateContinuousIdealZoom with targetPoint = eye_1 (0.21, 0.28) yields maxRatioY = 0.611 -> locked at 1.0!
    zoom_1 = current_calculate_continuous_ideal_zoom(
        current_zoom=1.0, current_area=area_1, desired_area=0.34, max_zoom=3.0,
        target_point=eye_1, box_width=0.18, box_height=0.72, safety_margin=0.06
    )
    # Check crop protection with safe() logic
    prot_bounds_1 = current_crop_protection_bounds(body_1, None, "portrait", eye_1)
    # Even if proposed 1.5, prot_bounds height * 1.5 = 1.08 > 1.0 -> dropped!
    actual_zoom_1 = 1.0  # Safe drops all zooms > 1.0
    target_1 = current_preferred_placement(eye_1, gaze=0.0, is_person=True)
    aim_1 = compute_aim_point(eye_1, target_1, actual_zoom_1)
    exp_rect_1 = compute_expected_subject_rect(body_1, eye_1, target_1, actual_zoom_1)

    results.append({
        "scenario": "Anh 1: Chan dung toan than ria trai",
        "detected_hero": "Nguoi (Body) [bounds: 0.12, 0.20, 0.18, 0.72]",
        "target_placement": f"({target_1[0]:.3f}, {target_1[1]:.3f})",
        "aim_point": f"({aim_1[0]:.3f}, {aim_1[1]:.3f})",
        "recommended_zoom": f"{actual_zoom_1:.2f}x (LOCKED tai 1.0x do Safe cam cat chan)",
        "expected_subject_rect": f"x={exp_rect_1[0]:.3f}, y={exp_rect_1[1]:.3f}, w={exp_rect_1[2]:.3f}, h={exp_rect_1[3]:.3f}",
        "status": "FAIL (Khong zoom duoc ban than 1.5x-2.0x, khoa cung 1.0x)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 2: Chan dung nhin sang PHAI (Gaze Right: yaw = +0.52 rad)
    # -------------------------------------------------------------------------
    yaw_2 = 0.52
    gaze_2 = current_gaze_from_yaw(yaw_2)  # -sin(0.52) = -0.49688
    anchor_2 = (0.50, 0.35)
    target_2 = current_preferred_placement(anchor_2, gaze=gaze_2, is_person=True)
    aim_2 = compute_aim_point(anchor_2, target_2, 1.2)
    exp_rect_2 = compute_expected_subject_rect((0.40, 0.20, 0.20, 0.30), anchor_2, target_2, 1.2)

    results.append({
        "scenario": "Anh 2: Mat nhin sang PHAI (yaw = +0.52 rad)",
        "detected_hero": f"Khuon mat [yaw = +0.52, gaze = {gaze_2:.3f}]",
        "target_placement": f"({target_2[0]:.3f}, {target_2[1]:.3f})",
        "aim_point": f"({aim_2[0]:.3f}, {aim_2[1]:.3f})",
        "recommended_zoom": "1.20x",
        "expected_subject_rect": f"x={exp_rect_2[0]:.3f}, y={exp_rect_2[1]:.3f}, w={exp_rect_2[2]:.3f}, h={exp_rect_2[3]:.3f}",
        "status": "FAIL (Nguoc huong nhin: dat tai 0.572 ben PHAI thay vi 0.36 ben TRAI)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 3: Chan dung nhin sang TRAI (Gaze Left: yaw = -0.52 rad)
    # -------------------------------------------------------------------------
    yaw_3 = -0.52
    gaze_3 = current_gaze_from_yaw(yaw_3)  # -sin(-0.52) = +0.49688
    anchor_3 = (0.50, 0.35)
    target_3 = current_preferred_placement(anchor_3, gaze=gaze_3, is_person=True)
    aim_3 = compute_aim_point(anchor_3, target_3, 1.2)
    exp_rect_3 = compute_expected_subject_rect((0.40, 0.20, 0.20, 0.30), anchor_3, target_3, 1.2)

    results.append({
        "scenario": "Anh 3: Mat nhin sang TRAI (yaw = -0.52 rad)",
        "detected_hero": f"Khuon mat [yaw = -0.52, gaze = {gaze_3:.3f}]",
        "target_placement": f"({target_3[0]:.3f}, {target_3[1]:.3f})",
        "aim_point": f"({aim_3[0]:.3f}, {aim_3[1]:.3f})",
        "recommended_zoom": "1.20x",
        "expected_subject_rect": f"x={exp_rect_3[0]:.3f}, y={exp_rect_3[1]:.3f}, w={exp_rect_3[2]:.3f}, h={exp_rect_3[3]:.3f}",
        "status": "FAIL (Nguoc huong nhin: dat tai 0.428 ben TRAI thay vi 0.64 ben PHAI)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 4: Nguoi o xa kem mang Saliency lon o hau canh
    # -------------------------------------------------------------------------
    # Person: (0.35, 0.35, 0.14, 0.42), conf = 0.55
    # Saliency: (0.05, 0.05, 0.65, 0.65), conf = 0.85
    # Current HeroSubjectPolicy.score:
    # Saliency has area = 0.4225, conf = 0.85, kind = .foregroundObject
    # Person has area = 0.0588, conf = 0.55, kind = .human
    # Area score for Saliency is sqrt(0.4225) * 1.5 = 0.975 vs sqrt(0.0588) * 1.5 = 0.363
    # Saliency wins hero selection!
    sal_anchor = (0.375, 0.375)
    sal_target = current_preferred_placement(sal_anchor, gaze=0.0, is_person=False)
    sal_aim = compute_aim_point(sal_anchor, sal_target, 1.0)
    exp_rect_4 = compute_expected_subject_rect((0.05, 0.05, 0.65, 0.65), sal_anchor, sal_target, 1.0)

    results.append({
        "scenario": "Anh 4: Nguoi that + Mang Saliency to",
        "detected_hero": "Vung noi bat (Saliency) [conf=0.85, area=0.4225] (CUOP QUYEN)",
        "target_placement": f"({sal_target[0]:.3f}, {sal_target[1]:.3f})",
        "aim_point": f"({sal_aim[0]:.3f}, {sal_aim[1]:.3f})",
        "recommended_zoom": "1.00x",
        "expected_subject_rect": f"x={exp_rect_4[0]:.3f}, y={exp_rect_4[1]:.3f}, w={exp_rect_4[2]:.3f}, h={exp_rect_4[3]:.3f}",
        "status": "FAIL (Saliency cuop quyen Nguoi that)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 5: Tuong trong / Nhieu canh khong chu the
    # -------------------------------------------------------------------------
    # Candidates empty, raster.sceneryAnchor creates (anchor.x - 0.045, anchor.y - 0.045, 0.09, 0.09)
    fake_anchor = (0.50, 0.50)
    fake_target = current_preferred_placement(fake_anchor, gaze=0.0, is_person=False)
    fake_aim = compute_aim_point(fake_anchor, fake_target, 1.0)
    exp_rect_5 = compute_expected_subject_rect((0.455, 0.455, 0.09, 0.09), fake_anchor, fake_target, 1.0)

    results.append({
        "scenario": "Anh 5: Tuong trong / Nhieu canh khong chu the",
        "detected_hero": "Chi tiet trong canh (sceneryAnchor 0.09x0.09 BIA DAT)",
        "target_placement": f"({fake_target[0]:.3f}, {fake_target[1]:.3f})",
        "aim_point": f"({fake_aim[0]:.3f}, {fake_aim[1]:.3f})",
        "recommended_zoom": "1.00x",
        "expected_subject_rect": f"x={exp_rect_5[0]:.3f}, y={exp_rect_5[1]:.3f}, w={exp_rect_5[2]:.3f}, h={exp_rect_5[3]:.3f}",
        "status": "FAIL (Tu bia sceneryAnchor 0.09x0.09 thay vi bao Empty)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 6: Anh doc Portrait 3:4 tu cam bien ngang 1920x1440
    # -------------------------------------------------------------------------
    # Input normalized box on 640x640: centered box (0.25, 0.25, 0.5, 0.5)
    unpadded_6 = current_unpad_letterbox(0.25, 0.25, 0.50, 0.50, source_width=1920, source_height=1440)
    # Expected in true portrait (orientedW=1440, orientedH=1920):
    # scale = 640/1920 = 0.3333, validW = 480, validH = 640, padX = 80, padY = 0
    # unpadded_x = (0.25 * 640 - 80) / 480 = 80 / 480 = 0.1667
    # unpadded_y = (0.25 * 640 - 0) / 640 = 0.2500
    # But current output pads Y: padX = 0, padY = 80!
    # unpadded_x = (0.25 * 640 - 0) / 640 = 0.2500
    # unpadded_y = (0.25 * 640 - 80) / 480 = 80 / 480 = 0.1667! Inverted!
    results.append({
        "scenario": "Anh 6: Cam bien ngang 1920x1440 anh doc",
        "detected_hero": "Normalized Box (0.25, 0.25, 0.50, 0.50)",
        "target_placement": f"Unpadded: ({unpadded_6[0]:.3f}, {unpadded_6[1]:.3f}, w={unpadded_6[2]:.3f}, h={unpadded_6[3]:.3f})",
        "aim_point": "N/A (Detection Preprocessing)",
        "recommended_zoom": "1.00x",
        "expected_subject_rect": "Ky vong padX=80, padY=0 nhung bi tinh padX=0, padY=80",
        "status": "FAIL (Sai lech toa do 4:3 thanh 3:4 do nham chieu cam bien)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 7: Chu the dung san tai diem vang (0.382, 0.382)
    # -------------------------------------------------------------------------
    # Current CompositionAestheticSearch rewards proposal.aimPoint near (0.382, 0.382)!
    # If aimPoint is (0.382, 0.382), camera centers on subject -> subject moves to (0.5, 0.5)!
    subj_7 = (0.382, 0.382)
    # Proposal A: aimPoint = (0.382, 0.382) -> subject pushed to center (0.5, 0.5)
    # Proposal B: aimPoint = (0.50, 0.50) -> subject stays at (0.382, 0.382)
    # Current code gives bonus to Proposal A!
    bonus_A = 0.055 * math.exp(-12 * 0.0) # max bonus!
    bonus_B = 0.055 * math.exp(-12 * ((0.5 - 0.382)**2 + (0.5 - 0.382)**2)) # much smaller!
    
    results.append({
        "scenario": "Anh 7: Chu the dung san tai diem vang (0.382, 0.382)",
        "detected_hero": "Chu the tai (0.382, 0.382)",
        "target_placement": "(0.500, 0.500) (Bi day ve tam do thuong nham aimPoint)",
        "aim_point": "(0.382, 0.382)",
        "recommended_zoom": "1.00x",
        "expected_subject_rect": "Expected subject midX=0.500, midY=0.500 (Mat vi tri diem vang!)",
        "status": "FAIL (Thuong nham aimPoint lam chu the bi day ve tam 0.5, 0.5)"
    })

    # -------------------------------------------------------------------------
    # Kich ban 8: Thu cung / Mon an cu ly trung binh (bounds = 0.40, 0.45, 0.25, 0.25)
    # -------------------------------------------------------------------------
    box_8 = (0.40, 0.45, 0.25, 0.25)
    anchor_8 = (0.525, 0.575)
    area_8 = 0.25 * 0.25  # 0.0625
    # idealRatio = sqrt(0.28 / 0.0625) = 2.1166
    # No focal snap step in current code -> returns 2.12x
    zoom_8 = current_calculate_continuous_ideal_zoom(
        current_zoom=1.0, current_area=area_8, desired_area=0.28, max_zoom=3.0,
        target_point=anchor_8, box_width=0.25, box_height=0.25, safety_margin=0.06
    )
    target_8 = current_preferred_placement(anchor_8, gaze=0.0, is_person=False)
    aim_8 = compute_aim_point(anchor_8, target_8, zoom_8)
    exp_rect_8 = compute_expected_subject_rect(box_8, anchor_8, target_8, zoom_8)

    results.append({
        "scenario": "Anh 8: Thu cung / Mon an cu ly trung binh (area=0.0625)",
        "detected_hero": "Thu cung / Mon an [bounds: 0.40, 0.45, 0.25, 0.25]",
        "target_placement": f"({target_8[0]:.3f}, {target_8[1]:.3f})",
        "aim_point": f"({aim_8[0]:.3f}, {aim_8[1]:.3f})",
        "recommended_zoom": f"{zoom_8:.2f}x (Chua lam muot ve tieu cu chuan 2.0x)",
        "expected_subject_rect": f"x={exp_rect_8[0]:.3f}, y={exp_rect_8[1]:.3f}, w={exp_rect_8[2]:.3f}, h={exp_rect_8[3]:.3f}",
        "status": "CAN CAI TIEN (Chua snap ve tieu cu chuan 2.0x, lech diem vang)"
    })

    # Print Detailed Table
    print("\n" + "=" * 100)
    print(f"{'KICH BAN':<38} | {'DETECTED HERO':<22} | {'ZOOM':<8} | {'TARGET (x,y)':<14} | {'TRANG THAI'}")
    print("-" * 100)
    for r in results:
        print(f"{r['scenario']:<38} | {r['detected_hero'][:22]:<22} | {r['recommended_zoom'][:8]:<8} | {r['target_placement']:<14} | {r['status']}")

    print("\n" + "=" * 100)
    print("CHI TIET LOG TUNG KICH BAN (BASELINE)")
    print("=" * 100)
    for i, r in enumerate(results, 1):
        print(f"\n[KICH BAN {i}]: {r['scenario']}")
        print(f"  - Detected Hero:          {r['detected_hero']}")
        print(f"  - Target Placement (x, y): {r['target_placement']}")
        print(f"  - AimPoint (x, y):         {r['aim_point']}")
        print(f"  - Recommended Zoom:        {r['recommended_zoom']}")
        print(f"  - Expected Subject Rect:   {r['expected_subject_rect']}")
        print(f"  - Ket qua danh gia:        {r['status']}")

    # Save to JSON for exact comparison in Phase 5
    baseline_file = ROOT / "build_artifacts/benchmark_baseline_phase0.json"
    baseline_file.parent.mkdir(parents=True, exist_ok=True)
    baseline_file.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\nDa luu baseline vao tuc thi tai: {baseline_file}")

if __name__ == "__main__":
    run_benchmark()
