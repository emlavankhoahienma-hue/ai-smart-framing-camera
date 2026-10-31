"""Score eval_results.json (from the Swift pipeline) against GAICD MOS crops.

    .venv\\Scripts\\python.exe tools\\eval\\score_results.py --results eval_results.json --eval-set eval_set.json

Per image (see docs/eval/SCHEMA.md for the input format):
  matched_iou    max IoU of the crop with any MOS-annotated crop
  matched_mos    MOS of that best-IoU crop, only if matched_iou >= 0.80, else "unmatched" (no interpolation)
  mos_percentile weak percentile rank (0-100) of matched_mos among the image's MOS values
  best_iou       IoU with the highest-MOS crop
  best_iou_top10 largest IoU with any crop in the image's top-10% MOS group (k = max(1, ceil(0.1 n)), ties included)

Evaluates TWO representations:
  1. crop_bbox (current crop_rect: axis-aligned bounding box of 3D sourceCorners)
  2. crop_simple (centroid of 4 corners, normalized size 1/zoom_final, shifted into frame)
Along with 3 baselines: full frame, center crop, random crop (and center_same_zoom).
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Sequence

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore as ec  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
METRICS = ["matched_iou", "best_iou", "best_iou_top10", "mos_percentile", "matched_mos"]
METHODS = ["ai", "full_frame", "center_crop", "random_crop"]
METHODS_SIMPLE = ["ai_simple", "full_frame", "center_same_zoom", "random_crop_simple"]


def git_short_hash() -> str:
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True)
        return out.stdout.strip() or "nogit"
    except Exception:
        return "nogit"


def valid_rect(value) -> bool:
    return (isinstance(value, (list, tuple)) and len(value) == 4 and all(isinstance(v, (int, float)) for v in value)
            and value[2] > 0 and value[3] > 0)


def total_ms(record: dict):
    t = record.get("timing_ms")
    if isinstance(t, dict):
        return t.get("total")
    return t if isinstance(t, (int, float)) else None


def score_one(record: dict | None, entry: dict) -> dict:
    gt = entry["crops"]
    row = {"image": entry["image"], "status": "ok", "timing_total_ms": None, "num_gt_crops": len(gt)}
    if record is None:
        row["status"] = "missing"
        return row
    row["timing_total_ms"] = total_ms(record)
    if not record.get("ok"):
        row["status"] = "ok=false"
        row["error"] = record.get("error")
        return row
    crop = record.get("crop_rect")
    if not valid_rect(crop):
        row["status"] = "no_crop_rect"
        return row
    crop = ec.clamp_rect(crop)
    row["ai_crop_rect"] = crop
    row["is_rotated"] = record.get("is_rotated")
    row["max_edge_tilt_deg"] = record.get("max_edge_tilt_deg")
    row["scene_intent"] = record.get("scene_intent")
    row["zoom_final"] = record.get("zoom_final")
    row["hero_subject_box"] = record.get("hero_subject_box")

    # Representation 1: crop_bbox (AABB bounding box)
    row["ai"] = ec.metrics_for_crop(crop, gt)
    row["ai_bbox"] = row["ai"]
    row["full_frame"] = ec.metrics_for_crop([0.0, 0.0, 1.0, 1.0], gt)
    row["center_crop"] = ec.metrics_for_crop(ec.center_crop_same_size(crop), gt)
    row["center_crop_bbox"] = row["center_crop"]
    trials_b = [ec.metrics_for_crop(r, gt) for r in ec.random_crops_same_size(crop, entry["image"])]
    matched_pct_b = [t["mos_percentile"] for t in trials_b if t["mos_percentile"] is not None]
    matched_mos_b = [t["matched_mos"] for t in trials_b if t["matched_mos"] != "unmatched"]
    row["random_crop"] = {
        "matched_iou": sum(t["matched_iou"] for t in trials_b) / len(trials_b),
        "best_iou": sum(t["best_iou"] for t in trials_b) / len(trials_b),
        "best_iou_top10": sum(t["best_iou_top10"] for t in trials_b) / len(trials_b),
        "mos_percentile": sum(matched_pct_b) / len(matched_pct_b) if matched_pct_b else None,
        "matched_mos": sum(matched_mos_b) / len(matched_mos_b) if matched_mos_b else "unmatched",
        "unmatched_rate": 1 - len(matched_mos_b) / len(trials_b),
        "trials": len(trials_b),
    }
    row["random_crop_bbox"] = row["random_crop"]

    # Representation 2: crop_simple (centroid of 4 corners, size 1/zoom_final, shifted in)
    crop_sim = ec.crop_simple(record.get("source_corners_raw"), record.get("zoom_final"))
    if crop_sim is None:
        crop_sim = crop
    row["crop_simple"] = crop_sim
    row["ai_simple"] = ec.metrics_for_crop(crop_sim, gt)
    center_sim = ec.center_crop_same_size(crop_sim)
    row["center_crop_simple"] = ec.metrics_for_crop(center_sim, gt)
    row["center_same_zoom"] = row["center_crop_simple"]
    trials_s = [ec.metrics_for_crop(r, gt) for r in ec.random_crops_same_size(crop_sim, entry["image"])]
    matched_pct_s = [t["mos_percentile"] for t in trials_s if t["mos_percentile"] is not None]
    matched_mos_s = [t["matched_mos"] for t in trials_s if t["matched_mos"] != "unmatched"]
    row["random_crop_simple"] = {
        "matched_iou": sum(t["matched_iou"] for t in trials_s) / len(trials_s),
        "best_iou": sum(t["best_iou"] for t in trials_s) / len(trials_s),
        "best_iou_top10": sum(t["best_iou_top10"] for t in trials_s) / len(trials_s),
        "mos_percentile": sum(matched_pct_s) / len(matched_pct_s) if matched_pct_s else None,
        "matched_mos": sum(matched_mos_s) / len(matched_mos_s) if matched_mos_s else "unmatched",
        "unmatched_rate": 1 - len(matched_mos_s) / len(trials_s),
        "trials": len(trials_s),
    }

    # Grouping categories
    z = record.get("zoom_final", 1.0)
    z_val = float(z) if (isinstance(z, (int, float)) and z > 0) else 1.0
    if z_val <= 1.05:
        row["group_zoom"] = "<= 1.05"
    elif z_val <= 1.20:
        row["group_zoom"] = "1.05 - 1.20"
    else:
        row["group_zoom"] = "> 1.20"

    row["group_intent"] = str(record.get("scene_intent") or "null")

    rot = record.get("is_rotated")
    row["group_rotated"] = "is_rotated=true" if rot is True else ("is_rotated=false" if rot is False else "null")

    box = record.get("hero_subject_box")
    if box and len(box) == 4 and box[2] > 0 and box[3] > 0:
        area = box[2] * box[3]
        if area < 0.05:
            row["group_hero_area"] = "nhỏ (<0.05)"
        elif area < 0.20:
            row["group_hero_area"] = "vừa (0.05-0.20)"
        else:
            row["group_hero_area"] = "lớn (>=0.20)"
    else:
        row["group_hero_area"] = "null"

    return row


def numeric(value):
    return None if value == "unmatched" else value


def compute_group_breakdown(scored: list[dict], group_field: str, ai_key: str, center_key: str) -> dict:
    categories = sorted(list({r[group_field] for r in scored}))
    res = {}
    for cat in categories:
        cat_rows = [r for r in scored if r[group_field] == cat]
        n = len(cat_rows)
        # best_iou_top10
        ai_top10 = [r[ai_key]["best_iou_top10"] for r in cat_rows]
        c_top10 = [r[center_key]["best_iou_top10"] for r in cat_rows]
        wins10 = sum(a > c for a, c in zip(ai_top10, c_top10))
        ties10 = sum(a == c for a, c in zip(ai_top10, c_top10))
        losses10 = sum(a < c for a, c in zip(ai_top10, c_top10))
        # best_iou
        ai_biou = [r[ai_key]["best_iou"] for r in cat_rows]
        c_biou = [r[center_key]["best_iou"] for r in cat_rows]
        wins_biou = sum(a > c for a, c in zip(ai_biou, c_biou))
        ties_biou = sum(a == c for a, c in zip(ai_biou, c_biou))
        losses_biou = sum(a < c for a, c in zip(ai_biou, c_biou))
        # mos_percentile (only both matched)
        both = [r for r in cat_rows if r[ai_key]["mos_percentile"] is not None and r[center_key]["mos_percentile"] is not None]
        ai_mos_pct = [r[ai_key]["mos_percentile"] for r in both]
        c_mos_pct = [r[center_key]["mos_percentile"] for r in both]
        wins_mos = sum(a > c for a, c in zip(ai_mos_pct, c_mos_pct))

        res[cat] = {
            "n": n,
            "ai_best_iou_top10_mean": sum(ai_top10) / n if n else None,
            "center_best_iou_top10_mean": sum(c_top10) / n if n else None,
            "win_rate_best_iou_top10": wins10 / n if n else None,
            "wins10": wins10, "ties10": ties10, "losses10": losses10,
            "ai_best_iou_mean": sum(ai_biou) / n if n else None,
            "center_best_iou_mean": sum(c_biou) / n if n else None,
            "win_rate_best_iou": wins_biou / n if n else None,
            "wins_biou": wins_biou, "ties_biou": ties_biou, "losses_biou": losses_biou,
            "n_matched": len(both),
            "ai_mos_percentile_mean": sum(ai_mos_pct) / len(both) if both else None,
            "center_mos_percentile_mean": sum(c_mos_pct) / len(both) if both else None,
            "win_rate_mos_percentile": wins_mos / len(both) if both else None,
            "wins_mos": wins_mos,
        }
    return res


def summarize(rows: list[dict]) -> dict:
    scored = [r for r in rows if r["status"] == "ok"]
    summary = {"images_total": len(rows), "images_scored": len(scored),
               "ok_false": sum(r["status"] == "ok=false" for r in rows),
               "missing": sum(r["status"] == "missing" for r in rows),
               "no_crop_rect": sum(r["status"] == "no_crop_rect" for r in rows)}

    # Stats for BBox representation
    stats = {}
    for method in METHODS:
        stats[method] = {}
        for metric in METRICS:
            stats[method][metric] = ec.aggregate(numeric(r[method][metric]) for r in scored)
        if method == "random_crop":
            summary["unmatched_random_mean_rate"] = (sum(r["random_crop"]["unmatched_rate"] for r in scored) / len(scored)) if scored else None
        else:
            summary[f"unmatched_{method}"] = sum(r[method]["matched_mos"] == "unmatched" for r in scored)

    # Stats for Simple representation
    stats_simple = {}
    for method in METHODS_SIMPLE:
        stats_simple[method] = {}
        for metric in METRICS:
            stats_simple[method][metric] = ec.aggregate(numeric(r[method][metric]) for r in scored)
        if method == "random_crop_simple":
            summary["unmatched_random_simple_mean_rate"] = (sum(r["random_crop_simple"]["unmatched_rate"] for r in scored) / len(scored)) if scored else None
        else:
            summary[f"unmatched_{method}"] = sum(r[method]["matched_mos"] == "unmatched" for r in scored)

    # Head-to-head AI BBox vs Center Crop
    wins = ties = losses = 0
    wins10 = ties10 = losses10 = 0
    for r in scored:
        a, c = r["ai"]["best_iou"], r["center_crop"]["best_iou"]
        wins += a > c
        ties += a == c
        losses += a < c
        a10, c10 = r["ai"]["best_iou_top10"], r["center_crop"]["best_iou_top10"]
        wins10 += a10 > c10
        ties10 += a10 == c10
        losses10 += a10 < c10
    summary["ai_vs_center_best_iou"] = {"wins": wins, "ties": ties, "losses": losses,
                                         "win_rate": (wins / len(scored)) if scored else None}
    summary["ai_vs_center_best_iou_top10"] = {"wins": wins10, "ties": ties10, "losses": losses10,
                                               "win_rate": (wins10 / len(scored)) if scored else None}

    # Head-to-head AI Simple vs Center Same Zoom
    s_wins = s_ties = s_losses = 0
    s_wins10 = s_ties10 = s_losses10 = 0
    for r in scored:
        a, c = r["ai_simple"]["best_iou"], r["center_same_zoom"]["best_iou"]
        s_wins += a > c
        s_ties += a == c
        s_losses += a < c
        a10, c10 = r["ai_simple"]["best_iou_top10"], r["center_same_zoom"]["best_iou_top10"]
        s_wins10 += a10 > c10
        s_ties10 += a10 == c10
        s_losses10 += a10 < c10
    summary["ai_simple_vs_center_best_iou"] = {"wins": s_wins, "ties": s_ties, "losses": s_losses,
                                                "win_rate": (s_wins / len(scored)) if scored else None}
    summary["ai_simple_vs_center_best_iou_top10"] = {"wins": s_wins10, "ties": s_ties10, "losses": s_losses10,
                                                      "win_rate": (s_wins10 / len(scored)) if scored else None}

    both_b = [r for r in scored if r["ai"]["mos_percentile"] is not None and r["center_crop"]["mos_percentile"] is not None]
    summary["ai_vs_center_mos_percentile_both_matched"] = {
        "n": len(both_b), "wins": sum(r["ai"]["mos_percentile"] > r["center_crop"]["mos_percentile"] for r in both_b)}

    both_s = [r for r in scored if r["ai_simple"]["mos_percentile"] is not None and r["center_same_zoom"]["mos_percentile"] is not None]
    summary["ai_simple_vs_center_mos_percentile_both_matched"] = {
        "n": len(both_s), "wins": sum(r["ai_simple"]["mos_percentile"] > r["center_same_zoom"]["mos_percentile"] for r in both_s)}

    rotated = [r for r in scored if r.get("is_rotated") is True]
    upright = [r for r in scored if r.get("is_rotated") is False]
    summary["rotated"] = {"is_rotated_true": len(rotated), "is_rotated_false": len(upright),
                          "is_rotated_unknown": len(scored) - len(rotated) - len(upright),
                          "ai_best_iou_mean_rotated": ec.aggregate(r["ai"]["best_iou"] for r in rotated)["mean"],
                          "ai_best_iou_mean_upright": ec.aggregate(r["ai"]["best_iou"] for r in upright)["mean"]}

    times = sorted(t for t in (r["timing_total_ms"] for r in rows) if isinstance(t, (int, float)))
    summary["timing_total_ms"] = ({"n": len(times), "p50": ec.percentile(times, 50), "p95": ec.percentile(times, 95)}
                                  if times else {"n": 0, "p50": None, "p95": None})

    # Group breakdowns for both representations
    groups_bbox = {
        "zoom": compute_group_breakdown(scored, "group_zoom", "ai", "center_crop"),
        "intent": compute_group_breakdown(scored, "group_intent", "ai", "center_crop"),
        "rotated": compute_group_breakdown(scored, "group_rotated", "ai", "center_crop"),
        "hero_area": compute_group_breakdown(scored, "group_hero_area", "ai", "center_crop"),
    }
    groups_simple = {
        "zoom": compute_group_breakdown(scored, "group_zoom", "ai_simple", "center_same_zoom"),
        "intent": compute_group_breakdown(scored, "group_intent", "ai_simple", "center_same_zoom"),
        "rotated": compute_group_breakdown(scored, "group_rotated", "ai_simple", "center_same_zoom"),
        "hero_area": compute_group_breakdown(scored, "group_hero_area", "ai_simple", "center_same_zoom"),
    }
    summary["groups_bbox"] = groups_bbox
    summary["groups_simple"] = groups_simple

    return {"summary": summary, "stats": stats, "stats_simple": stats_simple}


def fmt(v, dec=4):
    if v is None:
        return "–"
    return f"{v:.{dec}f}"


def fmt_pct(v):
    if v is None:
        return "–"
    return f"{v * 100:.1f}%"


def write_reports(out: Path, result: dict, meta: dict, rows: list[dict], eval_set_images: list[dict]) -> None:
    s = result["summary"]
    stats_b = result["stats"]
    stats_s = result["stats_simple"]
    scored = [r for r in rows if r["status"] == "ok"]

    gt_by_img = {e["image"]: e["crops"] for e in eval_set_images}

    # Identify 10 worst and 10 best photos by delta best_iou (bbox)
    for r in scored:
        r["delta_best_iou"] = r["ai"]["best_iou"] - r["center_crop"]["best_iou"]
        r["delta_best_iou_top10"] = r["ai"]["best_iou_top10"] - r["center_crop"]["best_iou_top10"]
        r["delta_simple_best_iou"] = r["ai_simple"]["best_iou"] - r["center_same_zoom"]["best_iou"]
        top_crop = ec.top_mos_crop(gt_by_img.get(r["image"], []))
        r["best_gt_mos"] = top_crop["mos"] if top_crop else None

    sorted_delta = sorted(scored, key=lambda r: r["delta_best_iou"])
    worst10 = sorted_delta[:10]
    best10 = sorted_delta[-10:][::-1]

    lines = [
        "# Báo cáo đánh giá AI Target & Zoom (Hai biểu diễn: crop_bbox vs crop_simple)",
        "",
        f"- **run**: `{meta['run_id']}`  |  **impl**: `{meta.get('impl')}`  |  **device**: `{meta.get('device')}`",
        f"- **kết quả**: `{meta['results_file']}`; **eval set**: `{meta['eval_set_file']}`" + (f"  |  **{meta['label']}**" if meta.get("label") else ""),
        f"- **ảnh**: {s['images_total']} (chấm được {s['images_scored']}, ok=false {s['ok_false']}, thiếu {s['missing']}, không có crop_rect {s['no_crop_rect']})",
        "",
        "> **Mục đích:** Đánh giá công bằng giữa (1) Biểu diễn `crop_bbox` (hộp bao trục AABB của 4 góc 3D kẹp [0,1]) "
        "và (2) Biểu diễn `crop_simple` (tâm = trọng tâm 4 góc, kích thước = 1/zoom_final, dịch vào trong ảnh nếu tràn). "
        "Mọi baseline đi kèm (`center_crop` và `center_same_zoom`) dùng đúng kích thước tương ứng để so sánh chuẩn xác.",
        "",
        "---",
        "",
        "## 1. So sánh hai biểu diễn: AI vs Baselines",
        "",
        "### A. Biểu diễn 1: `crop_bbox` (Hộp bao AABB hiện tại)",
        "",
        "| Phương pháp | best_iou mean | best_iou median | best_iou_top10 mean | mos_percentile mean | matched_mos mean |",
        "|---|:---:|:---:|:---:|:---:|:---:|",
    ]

    for m, name in [("ai", "AI (crop_bbox)"), ("full_frame", "Full Frame"), ("center_crop", "Center Crop (bbox size)"), ("random_crop", "Random Crop")]:
        st = stats_b[m]
        lines.append(f"| **{name}** | {fmt(st['best_iou']['mean'])} | {fmt(st['best_iou']['median'])} | "
                     f"{fmt(st['best_iou_top10']['mean'])} | {fmt(st['mos_percentile']['mean'], 2)} | {fmt(st['matched_mos']['mean'])} |")

    lines += [
        "",
        "**Đối đầu AI bbox vs Center Crop:**",
        f"- `best_iou`: AI thắng {s['ai_vs_center_best_iou']['wins']}, hòa {s['ai_vs_center_best_iou']['ties']}, thua {s['ai_vs_center_best_iou']['losses']} → tỉ lệ thắng **{fmt_pct(s['ai_vs_center_best_iou']['win_rate'])}**",
        f"- `best_iou_top10`: AI thắng {s['ai_vs_center_best_iou_top10']['wins']}, hòa {s['ai_vs_center_best_iou_top10']['ties']}, thua {s['ai_vs_center_best_iou_top10']['losses']} → tỉ lệ thắng **{fmt_pct(s['ai_vs_center_best_iou_top10']['win_rate'])}**",
        f"- `mos_percentile` (trên {s['ai_vs_center_mos_percentile_both_matched']['n']} ảnh cùng khớp): AI thắng **{s['ai_vs_center_mos_percentile_both_matched']['wins']}** ảnh",
        "",
        "### B. Biểu diễn 2: `crop_simple` (Trọng tâm 4 góc, kích thước chuẩn 1/zoom_final)",
        "",
        "| Phương pháp | best_iou mean | best_iou median | best_iou_top10 mean | mos_percentile mean | matched_mos mean |",
        "|---|:---:|:---:|:---:|:---:|:---:|",
    ]

    for m, name in [("ai_simple", "AI (crop_simple)"), ("full_frame", "Full Frame"), ("center_same_zoom", "Center Same Zoom (1/zoom)"), ("random_crop_simple", "Random Crop")]:
        st = stats_s[m]
        lines.append(f"| **{name}** | {fmt(st['best_iou']['mean'])} | {fmt(st['best_iou']['median'])} | "
                     f"{fmt(st['best_iou_top10']['mean'])} | {fmt(st['mos_percentile']['mean'], 2)} | {fmt(st['matched_mos']['mean'])} |")

    lines += [
        "",
        "**Đối đầu AI simple vs Center Same Zoom (Tách tác động của TÂM và ZOOM):**",
        f"- `best_iou`: AI thắng {s['ai_simple_vs_center_best_iou']['wins']}, hòa {s['ai_simple_vs_center_best_iou']['ties']}, thua {s['ai_simple_vs_center_best_iou']['losses']} → tỉ lệ thắng **{fmt_pct(s['ai_simple_vs_center_best_iou']['win_rate'])}**",
        f"- `best_iou_top10`: AI thắng {s['ai_simple_vs_center_best_iou_top10']['wins']}, hòa {s['ai_simple_vs_center_best_iou_top10']['ties']}, thua {s['ai_simple_vs_center_best_iou_top10']['losses']} → tỉ lệ thắng **{fmt_pct(s['ai_simple_vs_center_best_iou_top10']['win_rate'])}**",
        f"- `mos_percentile` (trên {s['ai_simple_vs_center_mos_percentile_both_matched']['n']} ảnh cùng khớp): AI thắng **{s['ai_simple_vs_center_mos_percentile_both_matched']['wins']}** ảnh",
        "",
        "---",
        "",
        "## 2. Phân tích theo nhóm (Breakdown Analysis)",
        "",
    ]

    group_defs = [
        ("zoom", "Nhóm Mức Zoom (`zoom_final`)", "group_zoom"),
        ("intent", "Nhóm Ý đồ cảnh (`scene_intent`)", "group_intent"),
        ("rotated", "Nhóm Xoay 3D (`is_rotated`)", "group_rotated"),
        ("hero_area", "Nhóm Diện tích Chủ thể Hero (`hero_subject_box`)", "group_hero_area"),
    ]

    for g_key, g_title, _ in group_defs:
        lines += [
            f"### {g_title}",
            "",
            "#### Biểu diễn `crop_bbox` (so với Center Crop)",
            "",
            "| Nhóm | n | AI best_iou_top10 | Center top10 | Win Rate top10 | AI MOS %ile | Center MOS %ile | Win Rate MOS %ile |",
            "|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|",
        ]
        gb = s["groups_bbox"][g_key]
        for cat, data in gb.items():
            lines.append(f"| {cat} | {data['n']} | {fmt(data['ai_best_iou_top10_mean'])} | {fmt(data['center_best_iou_top10_mean'])} | "
                         f"{fmt_pct(data['win_rate_best_iou_top10'])} ({data['wins10']}/{data['n']}) | {fmt(data['ai_mos_percentile_mean'], 1)} | "
                         f"{fmt(data['center_mos_percentile_mean'], 1)} | {fmt_pct(data['win_rate_mos_percentile'])} |")

        lines += [
            "",
            "#### Biểu diễn `crop_simple` (so với Center Same Zoom)",
            "",
            "| Nhóm | n | AI simple top10 | Center Zoom top10 | Win Rate top10 | AI MOS %ile | Center MOS %ile | Win Rate MOS %ile |",
            "|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|",
        ]
        gs = s["groups_simple"][g_key]
        for cat, data in gs.items():
            lines.append(f"| {cat} | {data['n']} | {fmt(data['ai_best_iou_top10_mean'])} | {fmt(data['center_best_iou_top10_mean'])} | "
                         f"{fmt_pct(data['win_rate_best_iou_top10'])} ({data['wins10']}/{data['n']}) | {fmt(data['ai_mos_percentile_mean'], 1)} | "
                         f"{fmt(data['center_mos_percentile_mean'], 1)} | {fmt_pct(data['win_rate_mos_percentile'])} |")
        lines.append("")

    lines += [
        "---",
        "",
        "## 3. Top 10 ảnh AI kém Center Crop nhiều nhất (Worst 10)",
        "",
        "| Ảnh | Scene Intent | Zoom | Tilt (°) | Hero Area | AI best_iou | Center best_iou | Delta (AI - Center) | Best GT MOS |",
        "|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|",
    ]
    for r in worst10:
        box = r.get("hero_subject_box")
        area_str = fmt(box[2] * box[3]) if (box and len(box) == 4) else "null"
        lines.append(f"| `{r['image']}` | {r.get('scene_intent')} | {fmt(r.get('zoom_final'), 2)} | {fmt(r.get('max_edge_tilt_deg'), 1)}° | "
                     f"{area_str} | {fmt(r['ai']['best_iou'])} | {fmt(r['center_crop']['best_iou'])} | **{fmt(r['delta_best_iou'])}** | {fmt(r.get('best_gt_mos'), 2)} |")

    lines += [
        "",
        "## 4. Top 10 ảnh AI tốt hơn Center Crop nhiều nhất (Best 10)",
        "",
        "| Ảnh | Scene Intent | Zoom | Tilt (°) | Hero Area | AI best_iou | Center best_iou | Delta (AI - Center) | Best GT MOS |",
        "|---|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|",
    ]
    for r in best10:
        box = r.get("hero_subject_box")
        area_str = fmt(box[2] * box[3]) if (box and len(box) == 4) else "null"
        lines.append(f"| `{r['image']}` | {r.get('scene_intent')} | {fmt(r.get('zoom_final'), 2)} | {fmt(r.get('max_edge_tilt_deg'), 1)}° | "
                     f"{area_str} | {fmt(r['ai']['best_iou'])} | {fmt(r['center_crop']['best_iou'])} | **+{fmt(r['delta_best_iou'])}** | {fmt(r.get('best_gt_mos'), 2)} |")

    lines += [
        "",
        "---",
        "",
        "## 5. Thời gian runner (ms, trên macOS CI runner)",
        "",
        f"- n={s['timing_total_ms']['n']}, p50={fmt(s['timing_total_ms']['p50'])}, p95={fmt(s['timing_total_ms']['p95'])}",
        "",
    ]

    (out / "report.md").write_text("\n".join(lines), encoding="utf-8")

    # CSV outputs
    with (out / "report.csv").open("w", newline="", encoding="utf-8") as f:
        w_ = csv.writer(f)
        w_.writerow(["section", "method", "metric", "n", "mean", "median", "p25", "p75"])
        for method in METHODS:
            for metric in METRICS:
                a = stats_b[method][metric]
                w_.writerow(["stats_bbox", method, metric, a["n"], a["mean"], a["median"], a["p25"], a["p75"]])
        for method in METHODS_SIMPLE:
            for metric in METRICS:
                a = stats_s[method][metric]
                w_.writerow(["stats_simple", method, metric, a["n"], a["mean"], a["median"], a["p25"], a["p75"]])

    with (out / "groups.csv").open("w", newline="", encoding="utf-8") as f:
        w_ = csv.writer(f)
        w_.writerow(["representation", "dimension", "category", "n", "ai_top10_mean", "center_top10_mean", "win_rate_top10", "ai_biou_mean", "center_biou_mean", "win_rate_biou", "n_matched", "ai_mos_pct_mean", "center_mos_pct_mean", "win_rate_mos_pct"])
        for rep, data in [("bbox", s["groups_bbox"]), ("simple", s["groups_simple"])]:
            for dim, cats in data.items():
                for cat, v in cats.items():
                    w_.writerow([rep, dim, cat, v["n"], v["ai_best_iou_top10_mean"], v["center_best_iou_top10_mean"], v["win_rate_best_iou_top10"],
                                 v["ai_best_iou_mean"], v["center_best_iou_mean"], v["win_rate_best_iou"], v["n_matched"], v["ai_mos_percentile_mean"],
                                 v["center_mos_percentile_mean"], v["win_rate_mos_percentile"]])

    with (out / "worst_best.csv").open("w", newline="", encoding="utf-8") as f:
        w_ = csv.writer(f)
        w_.writerow(["kind", "rank", "image", "scene_intent", "zoom_final", "max_edge_tilt_deg", "ai_best_iou", "center_best_iou", "delta_best_iou", "ai_top10", "center_top10", "best_gt_mos"])
        for i, r in enumerate(worst10, 1):
            w_.writerow(["worst", i, r["image"], r.get("scene_intent"), r.get("zoom_final"), r.get("max_edge_tilt_deg"), r["ai"]["best_iou"], r["center_crop"]["best_iou"], r["delta_best_iou"], r["ai"]["best_iou_top10"], r["center_crop"]["best_iou_top10"], r.get("best_gt_mos")])
        for i, r in enumerate(best10, 1):
            w_.writerow(["best", i, r["image"], r.get("scene_intent"), r.get("zoom_final"), r.get("max_edge_tilt_deg"), r["ai"]["best_iou"], r["center_crop"]["best_iou"], r["delta_best_iou"], r["ai"]["best_iou_top10"], r["center_crop"]["best_iou_top10"], r.get("best_gt_mos")])


def render_local_vis(out_vis: Path, images_dir: Path, selected_rows: list[dict], eval_set_images: list[dict], prefix: str = "") -> None:
    out_vis.mkdir(parents=True, exist_ok=True)
    gt_map = {e["image"]: e["crops"] for e in eval_set_images}
    for idx, r in enumerate(selected_rows, 1):
        img_name = r["image"]
        img_path = images_dir / img_name
        if not img_path.exists():
            continue
        with Image.open(img_path) as im:
            canvas = im.convert("RGB")
        w, h = canvas.size
        d = ImageDraw.Draw(canvas)

        def draw_box(box, color, label):
            if not box or len(box) != 4:
                return
            x1, y1, x2, y2 = ec.norm_to_px_corners(box, w, h)
            d.rectangle([x1, y1, x2, y2], outline=color, width=max(2, w // 250))
            d.text((x1 + 3, max(0, y1 - 12)), label, fill=color)

        gt = gt_map.get(img_name, [])
        top = ec.top_mos_crop(gt) if gt else None
        if top:
            draw_box(top["rect"], "lime", f"Best GT MOS {top['mos']:.2f}")

        # Center crop (orange)
        draw_box(r.get("center_crop_bbox", r.get("center_crop", {}).get("rect", ec.center_crop_same_size(r["ai_crop_rect"]))), "orange", "Center")

        # AI bbox (red)
        draw_box(r.get("ai_crop_rect"), "red", f"AI bbox (IoU {r['ai']['best_iou']:.2f})")

        # AI simple (cyan)
        draw_box(r.get("crop_simple"), "cyan", f"AI simple (IoU {r['ai_simple']['best_iou']:.2f})")

        # Hero subject (yellow)
        if r.get("hero_subject_box"):
            draw_box(r["hero_subject_box"], "yellow", "Hero")

        title = f"{img_name} | {r.get('scene_intent')} | z={r.get('zoom_final', 1):.2f} | tilt={r.get('max_edge_tilt_deg', 0):.1f}° | Delta={r.get('delta_best_iou', 0):+.2f}"
        d.rectangle([0, 0, w, 22], fill="black")
        d.text((5, 4), title, fill="white")

        out_name = f"{prefix}_{idx:02d}_{Path(img_name).stem}.jpg"
        canvas.save(out_vis / out_name, quality=90)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=REPO / "eval_results.json")
    ap.add_argument("--eval-set", type=Path, default=REPO / "eval_set.json")
    ap.add_argument("--runs-dir", type=Path, default=REPO / "eval_runs")
    ap.add_argument("--images-dir", type=Path, default=REPO / "eval_input")
    ap.add_argument("--label", help="free-text label stored in the report (e.g. FAKE DATA)")
    args = ap.parse_args()

    results = json.loads(args.results.read_text(encoding="utf-8"))
    eval_set = json.loads(args.eval_set.read_text(encoding="utf-8"))
    by_image = {r["image"]: r for r in results}
    rows = [score_one(by_image.get(entry["image"]), entry) for entry in eval_set["images"]]
    extra = sorted(set(by_image) - {e["image"] for e in eval_set["images"]})
    result = summarize(rows)
    run_id = f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}_{git_short_hash()}"
    out = args.runs_dir / run_id
    out.mkdir(parents=True, exist_ok=False)
    impls = sorted({str(r.get("impl")) for r in results})
    devices = sorted({str(r.get("device")) for r in results})
    meta = {"run_id": run_id, "results_file": str(args.results), "eval_set_file": str(args.eval_set), "label": args.label,
            "impl": ",".join(impls), "device": ",".join(devices), "results_not_in_eval_set": extra}
    shutil.copyfile(args.results, out / "eval_results.json")
    (out / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    (out / "per_image.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")
    (out / "summary.json").write_text(json.dumps(result, indent=1), encoding="utf-8")
    write_reports(out, result, meta, rows, eval_set["images"])

    with (out / "per_image.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["image", "status", "timing_total_ms", "group_zoom", "group_intent", "group_rotated", "group_hero_area", "delta_best_iou"] +
                   [f"{m}_{k}" for m in METHODS for k in METRICS] +
                   [f"simple_{m}_{k}" for m in ["ai_simple", "center_same_zoom"] for k in METRICS])
        for r in rows:
            w.writerow([r["image"], r["status"], r["timing_total_ms"], r.get("group_zoom"), r.get("group_intent"), r.get("group_rotated"), r.get("group_hero_area"), r.get("delta_best_iou")] +
                       [r[m][k] if m in r else "" for m in METHODS for k in METRICS] +
                       [r[m][k] if m in r else "" for m in ["ai_simple", "center_same_zoom"] for k in METRICS])

    # Render local visualizations for 10 worst and 10 best photos if images exist
    scored = [r for r in rows if r["status"] == "ok"]
    sorted_delta = sorted(scored, key=lambda r: r.get("delta_best_iou", 0))
    worst10 = sorted_delta[:10]
    best10 = sorted_delta[-10:][::-1]
    if args.images_dir.exists():
        vis_dir = out / "vis"
        render_local_vis(vis_dir, args.images_dir, worst10, eval_set["images"], prefix="worst")
        render_local_vis(vis_dir, args.images_dir, best10, eval_set["images"], prefix="best")
        print(f"Rendered visualizations: {vis_dir}")

    print(f"OK: {out}")
    print((out / "report.md").read_text(encoding="utf-8").split("## 2. Phân tích")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
