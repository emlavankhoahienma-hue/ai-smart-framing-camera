# README — bộ đánh giá offline AI Target & Zoom (Windows 10)

Phạm vi hiện tại: **chỉ phần Python** (chuẩn bị GAICD + chấm điểm). Runner Swift trên macOS CI **chưa viết** (chờ duyệt `CI_AUDIT.md`).
Không tải model, không cài torch/transformers. Chỉ numpy, pillow, matplotlib, pytest.

## 1. Môi trường (đường dẫn Python không chuẩn → luôn dùng venv)
```powershell
cd C:\Users\admin\Downloads\taovideo\repo_smart_camera
C:\Users\admin\AppData\Local\Programs\Python\Python312\python.exe -m venv .venv
.\.venv\Scripts\python.exe -c "import sys; print(sys.executable)"
.\.venv\Scripts\python.exe -m pip install numpy pillow matplotlib pytest
```

## 2. Kiểm tra harness (bắt buộc trước khi tin số liệu)
```powershell
.\.venv\Scripts\python.exe -m pytest tools/eval/test_harness.py -q
```
Bao gồm IoU, chuyển tọa độ, matching (ngưỡng 0.80), percentile, và sanity "crop = crop MOS cao nhất → best_iou=1.0, mos_percentile=100". Dữ liệu trong test là **tổng hợp/giả**.

## 3. Chuẩn bị GAICD
Giải nén GAICD vào `data\GAICD\` (link ở README của HuiZeng/Grid-Anchor-based-Image-Cropping), rồi:
```powershell
.\.venv\Scripts\python.exe tools/eval/prepare_gaicd.py
```
Ghi `docs/eval/GAICD_FORMAT.md` (cấu trúc thật tự khám phá), `debug/gaicd_check_*.jpg` (3 crop MOS cao nhất = xanh lá, 3 thấp nhất = đỏ — **hãy mở xem**), `eval_set.json` (150 ảnh, seed 42, test rồi val), `eval_input/`.
Nếu thứ tự cột mơ hồ/cấu trúc lạ, script dừng (mã thoát 2) và ghi lý do; chạy lại với `--order xyxy|yxyx|xywh|yxhw` / `--mos-col N` sau khi xem `debug/`.
`eval_input/`, `data/`, `debug/` nằm trong `.gitignore` (ảnh Flickr không commit).

## 4. Chấm điểm một lần chạy
```powershell
.\.venv\Scripts\python.exe tools/eval/score_results.py --results eval_results.json --eval-set eval_set.json
```
Ra `eval_runs\<timestamp>_<git hash>\` gồm `report.md`, `report.csv`, `per_image.csv/json`, `summary.json`, `meta.json`, bản sao `eval_results.json`.

## 5. So sánh hai lần chạy / trực quan hóa
```powershell
.\.venv\Scripts\python.exe tools/eval/compare_runs.py eval_runs\<A> eval_runs\<B>
.\.venv\Scripts\python.exe tools/eval/visualize.py --results eval_results.json --eval-set eval_set.json --images eval_input --out debug/vis
```
Đỏ = crop AI, xanh lá = crop MOS cao nhất, vàng = hero box.

## 6. Thử harness bằng dữ liệu GIẢ (không phải kết quả AI)
```powershell
.\.venv\Scripts\python.exe tools/eval/make_fake_results.py --eval-set eval_set.json --mode best --out fake_results.json
.\.venv\Scripts\python.exe tools/eval/score_results.py --results fake_results.json --eval-set eval_set.json --label "FAKE DATA"
```
Mọi bản ghi giả mang `impl: "FAKE_FROM_ANNOTATION"`.

## 7. Phần Swift/CI
Chưa làm. Xem `CI_AUDIT.md` (kết luận + các câu hỏi cần trả lời) và `SCHEMA.md` (định dạng `eval_results.json` mà runner phải sinh).
