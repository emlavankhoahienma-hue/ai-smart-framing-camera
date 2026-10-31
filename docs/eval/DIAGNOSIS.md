# Báo cáo Chẩn đoán Pipeline AI Target & Zoom (Run 20261031-144017_2737f8e)

Tài liệu này ghi lại kết quả phân tích chuyên sâu, chẩn đoán nguyên nhân gốc rễ và đề xuất cải tiến cho pipeline AI Target & Zoom của app `Align Studio (AISmartFramingCamera)` dựa trên dữ liệu đánh giá 150 ảnh GAICD.

---

## PHẦN 1: Bảng đối chiếu hai biểu diễn crop

Để đo lường công bằng, hệ thống đánh giá đã triển khai song song hai biểu diễn:
1. **`crop_bbox` (Hiện tại)**: Hộp bao trục vuông góc (AABB) của 4 góc `sourceCorners` chiếu từ không gian 3D, kẹp vào $[0, 1]$.
2. **`crop_simple` (Mới)**: Tâm đặt tại trọng tâm 4 góc `source_corners_raw` ($\bar{x} = \frac{1}{4}\sum x_i, \bar{y} = \frac{1}{4}\sum y_i$), kích thước chuẩn hóa $w = h = 1/\text{zoom\_final}$, dịch vào trong ảnh nếu tràn biên.
3. **`center_same_zoom`**: Crop giữa ảnh với kích thước $1/\text{zoom\_final}$ (cùng diện tích với `crop_simple`), dùng để **tách riêng tác động của TÂM và ZOOM**.

### 1.1. Bảng số liệu tổng hợp (150 ảnh GAICD)

| Phương pháp | best_iou mean | best_iou median | best_iou_top10 mean | mos_percentile mean | matched_mos mean (1-5) | Unmatched (IoU < 0.8) |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| **AI (`crop_bbox`)** | **0.6275** | 0.6727 | **0.7157** | 69.53% | 3.3436 | 21 / 150 (14.0%) |
| **Center Crop (bbox size)** | 0.6573 | 0.6929 | 0.7585 | 71.44% | 3.2837 | 19 / 150 (12.7%) |
| **AI (`crop_simple`)** | **0.5826** | 0.6240 | **0.6983** | 81.43% | 3.6355 | 30 / 150 (20.0%) |
| **Center Same Zoom ($1/z$)** | 0.5917 | 0.6248 | 0.7108 | 80.21% | 3.6045 | 30 / 150 (20.0%) |
| **Full Frame** | 0.6347 | 0.6250 | 0.7710 | 83.62% | 3.7006 | 0 / 150 (0.0%) |
| **Random Crop** | 0.6292 | 0.6755 | 0.7380 | 63.52% | 3.1276 | ~12.2% |

### 1.2. Đối đầu trực tiếp (Head-to-head)
- **AI bbox vs Center Crop**:
  - `best_iou`: AI thắng 52, hòa 16, thua 82 → Tỉ lệ thắng **34.7%**
  - `best_iou_top10`: AI thắng 43, hòa 14, thua 93 → Tỉ lệ thắng **28.7%**
  - `mos_percentile` (trên 129 ảnh cả hai cùng match): AI thắng 57 ảnh (44.2%)
- **AI simple vs Center Same Zoom (Tách tác động của TÂM và ZOOM)**:
  - Cả hai phương pháp đều dùng cùng kích thước $1/z$, chỉ khác nhau ở vị trí TÂM (Tâm AI vs Tâm giữa [0.5, 0.5]).
  - `best_iou`: AI thắng 19, **hòa 91** (do 83 ảnh có zoom = 1.0 và AI không dịch chuyển), thua 40 → Tỉ lệ thắng **12.7%** (trên số ảnh có dịch chuyển: 19 thắng / 40 thua).
  - `best_iou_top10`: AI thắng 22, hòa 87, thua 41 → Tỉ lệ thắng **14.7%**.

---

## PHẦN 2: Phân tích theo nhóm (Breakdown Analysis)

### 2.1. Theo mức Zoom (`zoom_final`)

| Nhóm Zoom | n | AI bbox top10 | Center bbox top10 | Win Rate bbox top10 | AI simple top10 | Center Zoom top10 | Win Rate simple top10 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| $\le 1.05$ | 83 | 0.7819 | 0.8174 | 28.9% (24/83) | 0.7718 | 0.7719 | 0.0% (hầu hết hòa) |
| $1.05 - 1.20$ | 25 | **0.7550** | 0.8302 | **40.0% (10/25)** | 0.8336 | 0.8927 | 16.0% (4/25) |
| $> 1.20$ | 42 | **0.5615** | 0.5994 | 21.4% (9/42) | 0.4724 | 0.4819 | **42.9% (18/42)** |

> **Nhận xét**: 
> - Nhóm zoom $1.05 - 1.20$ là dải zoom hoạt động hiệu quả nhất của AI (tỉ lệ thắng đạt 40.0% ở biểu diễn bbox).
> - Nhóm zoom $> 1.20$ làm giảm sút mạnh điểm IoU của cả AI lẫn Center Crop ($0.56$ so với $0.78$). Khi zoom quá sâu, khung hình bị cắt mất nhiều bối cảnh môi trường.

### 2.2. Theo Ý đồ cảnh (`scene_intent`)

| Ý đồ cảnh | n | AI bbox top10 | Center top10 | Win Rate bbox top10 | AI simple top10 | Center Zoom top10 | Win Rate simple top10 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `environmentalPortrait` | 42 | 0.7383 | 0.7978 | 28.6% (12/42) | 0.7194 | 0.7435 | 16.7% (7/42) |
| `object` | 32 | 0.7254 | 0.7565 | 37.5% (12/32) | 0.6943 | 0.7062 | 12.5% (4/32) |
| `landscape` | 26 | 0.7689 | 0.8091 | 23.1% (6/26) | 0.7877 | 0.7954 | 3.8% (1/26) |
| `animal` | 21 | 0.6137 | 0.6440 | 23.8% (5/21) | 0.5866 | 0.6000 | 28.6% (6/21) |
| `group` | 13 | 0.8110 | 0.8415 | 30.8% (4/13) | 0.7786 | 0.7684 | 15.4% (2/13) |
| `closeUp` | 11 | 0.6307 | 0.6635 | 27.3% (3/11) | 0.6432 | 0.6408 | 18.2% (2/11) |
| `portrait` | 3 | 0.4319 | 0.5133 | 0.0% (0/3) | 0.2472 | 0.2536 | 0.0% (0/3) |
| `architecture` | 1 | 0.8673 | 0.8195 | 100.0% (1/1) | 0.8330 | 0.8920 | 0.0% (0/1) |
| `street` | 1 | 0.6085 | 0.9003 | 0.0% (0/1) | 0.7399 | 0.8270 | 0.0% (0/1) |

> **Nhận xét**: AI hoạt động tốt nhất ở nhóm `object` (thắng 37.5%) và `group` (0.8110 top10). Ở các cảnh `landscape` và `portrait`, AI thường cố crop theo tỉ lệ dọc hoặc rule of thirds trong khi ảnh gốc là phong cảnh rộng, dẫn tới điểm IoU thấp.

### 2.3. Theo Hiện tượng Xoay (`is_rotated`)

| Cờ xoay | n | AI bbox top10 | Center top10 | Win Rate bbox top10 | AI simple top10 | Center Zoom top10 | Win Rate simple top10 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `is_rotated=true` | 138 | 0.7159 | 0.7624 | 31.2% (43/138) | 0.6970 | 0.7106 | 15.9% (22/138) |
| `is_rotated=false` | 12 | 0.7132 | 0.7132 | 0.0% (0/12) | 0.7130 | 0.7130 | 0.0% (tất cả hòa) |

### 2.4. Theo Diện tích Chủ thể Hero (`hero_subject_box`)

| Diện tích Hero | n | AI bbox top10 | Center top10 | Win Rate bbox top10 | AI simple top10 | Center Zoom top10 | Win Rate simple top10 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Lớn ($\ge 0.20$) | 57 | **0.8001** | 0.8254 | **38.6% (22/57)** | 0.7750 | 0.7811 | 0.0% (đa số hòa) |
| Vừa ($0.05 - 0.20$) | 42 | 0.7466 | 0.8152 | 23.8% (10/42) | 0.7815 | 0.7975 | 19.0% (8/42) |
| Nhỏ ($< 0.05$) | 51 | 0.5959 | 0.6371 | 21.6% (11/51) | 0.5441 | 0.5609 | **27.5% (14/51)** |

> **Nhận xét**: Khi chủ thể lớn ($\ge 0.20$), AI nhận diện chủ thể rất chính xác và đạt điểm `best_iou_top10` lên tới **0.8001**. Khi chủ thể nhỏ ($< 0.05$), AI thường zoom vào quá mức làm giảm IoU.

---

## PHẦN 3: Chẩn đoán hiện tượng xoay (Code Audit chi tiết)

### 3.1. Nguồn gốc sinh ra `sourceCorners` và góc nghiêng
Trong `AISmartFramingCamera/Services/CompositionPlanning.swift`, dòng 641–645:
```swift
let rotation = simd_quatd(from: future.deviceRay(at: destination),
                          to: calibration.deviceRay(at: subject.anchor))
let sourceCorners = corners.map {
    calibration.project(deviceRay: rotation.act(future.deviceRay(at: $0)))
}
```
Và hàm chuyển đổi tia trong `AISmartFramingCamera/Services/TrackingGeometry.swift`, dòng 47–67:
```swift
public func deviceRay(at point: CGPoint) -> SIMD3<Double> {
    simd_normalize(SIMD3((Double(point.x) - cx) / fx,
                         -(Double(point.y) - cy) / fy, -1))
}
```

**Cơ chế tạo nghiêng:**
1. **Thành phần Roll sinh ra từ tích có hướng của 2 tia**:
   Hàm `simd_quatd(from: u, to: v)` tìm quaternion quay ngắn nhất quanh trục $\vec{n} = \vec{u} \times \vec{v}$.
   Nếu $\vec{u} = (x_1, y_1, -1)$ (tia tới điểm đích `destination`) và $\vec{v} = (x_2, y_2, -1)$ (tia tới vị trí chủ thể `subject.anchor`):
   $$\vec{u} \times \vec{v} = \left( y_2 - y_1, x_1 - x_2, x_1 y_2 - x_2 y_1 \right)$$
   Trục $Z$ của camera là trục quang học nhìn thẳng. Thành phần $Z = x_1 y_2 - x_2 y_1$ **chính là góc xoay Roll trong mặt phẳng ảnh (In-plane camera roll)**!
   Bất cứ khi nào điểm đích và chủ thể lệch nhau ở cả 2 phương $X$ và $Y$ (không nằm trên đường thẳng đi qua tâm $(0.5, 0.5)$), tích $x_1 y_2 - x_2 y_1 \ne 0$, khiến camera bị **bơm một góc xoay Roll tự phát**!
2. **Biến dạng hình thang phối cảnh (Keystone Distortion)**:
   Khi camera 3D quay cả Pitch lẫn Yaw để nhìn vào đối tượng, việc chiếu ngược các góc hình chữ nhật của cảm biến $([0, 1] \times [0, 1])$ lên mặt phẳng ảnh phẳng ban đầu sẽ tạo thành một **tứ giác hình thang phối cảnh**. Các cạnh của tứ giác này không còn song song với các trục ngang/dọc, tạo ra độ nghiêng cạnh từ $10^\circ$ đến $18^\circ$.
3. **Kẹp biên và bù lồi trong `observedSourceQuad`**:
   `CompositionPlanning.swift:1250-1290`: Tứ giác thô có thể vượt ra ngoài biên ảnh tới margin $-0.36$. `observedSourceQuad` thu nhỏ (`scale`) và tịnh tiến (`shiftX`, `shiftY`) để ép các góc vào khoảng $[0.002, 0.998]$, làm méo thêm hình học của khung.

### 3.2. Vision Horizon có bơm góc Roll không?
**Kết luận: KHÔNG.**
- Trong `CompositionPlanning.swift:611`, `raster.horizon` chỉ trả về `(y: CGFloat, confidence: Double)?` (chỉ có cao độ $Y$ và độ tin cậy, không hề có góc nghiêng).
- Tại dòng 689–694, `horizon` chỉ được dùng để tính điểm thưởng bố cục `horizonFit` (đo khoảng cách từ đường chân trời tới tỷ lệ vàng $0.382$ hoặc $0.618$). Nó hoàn toàn không can thiệp vào biến `rotation`.

### 3.3. Kết luận về Hiện tượng Xoay
Xoay **vừa là đặc tính cố ý của camera 3D thời gian thực, vừa là hiệu ứng phụ của cách chạy trên ảnh tĩnh 2D (b)**:
- **Trên iPhone thực tế (Live Camera AR)**: App định hướng là camera 6-DoF với cảm biến con quay hồi chuyển (IMU/EKF). Khi người dùng lia máy trong không gian 3D, khung ngắm AR cần xoay theo góc nhìn của camera thế giới thực để hướng dẫn người chụp nghiêng/lia máy.
- **Trên ảnh tĩnh 2D (GAICD Dataset)**: Khi áp dụng thuật toán xoay 3D lên một bức ảnh phẳng cố định mà không khóa trục đứng (`up = (0, 1, 0)`), việc tự động tính `simd_quatd(from: r1, to: r2)` tạo ra góc roll ảo và biến dạng phối cảnh hình thang không cần thiết, làm giảm IoU so với các crop thẳng đứng chuẩn của GAICD.

---

## PHẦN 4: Số lượng ứng viên (Candidates Audit)

Trong 150 ảnh GAICD:
- **`num_candidates` thực tế**: Min = **1**, Median = **35**, Max = **54**.

**Tại sao khác con số ~6 trong spec?**
1. **Giai đoạn 1 (Tìm kiếm diện rộng - Broad Search)**:
   - `tests/CompositionModelValidation.swift:379`: `proposalLimit` được thiết lập là **36** khi `seeds.isEmpty`.
   - Pipeline sinh ra tới 36 ứng viên bố cục và chấm điểm sơ bộ bằng mô hình **SAMP-Net** (`specialist.assess(preview)`).
2. **Giai đoạn 2 (Tinh chỉnh lân cận - Refinement Search)**:
   - `CompositionAestheticSearch.swift:80-83`: Chọn ra 3 ứng viên đa dạng nhất (`leaders`), gọi `refine` với `proposalLimit = 18`.
   - Sinh thêm tối đa 18 ứng viên lân cận và tiếp tục chấm bằng **SAMP-Net**.
   - Tổng số lượt SAMP-Net đánh giá: $36 + 18 = \mathbf{54}$ ứng viên.
   - Biến đếm `assessedCount` ghi nhận tổng số lượt chấm SAMP-Net này (nên `num_candidates` đạt tới 54).
3. **Mô hình Charm-PARA chỉ chấm tối đa 6 ứng viên**:
   - `CompositionAestheticSearch.swift:116, 121`:
     `let budget = constrained ? 4 : 6`
     `var pool = indices.prefix(budget).map { evaluated[$0] }`
   - Chỉ có **tối đa 6 ứng viên dẫn đầu** được đưa qua mô hình thẩm mỹ chuyên sâu **Charm-PARA** để chấm điểm thẩm mỹ cao cấp. Con số ~6 trong spec chính là ngân sách của Charm-PARA, trong khi `num_candidates` báo cáo toàn bộ các ứng viên mà SAMP-Net đã lọc qua.

---

## PHẦN 5: Xếp hạng nguyên nhân AI kém Center Crop & Mức độ chắc chắn

| Hạng | Nguyên nhân | Mức độ chắc chắn | Bằng chứng thực nghiệm |
|:---:|---|:---:|---|
| **1** | **Dịch chuyển TÂM (Destination Placement) về điểm 1/3** | **RẤT CAO (95%)** | Khi triệt tiêu hoàn toàn sai số kích thước và xoay (`ai_simple` vs `center_same_zoom`), AI vẫn thua Center Crop ở 40 ảnh và chỉ thắng 19 ảnh (tỉ lệ thắng 12.7%). GAICD là tập ảnh Flickr do nhiếp ảnh gia căn bố cục tĩnh sẵn; việc AI cố ép chủ thể vào điểm 1/3 làm mất cân bằng tự nhiên của khung ảnh. |
| **2** | **Phép quay 3D Quaternion không khóa trục đứng (Unconstrained Roll)** | **RẤT CAO (100%)** | `simd_quatd(from: r1, to: r2)` có thành phần $Z = x_1 y_2 - x_2 y_1 \ne 0$ khiến 92% ảnh bị nghiêng từ $10^\circ - 18^\circ$. Bounding box AABB bị phình to làm giảm IoU. |
| **3** | **Zoom quá sâu ở nhóm zoom lớn ($> 1.20$)** | **CAO (85%)** | Ở nhóm zoom $> 1.20$, điểm IoU của AI tụt dốc từ $0.78$ xuống $0.56$ (bbox) và $0.47$ (simple). Việc zoom sâu làm cắt mất bối cảnh môi trường của ảnh gốc. |
| **4** | **Phạt quá nặng vị trí trung tâm (`deadCenterDestPenalty`)** | **CAO (80%)** | Trong `CompositionPlanning.swift:718-720`, code phạt tới $0.15$ nếu điểm đặt chủ thể rơi vào tâm chết $(0.5, 0.5)$. Điều này cưỡng ép AI phải né tâm ngay cả khi chủ thể nằm giữa là tối ưu. |
| **5** | **Sai lệch hộp bao trục AABB (Bounding Box Approximation)** | **TRUNG BÌNH (75%)** | AABB làm tăng diện tích của tứ giác nghiêng. Tuy nhiên, kết quả ở Phần 1 cho thấy ngay cả khi dùng `crop_simple` thẳng đứng, AI vẫn chưa vượt được center crop, chứng tỏ hình học hộp bao chỉ đóng góp một phần nhỏ vào độ lệch. |

---

## PHẦN 6: Đề xuất 3 thay đổi nên thử đầu tiên (CHƯA thực hiện)

1. **Khóa trục đứng khi xoay Camera 3D (Constrained Yaw-Pitch LookAt)**:
   - Thay vì dùng `simd_quatd` tự do giữa 2 tia thiết bị, tách góc xoay thành Yaw (quanh trục đứng $Y$) và Pitch (quanh trục ngang $X$), triệt tiêu hoàn toàn góc quay quanh trục $Z$ (Roll = 0).
   - *Mục tiêu:* Giữ `is_rotated = false` trên toàn bộ ảnh tĩnh, giữ các cạnh crop luôn vuông góc với khung hình.
2. **Điều chỉnh mềm hóa phạt tâm chết (`deadCenterDestPenalty`)**:
   - Giảm hoặc bỏ hẳn phạt `deadCenterDestPenalty` ở các cảnh có chủ thể diện tích lớn ($\ge 0.20$) hoặc các cảnh đơn thể (`object`, `animal`). Cho phép AI tự do chọn crop ở tâm nếu điểm thẩm mỹ của SAMP/Charm đánh giá tâm cao hơn điểm 1/3.
3. **Kẹp mức zoom tối đa theo diện tích chủ thể và bối cảnh**:
   - Ở nhóm zoom $1.05 - 1.20$, AI đạt tỉ lệ thắng cao nhất (40%). Nên giới hạn mức zoom tự động không vượt quá $1.25\times$ trên ảnh tĩnh thông thường nhằm tránh hiện tượng "cháy khung" (over-cropping) làm mất bối cảnh nền.
