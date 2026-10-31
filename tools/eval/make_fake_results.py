"""Generate a FAKE eval_results.json derived from the annotations (for harness self-tests ONLY).

    make_fake_results.py --eval-set eval_set.json --mode best|center|full --out fake_results.json

Every record is labelled impl="FAKE_FROM_ANNOTATION" and device="FAKE" so it can never be
mistaken for a real pipeline run. mode=best -> crop_rect = highest-MOS crop (sanity check).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalcore as ec  # noqa: E402


def fake_results(eval_set: dict, mode: str) -> list[dict]:
    out = []
    for entry in eval_set["images"]:
        top = ec.top_mos_crop(entry["crops"])
        if mode == "best":
            crop = list(top["rect"])
        elif mode == "center":
            crop = ec.center_crop_same_size(top["rect"])
        else:
            crop = [0.0, 0.0, 1.0, 1.0]
        out.append({"image": entry["image"], "image_w": entry["w"], "image_h": entry["h"], "ok": True, "error": None,
                    "hero_subject_box": None, "scene_intent": None, "target_P": None, "zoom_current": None,
                    "zoom_ideal": None, "zoom_final": None, "crop_rect": crop,
                    "scores": {"samp": None, "charm": None, "geom": None, "final": None},
                    "num_candidates": None, "timing_ms": {"total": 100.0}, "device": "FAKE", "impl": "FAKE_FROM_ANNOTATION"})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-set", type=Path, required=True)
    ap.add_argument("--mode", choices=["best", "center", "full"], default="best")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()
    eval_set = json.loads(args.eval_set.read_text(encoding="utf-8"))
    args.out.write_text(json.dumps(fake_results(eval_set, args.mode), indent=1), encoding="utf-8")
    print(f"FAKE results ({args.mode}) → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
