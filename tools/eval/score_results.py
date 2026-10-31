"""Score eval_results.json (from the Swift pipeline) against GAICD MOS crops.

    .venv\\Scripts\\python.exe tools\\eval\\score_results.py --results eval_results.json --eval-set eval_set.json

Per image (see docs/eval/SCHEMA.md for the input format):
  matched_iou   max IoU of the crop with any MOS-annotated crop
  matched_mos   MOS of that best-IoU crop, only if matched_iou >= 0.80, else "unmatched" (no interpolation)
  mos_percentile weak percentile rank (0-100) of matched_mos among the image's MOS values
  best_iou      IoU with the highest-MOS crop
  best_iou_top10 largest IoU with any crop in the image's top-10% MOS group (k = max(1, ceil(0.1 n)), ties included)
Baselines on the SAME images and same crop size: full frame, centred crop, random crop (20 trials, fixed seed).
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore as ec  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
METRICS = ["matched_iou", "best_iou", "best_iou_top10", "mos_percentile", "matched_mos"]
METHODS = ["ai", "full_frame", "center_crop", "random_crop"]


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
    row["ai"] = ec.metrics_for_crop(crop, gt)
    row["full_frame"] = ec.metrics_for_crop([0.0, 0.0, 1.0, 1.0], gt)
    row["center_crop"] = ec.metrics_for_crop(ec.center_crop_same_size(crop), gt)
    trials = [ec.metrics_for_crop(r, gt) for r in ec.random_crops_same_size(crop, entry["image"])]
    matched_pct = [t["mos_percentile"] for t in trials if t["mos_percentile"] is not None]
    matched_mos = [t["matched_mos"] for t in trials if t["matched_mos"] != "unmatched"]
    row["random_crop"] = {
        "matched_iou": sum(t["matched_iou"] for t in trials) / len(trials),
        "best_iou": sum(t["best_iou"] for t in trials) / len(trials),
        "best_iou_top10": sum(t["best_iou_top10"] for t in trials) / len(trials),
        "mos_percentile": sum(matched_pct) / len(matched_pct) if matched_pct else None,
        "matched_mos": sum(matched_mos) / len(matched_mos) if matched_mos else "unmatched",
        "unmatched_rate": 1 - len(matched_mos) / len(trials),
        "trials": len(trials),
    }
    return row


def numeric(value):
    return None if value == "unmatched" else value


def summarize(rows: list[dict]) -> dict:
    scored = [r for r in rows if r["status"] == "ok"]
    summary = {"images_total": len(rows), "images_scored": len(scored),
               "ok_false": sum(r["status"] == "ok=false" for r in rows),
               "missing": sum(r["status"] == "missing" for r in rows),
               "no_crop_rect": sum(r["status"] == "no_crop_rect" for r in rows)}
    stats = {}
    for method in METHODS:
        stats[method] = {}
        for metric in METRICS:
            stats[method][metric] = ec.aggregate(numeric(r[method][metric]) for r in scored)
        if method == "random_crop":
            summary["unmatched_random_mean_rate"] = (sum(r["random_crop"]["unmatched_rate"] for r in scored) / len(scored)) if scored else None
        else:
            summary[f"unmatched_{method}"] = sum(r[method]["matched_mos"] == "unmatched" for r in scored)
    wins = ties = losses = 0
    for r in scored:
        a, c = r["ai"]["best_iou"], r["center_crop"]["best_iou"]
        wins += a > c
        ties += a == c
        losses += a < c
    summary["ai_vs_center_best_iou"] = {"wins": wins, "ties": ties, "losses": losses,
                                         "win_rate": (wins / len(scored)) if scored else None}
    wins10 = ties10 = losses10 = 0
    for r in scored:
        a, c = r["ai"]["best_iou_top10"], r["center_crop"]["best_iou_top10"]
        wins10 += a > c
        ties10 += a == c
        losses10 += a < c
    summary["ai_vs_center_best_iou_top10"] = {"wins": wins10, "ties": ties10, "losses": losses10,
                                               "win_rate": (wins10 / len(scored)) if scored else None}
    rotated = [r for r in scored if r.get("is_rotated") is True]
    upright = [r for r in scored if r.get("is_rotated") is False]
    summary["rotated"] = {"is_rotated_true": len(rotated), "is_rotated_false": len(upright),
                          "is_rotated_unknown": len(scored) - len(rotated) - len(upright),
                          "ai_best_iou_mean_rotated": ec.aggregate(r["ai"]["best_iou"] for r in rotated)["mean"],
                          "ai_best_iou_mean_upright": ec.aggregate(r["ai"]["best_iou"] for r in upright)["mean"]}
    both = [r for r in scored if r["ai"]["mos_percentile"] is not None and r["center_crop"]["mos_percentile"] is not None]
    summary["ai_vs_center_mos_percentile_both_matched"] = {
        "n": len(both), "wins": sum(r["ai"]["mos_percentile"] > r["center_crop"]["mos_percentile"] for r in both)}
    times = sorted(t for t in (r["timing_total_ms"] for r in rows) if isinstance(t, (int, float)))
    summary["timing_total_ms"] = ({"n": len(times), "p50": ec.percentile(times, 50), "p95": ec.percentile(times, 95)}
                                  if times else {"n": 0, "p50": None, "p95": None})
    return {"summary": summary, "stats": stats}


def fmt(v):
    return "–" if v is None else f"{v:.4f}"


def write_reports(out: Path, result: dict, meta: dict) -> None:
    s, stats = result["summary"], result["stats"]
    lines = ["# Báo cáo eval AI Target & Zoom", "",
             f"- run: `{meta['run_id']}`  |  impl: `{meta.get('impl')}`  |  device: `{meta.get('device')}`",
             f"- kết quả: `{meta['results_file']}`; eval set: `{meta['eval_set_file']}`" + (f"  |  **{meta['label']}**" if meta.get("label") else ""),
             f"- ảnh: {s['images_total']} (chấm được {s['images_scored']}, ok=false {s['ok_false']}, thiếu {s['missing']}, không có crop_rect {s['no_crop_rect']})",
             "", "> **Phạm vi:** đây là kết quả đo CHẤT LƯỢNG KHUNG (target/zoom/crop). **KHÔNG đo tốc độ.** Pipeline Swift chạy trên "
             "macOS CLI (CoreML trên runner CI, không có Apple Neural Engine) nên số có thể **lệch nhẹ so với iPhone thật**. "
             "Cột thời gian chỉ mang tính tham khảo của runner, không phải tốc độ trên điện thoại.",
             "> **`crop_rect` là xấp xỉ:** hộp bao trục của tứ giác `sourceCorners` kẹp [0,1]; tứ giác thật có thể xoay/lồi ra ngoài ảnh. "
             "Xem mục xoay bên dưới.", "",
             "Mọi phương pháp được tính trên CÙNG tập ảnh đã chấm được; baseline center/random dùng cùng w×h với crop của AI.", ""]
    for metric in METRICS:
        lines += [f"## {metric}", "", "| phương pháp | n | mean | median | p25 | p75 |", "|---|---|---|---|---|---|"]
        for method in METHODS:
            a = stats[method][metric]
            lines.append(f"| {method} | {a['n']} | {fmt(a['mean'])} | {fmt(a['median'])} | {fmt(a['p25'])} | {fmt(a['p75'])} |")
        lines.append("")
    lines += ["`matched_mos`/`mos_percentile` chỉ tính trên ảnh có matched_iou ≥ 0.80 (cột n = số ảnh khớp). "
              "Với random_crop, giá trị mỗi ảnh là trung bình trên các lần thử khớp.", "",
              "## Unmatched (matched_iou < 0.80)", "", "| phương pháp | số ảnh unmatched |", "|---|---|"]
    for method in ("ai", "full_frame", "center_crop"):
        lines.append(f"| {method} | {s[f'unmatched_{method}']} / {s['images_scored']} |")
    lines.append(f"| random_crop (tỉ lệ lần thử unmatched, trung bình) | {fmt(s['unmatched_random_mean_rate'])} |")
    w = s["ai_vs_center_best_iou"]
    p = s["ai_vs_center_mos_percentile_both_matched"]
    t = s["timing_total_ms"]
    w10 = s["ai_vs_center_best_iou_top10"]
    rot = s["rotated"]
    lines += ["", "## AI vs crop giữa", "",
              f"- **Chỉ số chính** `best_iou` (gần crop MOS cao nhất hơn): thắng {w['wins']}, hòa {w['ties']}, thua {w['losses']} → tỉ lệ thắng {fmt(w['win_rate'])}",
              f"- Theo `best_iou_top10` (IoU lớn nhất với nhóm top 10% MOS): thắng {w10['wins']}, hòa {w10['ties']}, thua {w10['losses']} → tỉ lệ thắng {fmt(w10['win_rate'])}",
              f"- Theo `mos_percentile`, chỉ ảnh cả hai đều khớp: n={p['n']}, AI thắng {p['wins']}", "",
              "## Crop xoay (`is_rotated`, ngưỡng do runner Swift quyết định)", "",
              f"- is_rotated=true: {rot['is_rotated_true']}, false: {rot['is_rotated_false']}, không rõ: {rot['is_rotated_unknown']}",
              f"- `best_iou` trung bình của AI: ảnh xoay {fmt(rot['ai_best_iou_mean_rotated'])} | ảnh thẳng {fmt(rot['ai_best_iou_mean_upright'])}", "",
              "## Thời gian runner (ms, tham khảo, KHÔNG phải tốc độ iPhone)", "", f"n={t['n']}, p50={fmt(t['p50'])}, p95={fmt(t['p95'])}", ""]
    (out / "report.md").write_text("\n".join(lines), encoding="utf-8")
    with (out / "report.csv").open("w", newline="", encoding="utf-8") as f:
        w_ = csv.writer(f)
        w_.writerow(["section", "method", "metric", "n", "mean", "median", "p25", "p75"])
        for method in METHODS:
            for metric in METRICS:
                a = stats[method][metric]
                w_.writerow(["stats", method, metric, a["n"], a["mean"], a["median"], a["p25"], a["p75"]])
        for key in ("images_total", "images_scored", "ok_false", "missing", "no_crop_rect", "unmatched_ai", "unmatched_full_frame",
                    "unmatched_center_crop", "unmatched_random_mean_rate"):
            w_.writerow(["summary", "", key, "", s[key], "", "", ""])
        w_.writerow(["summary", "ai_vs_center", "win_rate_best_iou", w["wins"] + w["ties"] + w["losses"], w["win_rate"], "", "", ""])
        w_.writerow(["summary", "ai_vs_center", "win_rate_best_iou_top10", w10["wins"] + w10["ties"] + w10["losses"], w10["win_rate"], "", "", ""])
        w_.writerow(["summary", "rotated", "is_rotated_true", "", rot["is_rotated_true"], "", "", ""])
        w_.writerow(["summary", "timing_total_ms", "p50_p95", t["n"], t["p50"], t["p95"], "", ""])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=REPO / "eval_results.json")
    ap.add_argument("--eval-set", type=Path, default=REPO / "eval_set.json")
    ap.add_argument("--runs-dir", type=Path, default=REPO / "eval_runs")
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
    write_reports(out, result, meta)
    with (out / "per_image.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["image", "status", "timing_total_ms"] + [f"{m}_{k}" for m in METHODS for k in METRICS])
        for r in rows:
            w.writerow([r["image"], r["status"], r["timing_total_ms"]] +
                       [r[m][k] if m in r else "" for m in METHODS for k in METRICS])
    print(f"OK: {out}")
    print((out / "report.md").read_text(encoding="utf-8").split("## Unmatched")[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
