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
- **Commit**: `82468b5`
- **CI Run ID**: `41194400583` (Run #7)
- **Mục tiêu**: Triệt tiêu góc quay tự do quanh trục quang học Z (in-plane roll) khi dịch chuyển tâm bố cục.
- **Giả thuyết (Hypothesis)**: `simd_quatd(from: u, to: v)` giữa hai tia thiết bị sinh ra thành phần $Z$ khác 0 khiến khung ngắm bị nghiêng từ $10^\circ - 18^\circ$ trên 92% số ảnh. Việc triệt tiêu roll qua phân rã Swing-Twist (ép trục Z về 0, chỉ xoay Yaw + Pitch) sẽ giữ khung hình song song trục ảnh, giảm mạnh `is_rotated`, giảm diện tích bao giả tạo và cải thiện IoU / MOS soft với GAICD.
- **Thay đổi Code**: `AISmartFramingCamera/Services/CompositionPlanning.swift:641-651`. Tách `rawRotation` thành `swing` (yaw-pitch) và `twist` (roll), dùng `rotation = simd_normalize(rawRotation * twistInv)`.
- **Kết quả đo lường (Biểu diễn `crop_simple`)**:

| Chỉ số | Baseline (Run #6) | Thí nghiệm B1 | Chênh lệch ($\Delta$) | Cổng kiểm DEV |
|---|:---:|:---:|:---:|:---:|
| **DEV `mos_soft`** | 3.1058 | 3.0933 | -0.0125 | - |
| **DEV `mos_soft_percentile`** | 57.14% | 57.64% | **+0.50%** | Chưa đạt ($\ge +1.0$) |
| **DEV `best_iou_top10`** | 0.6986 | 0.7073 | **+0.0087** | Chưa đạt ($\ge +0.01$) |
| **DEV Active Win Rate (`mos_soft`)** | 20.9% | 28.4% | **+7.5%** | Đạt |
| **DEV Active Win Rate (`iou_top10`)** | 16.5% | 13.7% | **-2.8%** | **KHÔNG ĐẠT** (tụt > 2.0%) |
| **HOLDOUT `mos_soft_percentile`** | 59.99% | 60.31% | **+0.32%** | Đạt (không tụt > 0.5) |
| **HOLDOUT `best_iou_top10`** | 0.6976 | 0.7027 | **+0.0051** | Đạt |
| **Số ảnh `is_rotated` (ALL)** | 138 / 150 | 141 / 150 | +3 ảnh | Nghiêng phối cảnh 3D vẫn tồn tại |
| **Số ảnh lỗi (`ok=false`)** | 0 | 0 | 0 | Đạt |

- **Đánh giá Cổng kiểm**: **KHÔNG ĐẠT (FAIL)**.
  - Mặc dù `mos_soft_percentile` (+0.50%) và `best_iou_top10` (+0.0087) có tăng nhẹ, cả hai đều chưa vượt qua ngưỡng tối thiểu của cổng kiểm (+1.0 điểm % hoặc +0.01 IoU).
  - Tỉ lệ thắng active framing trên `best_iou_top10` bị sụt giảm từ 16.5% xuống 13.7% (-2.8%, vi phạm điều kiện không tụt quá 2.0%).
  - Nguyên nhân: Việc ép roll quanh trục Z về 0 chỉ triệt tiêu góc xoay trục Z thuần túy, nhưng phép chiếu phối cảnh 3D khi camera Yaw và Pitch vẫn tạo ra biến dạng hình thang (keystoning) trên mặt phẳng ảnh 2D, khiến `is_rotated` vẫn duy trì ở 141/150 ảnh với độ nghiêng mép trung bình 9.53°.
- **Quyết định**: **HOÀN TÁC (`git revert`)** code Swift, giữ nguyên nhật ký thí nghiệm.


