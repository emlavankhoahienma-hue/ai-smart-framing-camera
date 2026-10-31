"""Compare two scored runs:  compare_runs.py <run_dir_A> <run_dir_B>

Prints the per-metric delta (B - A) for the AI crop and the 10 images that got worst
(largest drop in best_iou, then in mos_percentile) from A to B.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore  # noqa: E402,F401  (side effect: UTF-8 console output on Windows)

METRICS = ["matched_iou", "best_iou", "best_iou_top10", "mos_percentile", "matched_mos"]


def load(run: Path):
    return (json.loads((run / "summary.json").read_text(encoding="utf-8")),
            {r["image"]: r for r in json.loads((run / "per_image.json").read_text(encoding="utf-8"))})


def f(v):
    return "–" if v is None else f"{v:+.4f}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("a", type=Path)
    ap.add_argument("b", type=Path)
    args = ap.parse_args()
    (sa, ra), (sb, rb) = load(args.a), load(args.b)
    lines = [f"A = {args.a.name}", f"B = {args.b.name}", "", "AI crop: delta = B - A",
             "| metric | stat | A | B | delta |", "|---|---|---|---|---|"]
    for metric in METRICS:
        for stat in ("mean", "median", "p25", "p75"):
            a, b = sa["stats"]["ai"][metric][stat], sb["stats"]["ai"][metric][stat]
            lines.append(f"| {metric} | {stat} | {'–' if a is None else f'{a:.4f}'} | {'–' if b is None else f'{b:.4f}'} | {f(None if a is None or b is None else b - a)} |")
    for key in ("images_scored", "ok_false", "unmatched_ai"):
        lines.append(f"| {key} | | {sa['summary'][key]} | {sb['summary'][key]} | {sb['summary'][key] - sa['summary'][key]:+d} |")
    common = [i for i in ra if i in rb and ra[i]["status"] == "ok" and rb[i]["status"] == "ok"]
    deltas = []
    for image in common:
        a, b = ra[image]["ai"], rb[image]["ai"]
        d_best = b["best_iou"] - a["best_iou"]
        pa, pb = a["mos_percentile"], b["mos_percentile"]
        d_pct = None if pa is None or pb is None else pb - pa
        deltas.append((d_best, d_pct, image, a["best_iou"], b["best_iou"], pa, pb))
    deltas.sort(key=lambda t: (t[0], 0 if t[1] is None else t[1]))
    lines += ["", f"Ảnh chung chấm được ở cả hai run: {len(common)}.", "", "10 ảnh tệ đi nhiều nhất (theo best_iou):",
              "| ảnh | best_iou A | best_iou B | delta | pct A | pct B |", "|---|---|---|---|---|---|"]
    for d_best, _, image, ba, bb, pa, pb in deltas[:10]:
        lines.append(f"| {image} | {ba:.4f} | {bb:.4f} | {d_best:+.4f} | {'–' if pa is None else f'{pa:.1f}'} | {'–' if pb is None else f'{pb:.1f}'} |")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
