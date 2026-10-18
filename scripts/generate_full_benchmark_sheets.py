#!/usr/bin/env python3
"""Full Python Diagnostic & Visual Evaluation Suite for AI Smart Framing Camera.

Tests YOLOv12 object bounding boxes and Swift CompositionPlanning framing on:
  1. The 6 exact COCO photos shown in user's reference image
  2. 12 diverse real-world photographic test photos (portraits, animals, food, objects, street)
Produces 4-column diagnostic sheets and geometric validation reports.
"""
from __future__ import annotations

import io
import json
import math
from pathlib import Path
import shutil

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SWIFT_PHOTOS = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/swift"
YOLO_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/detection/yolo12s-real-photos.json"
POSE_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/pose-report.json"
COCO_DIR = ROOT / "build_artifacts/diagnostic_sheets/user_coco"
OUTPUT_DIR = ROOT / "build_artifacts/diagnostic_sheets"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Golden Ratio and Rule of Thirds constants (from CompositionPlanning.swift)
PHI_LEFT = 0.382
PHI_RIGHT = 0.618
PHI_TOP = 0.382
PHI_BOTTOM = 0.618
THIRD_LEFT = 1.0 / 3.0
THIRD_RIGHT = 2.0 / 3.0
THIRD_TOP = 1.0 / 3.0
THIRD_BOTTOM = 2.0 / 3.0

def get_font(size: int = 14, bold: bool = False):
    font_names = ["segoeuib.ttf", "arialbd.ttf"] if bold else ["segoeui.ttf", "arial.ttf", "calibri.ttf"]
    for name in font_names:
        p = Path("C:/Windows/Fonts") / name
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size=size)
            except Exception:
                pass
    return ImageFont.load_default()

FONT_TITLE = get_font(16, bold=True)
FONT_SUBTITLE = get_font(12, bold=False)
FONT_ROW_TITLE = get_font(13, bold=True)
FONT_HEADER = get_font(12, bold=True)
FONT_BADGE = get_font(11, bold=True)

# Exact detections for user COCO images (ground truth & YOLO12s from user's benchmark image)
COCO_DETECTIONS = {
    "000000147205.jpg": {
        "scene": "food",
        "description": "Bàn ăn & Món gà quay (Food / Tableware)",
        "detections": [
            {"box": [0.00, 0.05, 0.16, 0.18], "label": "Bánh ngọt", "confidence": 0.50, "category": "Food"},
            {"box": [0.00, 0.02, 0.25, 0.15], "label": "Bàn ăn", "confidence": 0.70, "category": "Object"},
            {"box": [0.15, 0.15, 0.75, 0.72], "label": "Món chính (Gà quay)", "confidence": 0.94, "category": "Food"}
        ],
        "pose": {}
    },
    "000000275791.jpg": {
        "scene": "cityscape",
        "description": "Tàu hỏa & Thuyền trên kênh (Train & Canal Boats)",
        "detections": [
            {"box": [0.43, 0.23, 0.22, 0.08], "label": "Tàu hỏa", "confidence": 0.81, "category": "Vehicle"},
            {"box": [0.40, 0.28, 0.15, 0.10], "label": "Thuyền", "confidence": 0.51, "category": "Vehicle"},
            {"box": [0.51, 0.27, 0.12, 0.08], "label": "Thuyền", "confidence": 0.67, "category": "Vehicle"},
            {"box": [0.58, 0.26, 0.10, 0.08], "label": "Thuyền", "confidence": 0.69, "category": "Vehicle"},
            {"box": [0.33, 0.29, 0.12, 0.08], "label": "Thuyền", "confidence": 0.47, "category": "Vehicle"},
            {"box": [0.82, 0.25, 0.12, 0.08], "label": "Thuyền", "confidence": 0.70, "category": "Vehicle"}
        ],
        "pose": {}
    },
    "000000013201.jpg": {
        "scene": "human",
        "description": "Vận động viên trượt ván (Skateboarder Action)",
        "detections": [
            {"box": [0.45, 0.37, 0.12, 0.23], "label": "Người", "confidence": 0.92, "category": "Human"},
            {"box": [0.46, 0.44, 0.05, 0.04], "label": "Ván trượt", "confidence": 0.91, "category": "Object"}
        ],
        "pose": {
            "bodies": [[0.45, 0.37, 0.12, 0.23]],
            "faces": [[0.50, 0.41, 0.04, 0.04]]
        }
    },
    "000000426268.jpg": {
        "scene": "architecture",
        "description": "Đầu máy xe lửa cổ & Bác tài (Vintage Locomotive & Driver)",
        "detections": [
            {"box": [0.33, 0.53, 0.62, 0.25], "label": "Tàu hỏa", "confidence": 0.90, "category": "Vehicle"},
            {"box": [0.47, 0.55, 0.04, 0.06], "label": "Người", "confidence": 0.74, "category": "Human"}
        ],
        "pose": {
            "bodies": [[0.47, 0.55, 0.04, 0.06]]
        }
    },
    "000000458223.jpg": {
        "scene": "human",
        "description": "Người dắt xe đạp bên ngọn hải đăng (Pier Lighthouse Walk)",
        "detections": [
            {"box": [0.41, 0.73, 0.04, 0.10], "label": "Người", "confidence": 0.88, "category": "Human"},
            {"box": [0.42, 0.75, 0.03, 0.07], "label": "Xe đạp", "confidence": 0.83, "category": "Vehicle"},
            {"box": [0.60, 0.72, 0.03, 0.03], "label": "Thuyền", "confidence": 0.70, "category": "Vehicle"},
            {"box": [0.36, 0.70, 0.05, 0.14], "label": "Hải đăng", "confidence": 0.92, "category": "Architecture"}
        ],
        "pose": {
            "bodies": [[0.41, 0.73, 0.04, 0.10]]
        }
    },
    "000000421923.jpg": {
        "scene": "indoor",
        "description": "Tượng, sách & bình hoa (Statue Bust & Still Life)",
        "detections": [
            {"box": [0.43, 0.90, 0.08, 0.12], "label": "Tượng", "confidence": 0.85, "category": "Object"},
            {"box": [0.48, 0.87, 0.05, 0.06], "label": "Sách", "confidence": 0.58, "category": "Object"},
            {"box": [0.48, 0.91, 0.07, 0.04], "label": "Sách", "confidence": 0.43, "category": "Object"},
            {"box": [0.55, 0.95, 0.04, 0.08], "label": "Bình hoa", "confidence": 0.78, "category": "Object"},
            {"box": [0.50, 0.92, 0.10, 0.08], "label": "Chậu hoa", "confidence": 0.48, "category": "Plant"}
        ],
        "pose": {}
    }
}

def compute_composition_plan(img_w: int, img_h: int, scene: str, detections: list, pose_info: dict) -> dict:
    """Exact implementation of CompositionPlanning.swift framing and crop window calculation."""
    bodies = pose_info.get("bodies", [])
    faces = pose_info.get("faces", [])
    
    hero = None
    hero_kind = "object"
    
    if len(faces) > 0:
        faces_sorted = sorted(faces, key=lambda f: f[2] * f[3], reverse=True)
        fb = faces_sorted[0]
        hero = {
            "box": fb,
            "anchor": (fb[0] + fb[2] / 2.0, fb[1] + fb[3] / 2.0),
            "kind": "face",
            "label": "Gương mặt (Face)",
            "confidence": 0.95
        }
        hero_kind = "portrait"
    elif len(bodies) > 0:
        bodies_sorted = sorted(bodies, key=lambda b: b[2] * b[3], reverse=True)
        bb = bodies_sorted[0]
        hero = {
            "box": bb,
            "anchor": (bb[0] + bb[2] / 2.0, bb[1] + bb[3] * 0.22), # upper body / eye anchor
            "kind": "person",
            "label": "Người (Person)",
            "confidence": 0.90
        }
        hero_kind = "portrait"
    elif len(detections) > 0:
        sorted_dets = sorted(detections, key=lambda d: d.get("confidence", 0) * (d["box"][2] * d["box"][3]), reverse=True)
        d = sorted_dets[0]
        b = d["box"]
        cat = d.get("category", "")
        kind = "animal" if "Animal" in cat or "Động vật" in cat else ("food" if "Food" in cat or "Món" in cat else "object")
        hero = {
            "box": b,
            "anchor": (b[0] + b[2] / 2.0, b[1] + b[3] / 2.0),
            "kind": kind,
            "label": d.get("label", "Subject"),
            "confidence": d.get("confidence", 0.8)
        }
        hero_kind = kind
    else:
        hero = {
            "box": [0.25, 0.25, 0.5, 0.5],
            "anchor": (0.5, 0.5),
            "kind": "scenery",
            "label": "Toàn cảnh (Scenery)",
            "confidence": 0.70
        }
        hero_kind = "landscape"

    anchor_x, anchor_y = hero["anchor"]
    
    # Looking room / gaze direction estimation
    gaze_lead = 0.0
    if hero_kind == "portrait":
        if len(faces) > 0 and len(bodies) > 0:
            fb = faces[0]
            bb = bodies[0]
            gaze_lead = (fb[0] + fb[2]/2.0) - (bb[0] + bb[2]/2.0)
            gaze_lead = max(-1.0, min(1.0, gaze_lead * 4.0))
        elif anchor_x < 0.44:
            gaze_lead = 0.22
        elif anchor_x > 0.56:
            gaze_lead = -0.22

    # Target Placement (Rule of Thirds & Golden Ratio from CompositionPlanning.swift)
    dest_x = 0.5
    dest_y = 0.5
    alignment_rule = "Center"
    
    if abs(gaze_lead) >= 0.12:
        dest_x = 0.5 - 0.145 * gaze_lead
        alignment_rule = "Gaze Lead (Looking Room)"
    else:
        if anchor_x < 0.46:
            dest_x = PHI_LEFT  # 0.382
            alignment_rule = "Golden Ratio Left (x=0.382)"
        elif anchor_x > 0.54:
            dest_x = PHI_RIGHT # 0.618
            alignment_rule = "Golden Ratio Right (x=0.618)"
        else:
            dest_x = 0.5
            alignment_rule = "Balanced Center (x=0.500)"

    # Vertical target:
    if hero_kind == "portrait":
        dest_y = min(0.44, max(0.30, 0.075 + anchor_y * 0.64))
        alignment_rule += " + Headroom 1/3"
    elif hero_kind == "food":
        dest_y = PHI_TOP if anchor_y < 0.46 else (PHI_BOTTOM if anchor_y > 0.54 else 0.5)
        alignment_rule += " + Table Level"
    elif hero_kind in ("animal", "object"):
        dest_y = PHI_TOP if anchor_y < 0.46 else (PHI_BOTTOM if anchor_y > 0.54 else 0.42)
        alignment_rule += " + Golden Y"
    else:
        dest_y = 0.48

    # Desired area and Zoom ratio calculation
    desired_areas = {
        "portrait": 0.34,
        "face": 0.16,
        "environmentalPortrait": 0.13,
        "group": 0.40,
        "landscape": 0.15,
        "architecture": 0.48,
        "food": 0.40,
        "animal": 0.32,
        "object": 0.32
    }
    desired_area = desired_areas.get(hero_kind, 0.30)
    current_area = hero["box"][2] * hero["box"][3]
    
    zoom_ratio = math.sqrt(desired_area / max(0.005, current_area))
    zoom_ratio = max(1.0, min(2.8, zoom_ratio))
    
    # Crop window size and position
    crop_w = 1.0 / zoom_ratio
    crop_h = 1.0 / zoom_ratio
    
    crop_x = anchor_x - dest_x * crop_w
    crop_y = anchor_y - dest_y * crop_h
    
    crop_x = max(0.0, min(1.0 - crop_w, crop_x))
    crop_y = max(0.0, min(1.0 - crop_h, crop_y))
    
    aim_x = crop_x + crop_w / 2.0
    aim_y = crop_y + crop_h / 2.0

    return {
        "hero": hero,
        "hero_kind": hero_kind,
        "gaze_lead": gaze_lead,
        "target_dest": (dest_x, dest_y),
        "alignment_rule": alignment_rule,
        "zoom_ratio": zoom_ratio,
        "crop_window": (crop_x, crop_y, crop_w, crop_h),
        "aim_point": (aim_x, aim_y)
    }

def draw_panel_detections(img: Image.Image, detections: list, hero: dict) -> Image.Image:
    panel = img.copy()
    draw = ImageDraw.Draw(panel)
    w, h = panel.size
    
    colors = {
        "Người": "#00E5FF",
        "Human": "#00E5FF",
        "Person": "#00E5FF",
        "Chó": "#FF9100",
        "Mèo": "#FF9100",
        "Animal": "#FF9100",
        "Bánh ngọt": "#00E676",
        "Món": "#00E676",
        "Food": "#00E676",
        "Gương mặt": "#FF4081",
        "Face": "#FF4081",
        "Tàu": "#00B0FF",
        "Vehicle": "#00B0FF",
        "Hải đăng": "#E040FB"
    }
    
    for d in detections:
        box = d.get("box", [0, 0, 0, 0])
        bx1 = int(box[0] * w)
        by1 = int(box[1] * h)
        bx2 = int((box[0] + box[2]) * w)
        by2 = int((box[1] + box[3]) * h)
        label = d.get("label", "Object")
        conf = d.get("confidence", 0.0)
        
        color = "#FFD700"
        for k, c in colors.items():
            if k in label or k in d.get("category", ""):
                color = c
                break
                
        draw.rectangle([bx1, by1, bx2, by2], outline=color, width=2)
        badge_text = f"{label} {conf:.2f}"
        bbox = draw.textbbox((0, 0), badge_text, font=FONT_BADGE)
        tw = bbox[2] - bbox[0] + 8
        th = bbox[3] - bbox[1] + 6
        draw.rectangle([bx1, max(0, by1 - th - 2), bx1 + tw, by1], fill=color)
        draw.text((bx1 + 4, max(0, by1 - th)), badge_text, fill="#000000", font=FONT_BADGE)

    if hero:
        ax = int(hero["anchor"][0] * w)
        ay = int(hero["anchor"][1] * h)
        draw.ellipse([ax - 5, ay - 5, ax + 5, ay + 5], fill="#FF1744", outline="#FFFFFF", width=1)
        
    return panel

def draw_panel_composition_guides(img: Image.Image, plan: dict) -> Image.Image:
    panel = img.copy()
    draw = ImageDraw.Draw(panel)
    w, h = panel.size
    
    # Rule of Thirds lines (subtle cyan)
    for tx in (THIRD_LEFT, THIRD_RIGHT):
        x = int(tx * w)
        draw.line([(x, 0), (x, h)], fill=(0, 229, 255, 120), width=1)
    for ty in (THIRD_TOP, THIRD_BOTTOM):
        y = int(ty * h)
        draw.line([(0, y), (w, y)], fill=(0, 229, 255, 120), width=1)
        
    # Golden Ratio lines (gold)
    for gx in (PHI_LEFT, PHI_RIGHT):
        x = int(gx * w)
        draw.line([(x, 0), (x, h)], fill="#FFD700", width=2)
    for gy in (PHI_TOP, PHI_BOTTOM):
        y = int(gy * h)
        draw.line([(0, y), (w, y)], fill="#FFD700", width=2)
        
    # 4 Golden Power Intersections
    for gx in (PHI_LEFT, PHI_RIGHT):
        for gy in (PHI_TOP, PHI_BOTTOM):
            px, py = int(gx * w), int(gy * h)
            draw.ellipse([px - 6, py - 6, px + 6, py + 6], outline="#FFD700", fill="#FFD700", width=2)
            draw.ellipse([px - 10, py - 10, px + 10, py + 10], outline="#FFD700", width=1)
            
    # Target Crosshair
    aim_x, aim_y = plan["aim_point"]
    cx, cy = int(aim_x * w), int(aim_y * h)
    draw.line([(cx - 15, cy), (cx + 15, cy)], fill="#00E676", width=2)
    draw.line([(cx, cy - 15), (cx, cy + 15)], fill="#00E676", width=2)
    draw.ellipse([cx - 8, cy - 8, cx + 8, cy + 8], outline="#00E676", width=2)
    
    # Gaze Lead arrow
    hero = plan["hero"]
    ax, ay = int(hero["anchor"][0] * w), int(hero["anchor"][1] * h)
    lead = plan["gaze_lead"]
    if abs(lead) > 0.05:
        arrow_dx = int(lead * 80)
        draw.line([(ax, ay), (ax + arrow_dx, ay)], fill="#FF4081", width=3)
        draw.polygon([(ax + arrow_dx, ay - 6), (ax + arrow_dx + (10 if arrow_dx > 0 else -10), ay), (ax + arrow_dx, ay + 6)], fill="#FF4081")
        
    return panel

def draw_panel_crop_window(img: Image.Image, plan: dict) -> Image.Image:
    w, h = img.size
    cx, cy, cw, ch = plan["crop_window"]
    x1, y1 = int(cx * w), int(cy * h)
    x2, y2 = int((cx + cw) * w), int((cy + ch) * h)
    
    overlay = np.array(img).astype(np.float32)
    overlay[:y1, :] *= 0.45
    overlay[y2:, :] *= 0.45
    overlay[y1:y2, :x1] *= 0.45
    overlay[y1:y2, x2:] *= 0.45
    panel = Image.fromarray(np.clip(overlay, 0, 255).astype(np.uint8))
    
    draw = ImageDraw.Draw(panel)
    draw.rectangle([x1, y1, x2, y2], outline="#00E5FF", width=2)
    bracket_len = min(24, int(min(cw * w, ch * h) * 0.15))
    for corner_x, corner_y, dx, dy in [(x1, y1, 1, 1), (x2, y1, -1, 1), (x1, y2, 1, -1), (x2, y2, -1, -1)]:
        draw.line([(corner_x, corner_y), (corner_x + dx * bracket_len, corner_y)], fill="#FFD700", width=4)
        draw.line([(corner_x, corner_y), (corner_x, corner_y + dy * bracket_len)], fill="#FFD700", width=4)
        
    tag = f"AI Zoom {plan['zoom_ratio']:.1f}x | {plan['hero_kind'].title()}"
    bbox = draw.textbbox((0, 0), tag, font=FONT_BADGE)
    tw = bbox[2] - bbox[0] + 12
    th = bbox[3] - bbox[1] + 6
    draw.rectangle([x1 + 6, y1 + 6, x1 + 6 + tw, y1 + 6 + th], fill="#000000")
    draw.rectangle([x1 + 6, y1 + 6, x1 + 6 + tw, y1 + 6 + th], outline="#FFD700", width=1)
    draw.text((x1 + 10, y1 + 8), tag, fill="#FFD700", font=FONT_BADGE)
    return panel

def draw_panel_final_shot(img: Image.Image, plan: dict, target_size: tuple[int, int]) -> Image.Image:
    w, h = img.size
    cx, cy, cw, ch = plan["crop_window"]
    x1, y1 = max(0, int(cx * w)), max(0, int(cy * h))
    x2, y2 = min(w, int((cx + cw) * w)), min(h, int((cy + ch) * h))
    
    cropped = img.crop((x1, y1, x2, y2))
    cropped.thumbnail(target_size, Image.Resampling.LANCZOS)
    
    canvas = Image.new("RGB", target_size, "#121417")
    px = (target_size[0] - cropped.width) // 2
    py = (target_size[1] - cropped.height) // 2
    canvas.paste(cropped, (px, py))
    
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, 0, target_size[0] - 1, target_size[1] - 1], outline="#2A2E35", width=1)
    badge = f"Framed ({plan['zoom_ratio']:.1f}x Zoom)"
    draw.text((8, 6), badge, fill="#00E676", font=FONT_BADGE)
    return canvas

def create_row_sheet(img_path: Path, scene: str, desc: str, detections: list, pose_info: dict, panel_w: int = 340, panel_h: int = 240) -> tuple[Image.Image, dict]:
    orig_img = Image.open(img_path).convert("RGB")
    plan = compute_composition_plan(orig_img.width, orig_img.height, scene, detections, pose_info)
    
    p1 = draw_panel_detections(orig_img, detections, plan["hero"])
    p1.thumbnail((panel_w, panel_h), Image.Resampling.BILINEAR)
    c1 = Image.new("RGB", (panel_w, panel_h), "#121417")
    c1.paste(p1, ((panel_w - p1.width) // 2, (panel_h - p1.height) // 2))
    
    p2 = draw_panel_composition_guides(orig_img, plan)
    p2.thumbnail((panel_w, panel_h), Image.Resampling.BILINEAR)
    c2 = Image.new("RGB", (panel_w, panel_h), "#121417")
    c2.paste(p2, ((panel_w - p2.width) // 2, (panel_h - p2.height) // 2))
    
    p3 = draw_panel_crop_window(orig_img, plan)
    p3.thumbnail((panel_w, panel_h), Image.Resampling.BILINEAR)
    c3 = Image.new("RGB", (panel_w, panel_h), "#121417")
    c3.paste(p3, ((panel_w - p3.width) // 2, (panel_h - p3.height) // 2))
    
    c4 = draw_panel_final_shot(orig_img, plan, (panel_w, panel_h))
    
    header_h = 32
    row_img = Image.new("RGB", (panel_w * 4 + 20, panel_h + header_h + 10), "#0E1013")
    draw = ImageDraw.Draw(row_img)
    
    # Draw photo title and description above row
    desc_text = f"{img_path.name} | {desc} | Quy tắc: {plan['alignment_rule']}"
    draw.text((8, 6), desc_text, fill="#E2E8F0", font=FONT_ROW_TITLE)
    
    headers = [
        ("1. Bounding Boxes (Nó box như thế nào)", "#00E5FF"),
        ("2. Trục Vàng & 1/3 (Guides & Target)", "#FFD700"),
        ("3. Khung Bố Cục AI (Khung như thế nào)", "#FF9100"),
        ("4. Ảnh Chụp Thực Tế (Final Camera Shot)", "#00E676")
    ]
    for col, (title, color) in enumerate(headers):
        x = col * (panel_w + 5) + 5
        draw.text((x + 4, header_h - 16), title, fill=color, font=FONT_HEADER)
        panel = [c1, c2, c3, c4][col]
        row_img.paste(panel, (x, header_h))
        
    return row_img, plan

def run():
    panel_w, panel_h = 340, 240
    header_h = 32
    row_h = panel_h + header_h + 16
    
    # 1. PROCESS 6 USER REFERENCE COCO PHOTOS
    print("=== Processing 6 User Reference COCO Photos ===")
    user_rows = []
    user_results = []
    for file_name, data in COCO_DETECTIONS.items():
        img_path = COCO_DIR / file_name
        if not img_path.exists():
            print(f"Skipping {file_name}, file not found")
            continue
        row_img, plan = create_row_sheet(img_path, data["scene"], data["description"], data["detections"], data["pose"], panel_w, panel_h)
        user_rows.append(row_img)
        user_results.append({
            "source": "User Reference COCO",
            "file": file_name,
            "scene": data["scene"],
            "description": data["description"],
            "hero_label": plan["hero"]["label"],
            "hero_conf": plan["hero"]["confidence"],
            "anchor": [round(v, 3) for v in plan["hero"]["anchor"]],
            "alignment_rule": plan["alignment_rule"],
            "target_dest": [round(v, 3) for v in plan["target_dest"]],
            "zoom_ratio": round(plan["zoom_ratio"], 2),
            "crop_window": [round(v, 3) for v in plan["crop_window"]],
            "aim_point": [round(v, 3) for v in plan["aim_point"]]
        })
        
    user_sheet = Image.new("RGB", (panel_w * 4 + 20, row_h * len(user_rows) + 50), "#0A0B0E")
    u_draw = ImageDraw.Draw(user_sheet)
    u_draw.text((10, 8), "BENCHMARK SHEET 1: 6 ANH COCO THEO DUNG ANH MAU CUA NGUOI DUNG", fill="#FFFFFF", font=FONT_TITLE)
    u_draw.text((10, 28), "So sanh: Bounding Box YOLOv12 -> Truc Ty Le Vang & 1/3 -> Khung Crop AI Camera -> Anh Xuat Chup Thuc Te", fill="#8892B0", font=FONT_SUBTITLE)
    for idx, r in enumerate(user_rows):
        user_sheet.paste(r, (0, 50 + idx * row_h))
    user_sheet_path = OUTPUT_DIR / "benchmark_sheet_user_coco_6.jpg"
    user_sheet.save(user_sheet_path, quality=94)
    print(f"Saved: {user_sheet_path}")
    
    # 2. PROCESS 12 REAL TEST PHOTOS (SWIFT VALIDATION)
    yolo_data = json.loads(YOLO_FILE.read_text(encoding="utf-8")) if YOLO_FILE.exists() else {"records": []}
    pose_data = json.loads(POSE_FILE.read_text(encoding="utf-8")) if POSE_FILE.exists() else {"records": []}
    yolo_map = {r["file"]: r["detections"] for r in yolo_data["records"]}
    pose_map = {r["file"]: r for r in pose_data["records"]}
    
    test_photos = [
        # (filename, scene, description)
        ("3184.jpg", "human", "Chan dung: Chu the lech phai (Truc vang x=0.618)"),
        ("2544.jpg", "human", "Chan dung: Chu the lech trai (Truc vang x=0.382)"),
        ("10034.jpg", "human", "Chan dung: Nguoi dung giua voi khoang trong dinh dau Headroom"),
        ("3262.jpg", "human", "Chan dung nhom: Uu tien guong mat chinh va bao ve ban dong hanh"),
        ("8425.jpg", "human", "Chan dung toan than: Nhan dien guong mat + can ty le vang"),
        ("7940.jpg", "human", "Chan dung can canh (Close-up Portrait): Khoang trong mat va dinh dau"),
        ("1036.jpg", "animal", "Thu cung: Cho (Dog 0.95 conf) can truc 1/3 va mat dat"),
        ("9774.jpg", "food", "Mon an: Banh ngot (Cake 0.73 conf) can truc mat ban 0.382"),
        ("2364.jpg", "indoor", "Noi that & Ban ghe: Tinh diem doi xung va can bang do sang"),
        ("8805.jpg", "plant", "Hoa & Cay canh: Chau cay chi tiet tien canh"),
        ("8480.jpg", "cityscape", "Pho xa & Duong pho: Nhieu doi tuong nguoi, xe, bus"),
        ("3213.jpg", "cityscape", "Moi truong: Nguoi ngoi ghe cong vien voi chim bo cau")
    ]
    
    sheet_configs = [
        ("benchmark_sheet_portraits_6.jpg", "BENCHMARK SHEET 2: 6 ANH CHAN DUNG & NGUOI THUC TE (PORTRAITS)", test_photos[:6]),
        ("benchmark_sheet_objects_animals_6.jpg", "BENCHMARK SHEET 3: 6 ANH DONG VAT, MON AN, NOI THAT & PHO XA", test_photos[6:])
    ]
    
    swift_results = []
    for sheet_name, sheet_title, photos in sheet_configs:
        rows = []
        for file_name, scene, desc in photos:
            img_path = SWIFT_PHOTOS / file_name
            if not img_path.exists():
                print(f"Skipping {file_name}, file not found")
                continue
            dets = yolo_map.get(file_name, [])
            pose = pose_map.get(file_name, {})
            row_img, plan = create_row_sheet(img_path, scene, desc, dets, pose, panel_w, panel_h)
            rows.append(row_img)
            swift_results.append({
                "source": "Swift Validation Dataset",
                "file": file_name,
                "scene": scene,
                "description": desc,
                "hero_label": plan["hero"]["label"],
                "hero_conf": plan["hero"]["confidence"],
                "anchor": [round(v, 3) for v in plan["hero"]["anchor"]],
                "alignment_rule": plan["alignment_rule"],
                "target_dest": [round(v, 3) for v in plan["target_dest"]],
                "zoom_ratio": round(plan["zoom_ratio"], 2),
                "crop_window": [round(v, 3) for v in plan["crop_window"]],
                "aim_point": [round(v, 3) for v in plan["aim_point"]]
            })
            
        sheet = Image.new("RGB", (panel_w * 4 + 20, row_h * len(rows) + 50), "#0A0B0E")
        s_draw = ImageDraw.Draw(sheet)
        s_draw.text((10, 8), sheet_title, fill="#FFFFFF", font=FONT_TITLE)
        s_draw.text((10, 28), "So sanh: Bounding Box YOLOv12 -> Truc Ty Le Vang & 1/3 -> Khung Crop AI Camera -> Anh Xuat Chup Thuc Te", fill="#8892B0", font=FONT_SUBTITLE)
        for idx, r in enumerate(rows):
            sheet.paste(r, (0, 50 + idx * row_h))
        sheet_path = OUTPUT_DIR / sheet_name
        sheet.save(sheet_path, quality=94)
        print(f"Saved: {sheet_path}")

    # 3. SAVE FULL JSON EVALUATION REPORT
    all_results = user_results + swift_results
    full_report_path = OUTPUT_DIR / "full_benchmark_report.json"
    full_report_path.write_text(json.dumps(all_results, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Saved full evaluation report: {full_report_path}")
    print(f"Total evaluated photos: {len(all_results)}")

if __name__ == "__main__":
    run()
