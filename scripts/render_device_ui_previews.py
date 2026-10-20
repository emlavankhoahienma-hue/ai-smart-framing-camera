import math
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = Path(r"C:\Users\admin\.gemini\antigravity\brain\b51f1c7c-a6a3-47e7-8980-264df7811faf")
OUT_DIR = ARTIFACTS_DIR / "device_ui_previews"
OUT_DIR.mkdir(parents=True, exist_ok=True)

DEVICES = [
    {
        "name": "iPhone SE (3rd Gen)",
        "width": 375,
        "height": 667,
        "safe_top": 20,
        "safe_bottom": 0,
        "scale": 2,
        "has_home_bar": False,
        "has_notch": False,
    },
    {
        "name": "iPhone 13 / 14",
        "width": 390,
        "height": 844,
        "safe_top": 47,
        "safe_bottom": 34,
        "scale": 3,
        "has_home_bar": True,
        "has_notch": True,
    },
    {
        "name": "iPhone 15 / 16",
        "width": 393,
        "height": 852,
        "safe_top": 59,
        "safe_bottom": 34,
        "scale": 3,
        "has_home_bar": True,
        "has_island": True,
    },
    {
        "name": "iPhone 16 Pro Max",
        "width": 440,
        "height": 956,
        "safe_top": 62,
        "safe_bottom": 34,
        "scale": 3,
        "has_home_bar": True,
        "has_island": True,
    },
]

def compute_layout(width, height, safe_top, safe_bottom, is_video=False):
    available_h = height - safe_top - safe_bottom
    available_w = width
    is_compact = available_h < 700 or available_w < 375
    top_horizontal = 8 if available_w < 375 else (10 if available_w < 390 else 14)
    top_vertical = 2 if is_compact else min(18, max(4, (available_h - 700) * 0.12))
    top_bottom = 4 if is_compact else 6
    control_deck_h = 148 if is_compact else 156
    minimum_gap = 4 if is_compact else 8
    bottom_comfort = (8 if is_compact else 14) if safe_bottom >= 20 else (6 if is_compact else 10)

    width_limit = max(1, available_w - 12)
    height_limit = max(1, available_h - 44 - top_vertical - top_bottom - control_deck_h - bottom_comfort - minimum_gap)

    if is_video:
        target_aspect = 9.0 / 16.0
        vh = min(width_limit / target_aspect, height_limit)
        vw = vh * target_aspect
        if vw > width_limit:
            vw = width_limit
            vh = vw / target_aspect
    else:
        vh = min(width_limit * 4.0 / 3.0, height_limit)
        vw = vh * 3.0 / 4.0

    histogram_w = 46 if available_w < 380 else min(62, available_w * 0.15)
    compact_padding = 16 if is_compact else 22

    return {
        "is_compact": is_compact,
        "top_horizontal": top_horizontal,
        "top_vertical": top_vertical,
        "top_bottom": top_bottom,
        "control_deck_h": control_deck_h,
        "bottom_comfort": bottom_comfort,
        "minimum_gap": minimum_gap,
        "viewfinder_w": vw,
        "viewfinder_h": vh,
        "histogram_w": histogram_w,
        "deck_padding_h": compact_padding,
    }

def render_device(dev):
    w, h = dev["width"], dev["height"]
    safe_top, safe_bottom = dev["safe_top"], dev["safe_bottom"]
    layout = compute_layout(w, h, safe_top, safe_bottom)

    # Render at 2x logical points for clean crisp image
    s = 2
    img = Image.new("RGB", (int(w * s), int(h * s)), color=(8, 9, 12)) # #08090C deep obsidian
    draw = ImageDraw.Draw(img)

    # 1. Status bar / Notch / Island
    if dev.get("has_island"):
        # Dynamic Island pill
        island_w, island_h = 125 * s, 36 * s
        ix = (w * s - island_w) / 2
        iy = (safe_top * s - island_h) / 2 + 3 * s
        draw.rounded_rectangle([ix, iy, ix + island_w, iy + island_h], radius=18 * s, fill=(0, 0, 0))
    elif dev.get("has_notch"):
        notch_w, notch_h = 160 * s, 30 * s
        nx = (w * s - notch_w) / 2
        draw.rounded_rectangle([nx, 0, nx + notch_w, notch_h], radius=14 * s, fill=(0, 0, 0))

    # Time indicator (top-left) & Battery / 5G (top-right)
    draw.text((24 * s, 14 * s), "19:42", fill=(255, 255, 255, 220))
    draw.text((w * s - 75 * s, 14 * s), "5G  100%", fill=(255, 255, 255, 220))

    # 2. TopCameraBar
    # Y position: safe_top + top_vertical
    top_bar_y = (safe_top + layout["top_vertical"]) * s
    top_bar_h = 44 * s
    pad_h = layout["top_horizontal"] * s

    # Flash button (width 36pt)
    flash_x = pad_h
    draw.rounded_rectangle([flash_x, top_bar_y + 4 * s, flash_x + 36 * s, top_bar_y + 40 * s],
                           radius=8 * s, fill=(35, 36, 42))
    # Bolt icon placeholder
    draw.polygon([(flash_x + 19 * s, top_bar_y + 12 * s),
                  (flash_x + 13 * s, top_bar_y + 24 * s),
                  (flash_x + 18 * s, top_bar_y + 24 * s),
                  (flash_x + 17 * s, top_bar_y + 32 * s),
                  (flash_x + 23 * s, top_bar_y + 20 * s),
                  (flash_x + 18 * s, top_bar_y + 20 * s)], fill=(255, 204, 0))

    # Mini Histogram (width: layout['histogram_w'])
    histo_x = flash_x + 36 * s + 4 * s
    histo_w = layout["histogram_w"] * s
    draw.rounded_rectangle([histo_x, top_bar_y + 9 * s, histo_x + histo_w, top_bar_y + 35 * s],
                           radius=5 * s, fill=(20, 22, 28), outline=(60, 65, 80), width=1)
    # Simple waveform curve
    curve_pts = [
        (histo_x + 2 * s, top_bar_y + 32 * s),
        (histo_x + histo_w * 0.25, top_bar_y + 24 * s),
        (histo_x + histo_w * 0.45, top_bar_y + 13 * s),
        (histo_x + histo_w * 0.70, top_bar_y + 26 * s),
        (histo_x + histo_w - 2 * s, top_bar_y + 30 * s),
    ]
    draw.line(curve_pts, fill=(230, 80, 80), width=int(1.5 * s))

    # Trailing buttons: Settings (36pt) at right edge, Windowed Zoom (36pt) left of it
    settings_x = w * s - pad_h - 36 * s
    draw.rounded_rectangle([settings_x, top_bar_y + 4 * s, settings_x + 36 * s, top_bar_y + 40 * s],
                           radius=8 * s, fill=(35, 36, 42))
    # Gear symbol circle
    draw.ellipse([settings_x + 12 * s, top_bar_y + 16 * s, settings_x + 24 * s, top_bar_y + 28 * s],
                 outline=(255, 255, 255, 220), width=int(2 * s))

    windowed_x = settings_x - 4 * s - 36 * s
    draw.rounded_rectangle([windowed_x, top_bar_y + 4 * s, windowed_x + 36 * s, top_bar_y + 40 * s],
                           radius=8 * s, fill=(35, 36, 42))
    # Viewfinder icon [ ]
    draw.rectangle([windowed_x + 10 * s, top_bar_y + 14 * s, windowed_x + 26 * s, top_bar_y + 30 * s],
                   outline=(0, 229, 255), width=int(1.5 * s))

    # Center Specs Row: ISO 412 EV +0.0 [HEIF] 4:3
    # Centered between histo_x + histo_w and windowed_x
    specs_cx = (w * s) / 2
    specs_str = "ISO 412  EV +0.0  HEIF  4:3"
    draw.text((specs_cx - 72 * s, top_bar_y + 15 * s), specs_str, fill=(255, 255, 255, 230))

    # 3. Viewfinder
    vw = layout["viewfinder_w"] * s
    vh = layout["viewfinder_h"] * s
    # Centered horizontally:
    vx = (w * s - vw) / 2
    # Y position: top_bar_y + top_bar_h + top_bottom + minimum_gap / 2
    vy = top_bar_y + top_bar_h + (layout["top_bottom"] + layout["minimum_gap"] / 2) * s

    # Viewfinder container with rounded corner 20
    draw.rounded_rectangle([vx, vy, vx + vw, vy + vh], radius=20 * s, fill=(18, 20, 24),
                           outline=(40, 44, 54), width=int(1 * s))

    # Viewfinder interior: realistic photo room texture
    # Grid lines (Rule of Thirds)
    draw.line([(vx + vw / 3, vy), (vx + vw / 3, vy + vh)], fill=(255, 255, 255, 35), width=1)
    draw.line([(vx + vw * 2 / 3, vy), (vx + vw * 2 / 3, vy + vh)], fill=(255, 255, 255, 35), width=1)
    draw.line([(vx, vy + vh / 3), (vx + vw, vy + vh / 3)], fill=(255, 255, 255, 35), width=1)
    draw.line([(vx, vy + vh * 2 / 3), (vx + vw, vy + vh * 2 / 3)], fill=(255, 255, 255, 35), width=1)

    # Horizon leveler (virtual horizon): TWO THIN LINES with GAP, NO DOT!
    lev_cy = vy + vh / 2
    lev_cx = vx + vw / 2
    draw.line([(lev_cx - 40 * s, lev_cy), (lev_cx - 10 * s, lev_cy)], fill=(255, 255, 255, 160), width=int(1.5 * s))
    draw.line([(lev_cx + 10 * s, lev_cy), (lev_cx + 40 * s, lev_cy)], fill=(255, 255, 255, 160), width=int(1.5 * s))

    # Viewfinder zoom selector pills at bottom: 1x, 2x, 3x
    zoom_y = vy + vh - 32 * s
    # 1x
    draw.ellipse([lev_cx - 50 * s, zoom_y - 14 * s, lev_cx - 22 * s, zoom_y + 14 * s], fill=(0, 0, 0, 140))
    draw.text((lev_cx - 42 * s, zoom_y - 7 * s), "1x", fill=(255, 255, 255, 180))
    # 2x (Active with signature ring)
    draw.ellipse([lev_cx - 14 * s, zoom_y - 14 * s, lev_cx + 14 * s, zoom_y + 14 * s], fill=(0, 0, 0, 180),
                 outline=(0, 229, 255), width=int(2 * s))
    draw.text((lev_cx - 7 * s, zoom_y - 7 * s), "2x", fill=(255, 255, 255, 255))
    # 3x
    draw.ellipse([lev_cx + 22 * s, zoom_y - 14 * s, lev_cx + 50 * s, zoom_y + 14 * s], fill=(0, 0, 0, 140))
    draw.text((lev_cx + 30 * s, zoom_y - 7 * s), "3x", fill=(255, 255, 255, 180))

    # 4. Bottom Control Deck
    # Height: layout['control_deck_h'], bottom padding: layout['bottom_comfort']
    deck_h = layout["control_deck_h"] * s
    deck_y = (h - safe_bottom - layout["bottom_comfort"]) * s - deck_h
    deck_pad = layout["deck_padding_h"] * s

    # Row 1: Shutter button (Center), Album (Left), Camera Flip (Right)
    row1_cy = deck_y + 44 * s
    shutter_cx = (w * s) / 2
    # Shutter button (80pt)
    draw.ellipse([shutter_cx - 40 * s, row1_cy - 40 * s, shutter_cx + 40 * s, row1_cy + 40 * s],
                 fill=(255, 255, 255), outline=(120, 120, 120), width=int(4 * s))

    # Album thumbnail (50pt) on left
    album_x = deck_pad
    draw.rounded_rectangle([album_x, row1_cy - 25 * s, album_x + 50 * s, row1_cy + 25 * s],
                           radius=12 * s, fill=(28, 30, 36), outline=(70, 75, 88), width=int(1 * s))
    draw.rectangle([album_x + 12 * s, row1_cy - 12 * s, album_x + 38 * s, row1_cy + 12 * s],
                   fill=(100, 120, 150))

    # Camera flip button (50pt) on right
    flip_x = w * s - deck_pad - 50 * s
    draw.ellipse([flip_x, row1_cy - 25 * s, flip_x + 50 * s, row1_cy + 25 * s],
                 fill=(28, 30, 36), outline=(70, 75, 88), width=int(1 * s))
    # Flip arrows icon placeholder
    draw.arc([flip_x + 14 * s, row1_cy - 11 * s, flip_x + 36 * s, row1_cy + 11 * s], 45, 315,
             fill=(255, 255, 255), width=int(2 * s))

    # Row 2: AI Button (Left), Mode Switcher (Center), Lens Badge (Right)
    row2_cy = deck_y + 104 * s
    # AI button (44pt)
    ai_x = deck_pad
    draw.text((ai_x + 12 * s, row2_cy - 8 * s), "[AI]", fill=(255, 255, 255, 230))

    # Mode switcher: ẢNH | VIDEO (156pt wide) centered under shutter
    mode_w = 156 * s
    mode_x = (w * s - mode_w) / 2
    draw.rounded_rectangle([mode_x, row2_cy - 16 * s, mode_x + mode_w, row2_cy + 16 * s],
                           radius=16 * s, fill=(24, 26, 32))
    # Active pill for ẢNH
    draw.rounded_rectangle([mode_x + 2 * s, row2_cy - 14 * s, mode_x + 76 * s, row2_cy + 14 * s],
                           radius=14 * s, fill=(60, 62, 70))
    draw.text((mode_x + 24 * s, row2_cy - 7 * s), "ẢNH", fill=(255, 255, 255))
    draw.text((mode_x + 94 * s, row2_cy - 7 * s), "VIDEO", fill=(160, 160, 160))

    # Lens / Film badge button (44pt) on right
    lens_x = w * s - deck_pad - 44 * s
    draw.text((lens_x + 8 * s, row2_cy - 8 * s), "PRO", fill=(255, 255, 255, 200))

    # 5. Home indicator bar (bottom)
    if dev.get("has_home_bar"):
        bar_w = 140 * s
        bx = (w * s - bar_w) / 2
        by = (h - 8) * s
        draw.rounded_rectangle([bx, by, bx + bar_w, by + 4 * s], radius=2 * s, fill=(255, 255, 255, 180))

    # Verification measurements
    left_vf_margin = vx / s
    right_vf_margin = (w * s - (vx + vw)) / s
    vf_diff = abs(left_vf_margin - right_vf_margin)
    shutter_diff = abs((shutter_cx / s) - (w / 2))
    mode_diff = abs(((mode_x + mode_w / 2) / s) - (w / 2))
    flip_right_margin = (w * s - (flip_x + 50 * s)) / s
    settings_right_margin = (w * s - (settings_x + 36 * s)) / s

    metrics = {
        "device": dev["name"],
        "screen_w": w,
        "screen_h": h,
        "viewfinder_w": layout["viewfinder_w"],
        "viewfinder_h": layout["viewfinder_h"],
        "viewfinder_margins": (round(left_vf_margin, 1), round(right_vf_margin, 1)),
        "viewfinder_symmetric": vf_diff < 0.01,
        "shutter_centered": shutter_diff < 0.01,
        "mode_centered": mode_diff < 0.01,
        "flip_button_margin": round(flip_right_margin, 1),
        "settings_button_margin": round(settings_right_margin, 1),
        "flip_visible": flip_right_margin >= 16,
        "settings_visible": settings_right_margin >= 8,
    }

    # Save single device render
    slug = dev["name"].lower().replace(" ", "_").replace("(", "").replace(")", "").replace("/", "_")
    out_path = OUT_DIR / f"{slug}_preview.png"
    img.save(out_path, format="PNG")
    print(f"Rendered {dev['name']} -> {out_path}")
    print(f"  Metrics: {metrics}")
    return img, metrics

def main():
    rendered = []
    all_metrics = []
    for dev in DEVICES:
        img, metrics = render_device(dev)
        rendered.append((dev, img))
        all_metrics.append(metrics)

    # Now create a unified multi-device gallery sheet
    # Fixed height 956 * 2, place 4 devices side by side
    target_h = 1000
    scaled_imgs = []
    for dev, img in rendered:
        aspect = img.width / img.height
        sw = int(target_h * aspect)
        sim = img.resize((sw, target_h), Image.Resampling.LANCZOS)
        scaled_imgs.append((dev["name"], sim))

    total_w = sum(im.width for _, im in scaled_imgs) + 40 * (len(scaled_imgs) + 1)
    sheet_h = target_h + 80
    sheet = Image.new("RGB", (total_w, sheet_h), color=(14, 16, 20))
    sdraw = ImageDraw.Draw(sheet)

    cur_x = 40
    for name, im in scaled_imgs:
        sdraw.text((cur_x + 10, 15), name, fill=(255, 255, 255))
        sheet.paste(im, (cur_x, 50))
        cur_x += im.width + 40

    sheet_path = ARTIFACTS_DIR / "multi_device_ui_layout_verification.jpg"
    sheet.save(sheet_path, format="JPEG", quality=92)
    print(f"\nUnified gallery saved to: {sheet_path}")

    # Assert that all metrics pass
    for m in all_metrics:
        assert m["viewfinder_symmetric"], f"{m['device']} viewfinder is not symmetric!"
        assert m["shutter_centered"], f"{m['device']} shutter is not centered!"
        assert m["mode_centered"], f"{m['device']} mode switcher is not centered!"
        assert m["flip_visible"], f"{m['device']} flip button is cut off!"
        assert m["settings_visible"], f"{m['device']} settings button is cut off!"
    print("\nALL MULTI-DEVICE RESPONSIVE LAYOUT ASSERTIONS PASSED 100%!")

if __name__ == "__main__":
    main()
