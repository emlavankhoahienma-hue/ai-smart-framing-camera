"""Discover the REAL structure of data/GAICD/, document it, and build the 150-image eval set.

Nothing about the annotation layout is assumed: the script inspects files, tests which
coordinate-column order is consistent with the image sizes, and refuses to continue when the
data is ambiguous or unsupported (use --order / --mos-col to resolve, after looking at debug/).

Usage (Windows):  .venv\\Scripts\\python.exe tools\\eval\\prepare_gaicd.py [--root data/GAICD]
Outputs: docs/eval/GAICD_FORMAT.md, debug/*.jpg, eval_set.json, eval_input/ (git-ignored).
"""
from __future__ import annotations

import argparse
import json
import random
import shutil
import sys
from collections import Counter
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalcore import px_corners_to_norm  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
IMAGE_EXT = {".jpg", ".jpeg", ".png"}
SPLITS = ("train", "val", "test")
SEED = 42
COUNT = 150
# Candidate orders for the first four columns. Each maps raw (a, b, c, d) -> (x1, y1, x2, y2).
ORDERS = {
    "xyxy": lambda a, b, c, d: (a, b, c, d),
    "yxyx": lambda a, b, c, d: (b, a, d, c),
    "xywh": lambda a, b, c, d: (a, b, a + c, b + d),
    "yxhw": lambda a, b, c, d: (b, a, b + d, a + c),
}


def split_of(path: Path, root: Path) -> str | None:
    for part in path.relative_to(root).parts[:-1]:
        low = part.lower()
        if low in SPLITS:
            return low
        if low == "validation":
            return "val"
    return None


def read_rows(path: Path) -> list[list[float]] | None:
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip().replace(",", " ")
        if not line:
            continue
        try:
            rows.append([float(tok) for tok in line.split()])
        except ValueError:
            return None
    return rows


def consistent(order: str, rows: list[list[float]], width: int, height: int, normalised: bool) -> bool:
    for row in rows:
        a, b, c, d = row[:4]
        x1, y1, x2, y2 = ORDERS[order](a, b, c, d)
        mw, mh = (1.0, 1.0) if normalised else (width, height)
        if not (0 <= x1 < x2 <= mw + 1e-6 and 0 <= y1 < y2 <= mh + 1e-6):
            return False
    return True


def exif_orientation(image: Image.Image) -> int | None:
    try:
        return image.getexif().get(0x0112)
    except Exception:
        return None


def draw_crops(src: Path, boxes: list[tuple[tuple[float, float, float, float], float]], out: Path, colors: list[str]) -> None:
    with Image.open(src) as im:
        canvas = im.convert("RGB")
    draw = ImageDraw.Draw(canvas)
    line = max(2, canvas.width // 200)
    for ((x1, y1, x2, y2), mos), color in zip(boxes, colors):
        draw.rectangle([x1, y1, x2, y2], outline=color, width=line)
        draw.text((x1 + 4, y1 + 4), f"MOS {mos:.3f}", fill=color)
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, quality=90)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=REPO / "data" / "GAICD")
    ap.add_argument("--order", choices=sorted(ORDERS), help="force coordinate-column order (after checking debug/)")
    ap.add_argument("--mos-col", type=int, help="0-based MOS column index (default: last column)")
    ap.add_argument("--docs", type=Path, default=REPO / "docs" / "eval" / "GAICD_FORMAT.md")
    ap.add_argument("--debug-dir", type=Path, default=REPO / "debug")
    ap.add_argument("--eval-set", type=Path, default=REPO / "eval_set.json")
    ap.add_argument("--eval-input", type=Path, default=REPO / "eval_input")
    ap.add_argument("--count", type=int, default=COUNT)
    args = ap.parse_args()

    root = args.root
    if not root.is_dir():
        print(f"KHÔNG TÌM THẤY thư mục {root}. Giải nén GAICD vào đó rồi chạy lại.", file=sys.stderr)
        return 2

    files = [p for p in root.rglob("*") if p.is_file()]
    ext_count = Counter(p.suffix.lower() for p in files)
    images = {}
    for p in files:
        if p.suffix.lower() in IMAGE_EXT:
            images.setdefault((split_of(p, root), p.stem), []).append(p)
    txts = {}
    for p in files:
        if p.suffix.lower() == ".txt":
            txts.setdefault((split_of(p, root), p.stem), []).append(p)
    report = ["# GAICD_FORMAT (auto-discovered by tools/eval/prepare_gaicd.py)", "",
              f"Root: `{root}`", "", "## Cây thư mục / đuôi file", "",
              "| đuôi | số file |", "|---|---|", *[f"| `{e or '(none)'}` | {n} |" for e, n in sorted(ext_count.items())], ""]
    top_dirs = sorted({p.relative_to(root).parts[0] for p in files if len(p.relative_to(root).parts) > 1})
    report += ["Thư mục cấp 1: " + (", ".join(f"`{d}`" for d in top_dirs) or "(không có)"), ""]
    split_counts = Counter(k[0] for k in images)
    report += ["Số ảnh theo split (suy từ tên thư mục): " + ", ".join(f"{k}={v}" for k, v in sorted(split_counts.items(), key=str)), ""]

    paired = {}
    for k, imgs in images.items():
        split, stem = k
        if k in txts:
            paired[k] = (imgs[0], txts[k][0])
        elif (None, stem) in txts:
            paired[k] = (imgs[0], txts[(None, stem)][0])
    if not paired:
        report += ["## KẾT LUẬN", "", "Không ghép được ảnh với file annotation `.txt` cùng tên (cùng split). "
                   "Cấu trúc này chưa được hỗ trợ — KHÔNG đoán. Các file mẫu:", ""]
        report += [f"- `{p.relative_to(root)}`" for p in files[:15]]
        args.docs.parent.mkdir(parents=True, exist_ok=True)
        args.docs.write_text("\n".join(report) + "\n", encoding="utf-8")
        print("Không ghép được ảnh↔annotation; xem", args.docs, file=sys.stderr)
        return 2

    sample_keys = sorted(paired, key=lambda k: (str(k[0]), k[1]))
    report += [f"Ảnh ghép được với annotation `.txt` cùng tên: {len(paired)} / {len(images)} ảnh.", ""]
    sample_key = sample_keys[0]
    sample_rows_raw = paired[sample_key][1].read_text(encoding="utf-8", errors="replace").splitlines()[:5]
    report += [f"Ví dụ `{paired[sample_key][1].relative_to(root)}` (5 dòng đầu, nguyên văn):", "", "```", *sample_rows_raw, "```", ""]

    data: dict = {}
    col_counts: Counter = Counter()
    unreadable = []
    max_val = 0.0
    for key in sample_keys:
        img_path, txt_path = paired[key]
        rows = read_rows(txt_path)
        if not rows:
            unreadable.append(str(txt_path.relative_to(root)))
            continue
        for r in rows:
            col_counts[len(r)] += 1
            max_val = max(max_val, max(r[:4]))
        with Image.open(img_path) as im:
            data[key] = {"img": img_path, "w": im.width, "h": im.height, "orient": exif_orientation(im), "rows": rows}
    report += [f"Số cột mỗi dòng: " + ", ".join(f"{c} cột × {n} dòng" for c, n in sorted(col_counts.items())), ""]
    if unreadable:
        report += [f"File annotation không đọc được dạng số: {len(unreadable)} (vd `{unreadable[0]}`).", ""]
    normalised = max_val <= 1.0
    report += [f"Giá trị tọa độ lớn nhất ở 4 cột đầu = {max_val:g} → hệ tọa độ: **{'chuẩn hóa 0..1' if normalised else 'pixel'}**.", ""]

    if len(col_counts) != 1 or next(iter(col_counts)) < 5:
        report += ["## KẾT LUẬN", "", "Số cột không đồng nhất hoặc < 5 (4 tọa độ + MOS). Cần xem tay. DỪNG.", ""]
        args.docs.parent.mkdir(parents=True, exist_ok=True)
        args.docs.write_text("\n".join(report) + "\n", encoding="utf-8")
        print("Cấu trúc cột bất thường; xem", args.docs, file=sys.stderr)
        return 2
    ncol = next(iter(col_counts))
    mos_col = args.mos_col if args.mos_col is not None else ncol - 1
    report += [f"Cột MOS dùng: chỉ số {mos_col} (0-based){' (mặc định = cột cuối)' if args.mos_col is None else ' (chỉ định bằng --mos-col)'}.", ""]
    if ncol > 5 and args.mos_col is None:
        report += ["Có > 5 cột và chưa chỉ định `--mos-col`. DỪNG.", ""]
        args.docs.write_text("\n".join(report) + "\n", encoding="utf-8")
        print("Nhiều hơn 5 cột; chỉ định --mos-col", file=sys.stderr)
        return 2

    report += ["## Thử các thứ tự cột tọa độ (tỉ lệ dòng hợp lệ trong biên ảnh thật)", "", "| order | ý nghĩa 4 cột đầu | ảnh hợp lệ toàn bộ |", "|---|---|---|"]
    meaning = {"xyxy": "x1 y1 x2 y2", "yxyx": "y1 x1 y2 x2", "xywh": "x y w h", "yxhw": "y x h w"}
    valid_orders = []
    for order in ORDERS:
        ok_imgs = sum(consistent(order, d["rows"], d["w"], d["h"], normalised) for d in data.values())
        full = ok_imgs == len(data)
        report.append(f"| `{order}` | {meaning[order]} | {ok_imgs}/{len(data)}{' ✔' if full else ''} |")
        if full:
            valid_orders.append(order)
    report.append("")
    order = args.order
    if order is None:
        if len(valid_orders) == 1:
            order = valid_orders[0]
        else:
            report += ["## KẾT LUẬN", "", f"Thứ tự cột {'KHÔNG xác định được' if not valid_orders else 'mơ hồ'}: hợp lệ = {valid_orders or 'không có'}. "
                       "Đã vẽ crop debug cho từng ứng viên; xem `debug/` rồi chạy lại với `--order`. DỪNG.", ""]
            args.docs.parent.mkdir(parents=True, exist_ok=True)
            args.docs.write_text("\n".join(report) + "\n", encoding="utf-8")
            first = data[sample_keys[0]]
            for cand in (valid_orders or list(ORDERS)):
                pts = []
                for row in sorted(first["rows"], key=lambda r: r[mos_col])[-1:] + sorted(first["rows"], key=lambda r: r[mos_col])[:1]:
                    x1, y1, x2, y2 = ORDERS[cand](*row[:4])
                    k = (first["w"], first["h"]) if not normalised else (1, 1)
                    s = (first["w"], first["h"]) if normalised else (1, 1)
                    pts.append(((x1 / k[0] * s[0], y1 / k[1] * s[1], x2 / k[0] * s[0], y2 / k[1] * s[1]), row[mos_col]))
                draw_crops(first["img"], pts, args.debug_dir / f"ambiguous_{cand}_{first['img'].stem}.jpg", ["lime", "red"])
            print("Thứ tự cột mơ hồ/không xác định; xem", args.docs, file=sys.stderr)
            return 2
    report += [f"Thứ tự cột dùng: **`{order}`** ({meaning[order]}){' (chỉ định bằng --order)' if args.order else ' (duy nhất hợp lệ với mọi ảnh)'}.", ""]

    def crops(entry: dict) -> list[dict]:
        out = []
        for row in entry["rows"]:
            mos = row[mos_col]
            if mos < 0 or mos == -2.0:
                continue
            x1, y1, x2, y2 = ORDERS[order](*row[:4])
            if normalised:
                rect = [x1, y1, x2 - x1, y2 - y1]
            else:
                rect = px_corners_to_norm(x1, y1, x2, y2, entry["w"], entry["h"])
            out.append({"rect": rect, "mos": mos})
        return out

    raw_mos = [r[mos_col] for d in data.values() for r in d["rows"]]
    neg_mos = [m for m in raw_mos if m < 0]
    valid_mos = [m for m in raw_mos if m >= 0]
    per_img_valid = [len(crops(d)) for d in data.values()]
    report += [
        f"### Thống kê điểm MOS và xử lý giá trị placeholder -2.0", "",
        f"- Tổng số dòng annotation: {len(raw_mos)} dòng trên {len(data)} ảnh.",
        f"- Số crop mang điểm MOS = -2.0 (placeholder/invalid): **{len(neg_mos)} crop ({len(neg_mos)/len(raw_mos)*100:.2f}%)** trên {sum(any(r[mos_col] < 0 for r in d['rows']) for d in data.values())} ảnh.",
        f"- **Ý nghĩa của -2.0 theo mã nguồn GAICD gốc**: Theo mã nguồn PyTorch chính thức của tác giả Hui Zeng (`HuiZeng/Grid-Anchor-based-Image-Cropping-Pytorch/croppingDataset.py:78`), dòng annotation có `float(annotation_split[4]) == -2` đại diện cho các anchor dạng lưới không hợp lệ (tỷ lệ khung hình quá lệch hoặc bị loại trong quá trình tạo grid-anchor). Tác giả chính thức loại bỏ chúng bằng lệnh `if float(annotation_split[4]) != -2:`.",
        f"- **Xử lý**: Đã loại bỏ hoàn toàn {len(neg_mos)} crop mang điểm -2.0. Số crop hợp lệ còn lại: **{len(valid_mos)} crop**.",
        f"- Thống kê trên các crop hợp lệ: min={min(valid_mos):.4f}, max={max(valid_mos):.4f}, mean={sum(valid_mos)/len(valid_mos):.4f} (chuẩn thang đo 1.0 đến 5.0).",
        f"- Số crop hợp lệ mỗi ảnh: min={min(per_img_valid)}, max={max(per_img_valid)}, mean={sum(per_img_valid)/len(per_img_valid):.1f}.", ""
    ]
    orient_count = Counter(d["orient"] for d in data.values())
    report += ["EXIF Orientation của ảnh: " + ", ".join(f"{k}: {v}" for k, v in sorted(orient_count.items(), key=str)) +
               ". Ảnh có Orientation khác 1/None bị loại khỏi eval set (toạ độ annotation theo lưới pixel lưu trữ, "
               "tránh nhập nhằng sau khi xoay EXIF).", ""]

    # Debug rendering: 3 highest- and 3 lowest-MOS crops on a few images.
    debug_keys = [k for k in sample_keys if k[0] == "test"][:2] or sample_keys[:2]
    debug_keys += [k for k in sample_keys if k not in debug_keys][:2]
    for key in debug_keys:
        d = data[key]
        ranked = sorted(crops(d), key=lambda c: c["mos"])
        chosen = ranked[-3:][::-1] + ranked[:3]
        boxes = [(tuple(v * s for v, s in zip((c["rect"][0], c["rect"][1], c["rect"][0] + c["rect"][2], c["rect"][1] + c["rect"][3]), (d["w"], d["h"], d["w"], d["h"]))), c["mos"]) for c in chosen]
        draw_crops(d["img"], boxes, args.debug_dir / f"gaicd_check_{key[0]}_{key[1]}.jpg", ["lime"] * 3 + ["red"] * 3)
    report += [f"Đã vẽ 3 crop MOS cao nhất (xanh lá) và 3 thấp nhất (đỏ) cho {len(debug_keys)} ảnh vào `debug/gaicd_check_*.jpg`. "
               "**Hãy mở xem để xác nhận** thứ tự cột và hệ tọa độ trước khi tin eval_set.json.", ""]

    # Selection: test split first, then val if short.
    def usable(k: tuple) -> bool:
        return data[k]["orient"] in (None, 1)
    pool_test = [k for k in sample_keys if k[0] == "test" and k in data and usable(k)]
    pool_val = [k for k in sample_keys if k[0] == "val" and k in data and usable(k)]
    rng = random.Random(SEED)
    chosen_keys = rng.sample(pool_test, min(args.count, len(pool_test)))
    used = ["test"]
    if len(chosen_keys) < args.count:
        need = args.count - len(chosen_keys)
        chosen_keys += rng.sample(pool_val, min(need, len(pool_val)))
        used.append("val")
    if len(chosen_keys) < args.count:
        report += [f"## CẢNH BÁO", "", f"Chỉ có {len(chosen_keys)} ảnh dùng được (<{args.count}) từ test+val.", ""]
    report += [f"## Chọn tập eval", "", f"seed={SEED}; nguồn: {', '.join(used)} (test: {len(pool_test)} dùng được, val: {len(pool_val)}). "
               "GAICD không có nhãn loại cảnh nên KHÔNG cân bằng theo cảnh; chỉ lấy ngẫu nhiên cố định. "
               f"Đã chọn {len(chosen_keys)} ảnh.", ""]

    if args.eval_input.exists():
        shutil.rmtree(args.eval_input)
    args.eval_input.mkdir(parents=True)
    items = []
    for key in sorted(chosen_keys, key=lambda k: (str(k[0]), k[1])):
        d = data[key]
        dest_name = f"{key[0]}_{d['img'].name}" if len({k[1] for k in chosen_keys}) != len(chosen_keys) else d["img"].name
        shutil.copyfile(d["img"], args.eval_input / dest_name)
        items.append({"image": dest_name, "split": key[0], "w": d["w"], "h": d["h"], "exif_orientation": d["orient"],
                      "source": str(d["img"].relative_to(root)).replace("\\", "/"), "crops": crops(d)})
    args.eval_set.write_text(json.dumps({"seed": SEED, "dataset": "GAICD", "coord_order": order, "coords": "normalised" if normalised else "pixel",
                                          "mos_col": mos_col, "rect_format": "[x,y,w,h] normalised 0..1 top-left", "images": items}, indent=1), encoding="utf-8")
    report += [f"Đã ghi `eval_set.json` ({len(items)} ảnh) và copy ảnh vào `eval_input/` (đã nằm trong .gitignore; không commit ảnh Flickr).", ""]
    args.docs.parent.mkdir(parents=True, exist_ok=True)
    args.docs.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(f"OK: {len(items)} ảnh → {args.eval_set}; mô tả định dạng: {args.docs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
