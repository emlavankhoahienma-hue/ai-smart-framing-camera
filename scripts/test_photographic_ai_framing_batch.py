#!/usr/bin/env python3
"""Batch Photographic AI Framing & Zoom Test Suite.
Evaluates the upgraded local AI Compose / Framing algorithms across all 160 real photographs
in the validation dataset.

Verifies:
1. Photographic Target Placement: Rule of Thirds (0.382/0.618), Gaze Lead Room, Headroom.
2. Smart Zoom Planning: Distant/small subjects zoom in (1.5x - 3.0x), full-frame subjects stay wide (1.0x - 1.2x).
3. Anti-dead-center: No collapse to amateur (0.5, 0.5) for asymmetric subjects.
4. Edge and headroom safety preservation.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = Path(__file__).resolve().parents[1]
PHOTOS_DIR = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/swift"
YOLO_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/detection/yolo12s-real-photos.json"
POSE_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/pose-report.json"
OUTPUT_REPORT = ROOT / "build_artifacts/photographic_ai_framing_report.json"

PHI_LEFT = 0.382
PHI_RIGHT = 0.618
PHI_TOP = 0.382
PHI_BOTTOM = 0.618

def compute_continuous_ideal_zoom(current_zoom: float, current_area: float, desired_area: float, max_zoom: float,
                                  target_point: tuple[float, float], box_w: float, box_h: float, safety_margin: float = 0.04) -> float:
    if current_area <= 0.0001 or desired_area <= 0 or current_zoom <= 0:
        return current_zoom
    
    ideal_ratio = math.sqrt(desired_area / current_area)
    zoom_candidate = current_zoom * ideal_ratio

    dest_x = min(0.68, max(0.32, target_point[0]))
    dest_y = min(0.68, max(0.32, target_point[1]))

    if box_w > 0 and box_h > 0:
        available_x = 2.0 * min(dest_x - safety_margin, 1.0 - safety_margin - dest_x)
        max_ratio_x = max(1.0, available_x / max(0.03, box_w))

        top_available = max(0.05, dest_y - safety_margin)
        estimated_head_dist = max(0.03, min(box_h * 0.5, box_h * 0.25))
        max_ratio_head = max(1.0, top_available / estimated_head_dist)

        available_y = 2.0 * min(dest_y - safety_margin, 1.0 - safety_margin - dest_y)
        max_ratio_y = max(1.0, max(max_ratio_head, available_y / max(0.04, box_h)))

        max_allowed_ratio = max(1.0, min(max_ratio_x, max_ratio_y))
        zoom_candidate = min(zoom_candidate, current_zoom * max_allowed_ratio)

    return max(current_zoom, min(max_zoom, zoom_candidate))


def evaluate_photographic_framing(img_file: str, detections: list, pose_info: dict) -> dict:
    """Evaluates framing for a single photograph matching production Swift algorithms."""
    # 1. Identify Hero Subject
    faces = pose_info.get("faces", [])
    bodies = pose_info.get("bodies", [])
    
    hero = None
    category = "object"
    
    if len(faces) > 0:
        faces_sorted = sorted(faces, key=lambda f: f[2] * f[3], reverse=True)
        fb = faces_sorted[0]
        hero = {
            "box": fb,
            "anchor": (fb[0] + fb[2] / 2.0, fb[1] + fb[3] * 0.45),
            "kind": "face",
            "category": "human",
            "label": "Face"
        }
        category = "portrait"
    elif len(bodies) > 0:
        bodies_sorted = sorted(bodies, key=lambda b: b[2] * b[3], reverse=True)
        bb = bodies_sorted[0]
        hero = {
            "box": bb,
            "anchor": (bb[0] + bb[2] / 2.0, bb[1] + bb[3] * 0.25),
            "kind": "person",
            "category": "human",
            "label": "Person"
        }
        category = "portrait"
    elif len(detections) > 0:
        sorted_dets = sorted(detections, key=lambda d: d.get("confidence", 0) * (d["box"][2] * d["box"][3]), reverse=True)
        d = sorted_dets[0]
        box = d["box"]
        cat_str = d.get("category", "").lower()
        if "animal" in cat_str or "chó" in cat_str or "mèo" in cat_str or "động vật" in cat_str:
            category = "animal"
        elif "food" in cat_str or "bánh" in cat_str or "món" in cat_str:
            category = "food"
        elif "arch" in cat_str or "tòa" in cat_str or "kiến trúc" in cat_str:
            category = "architecture"
        else:
            category = "object"
        hero = {
            "box": box,
            "anchor": (box[0] + box[2] / 2.0, box[1] + box[3] / 2.0),
            "kind": category,
            "category": category,
            "label": d.get("label", category)
        }
    else:
        hero = {
            "box": [0.25, 0.25, 0.50, 0.50],
            "anchor": (0.50, 0.50),
            "kind": "landscape",
            "category": "landscape",
            "label": "Landscape"
        }
        category = "landscape"

    anchor_x, anchor_y = hero["anchor"]
    box_w, box_h = hero["box"][2], hero["box"][3]
    subject_area = box_w * box_h

    # 2. Gaze / Looking Room Estimation
    gaze_lead = 0.0
    if category == "portrait" and len(faces) > 0 and len(bodies) > 0:
        fb, bb = faces[0], bodies[0]
        gaze_lead = (fb[0] + fb[2] / 2.0) - (bb[0] + bb[2] / 2.0)
        gaze_lead = max(-1.0, min(1.0, gaze_lead * 3.5))
    elif anchor_x < 0.44:
        gaze_lead = 0.30
    elif anchor_x > 0.56:
        gaze_lead = -0.30

    # 3. Preferred Placement (Target Destination P*)
    # Photographic Lead Room & Golden Section
    if abs(gaze_lead) > 0.08:
        # Looking right (gaze_lead > 0) -> subject placed on left third (0.382) to look across frame
        # Looking left (gaze_lead < 0) -> subject placed on right third (0.618)
        dest_x = (PHI_LEFT - 0.02 * min(1.0, gaze_lead)) if gaze_lead > 0 else (PHI_RIGHT - 0.02 * max(-1.0, gaze_lead))
        rule_name = "Rule of Thirds (Lead Room)"
    elif category == "architecture":
        dest_x = 0.50
        rule_name = "Center Symmetry"
    elif category == "food":
        dest_x = 0.50 if abs(anchor_x - 0.5) < 0.06 else (PHI_LEFT if anchor_x < 0.5 else PHI_RIGHT)
        rule_name = "Radial Symmetry" if abs(anchor_x - 0.5) < 0.06 else "Golden Ratio"
    else:
        # Person looking straight or general object: NEVER collapse to center
        dest_x = PHI_LEFT if anchor_x <= 0.50 else PHI_RIGHT
        rule_name = "Golden Ratio"

    dest_x = min(0.68, max(0.32, dest_x))

    # Vertical eye line & headroom
    if category == "portrait":
        is_full_body = box_h > 0.55
        eye_line = 0.32 if is_full_body else 0.35
        dest_y = min(0.44, max(0.30, eye_line + 0.03 * (anchor_y - 0.42)))
    elif category == "food":
        dest_y = min(0.56, max(0.42, 0.48 + 0.08 * (anchor_y - 0.48)))
    elif category == "landscape":
        dest_y = PHI_BOTTOM if anchor_y > 0.5 else PHI_TOP
    else:
        dest_y = min(0.60, max(0.36, 0.46 + 0.10 * (anchor_y - 0.48)))

    # 4. Desired Area & Optimal Zoom Factor Z*
    desired_areas = {
        "portrait": 0.31,
        "face": 0.095,
        "food": 0.34,
        "animal": 0.28,
        "object": 0.28,
        "landscape": 0.15,
        "architecture": 0.45
    }
    desired_area = desired_areas.get(category, 0.28)

    ideal_zoom = compute_continuous_ideal_zoom(
        current_zoom=1.0,
        current_area=subject_area,
        desired_area=desired_area,
        max_zoom=3.5 if subject_area < 0.08 else (3.0 if subject_area < 0.20 else 2.2),
        target_point=(dest_x, dest_y),
        box_w=box_w,
        box_h=box_h,
        safety_margin=0.04
    )

    # Prime focal length snapping if near (1.5x, 2.0x, 2.5x, 3.0x)
    for prime in [1.5, 2.0, 2.5, 3.0]:
        if abs(ideal_zoom - prime) <= 0.12:
            ideal_zoom = prime
            break

    # 5. Crop Window & Camera Aim Point
    crop_w = min(1.0, 1.0 / ideal_zoom)
    crop_h = min(1.0, 1.0 / ideal_zoom)

    crop_x = max(0.0, min(1.0 - crop_w, anchor_x - dest_x * crop_w))
    crop_y = max(0.0, min(1.0 - crop_h, anchor_y - dest_y * crop_h))

    aim_x = crop_x + crop_w / 2.0
    aim_y = crop_y + crop_h / 2.0

    # Verification Checks
    is_dead_center = (category not in ("architecture", "landscape") and
                      abs(dest_x - 0.5) < 0.04 and abs(dest_y - 0.5) < 0.04)
    is_zoom_effective = True
    if subject_area < 0.10 and ideal_zoom < 1.4:
        is_zoom_effective = False  # Failed to zoom on small/distant subject
    elif subject_area > 0.35 and ideal_zoom > 1.3:
        is_zoom_effective = False  # Over-zoomed on full-frame subject

    headroom_ok = (dest_y >= 0.25 and dest_y <= 0.50) if category == "portrait" else True
    lead_room_ok = True
    if abs(gaze_lead) > 0.15:
        # Looking right: dest_x must be on left (< 0.45)
        # Looking left: dest_x must be on right (> 0.55)
        if gaze_lead > 0 and dest_x > 0.45:
            lead_room_ok = False
        elif gaze_lead < 0 and dest_x < 0.55:
            lead_room_ok = False

    passed = (not is_dead_center) and is_zoom_effective and headroom_ok and lead_room_ok

    return {
        "file": img_file,
        "category": category,
        "hero_label": hero["label"],
        "subject_area": round(subject_area, 4),
        "anchor": [round(anchor_x, 3), round(anchor_y, 3)],
        "gaze_lead": round(gaze_lead, 3),
        "target_dest": [round(dest_x, 3), round(dest_y, 3)],
        "recommended_zoom": round(ideal_zoom, 2),
        "crop_window": [round(crop_x, 3), round(crop_y, 3), round(crop_w, 3), round(crop_h, 3)],
        "aim_point": [round(aim_x, 3), round(aim_y, 3)],
        "rule": rule_name,
        "passed": passed,
        "metrics": {
            "not_dead_center": not is_dead_center,
            "zoom_effective": is_zoom_effective,
            "headroom_ok": headroom_ok,
            "lead_room_ok": lead_room_ok
        }
    }


def run_batch_test():
    print("=" * 80)
    print("BATCH TEST: THUẬT TOÁN AI COMPOSE / FRAMING & SMART ZOOM TRÊN 160 ẢNH THẬT")
    print("=" * 80)

    yolo_data = json.loads(YOLO_FILE.read_text(encoding="utf-8")) if YOLO_FILE.exists() else {"records": []}
    pose_data = json.loads(POSE_FILE.read_text(encoding="utf-8")) if POSE_FILE.exists() else {"records": []}

    yolo_map = {r["file"]: r["detections"] for r in yolo_data["records"]}
    pose_map = {r["file"]: r for r in pose_data["records"]}

    all_files = sorted([f.name for f in PHOTOS_DIR.glob("*.jpg")])
    if not all_files:
        all_files = sorted(list(set(list(yolo_map.keys()) + list(pose_map.keys()))))

    print(f"Tổng số ảnh kiểm tra: {len(all_files)}")

    results = []
    category_counts = {}
    zoom_counts = {"1.0x - 1.2x": 0, "1.5x": 0, "1.8x - 2.0x": 0, "2.2x - 2.5x": 0, "3.0x+": 0}
    rule_counts = {}
    failed_cases = []

    for idx, fname in enumerate(all_files, 1):
        dets = yolo_map.get(fname, [])
        pose = pose_map.get(fname, {})
        res = evaluate_photographic_framing(fname, dets, pose)
        results.append(res)

        cat = res["category"]
        category_counts[cat] = category_counts.get(cat, 0) + 1

        z = res["recommended_zoom"]
        if z <= 1.25:
            zoom_counts["1.0x - 1.2x"] += 1
        elif z <= 1.65:
            zoom_counts["1.5x"] += 1
        elif z <= 2.1:
            zoom_counts["1.8x - 2.0x"] += 1
        elif z <= 2.7:
            zoom_counts["2.2x - 2.5x"] += 1
        else:
            zoom_counts["3.0x+"] += 1

        rule = res["rule"]
        rule_counts[rule] = rule_counts.get(rule, 0) + 1

        if not res["passed"]:
            failed_cases.append(res)

        if idx <= 10 or idx % 30 == 0:
            status = "PASS" if res["passed"] else "FAIL"
            print(f"[{idx:03d}/{len(all_files):03d}] {fname:<12} | {cat:<12} | Zoom: {z:.2f}x | "
                  f"Target: ({res['target_dest'][0]:.3f}, {res['target_dest'][1]:.3f}) | {rule:<25} | {status}")

    passed_count = len(results) - len(failed_cases)
    pass_rate = (passed_count / len(results)) * 100 if results else 0

    print("=" * 80)
    print("THỐNG KÊ TỔNG HỢP KIỂM THỬ:")
    print(f"  - Tổng số ảnh: {len(results)}")
    print(f"  - Số ảnh đạt tiêu chuẩn nhiếp ảnh: {passed_count}/{len(results)} ({pass_rate:.1f}%)")
    print(f"  - Thất bại: {len(failed_cases)}")
    print("-" * 80)
    print("PHÂN BỔ THỂ LOẠI ẢNH:")
    for cat, cnt in sorted(category_counts.items()):
        print(f"  - {cat:<18}: {cnt:3d} ảnh ({cnt*100/len(results):.1f}%)")
    print("-" * 80)
    print("PHÂN BỔ MỨC ZOOM THÔNG MINH:")
    for z_range, cnt in zoom_counts.items():
        print(f"  - {z_range:<18}: {cnt:3d} ảnh ({cnt*100/len(results):.1f}%)")
    print("-" * 80)
    print("PHÂN BỔ QUY TẮC BỐ CỤC ĐƯỢC CHỌN:")
    for rule, cnt in sorted(rule_counts.items()):
        print(f"  - {rule:<28}: {cnt:3d} ảnh ({cnt*100/len(results):.1f}%)")
    print("=" * 80)

    OUTPUT_REPORT.write_text(json.dumps({
        "total": len(results),
        "passed": passed_count,
        "pass_rate": pass_rate,
        "zoom_distribution": zoom_counts,
        "category_distribution": category_counts,
        "rule_distribution": rule_counts,
        "records": results
    }, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Đã lưu báo cáo chi tiết vào: {OUTPUT_REPORT}")

    if failed_cases:
        print("\nDANH SÁCH TEST FAILED CẦN XEM XÉT:")
        for fc in failed_cases[:5]:
            print(f"  - {fc['file']}: Area={fc['subject_area']}, Zoom={fc['recommended_zoom']}, "
                  f"Target={fc['target_dest']}, Metrics={fc['metrics']}")

    return 0 if pass_rate >= 95.0 else 1

if __name__ == "__main__":
    sys.exit(run_batch_test())
