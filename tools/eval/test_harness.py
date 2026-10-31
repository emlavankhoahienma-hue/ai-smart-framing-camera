"""Self-tests for the offline evaluation harness.

Run:  .venv\\Scripts\\python.exe -m pytest tools/eval/test_harness.py -q

Every expected value below is computed BY HAND (arithmetic shown in comments), never from the
code under test. All datasets here are SYNTHETIC / FAKE and exist only to test the harness.
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

import pytest
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import evalcore as ec  # noqa: E402
import make_fake_results  # noqa: E402
import prepare_gaicd  # noqa: E402
import score_results  # noqa: E402


# ------------------------------------------------------------------ IoU
@pytest.mark.parametrize("a,b,expected", [
    # inter = 0.25*0.25 = 0.0625; union = 0.25 + 0.25 - 0.0625 = 0.4375; 0.0625/0.4375 = 1/7
    ([0, 0, .5, .5], [.25, .25, .5, .5], 1 / 7),
    ([.1, .2, .3, .4], [.1, .2, .3, .4], 1.0),      # identical
    ([0, 0, .25, .25], [.5, .5, .25, .25], 0.0),    # disjoint
    ([0, 0, 1, 1], [0, 0, .5, 1], 0.5),             # inter .5, union 1
    ([0, 0, 1, 1], [.25, .25, .5, .5], 0.25),       # contained: .25 / 1
])
def test_iou_hand_values(a, b, expected):
    assert ec.iou(a, b) == pytest.approx(expected, abs=1e-12)
    assert ec.iou(b, a) == pytest.approx(expected, abs=1e-12)


# ------------------------------------------------------------------ coordinates
def test_pixel_to_norm_hand_values():
    # 200x100 image, corners (20,10)-(120,60): x=20/200=.1, y=10/100=.1, w=100/200=.5, h=50/100=.5
    assert ec.px_corners_to_norm(20, 10, 120, 60, 200, 100) == pytest.approx([.1, .1, .5, .5])
    # 400x300, corners (100,75)-(300,225): [.25, .25, .5, .5]
    assert ec.px_corners_to_norm(100, 75, 300, 225, 400, 300) == pytest.approx([.25, .25, .5, .5])
    # full frame
    assert ec.px_corners_to_norm(0, 0, 640, 480, 640, 480) == [0.0, 0.0, 1.0, 1.0]


def test_norm_to_pixel_roundtrip_and_hand_value():
    # [.25,.5,.5,.25] on 400x200 -> x1=100,y1=100,x2=100+200=300,y2=100+50=150
    assert ec.norm_to_px_corners([.25, .5, .5, .25], 400, 200) == pytest.approx([100, 100, 300, 150])
    rect = ec.px_corners_to_norm(37, 11, 211, 90, 300, 120)
    back = ec.norm_to_px_corners(rect, 300, 120)
    assert back == pytest.approx([37, 11, 211, 90])


# ------------------------------------------------------------------ crop representations
def test_center_same_zoom_hand_values():
    assert ec.center_same_zoom(1.0) == [0.0, 0.0, 1.0, 1.0]
    assert ec.center_same_zoom(2.0) == [0.25, 0.25, 0.5, 0.5]
    assert ec.center_same_zoom(1.25) == pytest.approx([0.1, 0.1, 0.8, 0.8])
    assert ec.center_same_zoom(0.5) == [0.0, 0.0, 1.0, 1.0]
    assert ec.center_same_zoom(None) == [0.0, 0.0, 1.0, 1.0]


def test_crop_simple_hand_values():
    # centered quad at (0.5, 0.5), zoom 2.0 -> [0.25, 0.25, 0.5, 0.5]
    c_centered = [0.2, 0.2, 0.8, 0.2, 0.8, 0.8, 0.2, 0.8]
    assert ec.crop_simple(c_centered, 2.0) == pytest.approx([0.25, 0.25, 0.5, 0.5])

    # off-center quad with centroid (0.3, 0.3), zoom 2.0 -> [0.05, 0.05, 0.5, 0.5]
    c_offcenter = [0.1, 0.1, 0.5, 0.1, 0.5, 0.5, 0.1, 0.5]
    assert ec.crop_simple(c_offcenter, 2.0) == pytest.approx([0.05, 0.05, 0.5, 0.5])

    # overflow right-bottom: centroid (0.9, 0.9), zoom 2.0 -> clamped to [0.5, 0.5, 0.5, 0.5]
    c_rb_overflow = [0.7, 0.7, 1.1, 0.7, 1.1, 1.1, 0.7, 1.1]
    assert ec.crop_simple(c_rb_overflow, 2.0) == pytest.approx([0.5, 0.5, 0.5, 0.5])

    # overflow left-top: centroid (0.1, 0.1), zoom 2.0 -> clamped to [0.0, 0.0, 0.5, 0.5]
    c_lt_overflow = [-0.1, -0.1, 0.3, -0.1, 0.3, 0.3, -0.1, 0.3]
    assert ec.crop_simple(c_lt_overflow, 2.0) == pytest.approx([0.0, 0.0, 0.5, 0.5])

    # invalid inputs
    assert ec.crop_simple(None, 2.0) is None
    assert ec.crop_simple([1.0] * 7, 2.0) is None
    assert ec.crop_simple([1.0] * 8, 0.0) is None
    assert ec.crop_simple([1.0] * 8, -1.0) is None


def test_mos_soft_hand_values():
    # Only GT with IoU >= 0.5 included
    gt = [{"rect": [0, 0, 1, 1], "mos": 3.0}, {"rect": [0, 0, 0.5, 0.5], "mos": 1.0}]
    assert ec.mos_soft([0, 0, 1, 1], gt) == pytest.approx(3.0)

    # Weighted blend: g1 IoU 0.8 -> w1=0.8^4=0.4096; g2 IoU 1.0 -> w2=1.0
    gt2 = [{"rect": [0, 0, 1, 1], "mos": 2.0}, {"rect": [0, 0, 0.8, 1], "mos": 4.0}]
    expected = (0.4096 * 2.0 + 1.0 * 4.0) / (0.4096 + 1.0)
    assert ec.mos_soft([0, 0, 0.8, 1], gt2) == pytest.approx(expected)

    # Disjoint -> no crop >= 0.5 -> None
    assert ec.mos_soft([0.9, 0.9, 0.1, 0.1], gt2) is None


# ------------------------------------------------------------------ matching
GT = [{"rect": [0, 0, .5, .5], "mos": 3.0}, {"rect": [.5, .5, .5, .5], "mos": 4.0}]


def test_match_exact():
    assert ec.best_match([0, 0, .5, .5], GT) == (1.0, 3.0)


def test_match_above_threshold():
    # crop [0,0,.5,.4375] vs GT0: inter=.5*.4375=.21875, union=.25 -> .875 >= .8 -> matched mos 3
    iou_v, mos = ec.best_match([0, 0, .5, .4375], GT)
    assert iou_v == pytest.approx(.875) and mos == 3.0


def test_match_below_threshold_is_unmatched_no_interpolation():
    # crop [0,0,.5,.375]: inter=.1875, union=.25 -> .75 < .8 -> unmatched
    iou_v, mos = ec.best_match([0, 0, .5, .375], GT)
    assert iou_v == pytest.approx(.75) and mos is None
    assert ec.metrics_for_crop([0, 0, .5, .375], GT)["matched_mos"] == "unmatched"
    assert ec.metrics_for_crop([0, 0, .5, .375], GT)["mos_percentile"] is None


def test_match_threshold_is_inclusive():
    # GT [0,0,.5,1] vs crop [0,0,.625,1]: inter=.5, union=.625+.5-.5=.625 -> exactly .8 -> matched
    gt = [{"rect": [0, 0, .5, 1], "mos": 2.0}]
    iou_v, mos = ec.best_match([0, 0, .625, 1], gt)
    assert iou_v == pytest.approx(.8) and mos == 2.0


# ------------------------------------------------------------------ percentile
def test_percentile_hand_values():
    mos = [1, 2, 3, 4]
    assert ec.mos_percentile(3, mos) == 75.0     # 3 of 4 values <= 3
    assert ec.mos_percentile(4, mos) == 100.0    # highest -> exactly 100
    assert ec.mos_percentile(1, mos) == 25.0
    assert ec.mos_percentile(2, [1, 2, 2, 4]) == 75.0  # ties counted (<=): 3 of 4


def test_aggregate_hand_values():
    # data 1..4: mean 2.5, median 2.5; p25: k=(3)*.25=.75 -> 1+.75*(2-1)=1.75; p75: k=2.25 -> 3+.25=3.25
    a = ec.aggregate([4, 1, 3, 2, None])
    assert (a["n"], a["mean"], a["median"], a["p25"], a["p75"]) == (4, 2.5, 2.5, 1.75, 3.25)
    assert ec.aggregate([None])["mean"] is None


def test_best_iou_vs_top_mos():
    # top MOS crop is GT[1] ([.5,.5,.5,.5]); crop equal to GT[0] is disjoint from it -> 0
    assert ec.best_iou_vs_top([0, 0, .5, .5], GT) == 0.0
    assert ec.best_iou_vs_top([.5, .5, .5, .5], GT) == 1.0


def test_best_iou_top10_hand_values():
    # 10 crops with MOS 1..10
    # Top 10% of 10 items: ceil(0.10 * 10) = 1 item -> item with MOS 10
    gt10 = [
        {"rect": [0, 0, 0.5, 0.5], "mos": 10.0},
        {"rect": [0.5, 0, 0.5, 0.5], "mos": 9.0},
    ] + [{"rect": [0, 0.5, 0.1, 0.1], "mos": float(i)} for i in range(1, 9)]
    assert ec.best_iou_top10([0, 0, 0.5, 0.5], gt10) == 1.0
    assert ec.best_iou_top10([0.5, 0, 0.5, 0.5], gt10) == 0.0

    # 20 crops: top 10% is ceil(0.10 * 20) = 2 items (MOS 20 and MOS 19)
    gt20 = [
        {"rect": [0, 0, 0.5, 0.5], "mos": 20.0},
        {"rect": [0.5, 0, 0.5, 0.5], "mos": 19.0},
    ] + [{"rect": [0, 0.5, 0.1, 0.1], "mos": float(i)} for i in range(1, 19)]
    # A crop matching the 2nd best (MOS 19) has best_iou = 0 but best_iou_top10 = 1.0
    assert ec.best_iou_vs_top([0.5, 0, 0.5, 0.5], gt20) == 0.0
    assert ec.best_iou_top10([0.5, 0, 0.5, 0.5], gt20) == 1.0


def test_negative_mos_is_excluded_from_metrics():
    # In GAICD, invalid/placeholder crops carry MOS = -2.0.
    # Verify they are excluded from matched_mos, best_iou, best_iou_top10, and mos_percentile.
    gt_with_neg = [
        {"rect": [0, 0, 0.5, 0.5], "mos": 4.0},
        {"rect": [0.5, 0.5, 0.5, 0.5], "mos": -2.0},  # Invalid placeholder
    ]
    # Crop matching the invalid -2.0 crop with IoU 1.0 should NOT match it:
    matched_iou, matched_mos = ec.best_match([0.5, 0.5, 0.5, 0.5], gt_with_neg)
    assert matched_mos is None
    # Crop matching the valid crop:
    metrics = ec.metrics_for_crop([0, 0, 0.5, 0.5], gt_with_neg)
    assert metrics["matched_iou"] == 1.0
    assert metrics["matched_mos"] == 4.0
    assert metrics["mos_percentile"] == 100.0
    assert metrics["best_iou"] == 1.0
    assert metrics["best_iou_top10"] == 1.0

    # mos_percentile should ignore negative numbers in the denominator
    # If -2.0 is ignored, [4.0] has n=1 -> mos_percentile(4.0) = 100.0
    assert ec.mos_percentile(4.0, [4.0, -2.0]) == 100.0


# ------------------------------------------------------------------ baselines
def test_center_crop_same_size_hand_value():
    # w=.5,h=.25 -> x=(1-.5)/2=.25, y=(1-.25)/2=.375
    assert ec.center_crop_same_size([0, 0, .5, .25]) == [.25, .375, .5, .25]


def test_random_crops_deterministic_inside_and_same_size():
    crop = [.1, .1, .4, .3]
    a = ec.random_crops_same_size(crop, "img.jpg")
    b = ec.random_crops_same_size(crop, "img.jpg")
    c = ec.random_crops_same_size(crop, "other.jpg")
    assert a == b and a != c and len(a) == 20
    for x, y, w, h in a:
        assert (w, h) == (.4, .3) and 0 <= x <= .6 and 0 <= y <= .7


# ------------------------------------------------------------------ synthetic eval set + sanity
def synthetic_eval_set(n: int = 6, crops: int = 40) -> dict:
    """SYNTHETIC data (not GAICD): random crops with random MOS."""
    rng = random.Random(7)
    images = []
    for i in range(n):
        items = []
        for _ in range(crops):
            w, h = rng.uniform(.3, .9), rng.uniform(.3, .9)
            items.append({"rect": [rng.uniform(0, 1 - w), rng.uniform(0, 1 - h), w, h], "mos": round(rng.uniform(1, 5), 3)})
        images.append({"image": f"synthetic_{i}.jpg", "split": "test", "w": 400, "h": 300, "exif_orientation": None, "crops": items})
    return {"seed": 7, "dataset": "SYNTHETIC", "images": images}


def test_sanity_crop_equals_best_mos_crop():
    """Feeding the highest-MOS crop must give best_iou == 1.0 and mos_percentile == 100."""
    es = synthetic_eval_set()
    results = {r["image"]: r for r in make_fake_results.fake_results(es, "best")}
    rows = [score_results.score_one(results[e["image"]], e) for e in es["images"]]
    for row in rows:
        assert row["status"] == "ok"
        assert row["ai"]["best_iou"] == 1.0
        assert row["ai"]["best_iou_top10"] == 1.0
        assert row["ai"]["matched_iou"] == 1.0
        assert row["ai"]["mos_percentile"] == 100.0
    summary = score_results.summarize(rows)
    assert summary["stats"]["ai"]["mos_percentile"]["mean"] == 100.0
    assert summary["summary"]["unmatched_ai"] == 0
    assert summary["summary"]["ai_vs_center_best_iou"]["wins"] + summary["summary"]["ai_vs_center_best_iou"]["ties"] == len(rows)


def test_full_frame_baseline_values_hand_checked():
    # one image, one GT crop = full frame with MOS 3 and another [0,0,.5,.5] MOS 1
    gt = [{"rect": [0, 0, 1, 1], "mos": 3.0}, {"rect": [0, 0, .5, .5], "mos": 1.0}]
    m = ec.metrics_for_crop([0, 0, 1, 1], gt)
    assert m["matched_iou"] == 1.0 and m["matched_mos"] == 3.0
    assert m["mos_percentile"] == 100.0     # both MOS <= 3
    assert m["best_iou"] == 1.0


def test_failed_images_do_not_stop_the_batch_and_are_counted():
    es = synthetic_eval_set(n=4)
    results = make_fake_results.fake_results(es, "best")
    results[0].update(ok=False, error="boom", crop_rect=None)   # ok=false
    results[1].update(crop_rect=None)                            # ok but no crop
    del results[2]                                               # missing record
    by_image = {r["image"]: r for r in results}
    rows = [score_results.score_one(by_image.get(e["image"]), e) for e in es["images"]]
    assert [r["status"] for r in rows] == ["ok=false", "no_crop_rect", "missing", "ok"]
    s = score_results.summarize(rows)["summary"]
    assert (s["images_total"], s["images_scored"], s["ok_false"], s["missing"], s["no_crop_rect"]) == (4, 1, 1, 1, 1)


def test_end_to_end_scripts_on_fake_results(tmp_path, monkeypatch, capsys):
    es_path = tmp_path / "eval_set.json"
    es_path.write_text(json.dumps(synthetic_eval_set()), encoding="utf-8")
    fake = tmp_path / "fake_results.json"
    fake.write_text(json.dumps(make_fake_results.fake_results(synthetic_eval_set(), "best")), encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["score_results", "--results", str(fake), "--eval-set", str(es_path),
                                      "--runs-dir", str(tmp_path / "runs"), "--label", "FAKE DATA - harness self-test"])
    assert score_results.main() == 0
    run = next((tmp_path / "runs").iterdir())
    for name in ("report.md", "report.csv", "per_image.csv", "per_image.json", "summary.json", "eval_results.json", "meta.json"):
        assert (run / name).exists(), name
    assert "FAKE DATA" in (run / "report.md").read_text(encoding="utf-8")
    # compare_runs on identical runs: zero deltas
    import compare_runs
    monkeypatch.setattr(sys, "argv", ["compare_runs", str(run), str(run)])
    assert compare_runs.main() == 0
    assert "+0.0000" in capsys.readouterr().out


# ------------------------------------------------------------------ prepare_gaicd on a SYNTHETIC tree
def build_fake_gaicd(root: Path, order: str, square: bool = False) -> None:
    """SYNTHETIC tree: images/<split>/x.jpg + annotations/<split>/x.txt (rows: 4 coords + MOS)."""
    size = (100, 100) if square else (200, 100)
    rows_xyxy = [(20, 10, 120, 60, 3.5), (100, 50, 190, 95, 4.25), (0, 0, 200, 100, 2.0)] if not square else \
                [(20, 10, 60, 60, 3.5), (10, 20, 70, 90, 4.25)]
    for split, names in {"test": ["a", "b", "c"], "val": ["d", "e"], "train": ["f"]}.items():
        (root / "images" / split).mkdir(parents=True, exist_ok=True)
        (root / "annotations" / split).mkdir(parents=True, exist_ok=True)
        for name in names:
            Image.new("RGB", size, (90, 120, 200)).save(root / "images" / split / f"{name}.jpg")
            lines = []
            for x1, y1, x2, y2, mos in rows_xyxy:
                raw = (x1, y1, x2, y2) if order == "xyxy" else (y1, x1, y2, x2)
                lines.append(" ".join(str(v) for v in (*raw, mos)))
            (root / "annotations" / split / f"{name}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_prepare(tmp_path, monkeypatch, root, *extra):
    argv = ["prepare_gaicd", "--root", str(root), "--docs", str(tmp_path / "FORMAT.md"), "--debug-dir", str(tmp_path / "debug"),
            "--eval-set", str(tmp_path / "eval_set.json"), "--eval-input", str(tmp_path / "eval_input"), *extra]
    monkeypatch.setattr(sys, "argv", argv)
    return prepare_gaicd.main()


@pytest.mark.parametrize("order", ["xyxy", "yxyx"])
def test_prepare_discovers_order_and_converts(tmp_path, monkeypatch, order):
    root = tmp_path / "GAICD"
    build_fake_gaicd(root, order)
    assert run_prepare(tmp_path, monkeypatch, root, "--count", "4") == 0
    es = json.loads((tmp_path / "eval_set.json").read_text(encoding="utf-8"))
    assert es["coord_order"] == order and es["coords"] == "pixel" and es["mos_col"] == 4
    # 3 test images + 1 from val (test split first, then val)
    assert [i["split"] for i in es["images"]].count("test") == 3 and len(es["images"]) == 4
    first = es["images"][0]
    assert (first["w"], first["h"]) == (200, 100)
    # hand: (20,10,120,60) on 200x100 -> [.1,.1,.5,.5] with MOS 3.5
    assert first["crops"][0]["rect"] == pytest.approx([.1, .1, .5, .5]) and first["crops"][0]["mos"] == 3.5
    # hand: (100,50,190,95) -> [.5,.5,.45,.45]
    assert first["crops"][1]["rect"] == pytest.approx([.5, .5, .45, .45])
    assert (tmp_path / "eval_input" / first["image"]).exists()
    assert list((tmp_path / "debug").glob("gaicd_check_*.jpg"))
    assert "Thứ tự cột dùng" in (tmp_path / "FORMAT.md").read_text(encoding="utf-8")


def test_prepare_selection_is_seeded_and_reproducible(tmp_path, monkeypatch):
    root = tmp_path / "GAICD"
    build_fake_gaicd(root, "xyxy")
    run_prepare(tmp_path, monkeypatch, root, "--count", "2")
    first = json.loads((tmp_path / "eval_set.json").read_text(encoding="utf-8"))["images"]
    run_prepare(tmp_path, monkeypatch, root, "--count", "2")
    second = json.loads((tmp_path / "eval_set.json").read_text(encoding="utf-8"))["images"]
    assert [i["image"] for i in first] == [i["image"] for i in second]
    assert all(i["split"] == "test" for i in first)


def test_prepare_refuses_ambiguous_order(tmp_path, monkeypatch):
    root = tmp_path / "GAICD"
    build_fake_gaicd(root, "xyxy", square=True)   # square images: xyxy and yxyx both fit
    assert run_prepare(tmp_path, monkeypatch, root, "--count", "2") == 2
    assert not (tmp_path / "eval_set.json").exists()
    assert "mơ hồ" in (tmp_path / "FORMAT.md").read_text(encoding="utf-8")
    assert list((tmp_path / "debug").glob("ambiguous_*.jpg"))
    # explicit --order resolves it
    assert run_prepare(tmp_path, monkeypatch, root, "--count", "2", "--order", "xyxy") == 0


def test_prepare_excludes_rotated_exif_images(tmp_path, monkeypatch):
    root = tmp_path / "GAICD"
    build_fake_gaicd(root, "xyxy")
    path = root / "images" / "test" / "a.jpg"
    im = Image.open(path)
    exif = im.getexif()
    exif[0x0112] = 6
    im.save(path, exif=exif)
    assert run_prepare(tmp_path, monkeypatch, root, "--count", "2") == 0
    names = [i["image"] for i in json.loads((tmp_path / "eval_set.json").read_text(encoding="utf-8"))["images"]]
    assert "a.jpg" not in names


def test_prepare_missing_root_reports_not_found(tmp_path, monkeypatch, capsys):
    assert run_prepare(tmp_path, monkeypatch, tmp_path / "nope") == 2
    assert "KHÔNG TÌM THẤY" in capsys.readouterr().err
