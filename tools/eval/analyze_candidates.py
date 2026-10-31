"""Analyze all candidate proposals per image against GAICD ground truth.

Computes:
  (i)   mos_soft & mos_soft_percentile for:
        - Chosen by AI
        - Oracle (best candidate by mos_soft)
        - Median candidate
        - Full frame baseline
        - Center same zoom baseline
  (ii)  Per-image Spearman correlation between candidate mos_soft and (samp, charm, geom, final)
  (iii) Count of images where Oracle > Full Frame significantly, and where Identity is Oracle
  (iv)  Evaluation separately for DEV (100 images) and HOLDOUT (50 images)
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore as ec  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def spearman_rank_correlation(x: Sequence[float], y: Sequence[float]) -> float | None:
    """Compute Spearman rank correlation between two equal-length sequences."""
    valid_pairs = [(a, b) for a, b in zip(x, y) if a is not None and b is not None and math.isfinite(a) and math.isfinite(b)]
    n = len(valid_pairs)
    if n < 3:
        return None
    # Check if constant
    xs = [p[0] for p in valid_pairs]
    ys = [p[1] for p in valid_pairs]
    if len(set(xs)) <= 1 or len(set(ys)) <= 1:
        return 0.0

    def rank(seq):
        sorted_indices = sorted(range(len(seq)), key=lambda i: seq[i])
        ranks = [0.0] * len(seq)
        i = 0
        while i < len(seq):
            j = i
            while j + 1 < len(seq) and seq[sorted_indices[j + 1]] == seq[sorted_indices[i]]:
                j += 1
            avg_rank = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                ranks[sorted_indices[k]] = avg_rank
            i = j + 1
        return ranks

    rx = rank(xs)
    ry = rank(ys)
    d_sq = sum((a - b) ** 2 for a, b in zip(rx, ry))
    return 1.0 - (6.0 * d_sq) / (n * (n * n - 1))


def analyze(results_path: Path, eval_set_path: Path, split_path: Path | None = None) -> dict:
    results = json.loads(results_path.read_text(encoding="utf-8"))
    eval_set = json.loads(eval_set_path.read_text(encoding="utf-8"))
    gt_map = {e["image"]: [g for g in e["crops"] if g["mos"] >= 0] for e in eval_set["images"]}
    results_map = {r["image"]: r for r in results}

    dev_set = None
    holdout_set = None
    if split_path and split_path.exists():
        sp = json.loads(split_path.read_text(encoding="utf-8"))
        dev_set = set(sp.get("dev", []))
        holdout_set = set(sp.get("holdout", []))

    analyzed_images = []

    for entry in eval_set["images"]:
        img_name = entry["image"]
        rec = results_map.get(img_name)
        if not rec or not rec.get("ok"):
            continue
        gt = gt_map.get(img_name, [])
        if not gt:
            continue

        cands = rec.get("candidates", [])
        if not cands:
            # Fallback if candidates were not logged: treat selected as sole candidate
            continue

        scored_cands = []
        for c in cands:
            corners = c.get("source_corners_raw")
            z = c.get("zoom", 1.0)
            crop_sim = ec.crop_simple(corners, z)
            if crop_sim is None:
                crop_sim = c.get("crop_rect") or [0, 0, 1, 1]
            ms = ec.mos_soft(crop_sim, gt)
            ms_pct = ec.mos_soft_percentile(ms, gt)
            top10 = ec.best_iou_top10(crop_sim, gt)
            biou = ec.best_iou_vs_top(crop_sim, gt)
            scored_cands.append({
                "cand": c,
                "crop_simple": crop_sim,
                "mos_soft": ms,
                "mos_soft_percentile": ms_pct,
                "best_iou_top10": top10,
                "best_iou": biou,
                "scores": c.get("scores", {}),
                "is_selected": bool(c.get("is_selected")),
                "is_unchanged": bool(c.get("is_unchanged")),
                "zoom": z,
            })

        # Identify key candidates
        valid_ms_cands = [sc for sc in scored_cands if sc["mos_soft"] is not None]
        if not valid_ms_cands:
            continue

        selected_c = next((sc for sc in scored_cands if sc["is_selected"]), scored_cands[0])
        oracle_c = max(valid_ms_cands, key=lambda sc: sc["mos_soft"])
        sorted_by_ms = sorted(valid_ms_cands, key=lambda sc: sc["mos_soft"])
        median_c = sorted_by_ms[len(sorted_by_ms) // 2]
        unchanged_c = next((sc for sc in scored_cands if sc["is_unchanged"]), None)

        # Baseline: Full Frame
        ff_crop = [0.0, 0.0, 1.0, 1.0]
        ff_ms = ec.mos_soft(ff_crop, gt)
        ff_ms_pct = ec.mos_soft_percentile(ff_ms, gt)
        ff_top10 = ec.best_iou_top10(ff_crop, gt)
        ff_biou = ec.best_iou_vs_top(ff_crop, gt)

        # Baseline: Center Same Zoom
        csz_crop = ec.center_same_zoom(rec.get("zoom_final"))
        csz_ms = ec.mos_soft(csz_crop, gt)
        csz_ms_pct = ec.mos_soft_percentile(csz_ms, gt)
        csz_top10 = ec.best_iou_top10(csz_crop, gt)
        csz_biou = ec.best_iou_vs_top(csz_crop, gt)

        # Per-image Correlations
        # (between candidate mos_soft and its component scores: samp, charm, geom, final)
        ms_vals = [sc["mos_soft"] for sc in valid_ms_cands]
        samp_vals = [sc["scores"].get("samp") for sc in valid_ms_cands]
        charm_vals = [sc["scores"].get("charm") for sc in valid_ms_cands]
        geom_vals = [sc["scores"].get("geom") for sc in valid_ms_cands]
        final_vals = [sc["scores"].get("final") for sc in valid_ms_cands]

        corr_samp = spearman_rank_correlation(ms_vals, samp_vals)
        corr_charm = spearman_rank_correlation(ms_vals, charm_vals)
        corr_geom = spearman_rank_correlation(ms_vals, geom_vals)
        corr_final = spearman_rank_correlation(ms_vals, final_vals)

        # Check if framing changed
        corners = rec.get("source_corners_raw")
        z_final = rec.get("zoom_final", 1.0) or 1.0
        centroid_shifted = False
        if corners and len(corners) == 8:
            cx = sum(corners[0::2]) / 4.0
            cy = sum(corners[1::2]) / 4.0
            if math.hypot(cx - 0.5, cy - 0.5) > 0.01:
                centroid_shifted = True
        framing_changed = (z_final > 1.05) or centroid_shifted

        analyzed_images.append({
            "image": img_name,
            "is_dev": (img_name in dev_set) if dev_set else True,
            "num_candidates": len(scored_cands),
            "framing_changed": framing_changed,
            "has_unchanged": unchanged_c is not None,
            "unchanged_is_oracle": (unchanged_c is not None and abs(unchanged_c["mos_soft"] - oracle_c["mos_soft"]) < 1e-6),
            "oracle_beats_full_frame": (oracle_c["mos_soft"] > (ff_ms or 0) + 0.05),
            "oracle_beats_full_frame_pct": ((oracle_c["mos_soft_percentile"] or 0) >= (ff_ms_pct or 0) + 2.0),
            "selected": selected_c,
            "oracle": oracle_c,
            "median": median_c,
            "unchanged": unchanged_c,
            "full_frame": {"mos_soft": ff_ms, "mos_soft_percentile": ff_ms_pct, "best_iou_top10": ff_top10, "best_iou": ff_biou},
            "center_same_zoom": {"mos_soft": csz_ms, "mos_soft_percentile": csz_ms_pct, "best_iou_top10": csz_top10, "best_iou": csz_biou},
            "correlations": {
                "samp": corr_samp,
                "charm": corr_charm,
                "geom": corr_geom,
                "final": corr_final,
            }
        })

    return summarize_analysis(analyzed_images)


def summarize_analysis(items: list[dict]) -> dict:
    subsets = {
        "ALL": items,
        "DEV": [it for it in items if it["is_dev"]],
        "HOLDOUT": [it for it in items if not it["is_dev"]],
    }

    out = {}
    for subset_name, subset_items in subsets.items():
        n = len(subset_items)
        if n == 0:
            continue

        def avg(seq):
            valid = [v for v in seq if v is not None and math.isfinite(v)]
            return sum(valid) / len(valid) if valid else None

        # (i) Performance comparison
        sel_ms = avg([it["selected"]["mos_soft"] for it in subset_items])
        sel_pct = avg([it["selected"]["mos_soft_percentile"] for it in subset_items])
        sel_top10 = avg([it["selected"]["best_iou_top10"] for it in subset_items])

        ora_ms = avg([it["oracle"]["mos_soft"] for it in subset_items])
        ora_pct = avg([it["oracle"]["mos_soft_percentile"] for it in subset_items])
        ora_top10 = avg([it["oracle"]["best_iou_top10"] for it in subset_items])

        med_ms = avg([it["median"]["mos_soft"] for it in subset_items])
        med_pct = avg([it["median"]["mos_soft_percentile"] for it in subset_items])
        med_top10 = avg([it["median"]["best_iou_top10"] for it in subset_items])

        ff_ms = avg([it["full_frame"]["mos_soft"] for it in subset_items])
        ff_pct = avg([it["full_frame"]["mos_soft_percentile"] for it in subset_items])
        ff_top10 = avg([it["full_frame"]["best_iou_top10"] for it in subset_items])

        csz_ms = avg([it["center_same_zoom"]["mos_soft"] for it in subset_items])
        csz_pct = avg([it["center_same_zoom"]["mos_soft_percentile"] for it in subset_items])
        csz_top10 = avg([it["center_same_zoom"]["best_iou_top10"] for it in subset_items])

        # (ii) Spearman correlations
        corr_samp = avg([it["correlations"]["samp"] for it in subset_items])
        corr_charm = avg([it["correlations"]["charm"] for it in subset_items])
        corr_geom = avg([it["correlations"]["geom"] for it in subset_items])
        corr_final = avg([it["correlations"]["final"] for it in subset_items])

        # (iii) Counts
        has_unchanged_count = sum(1 for it in subset_items if it["has_unchanged"])
        unchanged_is_oracle_count = sum(1 for it in subset_items if it["unchanged_is_oracle"])
        oracle_beats_ff_count = sum(1 for it in subset_items if it["oracle_beats_full_frame"])
        oracle_beats_ff_pct_count = sum(1 for it in subset_items if it["oracle_beats_full_frame_pct"])

        # Active framing win rate (AI vs center_same_zoom when framing changed)
        changed_items = [it for it in subset_items if it["framing_changed"]]
        n_changed = len(changed_items)
        changed_wins_ms = sum(1 for it in changed_items if (it["selected"]["mos_soft"] or 0) > (it["center_same_zoom"]["mos_soft"] or 0))
        changed_wins_top10 = sum(1 for it in changed_items if (it["selected"]["best_iou_top10"] or 0) > (it["center_same_zoom"]["best_iou_top10"] or 0))

        out[subset_name] = {
            "n": n,
            "n_changed": n_changed,
            "performance": {
                "selected": {"mos_soft": sel_ms, "mos_soft_percentile": sel_pct, "best_iou_top10": sel_top10},
                "oracle": {"mos_soft": ora_ms, "mos_soft_percentile": ora_pct, "best_iou_top10": ora_top10},
                "median": {"mos_soft": med_ms, "mos_soft_percentile": med_pct, "best_iou_top10": med_top10},
                "full_frame": {"mos_soft": ff_ms, "mos_soft_percentile": ff_pct, "best_iou_top10": ff_top10},
                "center_same_zoom": {"mos_soft": csz_ms, "mos_soft_percentile": csz_pct, "best_iou_top10": csz_top10},
            },
            "correlations": {
                "samp": corr_samp,
                "charm": corr_charm,
                "geom": corr_geom,
                "final": corr_final,
            },
            "counts": {
                "has_unchanged": has_unchanged_count,
                "unchanged_is_oracle": unchanged_is_oracle_count,
                "oracle_beats_full_frame": oracle_beats_ff_count,
                "oracle_beats_full_frame_percentile": oracle_beats_ff_pct_count,
            },
            "active_framing_wins": {
                "n_changed": n_changed,
                "wins_mos_soft": changed_wins_ms,
                "win_rate_mos_soft": (changed_wins_ms / n_changed) if n_changed else None,
                "wins_best_iou_top10": changed_wins_top10,
                "win_rate_best_iou_top10": (changed_wins_top10 / n_changed) if n_changed else None,
            }
        }

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=REPO / "eval_results.json")
    ap.add_argument("--eval-set", type=Path, default=REPO / "eval_set.json")
    ap.add_argument("--split", type=Path, default=REPO / "tools/eval/split.json")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    summary = analyze(args.results, args.eval_set, args.split)
    print(json.dumps(summary, indent=2))
    if args.out:
        args.out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
