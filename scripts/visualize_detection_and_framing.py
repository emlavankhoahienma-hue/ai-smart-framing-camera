#!/usr/bin/env python3
"""Comprehensive Python Diagnostic Suite for AI Smart Framing Camera.

Tests YOLOv12 detections and Swift CompositionPlanning geometry on real photographs.
Produces multi-panel comparison sheets showing:
  1. YOLO Detections & Bounding Boxes
  2. Rule of Thirds & Golden Ratio Guides + Aiming Target
  3. AI Framing Crop Window Overlay
  4. Final Simulated Cropped / Zoomed Camera Shot
"""
from __future__ import annotations

import io
import json
import math
from pathlib import Path
import urllib.request

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# Define paths
ROOT = Path(__file__).resolve().parents[1]
SWIFT_PHOTOS = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/swift"
YOLO_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/detection/yolo12s-real-photos.json"
POSE_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/pose-report.json"
MANIFEST_FILE = ROOT / "build_artifacts/Photographic-Composition-Validation/validation/photos/manifest.json"
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

def load_data():
    yolo_data = json.loads(YOLO_FILE.read_text(encoding="utf-8")) if YOLO_FILE.exists() else {"records": []}
    pose_data = json.loads(POSE_FILE.read_text(encoding="utf-8")) if POSE_FILE.exists() else {"records": []}
    manifest = json.loads(MANIFEST_FILE.read_text(encoding="utf-8")) if MANIFEST_FILE.exists() else {"images": []}
    
    yolo_map = {r["file"]: r["detections"] for r in yolo_data["records"]}
    pose_map = {r["file"]: r for r in pose_data["records"]}
    scene_map = {img["file"]: img.get("scene", "general") for img in manifest.get("images", [])}
    return yolo_map, pose_map, scene_map

def compute_composition_plan(img_w: int, img_h: int, scene: str, detections: list, pose_info: dict) -> dict:
    """Implements exact CompositionPlanning.swift framing and crop window calculation."""
    # 1. Determine hero subject
    hero = None
    hero_kind = "object"
    
    # Check if pose detected a person or face
    bodies = pose_info.get("bodies", [])
    faces = pose_info.get("faces", [])
    
    if len(faces) > 0:
        # Sort faces by area
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
            "anchor": (bb[0] + bb[2] / 2.0, bb[1] + bb[3] * 0.22), # upper body anchor
            "kind": "person",
            "label": "Người (Person)",
            "confidence": 0.90
        }
        hero_kind = "portrait"
    elif len(detections) > 0:
        # Pick highest confidence / largest detection
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
        # Fallback to center landscape/scenery
        hero = {
            "box": [0.25, 0.25, 0.5, 0.5],
            "anchor": (0.5, 0.5),
            "kind": "scenery",
            "label": "Toàn cảnh (Scenery)",
            "confidence": 0.70
        }
        hero_kind = "landscape"

    anchor_x, anchor_y = hero["anchor"]
    
    # 2. Looking room / gaze direction estimation
    # For face: check if face center is shifted relative to body or image
    gaze_lead = 0.0
    if hero_kind == "portrait":
        if len(faces) > 0 and len(bodies) > 0:
            fb = faces[0]
            bb = bodies[0]
            # If face is to the right of body center, subject tends to look right
            gaze_lead = (fb[0] + fb[2]/2.0) - (bb[0] + bb[2]/2.0)
            gaze_lead = max(-1.0, min(1.0, gaze_lead * 4.0))
        elif anchor_x < 0.44:
            gaze_lead = 0.25 # On left side of frame, typically looking into frame (right)
        elif anchor_x > 0.56:
            gaze_lead = -0.25 # On right side of frame, looking into frame (left)

    # 3. Target Placement (Rule of Thirds & Golden Ratio from CompositionPlanning.swift)
    dest_x = 0.5
    dest_y = 0.5
    
    if abs(gaze_lead) >= 0.12:
        # Looking right (positive) -> place at left golden line (0.382)
        # Looking left (negative) -> place at right golden line (0.618)
        dest_x = 0.5 - 0.145 * gaze_lead
    else:
        # Natural position placement:
        if anchor_x < 0.46:
            dest_x = PHI_LEFT  # 0.382
        elif anchor_x > 0.54:
            dest_x = PHI_RIGHT # 0.618
        else:
            dest_x = 0.5

    # Vertical target:
    if hero_kind == "portrait":
        # Headroom rule: head/eye placed at upper third (y in [0.30, 0.44])
        dest_y = min(0.44, max(0.30, 0.075 + anchor_y * 0.64))
    elif hero_kind == "food":
        dest_y = PHI_TOP if anchor_y < 0.46 else (PHI_BOTTOM if anchor_y > 0.54 else 0.5)
    elif hero_kind in ("animal", "object"):
        dest_y = PHI_TOP if anchor_y < 0.46 else (PHI_BOTTOM if anchor_y > 0.54 else 0.42)
    else:
        dest_y = 0.48

    # 4. Desired area and Zoom ratio calculation
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
    # Clamp zoom ratio: at least 1.0x (no wide distortion), max 2.8x (optical/sensor limits)
    zoom_ratio = max(1.0, min(2.8, zoom_ratio))
    
    # 5. Crop window size and position (maintaining container aspect ratio)
    crop_w = 1.0 / zoom_ratio
    crop_h = 1.0 / zoom_ratio
    
    # Shift aim so that anchor ends up near dest_x, dest_y in the crop window
    # In cropped window: (anchor_x - crop_x) / crop_w = dest_x  =>  crop_x = anchor_x - dest_x * crop_w
    crop_x = anchor_x - dest_x * crop_w
    crop_y = anchor_y - dest_y * crop_h
    
    # Clamp crop within [0, 1] bounds
    crop_x = max(0.0, min(1.0 - crop_w, crop_x))
    crop_y = max(0.0, min(1.0 - crop_h, crop_y))
    
    # Calculate aim point (center of the crop window)
    aim_x = crop_x + crop_w / 2.0
    aim_y = crop_y + crop_h / 2.0

    return {
        "hero": hero,
        "hero_kind": hero_kind,
        "gaze_lead": gaze_lead,
        "target_dest": (dest_x, dest_y),
        "zoom_ratio": zoom_ratio,
        "crop_window": (crop_x, crop_y, crop_w, crop_h),
        "aim_point": (aim_x, aim_y)
    }

def draw_panel_detections(img: Image.Image, detections: list, hero: dict) -> Image.Image:
    """Panel 1: Original Image + Detected Subject Bounding Boxes."""
    panel = img.copy()
    draw = ImageDraw.Draw(panel)
    w, h = panel.size
    
    colors = {
        "Người": "#00E5FF",       # Cyan for people
        "Human": "#00E5FF",
        "Chó": "#FF9100",         # Orange for animals
        "Mèo": "#FF9100",
        "Animal": "#FF9100",
        "Bánh ngọt": "#00E676",    # Green for food
        "Food": "#00E676",
        "Gương mặt": "#FF4081",   # Magenta for face
    }
    
    # Draw all detections
    for d in detections:
        box = d.get("box", [0, 0, 0, 0])
        bx1 = int(box[0] * w)
        by1 = int(box[1] * h)
        bx2 = int((box[0] + box[2]) * w)
        by2 = int((box[1] + box[3]) * h)
        label = d.get("label", "Object")
        conf = d.get("confidence", 0.0)
        
        color = "#FFD700" # Default Gold
        for k, c in colors.items():
            if k in label or k in d.get("category", ""):
                color = c
                break
                
        # Draw bounding rectangle
        draw.rectangle([bx1, by1, bx2, by2], outline=color, width=2)
        
        # Label badge
        badge_text = f"{label} {conf:.2f}"
        tw = len(badge_text) * 7 + 8
        draw.rectangle([bx1, max(0, by1 - 18), bx1 + tw, by1], fill=color)
        draw.text((bx1 + 4, max(0, by1 - 16)), badge_text, fill="#000000")

    # Highlight Hero Anchor
    if hero:
        ax = int(hero["anchor"][0] * w)
        ay = int(hero["anchor"][1] * h)
        draw.ellipse([ax - 5, ay - 5, ax + 5, ay + 5], fill="#FF1744", outline="#FFFFFF", width=1)
        
    return panel

def draw_panel_composition_guides(img: Image.Image, plan: dict) -> Image.Image:
    """Panel 2: Composition Geometry Analysis (Rule of Thirds & Golden Ratio Guides)."""
    panel = img.copy()
    draw = ImageDraw.Draw(panel)
    w, h = panel.size
    
    # Draw Rule of Thirds subtle lines (1/3, 2/3) in light cyan
    for tx in (THIRD_LEFT, THIRD_RIGHT):
        x = int(tx * w)
        draw.line([(x, 0), (x, h)], fill=(0, 229, 255, 120), width=1)
    for ty in (THIRD_TOP, THIRD_BOTTOM):
        y = int(ty * h)
        draw.line([(0, y), (w, y)], fill=(0, 229, 255, 120), width=1)
        
    # Draw Golden Ratio lines (0.382, 0.618) in bold gold
    for gx in (PHI_LEFT, PHI_RIGHT):
        x = int(gx * w)
        draw.line([(x, 0), (x, h)], fill="#FFD700", width=2)
    for gy in (PHI_TOP, PHI_BOTTOM):
        y = int(gy * h)
        draw.line([(0, y), (w, y)], fill="#FFD700", width=2)
        
    # Draw 4 Golden Power Intersections
    for gx in (PHI_LEFT, PHI_RIGHT):
        for gy in (PHI_TOP, PHI_BOTTOM):
            px, py = int(gx * w), int(gy * h)
            draw.ellipse([px - 6, py - 6, px + 6, py + 6], outline="#FFD700", fill="#FFD700", width=2)
            draw.ellipse([px - 10, py - 10, px + 10, py + 10], outline="#FFD700", width=1)
            
    # Draw Target Crosshair
    aim_x, aim_y = plan["aim_point"]
    cx, cy = int(aim_x * w), int(aim_y * h)
    draw.line([(cx - 15, cy), (cx + 15, cy)], fill="#00E676", width=2)
    draw.line([(cx, cy - 15), (cx, cy + 15)], fill="#00E676", width=2)
    draw.ellipse([cx - 8, cy - 8, cx + 8, cy + 8], outline="#00E676", width=2)
    
    # Draw Gaze Lead arrow if active
    hero = plan["hero"]
    ax, ay = int(hero["anchor"][0] * w), int(hero["anchor"][1] * h)
    lead = plan["gaze_lead"]
    if abs(lead) > 0.05:
        arrow_dx = int(lead * 80)
        draw.line([(ax, ay), (ax + arrow_dx, ay)], fill="#FF4081", width=3)
        draw.polygon([(ax + arrow_dx, ay - 6), (ax + arrow_dx + (10 if arrow_dx > 0 else -10), ay), (ax + arrow_dx, ay + 6)], fill="#FF4081")
        
    return panel

def draw_panel_crop_window(img: Image.Image, plan: dict) -> Image.Image:
    """Panel 3: AI Framing Crop Window Overlay."""
    # Create darkened mask for outside region
    w, h = img.size
    cx, cy, cw, ch = plan["crop_window"]
    x1, y1 = int(cx * w), int(cy * h)
    x2, y2 = int((cx + cw) * w), int((cy + ch) * h)
    
    # Darken overlay
    overlay = np.array(img).astype(np.float32)
    overlay[:y1, :] *= 0.45
    overlay[y2:, :] *= 0.45
    overlay[y1:y2, :x1] *= 0.45
    overlay[y1:y2, x2:] *= 0.45
    panel = Image.fromarray(np.clip(overlay, 0, 255).astype(np.uint8))
    
    draw = ImageDraw.Draw(panel)
    # Draw Crop Box with bright gold corners
    draw.rectangle([x1, y1, x2, y2], outline="#00E5FF", width=2)
    bracket_len = min(24, int(min(cw * w, ch * h) * 0.15))
    for corner_x, corner_y, dx, dy in [(x1, y1, 1, 1), (x2, y1, -1, 1), (x1, y2, 1, -1), (x2, y2, -1, -1)]:
        draw.line([(corner_x, corner_y), (corner_x + dx * bracket_len, corner_y)], fill="#FFD700", width=4)
        draw.line([(corner_x, corner_y), (corner_x, corner_y + dy * bracket_len)], fill="#FFD700", width=4)
        
    # Badge
    tag = f"AI Crop {plan['zoom_ratio']:.1f}x | {plan['hero_kind'].title()}"
    tw = len(tag) * 7 + 10
    draw.rectangle([x1 + 6, y1 + 6, x1 + 6 + tw, y1 + 24], fill="#000000")
    draw.rectangle([x1 + 6, y1 + 6, x1 + 6 + tw, y1 + 24], outline="#FFD700", width=1)
    draw.text((x1 + 10, y1 + 8), tag, fill="#FFD700")
    return panel

def draw_panel_final_shot(img: Image.Image, plan: dict, target_size: tuple[int, int]) -> Image.Image:
    """Panel 4: Final Simulated Cropped & Framed Shot."""
    w, h = img.size
    cx, cy, cw, ch = plan["crop_window"]
    x1, y1 = max(0, int(cx * w)), max(0, int(cy * h))
    x2, y2 = min(w, int((cx + cw) * w)), min(h, int((cy + ch) * h))
    
    cropped = img.crop((x1, y1, x2, y2))
    # Resize to target size preserving aspect ratio with high quality Lanczos filter
    cropped.thumbnail(target_size, Image.Resampling.LANCZOS)
    
    # Place on dark canvas
    canvas = Image.new("RGB", target_size, "#121417")
    px = (target_size[0] - cropped.width) // 2
    py = (target_size[1] - cropped.height) // 2
    canvas.paste(cropped, (px, py))
    
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, 0, target_size[0] - 1, target_size[1] - 1], outline="#2A2E35", width=1)
    badge = f"Framed ({plan['zoom_ratio']:.1f}x Zoom)"
    draw.text((8, 6), badge, fill="#00E676")
    return canvas

def create_row_sheet(img_path: Path, scene: str, detections: list, pose_info: dict, panel_w: int = 320, panel_h: int = 240) -> tuple[Image.Image, dict]:
    """Generates a 4-panel row for a single photo: [Detections | Guides | Crop Window | Final Shot]."""
    orig_img = Image.open(img_path).convert("RGB")
    plan = compute_composition_plan(orig_img.width, orig_img.height, scene, detections, pose_info)
    
    # Resize original for panels
    thumb = orig_img.copy()
    thumb.thumbnail((panel_w, panel_h), Image.Resampling.BILINEAR)
    canvas_base = Image.new("RGB", (panel_w, panel_h), "#121417")
    px = (panel_w - thumb.width) // 2
    py = (panel_h - thumb.height) // 2
    canvas_base.paste(thumb, (px, py))
    
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
    
    # Label each panel header
    header_h = 24
    row_img = Image.new("RGB", (panel_w * 4 + 15, panel_h + header_h), "#0E1013")
    draw = ImageDraw.Draw(row_img)
    
    headers = [
        ("1. YOLOv12 Detections & Boxes", "#00E5FF"),
        ("2. Golden Ratio & Rule of Thirds", "#FFD700"),
        ("3. AI Crop Window & Headroom", "#FF9100"),
        ("4. Final AI Framed Camera Shot", "#00E676")
    ]
    for col, (title, color) in enumerate(headers):
        x = col * (panel_w + 5)
        draw.text((x + 6, 4), title, fill=color)
        panel = [c1, c2, c3, c4][col]
        row_img.paste(panel, (x, header_h))
        
    return row_img, plan

def run_evaluation():
    yolo_map, pose_map, scene_map = load_data()
    
    # Select 12 representative test photos across diverse scenes
    test_cases = [
        # (filename, scene_category, description)
        ("3184.jpg", "human", "Portrait: Subject on right (Golden Axis x=0.618)"),
        ("2544.jpg", "human", "Portrait: Subject on left (Golden Axis x=0.382)"),
        ("10034.jpg", "human", "Portrait: Center standing with headroom guide"),
        ("3262.jpg", "human", "Portrait: Multi-person group with primary face"),
        ("8425.jpg", "human", "Portrait: Full body subject with face detection"),
        ("1036.jpg", "animal", "Animal: Dog detection (0.95 conf) + 1/3 eye line"),
        ("9774.jpg", "food", "Food & Dining: Cake subject with table level"),
        ("2364.jpg", "indoor", "Indoor & Furniture: Dining table & chairs"),
        ("8805.jpg", "plant", "Plant & Flora: Potted plant focal detail"),
        ("9234.jpg", "static", "Object & Detail: Foreground product subject"),
        ("8480.jpg", "cityscape", "City Street: Dynamic urban street scene"),
        ("3213.jpg", "cityscape", "Environmental: Person on bench in city park")
    ]
    
    panel_w, panel_h = 320, 240
    header_h = 24
    row_h = panel_h + header_h + 8
    
    # Split into 2 sheets of 6 photos each
    for sheet_idx, chunk in enumerate([test_cases[:6], test_cases[6:]]):
        sheet_img = Image.new("RGB", (panel_w * 4 + 15, row_h * len(chunk) + 40), "#0A0B0E")
        sheet_draw = ImageDraw.Draw(sheet_img)
        title = f"AI Smart Framing Camera - Diagnostic Evaluation Sheet {sheet_idx + 1}"
        subtitle = "YOLOv12s Detections -> Golden Ratio & Rule of Thirds -> Dynamic Crop Window -> Framed Output"
        sheet_draw.text((10, 6), title, fill="#FFFFFF")
        sheet_draw.text((10, 22), subtitle, fill="#8892B0")
        
        y_offset = 40
        evaluations = []
        for file_name, scene, desc in chunk:
            img_path = SWIFT_PHOTOS / file_name
            if not img_path.exists():
                print(f"Warning: {img_path} not found")
                continue
            dets = yolo_map.get(file_name, [])
            pose = pose_map.get(file_name, {})
            row_img, plan = create_row_sheet(img_path, scene, dets, pose, panel_w, panel_h)
            sheet_img.paste(row_img, (0, y_offset))
            
            # Print evaluation metric
            cx, cy, cw, ch = plan["crop_window"]
            hero = plan["hero"]
            evaluations.append({
                "file": file_name,
                "scene": scene,
                "description": desc,
                "hero_label": hero["label"],
                "hero_conf": hero["confidence"],
                "anchor": [round(v, 3) for v in hero["anchor"]],
                "dest_target": [round(v, 3) for v in plan["target_dest"]],
                "zoom_ratio": round(plan["zoom_ratio"], 2),
                "crop_window": [round(v, 3) for v in plan["crop_window"]]
            })
            y_offset += row_h
            
        sheet_file = OUTPUT_DIR / f"diagnostic_sheet_{sheet_idx + 1}.jpg"
        sheet_img.save(sheet_file, quality=92)
        print(f"Saved: {sheet_file}")
        
        json_file = OUTPUT_DIR / f"evaluation_results_{sheet_idx + 1}.json"
        json_file.write_text(json.dumps(evaluations, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Saved: {json_file}")

if __name__ == "__main__":
    run_evaluation()
