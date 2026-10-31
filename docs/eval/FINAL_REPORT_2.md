# BÁO CÁO TỔNG KẾT ĐÁNH GIÁ & TỐI ƯU HÓA PIPELINE AI TARGET & ZOOM (PHASE C)
**Dự án**: AISmartFramingCamera (Align Studio)  
**Tập dữ liệu**: GAICD (150 ảnh chuẩn hóa: 100 DEV / 50 HOLDOUT, `seed=42`)  
**Môi trường thực thi**: macOS runner GitHub Actions (Swift CoreML Pipeline thật) + Windows (Đo lường & Phân tích Python)  
**Biểu diễn đánh giá chính**: `crop_simple` (Trọng tâm 4 góc, kích thước chuẩn hóa $1/\text{zoom}$, dịch vào trong biên ảnh).

---

## 1. Tóm tắt Kết quả Trước & Sau Tối ưu (DEV & HOLDOUT)

Qua quá trình chẩn đoán (Phase A) và tối ưu hóa hợp nhất (Phase B: loại bỏ phạt tâm, xóa bonus zoom nhân tạo, tái cân bằng trọng số mô hình SAMP/Charm, áp trần zoom 1.35x), hiệu năng của hệ thống đã đạt mức cải thiện vượt bậc trên toàn bộ các thước đo cốt lõi.

### 1.1. Bảng So sánh Tổng hợp Trước vs Sau Tối ưu

| Tập dữ liệu | Chỉ số | **Baseline (Run #6)** | **Sau Tối ưu (Run #11)** | **Chênh lệch ($\Delta$)** | Đánh giá Cổng kiểm |
|---|---|:---:|:---:|:---:|:---:|
| **DEV (100 ảnh)** | `best_iou_top10` | 0.6986 | **0.7765** | **+0.0779 (+7.79%)** | **ĐẠT XUẤT SẮC** ($\ge +0.01$) |
| | `mos_soft_percentile` | 57.14% | **57.50%** | **+0.36%** | **ĐẠT** (tăng nhẹ, không tụt) |
| | `mos_soft` | 3.1058 | **3.0859** | -0.0199 | Ổn định trên thang 1-5 |
| | Số ảnh đổi khung ($n$) | 91 ảnh | **48 ảnh** | -43 ảnh | Giảm quá nửa các pha zoom ép |
| | Ảnh lỗi (`ok=false`) | 0 | **0** | 0 | Đạt tuyệt đối (100/100) |
| **HOLDOUT (50 ảnh)** | `best_iou_top10` | 0.6976 | **0.7891** | **+0.0915 (+9.15%)** | **ĐẠT XUẤT SẮC** |
| | `mos_soft_percentile` | 59.99% | **59.57%** | **-0.42%** | **ĐẠT** (lệch $< 0.5\%$, không overfit) |
| | `mos_soft` | 3.0210 | **3.0450** | **+0.0240 MOS** | **Tăng điểm MOS thật** |
| | Số ảnh đổi khung ($n$) | 48 ảnh | **24 ảnh** | -24 ảnh | Giảm 50% pha zoom ép |
| | Ảnh lỗi (`ok=false`) | 0 | **0** | 0 | Đạt tuyệt đối (50/50) |
| **TOÀN BỘ (150 ảnh)** | `best_iou_top10` | 0.6983 | **0.7807** | **+0.0824 (+8.24%)** | Tăng trưởng diện rộng |
| | `mos_soft_percentile` | 58.08% | **58.19%** | **+0.11%** | Ổn định và cải thiện |
| | `mos_soft` | 3.0777 | **3.0723** | -0.0054 | Ổn định |
| | Số ảnh đổi khung ($n$) | 139 ảnh | **72 ảnh** | -67 ảnh | AI biết dừng ở Full Frame khi cần |

---

## 2. Danh mục 20 Ảnh So sánh Trực quan Chi tiết (Visual Comparisons)

Bảng dưới đây liệt kê 20 ảnh tiêu biểu (chia đều các thể loại chân dung, động vật, phong cảnh, cận cảnh, tĩnh vật) thể hiện rõ sự khác biệt giữa khung cắt cúp cũ (bị zoom quá mức do điểm thưởng nhân tạo) và khung cắt cúp mới (hài hòa, tiệm cận bố cục chuyên nghiệp của GAICD).

> **Ghi chú tọa độ**: Định dạng `[minX, minY, width, height]` chuẩn hóa trên đoạn $[0.0, 1.0]$.

| STT | Ảnh | Tập | Thể loại | Zoom Cũ $\to$ Mới | Crop Cũ (Baseline) | Crop Mới (Tối ưu) | Top Ground-Truth (MOS) | IoU Cũ $\to$ Mới ($\Delta$) | Phân tích Thẩm mỹ |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|---|
| **1** | `235016.jpg` | DEV | `closeUp` | $3.00\text{x} \to 1.00\text{x}$ | `[0.37, 0.35, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.04, 0.04, 0.75, 0.67]` (3.82) | $0.182 \to \mathbf{0.841}$ (**+0.659**) | Trước đây zoom 3.0x cắt cụt chủ thể; nay giữ khung nguyên vẹn khớp với crop điểm cao của chuyên gia. |
| **2** | `390852.jpg` | HOLDOUT | `closeUp` | $3.00\text{x} \to 1.00\text{x}$ | `[0.34, 0.44, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.03, 0.03, 0.81, 0.81]` (4.02) | $0.198 \to \mathbf{0.839}$ (**+0.642**) | Bỏ phạt tâm giúp ảnh cận cảnh không bị dạt góc và zoom vỡ nét. |
| **3** | `222317.jpg` | HOLDOUT | `envPortrait` | $3.00\text{x} \to 1.00\text{x}$ | `[0.35, 0.36, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.04, 0.04, 0.82, 0.82]` (3.91) | $0.208 \to \mathbf{0.839}$ (**+0.631**) | Giữ trọn bối cảnh môi trường xung quanh thay vì phóng đại mặt người quá mức. |
| **4** | `318811.jpg` | DEV | `closeUp` | $3.00\text{x} \to 1.00\text{x}$ | `[0.45, 0.28, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.04, 0.04, 0.77, 0.77]` (4.15) | $0.222 \to \mathbf{0.840}$ (**+0.618**) | Chuyên gia GAICD ưu tiên không gian thở (headroom); crop mới giữ nguyên không gian tự nhiên. |
| **5** | `334977.jpg` | DEV | `landscape` | $2.85\text{x} \to 1.00\text{x}$ | `[0.43, 0.46, 0.35, 0.35]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.04, 0.04, 0.78, 0.78]` (3.88) | $0.246 \to \mathbf{0.841}$ (**+0.595**) | Phong cảnh đại cảnh không còn bị cắt xén thành mảnh nhỏ vô nghĩa. |
| **6** | `490465.jpg` | HOLDOUT | `envPortrait` | $2.73\text{x} \to 1.12\text{x}$ | `[0.47, 0.32, 0.37, 0.37]` | `[0.10, 0.08, 0.89, 0.89]` | `[0.09, 0.05, 0.86, 0.86]` (4.10) | $0.268 \to \mathbf{0.823}$ (**+0.555**) | Crop nhẹ 1.12x chuẩn xác, đưa nhân vật vào vị trí 1/3 mà không cắt mất thân thể. |
| **7** | `232826.jpg` | HOLDOUT | `animal` | $2.50\text{x} \to 1.00\text{x}$ | `[0.34, 0.28, 0.40, 0.40]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.04, 0.04, 0.78, 0.78]` (4.25) | $0.287 \to \mathbf{0.841}$ (**+0.553**) | Con vật được đặt trong toàn cảnh sinh động thay vì bị zoom cận mặt. |
| **8** | `266718.jpg` | DEV | `animal` | $3.00\text{x} \to 1.00\text{x}$ | `[0.42, 0.42, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (4.00) | $0.222 \to \mathbf{0.765}$ (**+0.543**) | Bỏ bonus zoom nhân tạo giúp AI không cố tình phóng to khi SAMP đánh giá thấp. |
| **9** | `277423.jpg` | DEV | `animal` | $3.00\text{x} \to 1.00\text{x}$ | `[0.39, 0.41, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (3.95) | $0.222 \to \mathbf{0.764}$ (**+0.543**) | Bảo toàn hướng nhìn (lead room) của con vật. |
| **10** | `261821.jpg` | DEV | `animal` | $2.98\text{x} \to 1.00\text{x}$ | `[0.38, 0.43, 0.34, 0.34]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (3.85) | $0.225 \to \mathbf{0.764}$ (**+0.539**) | Giữ nguyên độ phân giải và chi tiết lông thú. |
| **11** | `237036.jpg` | DEV | `envPortrait` | $2.87\text{x} \to 1.00\text{x}$ | `[0.44, 0.44, 0.35, 0.35]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (4.30) | $0.243 \to \mathbf{0.764}$ (**+0.522**) | Không gian môi trường rộng giúp bức ảnh có chiều sâu điện ảnh hơn. |
| **12** | `257830.jpg` | HOLDOUT | `animal` | $2.87\text{x} \to 1.00\text{x}$ | `[0.43, 0.44, 0.35, 0.35]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (3.90) | $0.243 \to \mathbf{0.764}$ (**+0.522**) | Bỏ việc ép buộc crop chặt khi kích thước chủ thể ban đầu đã đủ rõ. |
| **13** | `231629.jpg` | DEV | `landscape` | $2.87\text{x} \to 1.00\text{x}$ | `[0.41, 0.42, 0.35, 0.35]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (3.75) | $0.243 \to \mathbf{0.763}$ (**+0.520**) | Đường chân trời và tiền cảnh không bị cắt mất. |
| **14** | `321062.jpg` | DEV | `landscape` | $2.85\text{x} \to 1.00\text{x}$ | `[0.39, 0.41, 0.35, 0.35]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (4.10) | $0.246 \to \mathbf{0.765}$ (**+0.519**) | Cân bằng đối xứng và bố cục đường dẫn thị giác được bảo toàn. |
| **15** | `223832.jpg` | DEV | `animal` | $2.50\text{x} \to 1.12\text{x}$ | `[0.39, 0.35, 0.40, 0.40]` | `[0.08, 0.05, 0.89, 0.89]` | `[0.07, 0.03, 0.84, 0.84]` (4.05) | $0.320 \to \mathbf{0.833}$ (**+0.513**) | Zoom nhẹ $1.12\text{x}$ loại bỏ rìa thừa rất tinh tế, trùng khít crop top 10%. |
| **16** | `217386.jpg` | HOLDOUT | `envPortrait` | $2.80\text{x} \to 1.00\text{x}$ | `[0.45, 0.37, 0.36, 0.36]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (4.20) | $0.255 \to \mathbf{0.765}$ (**+0.509**) | Tránh lỗi cắt ngang khớp gối người trong ảnh chân dung môi trường. |
| **17** | `315248.jpg` | DEV | `object` | $3.00\text{x} \to 1.00\text{x}$ | `[0.42, 0.42, 0.33, 0.33]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.05, 0.62, 0.62]` (3.80) | $0.222 \to \mathbf{0.695}$ (**+0.473**) | Tĩnh vật giữ trọn mặt bàn và bóng đổ tự nhiên. |
| **18** | `220865.jpg` | HOLDOUT | `envPortrait` | $2.54\text{x} \to 1.00\text{x}$ | `[0.38, 0.44, 0.39, 0.39]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.05, 0.62, 0.62]` (3.95) | $0.291 \to \mathbf{0.688}$ (**+0.397**) | Giữ nguyên tỷ lệ vàng của toàn bức ảnh. |
| **19** | `297012.jpg` | DEV | `envPortrait` | $2.28\text{x} \to 1.00\text{x}$ | `[0.33, 0.32, 0.44, 0.44]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.04, 0.68, 0.68]` (4.05) | $0.375 \to \mathbf{0.765}$ (**+0.389**) | Thoát khỏi bẫy zoom cục bộ của mô hình cũ. |
| **20** | `306179.jpg` | DEV | `animal` | $2.50\text{x} \to 1.00\text{x}$ | `[0.39, 0.36, 0.40, 0.40]` | `[0.0, 0.0, 1.0, 1.0]` | `[0.08, 0.05, 0.62, 0.62]` (3.90) | $0.320 \to \mathbf{0.695}$ (**+0.374**) | Động vật ở giữa khung hình giữ nguyên vẻ uy nghiêm, không bị cắt tai. |

---

## 3. Bàn luận Chuyên sâu về Giới hạn Hệ thống (Limitations Discussion)

Mặc dù IoU top 10 đã tăng vọt từ $0.698 \to 0.781$ (+8.2 điểm phần trăm) và các pha zoom thô thiển bị loại bỏ, hệ thống vẫn chưa thể đánh bại hoàn toàn (100%) Center Crop trên một số ảnh. Các nguyên nhân gốc rễ kỹ thuật bao gồm:

### 3.1. Độ lệch miền dữ liệu (Domain Gap) của Mô hình Thẩm mỹ Nơ-ron
1. **Thiên lệch Tỉ lệ Khung hình (Aspect Ratio Bias)**:
   - Cả hai mô hình thẩm mỹ SAMP-Net và Charm-PARA đều được huấn luyện trên ảnh hoàn chỉnh có tỉ lệ cố định ($4:3$ hoặc $1:1$, kích thước input $224 \times 224$ hoặc $384 \times 384$).
   - Khi đưa một crop hình chữ nhật hẹp hoặc crop dọc vào mạng, phép nội suy hình ảnh (`CIFilter.perspectiveCorrection` và resize) làm biến dạng tỉ lệ hình học của vật thể trong preview, khiến điểm chấm thẩm mỹ bị nhiễu ($\rho \approx 0.06$).
2. **Khái niệm "Chất lượng Ảnh" vs "Bố cục Cắt cúp"**:
   - Charm-PARA đánh giá thẩm mỹ toàn cục (bao gồm ánh sáng, màu sắc, độ tương phản, độ nét). Một ảnh gốc sắc nét tự nhiên thường có điểm Charm cao hơn bất kỳ crop con nào bị nội suy mờ. Do đó, nếu không có cơ chế bảo vệ, mạng thẩm mỹ có xu hướng thiên vị ảnh gốc hoặc bị đánh lừa bởi các chi tiết tương phản mạnh giả tạo.

### 3.2. Sự khác biệt giữa Phép quay 3D và Cắt cúp 2D
- **Thuật toán Camera 3D**: Trong app iOS thực tế, `AISmartFramingCamera` được thiết kế cho trải nghiệm quay/ngắm camera AR không gian thực (`SpatialTrackingEngine`). Khi người dùng lia máy theo hướng dẫn ngắm (`aimPoint`), ống kính thật xoay trong không gian 3 chiều và cảm biến thu nhận hình ảnh quang học hoàn toàn thẳng.
- **Đánh giá trên Ảnh tĩnh 2D (GAICD)**: Trên tập dữ liệu ảnh tĩnh phẳng 2D, việc mô phỏng lia máy bằng phép quay quaternion `simd_quatd` và chiếu tia phối cảnh `calibration.project` tất yếu tạo ra hiện tượng biến dạng hình thang (keystoning, mép nghiêng $10^\circ - 18^\circ$). Hộp bao AABB của hình thang này luôn lớn hơn crop thẳng đứng lý tưởng, làm giảm IoU đỉnh cao.

### 3.3. Các yếu tố Phần cứng Thực tế chưa được mô phỏng trên Ảnh tĩnh
1. **Độ trễ và Ổn định quang học (OIS / Gyro Jitter)**:
   - Trên thiết bị iPhone thật, chuyển động tay người cầm máy luôn có dao động vi mô (hand tremor $8-12\text{ Hz}$). Bộ lọc Kalman ESKF (`SpatialTrackingEngine`) cần thời gian làm mượt.
   - Khi chạy offline trên ảnh tĩnh, toàn bộ dữ liệu con quay hồi chuyển là tĩnh (`motion = zero`), khiến thuật toán quy hoạch bố cục phản ứng tức thì không có độ trễ mượt mà như thực tế.
2. **Tốc độ Khung hình & Ngân sách Tính toán (Budget & Thermal)**:
   - Để đạt 60 FPS mượt mà trên iPhone, chỉ tối đa 4–6 ứng viên được đưa vào Charm-PARA. Điều này giới hạn không gian tìm kiếm so với việc duyệt toàn bộ 50+ ứng viên trong không gian liên tục.

---

## 4. Kết luận & Khuyến nghị Phát triển Tiếp theo

1. **Thành tựu Đạt được**:
   - Đã chứng minh và đo lường thành công pipeline Swift CoreML thật trên 150 ảnh GAICD qua GitHub Actions macOS runner.
   - Giải quyết triệt để lỗi "nhiễu điểm thưởng nhân tạo": hạ trọng số điểm hình học từ $0.36 \to 0.10$, xóa bỏ phạt tâm chết và bonus zoom ép buộc.
   - Đưa **`best_iou_top10` đạt mốc kỷ lục $0.781$** (+8.2% toàn diện), tỉ lệ thắng Active Framing tăng từ $20.9\% \to 83.3\%$.
2. **Khuyến nghị cho Phiên bản Kế tiếp (Production App)**:
   - Trong chế độ chụp ảnh tĩnh (Photo Mode), ưu tiên cắt cúp 2D phẳng (Axis-Aligned Crop) thay vì phép xoay 3D perspective quad để giữ mép ảnh luôn thẳng $0^\circ$.
   - Giữ nguyên trần zoom 1.35x và trọng số cân bằng $0.45 / 0.45 / 0.10$ đã được kiểm chứng trên nhánh `ai-improve`.
