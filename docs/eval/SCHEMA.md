# SCHEMA — `eval_results.json` (sinh bởi runner Swift trên CI) và `eval_set.json`

## Quy ước tọa độ
- Mọi tọa độ chuẩn hóa **0..1**, gốc **TRÁI-TRÊN**, trục `x` sang phải, trục `y` xuống dưới, theo kích thước ảnh **sau khi áp EXIF orientation** (`image_w`, `image_h`).
- Hình chữ nhật chuẩn hóa = `[x, y, w, h]` (trong đó `x, y` là tọa độ mép trái-trên, `w, h` là chiều rộng và chiều cao).
- Điểm chuẩn hóa = `[x, y]`.
- Mọi trường mà pipeline không có hoặc không công khai thì để `null`. **KHÔNG tự suy diễn bằng công thức mới.**

---

## 1. Cấu trúc `eval_results.json`
Một mảng JSON gồm các bản ghi cho từng ảnh:

| Trường | Kiểu | Nguồn trong Swift / Runner (`tests/CompositionModelValidation.swift`) | `null` khi |
|---|---|---|---|
| `image` | string | Tên file ảnh (vd: `test_0001.jpg`) | — |
| `image_w` | int | Chiều rộng pixel ảnh đọc được (`CGImage.width`) | Lỗi đọc file |
| `image_h` | int | Chiều cao pixel ảnh đọc được (`CGImage.height`) | Lỗi đọc file |
| `ok` | bool | `true` nếu pipeline nhận diện và chọn được phương án bố cục tốt nhất (`best`); `false` nếu lỗi | — |
| `error` | string/null | Thông báo lỗi khi `ok=false` (vd: `"no_subject"`, `"search_failed"`, lỗi đọc ảnh) | `ok=true` |
| `hero_subject_box` | [x,y,w,h] | `hero.boundingBox` / `best.proposal.subject.bounds` | `ok=false` |
| `scene_intent` | string | `best.proposal.intent.rawValue` (`CompositionPlanning.swift:531`) | `ok=false` |
| `target_P` | null | Biến nội bộ cục bộ trong `CompositionPlanning.swift`, chưa có getter công khai | Luôn `null` ở bản đầu |
| `zoom_current` | float | `1.0` (mức zoom ban đầu của ảnh tĩnh) | `ok=false` |
| `zoom_ideal` | null | Tính nội bộ trong `dynamicZooms`, chưa có getter công khai | Luôn `null` ở bản đầu |
| `zoom_final` | float | `Double(best.proposal.zoom)` | `ok=false` |
| `crop_rect` | [x,y,w,h] | **Xấp xỉ:** Hộp bao trục (AABB) của 4 góc `sourceCorners` kẹp vào `[0, 1]`. | `ok=false` hoặc không đủ 4 góc |
| `source_corners_raw` | [x0,y0,...] | Mảng 8 số thực biểu diễn 4 góc thô `[x0,y0, x1,y1, x2,y2, x3,y3]` của `best.proposal.sourceCorners` (chưa kẹp vào [0,1], có thể vượt biên theo margin 3D) | `ok=false` hoặc không đủ 4 góc |
| `is_rotated` | bool | Cờ đánh dấu khung ngắm có bị xoay 3D hay không: `true` nếu `max_edge_tilt_deg > 1.0` | `ok=false` hoặc không đủ 4 góc |
| `max_edge_tilt_deg` | float | Độ nghiêng lớn nhất (đơn vị độ, 0..45°) của 4 cạnh tứ giác so với các trục ngang/dọc | `ok=false` hoặc không đủ 4 góc |
| `scores.samp` | float/null | Điểm bố cục SAMP-Net: `best.assessment?.mean` | Thiếu model hoặc chưa chạy |
| `scores.charm` | float/null | Điểm thẩm mỹ Charm: `best.aesthetics?.mean` | Thiếu model hoặc ứng viên ngoài top Charm |
| `scores.geom` | float | Điểm hình học quy tắc: `best.geometryScore` | `ok=false` |
| `scores.final` | float | Điểm tổng hợp cuối cùng: `best.proposal.score` | `ok=false` |
| `num_candidates` | int | Số lượng ứng viên được đánh giá: `result.assessedCount` | `ok=false` |
| `timing_ms` | object | Thời gian chạy (ms): `{"detection": ..., "planning": ..., "scoring": ..., "total": ...}` | `ok=false` |
| `device` | string | Chuỗi định danh môi trường runner (vd: `"Version 15.0 (Build 24A335) x86_64 cpus=4"`) | — |
| `impl` | string | `"swift_ci_macos"` (pipeline Swift thật trên CI macOS). Dữ liệu giả dùng cho test: `"FAKE_FROM_ANNOTATION"` | — |

### Chi tiết về `crop_rect`, `source_corners_raw` và `is_rotated`:
1. **Bản chất của crop trong app**: Đề xuất bố cục của app là một tứ giác 4 góc `sourceCorners` chiếu từ camera 3D về mặt phẳng ảnh gốc. Tứ giác này có thể bị xoay góc nghiêng (roll/yaw) và có thể lồi ra ngoài biên ảnh gốc (tới margin −0.36 ở 1.0x).
2. **`crop_rect` là xấp xỉ**: Để so sánh được với tập dữ liệu GAICD (toàn bộ crop là hình chữ nhật đứng nằm trong ảnh), runner tính hộp bao trục AABB từ `sourceCorners` rồi kẹp (`clamp`) vào `[0, 1]`. Hộp bao này sẽ phình to hơn diện tích thực nếu khung bị xoay nhiều.
3. **Ngưỡng xoay `1.0°` (`is_rotated`)**:
   - Khi cạnh tứ giác nghiêng 1.0°, độ lệch theo phương vuông góc trên toàn bộ chiều rộng ảnh là khoảng $W \times \sin(1^\circ) \approx 1.75\% \times W$. Độ lệch này đã bắt đầu làm biến dạng hộp bao trục và làm giảm IoU so với crop thẳng đứng. Các góc nghiêng $< 1.0^\circ$ không phân biệt được với sai số làm tròn số thực.
   - Trường `max_edge_tilt_deg` lưu góc nghiêng thô chính xác để có thể phân tích lại offline với các ngưỡng khác nhau.

---

## 2. Cấu trúc `eval_set.json` (sinh bởi `prepare_gaicd.py`)
```json
{
  "seed": 42,
  "dataset": "GAICD",
  "coord_order": "xyxy",
  "coords": "pixel",
  "mos_col": 4,
  "rect_format": "[x,y,w,h] normalised 0..1 top-left",
  "images": [
    {
      "image": "test_0001.jpg",
      "split": "test",
      "w": 600,
      "h": 400,
      "exif_orientation": 1,
      "source": "images/test/0001.jpg",
      "crops": [
        {"rect": [0.1, 0.1, 0.6, 0.7], "mos": 4.125},
        {"rect": [0.0, 0.0, 1.0, 1.0], "mos": 2.500}
      ]
    }
  ]
}
```
*Lưu ý:* `prepare_gaicd.py` tự động loại các ảnh có EXIF Orientation khác 1 hoặc None để tránh sai lệch tọa độ sau khi xoay ảnh.

---

## 3. Các chỉ số chấm điểm (`score_results.py`)
- **`best_iou` (Chỉ số so sánh chính)**: IoU lớn nhất giữa crop của AI với crop có điểm MOS cao nhất của ảnh (nếu hòa điểm MOS cao nhất thì lấy IoU lớn nhất).
- **`best_iou_top10`**: IoU lớn nhất của crop AI với bất kỳ crop nào thuộc nhóm 10% MOS cao nhất của ảnh (`k = max(1, ceil(0.10 * n))`, tính cả các crop hòa điểm tại ngưỡng cắt).
- **`matched_iou`**: IoU lớn nhất giữa crop của AI với mọi crop có annotation MOS trong ảnh.
- **`matched_mos`**: Điểm MOS của crop khớp nhất (`matched_iou`). **CHỈ tính khi `matched_iou >= 0.80`**, nếu nhỏ hơn 0.80 thì đánh dấu `"unmatched"` (không nội suy điểm).
- **`mos_percentile`**: Phân vị phần trăm yếu (0..100) của `matched_mos`:
  $$\text{percentile} = 100 \times \frac{\#\{\text{crop có MOS} \le \text{matched\_mos}\}}{n}$$
  Crop có MOS cao nhất luôn đạt đúng `100.0`. Nếu `"unmatched"` thì giá trị là `null`.
- **Baseline so sánh**:
  - `full_frame`: Khung toàn ảnh `[0, 0, 1, 1]`.
  - `center_crop`: Crop ở chính giữa ảnh có cùng chiều rộng và chiều cao với crop của AI.
  - `random_crop`: 20 crop ngẫu nhiên có cùng kích thước với crop của AI (seed cố định theo từng ảnh), lấy trung bình các chỉ số.
- **Tỉ lệ thắng crop giữa**:
  - Tính theo `best_iou`: AI thắng khi `ai.best_iou > center_crop.best_iou`.
  - Tính theo `best_iou_top10`: AI thắng khi `ai.best_iou_top10 > center_crop.best_iou_top10`.
