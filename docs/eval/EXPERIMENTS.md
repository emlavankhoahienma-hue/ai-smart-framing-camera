# Nhật ký Thí nghiệm Tối ưu Pipeline AI Target & Zoom (Phase B)

Tài liệu này ghi nhận toàn bộ quá trình thử nghiệm tuần tự, đánh giá định lượng trên 150 ảnh GAICD (chia 100 DEV / 50 HOLDOUT, `seed=42`) và quyết định giữ/hoàn tác theo CỔNG KIỂM.

---

## 1. Quy tắc Cổng kiểm (Gate Rules - DEV & HOLDOUT)

Mỗi thí nghiệm được kiểm tra độc lập theo quy tắc:
1. **Cổng kiểm DEV (100 ảnh)**:
   - **ĐẠT (GIỮ)** nếu:
     * `mos_soft_percentile` tăng $\ge +1.0$ điểm phần trăm **HOẶC** `best_iou_top10` tăng $\ge +0.01$.
     * **VÀ** không có thước đo nào tụt quá $0.5$ điểm phần vị / $0.005$ IoU.
     * **VÀ** tỉ lệ thắng active framing không tụt quá $2.0\%$.
     * **VÀ** số ảnh lỗi (`ok=false`) không tăng.
2. **Kiểm tra HOLDOUT (50 ảnh)**:
   - Nếu điểm HOLDOUT tụt quá $0.5$ điểm phần vị, coi là hiện tượng quá khớp (overfitting) và **BẮT BUỘC HOÀN TÁC (`git revert`)** ngay cả khi DEV tăng.
3. **Quy tắc dừng sớm**:
   - Nếu 3 thí nghiệm liên tiếp thất bại cổng kiểm.
   - Hoặc tổng số lần chạy CI vượt quá 15 lần.

---

## 2. Kết quả Baseline (Run #6 - commit `6cff955`)

Biểu diễn chuẩn: `crop_simple` (trọng tâm 4 góc, kích thước $1/\text{zoom}$, dịch vào trong biên).

| Tập dữ liệu | `mos_soft` | `mos_soft_percentile` | `best_iou_top10` | Active Framing Win Rate (`mos_soft`) | Active Framing Win Rate (`iou_top10`) | Số ảnh đổi khung ($n$) | Ảnh lỗi (`ok=false`) |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **DEV (100 ảnh)** | 3.1058 | **57.14%** | **0.6986** | 20.9% (19/91) | 16.5% (15/91) | 91 | 0 |
| **HOLDOUT (50 ảnh)** | 3.0210 | **59.99%** | **0.6976** | 22.9% (11/48) | 14.6% (7/48) | 48 | 0 |
| **ALL (150 ảnh)** | 3.0777 | **58.08%** | **0.6983** | 21.6% (30/139) | 15.8% (22/139) | 139 | 0 |

---

## 3. Nhật ký Thí nghiệm Chi tiết

### Thí nghiệm B1: Khóa Roll (Constrained Yaw-Pitch Rotation via Swing-Twist Decomposition)
- **Mục tiêu**: Triệt tiêu góc quay tự do quanh trục quang học Z (in-plane roll) khi dịch chuyển tâm bố cục.
- **Giả thuyết (Hypothesis)**: `simd_quatd(from: u, to: v)` giữa hai tia thiết bị sinh ra thành phần $Z$ khác 0 khiến khung ngắm bị nghiêng từ $10^\circ - 18^\circ$ trên 92% số ảnh. Việc triệt tiêu roll qua phân rã Swing-Twist (ép trục Z về 0, chỉ xoay Yaw + Pitch) sẽ giữ khung hình song song trục ảnh, giảm mạnh `is_rotated`, giảm diện tích bao giả tạo và cải thiện IoU / MOS soft với GAICD.
- **Thay đổi Code**: `AISmartFramingCamera/Services/CompositionPlanning.swift:641-651`. Tách `rawRotation` thành `swing` (yaw-pitch) và `twist` (roll), dùng `rotation = simd_normalize(rawRotation * twistInv)`.
- **Trạng thái**: Đang chạy CI 150 ảnh.

