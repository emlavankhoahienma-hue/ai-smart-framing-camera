"""Shared, pure-Python helpers for the offline crop evaluation harness.

Conventions (see docs/eval/SCHEMA.md):
  * rectangles are [x, y, w, h], normalised to 0..1, origin TOP-LEFT;
  * GAICD-style pixel corner boxes are (x1, y1, x2, y2) with x2/y2 exclusive-style
    extents (width = x2 - x1) in the image's stored pixel grid.
Nothing here depends on the Swift pipeline.
"""
from __future__ import annotations

import math
import random
import sys
from typing import Iterable, Sequence

# Windows consoles default to cp1252 and crash on Vietnamese text / arrows; force UTF-8 output.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # captured/redirected streams without reconfigure()
        pass

Rect = Sequence[float]  # [x, y, w, h]

MATCH_IOU = 0.80  # matched_mos is only defined at or above this IoU
RANDOM_TRIALS = 20
RANDOM_SEED = 12345


def iou(a: Rect, b: Rect) -> float:
    """IoU of two [x, y, w, h] rectangles."""
    ax1, ay1, aw, ah = a
    bx1, by1, bw, bh = b
    ax2, ay2, bx2, by2 = ax1 + aw, ay1 + ah, bx1 + bw, by1 + bh
    iw = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    ih = max(0.0, min(ay2, by2) - max(ay1, by1))
    inter = iw * ih
    union = aw * ah + bw * bh - inter
    # IoU is mathematically <= 1; float rounding of (x + w) can give 1.0000000000000004 for identical rects.
    return min(1.0, inter / union) if union > 0 else 0.0


def px_corners_to_norm(x1: float, y1: float, x2: float, y2: float, width: int, height: int) -> list[float]:
    """Pixel corners (x1, y1, x2, y2) -> normalised [x, y, w, h], top-left origin."""
    return [x1 / width, y1 / height, (x2 - x1) / width, (y2 - y1) / height]


def norm_to_px_corners(rect: Rect, width: int, height: int) -> list[float]:
    """Normalised [x, y, w, h] -> pixel corners (x1, y1, x2, y2)."""
    x, y, w, h = rect
    return [x * width, y * height, (x + w) * width, (y + h) * height]


def best_match(crop: Rect, gt: Sequence[dict]) -> tuple[float, float | None]:
    """Return (matched_iou, matched_mos).

    matched_iou is the largest IoU against any ground-truth crop. matched_mos is
    the MOS of that best-IoU crop ONLY when matched_iou >= 0.80, else None
    (== "unmatched"); there is no interpolation. Ties on IoU take the higher MOS.
    Invalid crops (MOS < 0, such as placeholder -2.0 in GAICD) are excluded.
    """
    valid_gt = [item for item in gt if item["mos"] >= 0]
    best_i, best_mos = -1.0, None
    for item in valid_gt:
        value = iou(crop, item["rect"])
        if value > best_i or (value == best_i and best_mos is not None and item["mos"] > best_mos):
            best_i, best_mos = value, item["mos"]
    if best_i < MATCH_IOU:
        return best_i, None
    return best_i, best_mos


def mos_percentile(mos: float, all_mos: Iterable[float]) -> float:
    """Weak percentile rank in 0..100: 100 * (#{m <= mos}) / n.

    The highest-MOS crop therefore scores exactly 100 (ties included).
    Only valid non-negative MOS values are considered.
    """
    values = [m for m in all_mos if m >= 0]
    if not values:
        return 0.0
    return 100.0 * sum(1 for m in values if m <= mos) / len(values)


def top_mos_crop(gt: Sequence[dict]) -> dict:
    valid = [item for item in gt if item["mos"] >= 0]
    return max(valid or gt, key=lambda item: item["mos"])


def best_iou_vs_top(crop: Rect, gt: Sequence[dict]) -> float:
    """IoU with the highest-MOS crop (max over crops tied for highest MOS)."""
    valid = [item for item in gt if item["mos"] >= 0]
    if not valid:
        return 0.0
    top = max(item["mos"] for item in valid)
    return max(iou(crop, item["rect"]) for item in valid if item["mos"] == top)


def top_fraction_crops(gt: Sequence[dict], fraction: float = 0.10) -> list[dict]:
    """Crops in the top `fraction` of MOS for this image.

    k = max(1, ceil(fraction * n)) highest-MOS crops; crops tied with the k-th MOS are all included.
    Invalid crops (MOS < 0) are excluded.
    """
    valid = [item for item in gt if item["mos"] >= 0]
    if not valid:
        return []
    ranked = sorted(valid, key=lambda item: item["mos"], reverse=True)
    k = max(1, math.ceil(fraction * len(ranked) - 1e-9))
    cutoff = ranked[k - 1]["mos"]
    return [item for item in ranked if item["mos"] >= cutoff]


def best_iou_top10(crop: Rect, gt: Sequence[dict]) -> float:
    """Largest IoU with any crop in the image's top-10% MOS group."""
    top_crops = top_fraction_crops(gt, 0.10)
    if not top_crops:
        return 0.0
    return max(iou(crop, item["rect"]) for item in top_crops)


def metrics_for_crop(crop: Rect, gt: Sequence[dict]) -> dict:
    valid_gt = [item for item in gt if item["mos"] >= 0]
    matched_iou, matched_mos = best_match(crop, valid_gt)
    return {
        "matched_iou": matched_iou,
        "matched_mos": matched_mos if matched_mos is not None else "unmatched",
        "mos_percentile": None if matched_mos is None else mos_percentile(matched_mos, [g["mos"] for g in valid_gt]),
        "best_iou": best_iou_vs_top(crop, valid_gt),
        "best_iou_top10": best_iou_top10(crop, valid_gt),
    }


def clamp_rect(rect: Rect) -> list[float]:
    x, y, w, h = rect
    x = min(max(x, 0.0), 1.0)
    y = min(max(y, 0.0), 1.0)
    return [x, y, max(0.0, min(w, 1.0 - x)), max(0.0, min(h, 1.0 - y))]


def center_crop_same_size(crop: Rect) -> list[float]:
    """Crop with the same width/height (hence area and aspect) as `crop`, centred in the frame."""
    _, _, w, h = crop
    return [(1.0 - w) / 2.0, (1.0 - h) / 2.0, w, h]


def random_crops_same_size(crop: Rect, key: str, trials: int = RANDOM_TRIALS, seed: int = RANDOM_SEED) -> list[list[float]]:
    """`trials` crops with the same w/h as `crop`, uniformly placed; deterministic per (seed, key)."""
    _, _, w, h = crop
    rng = random.Random(f"{seed}:{key}")
    return [[rng.uniform(0.0, max(0.0, 1.0 - w)), rng.uniform(0.0, max(0.0, 1.0 - h)), w, h] for _ in range(trials)]


def aggregate(values: Iterable[float | None]) -> dict:
    """mean/median/p25/p75 over the non-None values (linear-interpolated percentiles)."""
    data = sorted(v for v in values if v is not None and not (isinstance(v, float) and math.isnan(v)))
    if not data:
        return {"n": 0, "mean": None, "median": None, "p25": None, "p75": None}
    return {"n": len(data), "mean": sum(data) / len(data), "median": percentile(data, 50),
            "p25": percentile(data, 25), "p75": percentile(data, 75)}


def percentile(sorted_data: Sequence[float], q: float) -> float:
    """Linear-interpolated percentile (numpy default 'linear') of already-sorted data."""
    if not sorted_data:
        raise ValueError("empty")
    k = (len(sorted_data) - 1) * q / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_data[lo] if lo == hi else sorted_data[lo] + (sorted_data[hi] - sorted_data[lo]) * (k - lo)
