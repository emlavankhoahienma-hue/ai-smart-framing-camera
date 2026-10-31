"""Draw AI crop (red), highest-MOS crop (green) and hero box (yellow) on each eval image.

    visualize.py --results eval_results.json --eval-set eval_set.json --images eval_input --out debug/vis [--limit N]
All coordinates are normalised [x, y, w, h], top-left origin.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore as ec  # noqa: E402

REPO = Path(__file__).resolve().parents[2]


def draw(canvas: Image.Image, rect, color: str, label: str) -> None:
    w, h = canvas.size
    x1, y1, x2, y2 = ec.norm_to_px_corners(rect, w, h)
    d = ImageDraw.Draw(canvas)
    d.rectangle([x1, y1, x2, y2], outline=color, width=max(2, w // 200))
    d.text((x1 + 4, y1 + 4), label, fill=color)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=REPO / "eval_results.json")
    ap.add_argument("--eval-set", type=Path, default=REPO / "eval_set.json")
    ap.add_argument("--images", type=Path, default=REPO / "eval_input")
    ap.add_argument("--out", type=Path, default=REPO / "debug" / "vis")
    ap.add_argument("--limit", type=int)
    args = ap.parse_args()
    results = {r["image"]: r for r in json.loads(args.results.read_text(encoding="utf-8"))}
    eval_set = json.loads(args.eval_set.read_text(encoding="utf-8"))["images"]
    args.out.mkdir(parents=True, exist_ok=True)
    done = 0
    for entry in eval_set[: args.limit]:
        src = args.images / entry["image"]
        if not src.exists():
            print("thiếu ảnh:", src, file=sys.stderr)
            continue
        with Image.open(src) as im:
            canvas = im.convert("RGB")
        top = ec.top_mos_crop(entry["crops"])
        draw(canvas, top["rect"], "lime", f"best MOS {top['mos']:.3f}")
        record = results.get(entry["image"])
        if record and record.get("ok"):
            if record.get("hero_subject_box"):
                draw(canvas, record["hero_subject_box"], "yellow", "hero")
            if record.get("crop_rect"):
                draw(canvas, record["crop_rect"], "red", "AI")
        canvas.save(args.out / f"{Path(entry['image']).stem}_vis.jpg", quality=90)
        done += 1
    print(f"OK: {done} ảnh → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
