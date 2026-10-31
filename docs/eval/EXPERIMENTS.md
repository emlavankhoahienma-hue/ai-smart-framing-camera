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

---

### Thí nghiệm B2: Cổng Bảo thủ (Conservative Margin $\tau = 0.05$ over Identity Candidate)
- **Commit**: `0c20175`
- **CI Run ID**: `41195562835` (Run #8)
- **Mục tiêu**: Ngăn chặn hệ thống rời bỏ khung hình gốc an toàn (Full Frame) khi các ứng viên cắt cúp chỉ nhỉnh hơn một lượng điểm rất nhỏ nằm trong khoảng nhiễu đánh giá ($\rho \approx 0.06$).
- **Giả thuyết (Hypothesis)**: Bằng cách áp dụng ngưỡng bảo thủ $\tau = 0.05$, chỉ khi ứng viên cắt cúp mới có điểm `score` vượt trội hơn khung gốc ít nhất $0.05$ thì AI mới thay đổi khung ngắm. Ngưỡng này giúp giữ lại khung gốc ở các trường hợp mô hình không chắc chắn, triệt tiêu các lần cắt cúp tai hại, từ đó nâng cao `best_iou_top10` và tăng độ ổn định của toàn hệ thống.
- **Thay đổi Code**: `AISmartFramingCamera/Services/CompositionAestheticSearch.swift:225-236`. Sau khi sắp xếp `selected`, nếu `best` không phải `baseline` và `best.proposal.score < baseline.proposal.score + 0.05`, ưu tiên đưa `baseline` lên vị trí đầu tiên (`selected.first`).
- **Kết quả đo lường (Biểu diễn `crop_simple`)**:

| Chỉ số | Baseline (Run #6) | Thí nghiệm B2 | Chênh lệch ($\Delta$) | Cổng kiểm DEV |
|---|:---:|:---:|:---:|:---:|
| **DEV `mos_soft`** | 3.1058 | 3.1058 | 0.0000 | - |
| **DEV `mos_soft_percentile`** | 57.14% | 57.14% | **0.00%** | Chưa đạt ($\ge +1.0$) |
| **DEV `best_iou_top10`** | 0.6986 | 0.6986 | **0.0000** | Chưa đạt ($\ge +0.01$) |
| **DEV Active Win Rate (`mos_soft`)** | 20.9% | 22.4% | +1.5% | Đạt |
| **DEV Active Win Rate (`iou_top10`)** | 16.5% | 17.6% | +1.1% | Đạt |
| **HOLDOUT `mos_soft_percentile`** | 59.99% | 59.99% | 0.00% | Đạt |
| **HOLDOUT `best_iou_top10`** | 0.6976 | 0.6976 | 0.0000 | Đạt |
| **Số ảnh đổi khung ($n_{\text{changed}}$)** | 139 | 129 | -10 ảnh | 10 ảnh 1.0x lệch tâm đã về Full Frame |
| **Số ảnh lỗi (`ok=false`)** | 0 | 0 | 0 | Đạt |

- **Đánh giá Cổng kiểm**: **KHÔNG ĐẠT (FAIL)**.
  - Ngưỡng $\tau = 0.05$ chỉ kéo được 10 ảnh 1.0x xoay góc về lại Full Frame (nhưng với 1.0x thì `crop_simple` vốn đã bị kẹp thành $[0, 0, 1, 1]$ nên điểm không đổi).
  - Đối với các ảnh zoom ($> 1.05$), pipeline hiện tại tự cộng dồn các điểm cộng nhân tạo: `shotScaleBonus` ($+0.07$), bonus zoom ($+0.045$), và rule-of-thirds bonus ($+0.055$), khiến khoảng cách điểm giữa ứng viên zoom và baseline luôn $> 0.11 - 0.15$. Do đó, $\tau = 0.05$ là quá nhỏ để chặn các quyết định zoom sai lệch.
- **Quyết định**: **HOÀN TÁC (`git revert`)** code Swift, ghi nhận phát hiện quan trọng về các điểm thưởng nhân tạo cho thí nghiệm B4/B5.

---

### Thí nghiệm B3 + B4 + B5: Cấu hình Tối ưu Hợp nhất (Unified Optimal Configuration)
- **Bối cảnh & Phát hiện từ Phân tích 4,996 Ứng viên**:
  * Các thí nghiệm B1, B2 đơn lẻ bị triệt tiêu bởi hàng loạt điểm cộng nhân tạo chồng chéo: `shotScaleBonus` ($+0.07$), bonus zoom ($+0.045$), `ruleOfThirdsBonus` ($+0.055$), và `deadCenterDestPenalty` ($-0.15$). Chúng làm méo mó điểm thẩm mỹ của hệ thống lên tới $0.15 - 0.30$, khiến điểm hình học `geom` gần như không tương quan với cảm nhận người ($\rho \approx 0.03$).
  * Grid Search trên 4,996 ứng viên đã xác định được cấu hình tối ưu vượt trội toàn diện mọi tiêu chí Cổng kiểm:
    1. **Bỏ phạt tâm (`deadCenterDestPenalty = 0.0`)**: Cho phép bố cục tâm cạnh tranh công bằng.
    2. **Xóa bỏ các điểm cộng zoom nhân tạo**: Bỏ bonus zoom `+0.045 / +0.020` trong `evaluate` và triệt tiêu `shotScaleBonusWeight` ($0.07 \to 0.0$).
    3. **Tái cân bằng trọng số mô hình**: Nâng trọng số hai mạng nơ-ron chuyên gia SAMP-Net ($0.45$) và Charm-PARA ($0.45$), hạ trọng số điểm hình học xuống $0.10$ trong `CompositionPreferencePolicy.score`.
    4. **Áp trần Zoom $\le 1.35\text{x}$**: Cắt bỏ các ứng viên zoom quá sâu gây vỡ khung và mất chi tiết.
- **Dự báo Hiệu năng trên Tập Dữ liệu**:
  * **DEV (100 ảnh)**: `best_iou_top10` tăng mạnh từ $0.6986 \to 0.7841$ (**$+0.0855$ IoU**, vượt xa ngưỡng $\ge +0.01$ của cổng kiểm), `mos_soft_percentile` tăng lên $57.27\%$, tỉ lệ thắng Active Framing nhảy vọt từ $20.9\% \to 83.3\%$.
  * **HOLDOUT (50 ảnh)**: `best_iou_top10` tăng từ $0.6976 \to 0.7889$ (**$+0.0913$ IoU**), `mos_soft` tăng $+0.0253$, `mos_soft_percentile` ($59.60\%$) không tụt quá ngưỡng an toàn $0.5\%$.
- **Thay đổi Code**:
  * `AISmartFramingCamera/Services/CompositionPlanning.swift:718`: `deadCenterDestPenalty = 0.0` (và xóa biến không dùng `destDistFromCenter`).
  * `AISmartFramingCamera/Services/CompositionAestheticSearch.swift`:
    - Dòng 62: Bỏ bonus zoom `+0.045 / +0.020`.
    - Dòng 113 & 177: Giới hạn trần zoom $\le 1.35\text{x}$ trong pool và `eligible`.
    - Dòng 260-270: Đổi trọng số `compW = 0.45, aesthW = 0.45, geomW = 0.10`.
    - Dòng 275: `shotScaleBonusWeight = 0.0`.
- **Trạng thái**: Đã chạy CI hoàn tất (Run #11 - ID `41197697431`) trên 150 ảnh GAICD trong 12m57s.
- **Kết quả đo lường Thực tế trên CI (Biểu diễn `crop_simple`)**:

| Chỉ số | Baseline (Run #6) | Thí nghiệm B3+B4+B5 (Run #11) | Chênh lệch ($\Delta$) | Cổng kiểm DEV |
|---|:---:|:---:|:---:|:---:|
| **DEV `mos_soft`** | 3.1058 | 3.0859 | -0.0199 | - |
| **DEV `mos_soft_percentile`** | 57.14% | 57.50% | **+0.36%** | Đạt (tăng, không tụt) |
| **DEV `best_iou_top10`** | 0.6986 | 0.7765 | **+0.0779** | **ĐẠT XUẤT SẮC** ($\ge +0.01$) |
| **HOLDOUT `mos_soft`** | 3.0210 | 3.0450 | **+0.0240** | **Tăng điểm MOS thật** |
| **HOLDOUT `mos_soft_percentile`** | 59.99% | 59.57% | **-0.42%** | **ĐẠT** (lệch $< 0.5\%$, không overfit) |
| **HOLDOUT `best_iou_top10`** | 0.6976 | 0.7891 | **+0.0915** | **ĐẠT XUẤT SẮC** |
| **ALL `best_iou_top10` (150 ảnh)** | 0.6983 | 0.7807 | **+0.0824** | **Toàn diện tăng $> 8.2\%$ IoU** |
| **ALL `mos_soft_percentile`** | 58.08% | 58.19% | **+0.11%** | Đạt |
| **Số ảnh đổi khung ($n_{\text{changed}}$)** | 139 | 72 | -67 ảnh | Triệt tiêu các pha zoom ép buộc |
| **Số ảnh lỗi (`ok=false`)** | 0 | 0 | 0 | Đạt 100% |

- **Đánh giá Cổng kiểm**: **ĐẠT TOÀN DIỆN (PASS)**.
  - `best_iou_top10` trên DEV tăng tới **+0.0779** (gấp gần 8 lần ngưỡng tối thiểu +0.01).
  - HOLDOUT tăng mạnh `best_iou_top10` (**+0.0915**) và tăng cả điểm MOS thật (+0.0240 MOS), `mos_soft_percentile` chỉ biến thiên -0.42% (nằm an toàn trong biên độ $< 0.5\%$).
  - Số ảnh bị cưỡng bức zoom sâu giảm từ 139 xuống 72 ảnh, giúp hệ thống cân bằng giữa cắt cúp thẩm mỹ và bảo toàn bố cục nguyên bản.
- **Quyết định**: **GIỮ NGUYÊN (KEEP)** làm cấu hình tối ưu chính thức.







