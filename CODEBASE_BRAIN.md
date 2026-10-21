# BỘ NÃO DỰ ÁN (CODEBASE BRAIN) - ALIGNAI STUDIO

> **Tài liệu tham chiếu tối thượng dành cho AI và Kỹ sư phát triển.**
> Được lập vào: Tháng 10/2026.
> **NGUYÊN TẮC BẤT DI BẤT DỊCH**: Tuyệt đối không đoán mò, không xóa các cơ chế fix lỗi cũ, không phá vỡ ranh giới mã nguồn được bảo vệ (`TrackingBoundary.json` và `PhotographicDetectionBoundary.json`). Mọi thay đổi phải đảm bảo các bài test hồi quy (`run_regressions.py`, `check_swift_brackets.py`, `verify_tracking_boundary.py`) luôn vượt qua 100%.

---

## 1. TỔNG QUAN KIẾN TRÚC & SƠ ĐỒ LUỒNG DỮ LIỆU THỰC TẾ

AlignAI Studio là hệ thống máy ảnh nhiếp ảnh điện ảnh thông minh trên iOS (hỗ trợ iOS 17.0+ đến 18+), kết hợp trực tiếp giữa phần cứng camera Apple ISP 48MP, cảm biến chuyển động 6-DoF CoreMotion, chip gia tốc Apple Neural Engine (ANE), mô hình thị giác Vision / YOLOv26 / YOLO12 và các mô hình thẩm mỹ nhiếp ảnh cục bộ SAMP-Net & Charm (2025).

### 1.1. Sơ đồ Luồng Dữ Liệu Thời Gian Thực (Runtime Data Flow)

```mermaid
flowchart TD
    subgraph HARDWARE_TIER["1. TẦNG PHẦN CỨNG & CẢM BIẾN"]
        CS["AVCaptureSession (60 FPS)"] -->|"CMSampleBuffer"| CS_VDQ["videoDataQueue (CameraService)"]
        IMU["CoreMotion Gyroscope (100Hz)"] -->|"CMMotionManager"| DMS["DeviceMotionService (com.alignai.motion)"]
    end

    subgraph ENGINE_TIER["2. TẦNG XỬ LÝ THỊ GIÁC & BÁM BẮT KHÔNG GIAN"]
        CS_VDQ -->|"PixelBuffer (FrameContext)"| VFE["VisionFramingEngine (visionQueue)"]
        CS_VDQ -->|"Subsampled PixelBuffer"| RHE["RealtimeHistogramEngine (32-Bins Rec.709)"]
        CS_VDQ -->|"CIImage Frame"| FPE["FocusPeakingEngine (Metal GPU Sobel)"]
        DMS -->|"TrackingMotionSample (simd_quatd)"| STE["SpatialTrackingEngine (6-DoF ESKF Sphere S^2)"]
        VFE <-->|"Optical Measurements & Continuity"| TPF["TargetPatchFlow & 5x5 Grid Recovery"]
        VFE -->|"Optical Detection Point"| STE
    end

    subgraph INTELLIGENCE_TIER["3. TẦNG TRÍ TUỆ NHÂN TẠO & ĐIỀU PHỐI (MVVM)"]
        STE -->|"currentEstimatedScreenPoint + TrackingQuality"| CVM["CameraViewModel (@MainActor)"]
        VFE -->|"SubjectDetectionResult (Faces, Bodies, YOLO)"| CVM
        CVM -->|"Tracking Point + Pose"| ADG["AlignmentCaptureGate (Cổng Căn Tâm 240ms)"]
    - **Cơ chế Khóa Cứng (Hard Lock - Phase 1 Fix Lỗi 2)**: Bổ sung isTargetLocked: Bool, lockTarget(), unlockTarget(). Khi isTargetLocked == true, update duy trì inside = true và effectiveEvidence = true để thời gian ngắm (dwell) tích lũy mượt mà tới .ready mà không bị gián đoạn bởi nhiễu ngoại quan hay biến động toạ độ.
        CVM -->|"One-shot Offline Analysis"| NSIC["NeuralSubjectIntelligenceEngine"]
        NSIC -->|"Proposals & Rendered Crops"| CAS["CompositionAestheticSearch (SAMP-Net & Charm)"]
        CAS -->|"LocalFramingPlan"| CVM
    end

    subgraph PRESENTATION_TIER["4. TẦNG GIAO DIỆN & MÀN TRẬP QUANG HỌC"]
        CVM -->|"State & Geometry"| AR_HUD["ARFramingOverlayView & LiveColorHistogramHUDView"]
        ADG -->|"Trạng thái .ready (Tâm khớp)"| HAPTIC["HapticFeedbackService (Magnetic Snap)"]
        HAPTIC -->|"Auto-Capture Signal"| CAPTURE["CameraService.capturePhoto(isDNG:isHEIF:)"]
        CAPTURE -->|"Bayer RAW DNG + Companion JPEG Display P3"| PHOTOKIT["PhotoKit Dual-Resource Asset (Album: Align Studio)"]
    end
```

### 1.2. Vòng Đời Trạng Thái AI Capture (AI State Machine Lifecycle)

Hệ thống tuân thủ nghiêm ngặt cỗ máy trạng thái:
$$\text{idle} \longrightarrow \text{analyzing} \longrightarrow \text{targetPlaced} \longrightarrow \text{alignmentPerfect} \longrightarrow \text{capturing} \longrightarrow \text{done}$$

- **`idle`**: Camera xem trước bình thường, không khóa mục tiêu. Tâm ngắm chữ thập trung tâm được ẩn đi để giữ khung hình sạch sẽ.
- **`analyzing`**: Người dùng bấm nút AI hoặc chạm chủ thể; hệ thống phân tích frame nguồn bằng Vision, YOLO và trích xuất bố cục đề xuất.
- **`targetPlaced`**: Vòng vàng mục tiêu xuất hiện, bám chắc vào đối tượng thông qua 6-DoF ESKF Fusion. Tâm trắng quang học cố định ở tâm màn hình xuất hiện cùng đường ray chỉ dẫn (Guidance Ray).
- **`alignmentPerfect`**: Người dùng đưa tâm trắng khớp vào vòng vàng. Cổng `AlignmentCaptureGate` bắt đầu tích lũy thời gian duy trì (Dwell Time >= 220-240ms). Vòng chuyển màu xanh lá/vàng sáng kim.
- **`capturing`**: Rung phản hồi cơ học Magnetic Snap kích hoạt, phát lệnh chụp `capturePhoto`. Màn hình chớp nhẹ (Haptic & Visual Flash).
- **`done`**: Ảnh được xử lý, lưu vào PhotoKit hoặc chuyển sang màn hình xem trước `CapturedPhotoPreviewView`.

---

## 2. BẢN ĐỒ CHI TIẾT CÁC FILE NGUỒN VÀ BẢN FIX LỖI CẦN BẢO VỆ

### 2.1. Tầng Camera & Cảm biến (Hardware & Services)

#### `CameraService.swift`
- **Chức năng cốt lõi**:
  - Sở hữu độc quyền `AVCaptureSession`, `sessionQueue`, `videoDataQueue`, `photoProcessingQueue`.
  - Hỗ trợ đầy đủ camera trước/sau, DualCamera, TripleCamera, UltraWide (0.5x), Wide (1x), Telephoto (2x/3x/5x).
  - Chuyển đổi linh hoạt giữa Display Zoom và Device Zoom với dải trễ (Hysteresis Band) 1.98x / 1.65x để triệt tiêu hiện tượng rung chuyển ống kính (lens hunting/chattering).
  - Chụp ảnh ISP 48MP gốc (`maxPhotoDimensions`), chụp RAW DNG nguyên bản (Pure Bayer RAW) và đính kèm bản xem trước JPEG Display P3.
  - Quản lý ghi âm đa kênh Stereo chuẩn phòng thu (`AVAudioSession` orientation portrait).
- **Các hàm / biến quan trọng**:
  - `resolveOpticalLensTarget(for:)`: Thuật toán ngưỡng trễ chống nhảy ống kính quang học vật lý.
  - `convertDisplayZoomToDeviceZoom(_:)` & `convertDeviceZoomToDisplayZoom(_:)`: Chuyển đổi hệ số zoom hiển thị và zoom phần cứng.
  - `capturePhoto(isDNG:isHEIF:highResolution:)`: Khởi tạo `AVCapturePhotoSettings` cho RAW DNG hoặc HEIC/JPEG. Tuyệt đối không gọi `setPhotoQualityPrioritization` khi chụp RAW vì AVFoundation sẽ ném lỗi crash `NSInvalidArgumentException`.
  - `photoOutput(_:didFinishProcessingPhoto:error:)`: Tách bạch rõ luồng byte RAW cảm biến (không can thiệp CIRAWFilter hay tone-mapping giả) và ảnh nén hiển thị.
  - `scheduleDeviceConfiguration(after:operation:)`: Bắt buộc đi qua hàm này khi tương tác với `AVCaptureDevice`, luôn có `defer { camera.unlockForConfiguration() }`.
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `043a21ea2c9855bc4598a11dfae25ca8eb60853565a6863d5b183c235c80e49a`).

#### `DeviceMotionService.swift`
- **Chức năng cốt lõi**:
  - Đọc dữ liệu con quay hồi chuyển CoreMotion ở tần số 100Hz (`1 / 60.0` đến `1 / 100.0`s).
  - Chuyển ma trận quay $3 \times 3$ của CoreMotion thành quaternion định hướng toàn cầu `simd_quatd` qua phép chuyển vị: `simd_quatd(worldToDevice.transpose)`.
  - Cơ chế đồng bộ hóa luồng qua `streamGeneration` và `legacyGeneration` có khóa `NSRecursiveLock`, loại bỏ hoàn toàn mẫu dữ liệu trễ từ phiên cũ.
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `4db6747f363e2fb21b7fb09f1d1083213b4012215b7a4dc8e4765a6878313a3b`). Không bao giờ gọi synchronous dispatch lên Main Thread từ callback con quay hồi chuyển.

#### `HapticFeedbackService.swift`
- **Chức năng cốt lõi**:
  - Điều khiển các bộ sinh xung xúc giác: `UIImpactFeedbackGenerator(style: .rigid, .medium, .light, .soft)`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator`.
  - `triggerMagneticSnap()`: Xung lực dứt khoát 1.0 khi tâm ngắm trắng khớp vào vòng vàng mục tiêu. Có cờ debounce 0.35s ngăn ngừa mỏi xúc giác tay người dùng.

#### `SuperResolutionRAWEngine.swift` & `SuperResolutionMetalShaders.swift`
- **Chức năng cốt lõi**:
  - Dữ liệu DNG từ cảm biến được lưu giữ nguyên trạng 100% byte gốc, không đưa qua shader Metal xử lý màu sắc nhân tạo.
  - `decodeProcessedPhoto(_:context:)`: Giải mã ảnh JPEG/HEIF hiển thị đồng hành, đọc đúng cờ hướng ảnh EXIF (`CGImagePropertyOrientation`) một lần duy nhất, xuất ra không gian màu chuẩn Display P3.

#### `FocusPeakingEngine.swift`
- **Chức năng cốt lõi**:
  - Động cơ báo nét điện ảnh thời gian thực 60 FPS gia tốc GPU Metal thông qua `CIContext(mtlDevice:)`.
  - Tích hợp 4 màu báo nét neon: Xanh Lá Neon, Vàng Kim, Đỏ Rực, Xanh Dương.
  - Sử dụng ma trận Sobel Edge Detection kết hợp Color Matrix có cờ khóa `stateLock`, tự động downscale xuống chiều rộng 720px để tiết kiệm tài nguyên GPU.

#### `ProVideoManualControlsService.swift`
- **Chức năng cốt lõi**:
  - Quản lý trạng thái thủ công chuyên nghiệp: ISO (32-3200), Tốc độ màn trập (1/24s - 1/8000s), EV Bias (-2 đến +2), Cân bằng trắng Kelvin (2500K - 9000K), Lấy nét thủ công khoảng cách thấu kính `lensPosition` (0.0 đến 1.0).
  - Gom xung slider bằng `DispatchWorkItem` có khả năng hủy để tránh làm nghẽn hàng đợi lệnh của camera phần cứng.

#### `FilmFilterEngine.swift` & `Services/FilmSimulations/*`
- **Chức năng cốt lõi**:
  - Hệ thống đồ thị Core Image dựng 62 công thức màu phim kinh điển phân nhóm: Trending, Fuji Pro 400H, Kodak Portra, Cinematic Teal & Orange, Ricoh GR, B&W Noir, Vintage Cam 1998, Analog DV, Canon CCD Digicam.
  - Áp dụng trên không gian màu Display P3, hỗ trợ thanh trượt cường độ `intensity` từ 0.0 đến 1.0 và cơ chế giải phóng bộ nhớ `clearCache()`.

---

### 2.2. Tầng AI & Tracking (Engines)

#### `VisionFramingEngine.swift`
- **Chức năng cốt lõi**:
  - Quản lý chuỗi tracking quang học `VNTrackObjectRequest` với mức chính xác `.accurate`.
  - Bảo vệ vòng lặp nhận diện bằng `VisionContinuityPolicy` (chấp nhận mất dấu tối đa 6 khung hình ngắn hạn trước khi chuyển sang tái nhận diện).
  - **Thuật toán quét lưới 5x5 phục hồi mục tiêu (Budgeted Grid Search)**: Khi mục tiêu mất dấu quá 20 khung hình, hệ thống quét tuần tự 25 ô trên lưới 5x5, mỗi frame chỉ kiểm tra 2-3 ô ngân sách để không tụt 60 FPS.
  - Bộ lọc màu Bhattacharyya (ngưỡng tương đồng $\ge 0.62$) lọc bỏ 95% vùng sai chỉ trong 0.05 ms trước khi đưa vào mạng nơ-ron FeaturePrint so khớp.
  - `reidentifyWithDetectors`: Tái định danh kết hợp giữa YOLO CoreML (độ tin cậy $\ge 0.45$) và bộ yêu cầu Apple Vision (Face, Human, Animal, Saliency).
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `3eafbb9c21256df1cc46a6a2d057fee548ba7378c4b69a10ccd0a5397bbfa8e1`).

#### `SpatialTrackingEngine.swift`
- **Chức năng cốt lõi**:
  - Thuật toán Error-State Kalman Filter (ESKF) trên mặt phẳng tiếp xúc mặt cầu đơn vị $S^2$.
  - Theo dõi vector định hướng mục tiêu trong thế giới thực $\vec{r} \in \mathbb{R}^3 (||\vec{r}|| = 1)$ và vận tốc góc quay $\vec{\omega}$ (rad/s).
  - Tích hợp cổng kiểm định thống kê Mahalanobis Innovation Gating:
    $$\chi^2 = \vec{y}^T S^{-1} \vec{y} \le 16.0$$
    (ngưỡng 25.0 cho continuation và 100.0 cho confirmed continuation).
  - Lọc rung thích ứng Hermite Smoothstep: Khi máy đứng yên, chuyển về `ordinaryGain` tần số thấp; khi lia máy nhanh hoặc chủ thể di chuyển, chuyển mượt mà sang `motionGain`.
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `27678bbc7085d16712d87068af7e89885b8d7ba4fafdd82df1dcc9be99b34003`).

#### `TargetPatchFlow.swift`
- **Chức năng cốt lõi**:
  - Thuật toán bám bắt luồng quang học ma trận cục bộ (Local Patch Correspondence) độc lập với kích thước hộp Vision.
  - Tự động trích xuất các điểm đặc trưng bề mặt có giá trị riêng nhỏ nhất (Shi-Tomasi Minimum Eigenvalue $\ge 16.0$) trên ảnh xám chuẩn hóa độ sáng.
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `2c8e211f3912e93f27044a0f2f1ef806f08080c4b88845fab176b51cdfe8c442`).

#### `TrackingGeometry.swift`
- **Chức năng cốt lõi**:
  - `TrackingCalibration`: Lưu thông số nội tại camera $f_x, f_y, c_x, c_y, \text{aspect}$.
  - Phép bắn tia lỗ kim (`deviceRay`) và phép chiếu ngược (`project`). Khi mục tiêu ở sau lưng camera ($forward \le 0$), chuyển sang hệ tọa độ góc cầu để dẫn đường con trỏ chính xác về mép màn hình mà không bị đảo ngược vector.
  - `dock`: Ghim con trỏ mục tiêu vào viền màn hình (Edge Docking) với khoảng đệm an toàn 30px khi đối tượng trôi ra ngoài tầm nhìn (Off-screen).
  - `AlignmentCaptureGate`: Bộ đếm tích lũy thời gian căn tâm chống rung tay sinh học. Ngưỡng vào $1.0\times$, ngưỡng giữ chống rung $1.45\times - 1.8\times$, thời gian trễ dung sai 180ms, thời gian tích lũy yêu cầu 220-240ms.
- **Cơ chế fix lỗi đặc biệt**: Được bảo vệ bởi `TrackingBoundary.json` (SHA256: `8de12daeec3b0303f8161b2e5cca3dc21a72960399055a539e8553d61f4c5f8e`).

#### `YOLODetectionEngine.swift`
- **Chức năng cốt lõi**:
  - Tải và điều phối các mô hình Core ML gia tốc ANE: `yolo12s`, `yolo12n`, `yolov26_416_fp16`, `yolov26_ane`.
  - Nhận diện toàn diện 80 lớp đối tượng chuẩn COCO (người, động vật, xe cộ, đồ đạc, hoa quả...).
  - Quản lý bộ đệm `CVPixelBufferPool` có khóa an toàn, tự động co giãn kích thước đầu vào (416x416 hoặc 640x640) giữ đúng tỷ lệ hình học.
- **Cơ chế fix lỗi gần đây**:
  - Đã fix lỗi tràn kích thước ANE input resizing guard và triệt tiêu phát hiện người ảo (phantom person detection) khi chỉ có nhiễu nền.

#### `NeuralSubjectIntelligenceEngine.swift`
- **Chức năng cốt lõi**:
  - Phân tích ngữ cảnh ảnh tĩnh chụp một chạm bằng Google SigLIP (`SigLIPBaseImage.mlmodelc` + `SigLIPPrompts.json`), giải phóng model ngay khi phân tích xong để tiết kiệm RAM.
  - Phân loại chủ thể chính (Hero Subject Policy): Tính điểm diện tích, danh mục, liên kết khuôn mặt với thân mình, mật độ chú ý, độ tương phản cục bộ.
  - Phát hiện tư thế cơ thể `VNDetectHumanBodyPoseRequest` kết hợp `PortraitFramingEvidence` để xác định đường cắt thân mình an toàn cho ảnh chụp chân dung (tránh cắt trúng khuỷu tay/cổ tay).
- **Cơ chế fix lỗi gần đây**:
  - Đã fix thứ tự khai báo `faceCandidates`, gán mutable cho `boundingBox`, bảo vệ nhóm người và giữ góc rộng cho phong cảnh/toàn cảnh.

#### `PhotographicCompositionModel.swift` & `CharmPhotographicModel.swift`
- **Chức năng cốt lõi**:
  - `PhotographicCompositionModel`: Mô hình SAMP-Net (BMVC 2021) chấm điểm bố cục 5 mức trên tập CADB, kết hợp bản đồ chú ý quang phổ `SpectralCompositionSaliency` và tiền xử lý ảnh bilinear Pillow-compatible 224x224.
  - `CharmPhotographicModel`: Mô hình Charm (2025) DINOv2-small 21.5M tham số đánh giá thẩm mỹ ảnh nhiếp ảnh PARA (9-bin distribution), sử dụng embedding vị trí nội suy bicubic.
  - Kết hợp trọng số chuẩn: 0.45 SAMP-Net + 0.40 Charm + 0.15 Hình học. Điều kiện crop zoom > 1.08x phải cải thiện điểm tối thiểu +0.008 (`prefersCrop`).

#### `RealtimeHistogramEngine.swift`
- **Chức năng cốt lõi**:
  - Tính biểu đồ quang phổ 32 băng tần Rec.709 ($Y = 0.2126R + 0.7152G + 0.0722B$) ở tốc độ 60 FPS, tiêu thụ CPU dưới 0.3%.
  - Bộ lọc làm mượt bất đối xứng: Tăng nhanh bắt sáng ($\alpha = 0.45$), giảm chậm giữ hình ($\alpha = 0.22$).

---

### 2.3. Tầng Bố cục & Điều phối (Intelligence & ViewModel)

#### `CompositionCalculator.swift` (Đã hoàn thiện Phase 3 & Phase 4: AI Multi-Hypothesis Composition & Virtual Crop Zoom Scorer)
- **Chức năng cốt lõi**:
  - Chứa `LocalFramingPlan`, `FramingTargetResult`, `SceneCompositionEvidence`, `VirtualCropZoomScore`, `VirtualCropZoomDecision`.
  - **Vá 5 Lỗ hổng Kỹ thuật Phase 3**:
    1. *Cadence Throttling*: Nhịp nhanh (Face, Human, YOLO) chạy mỗi frame; Nhịp chậm (Horizon, Classify, Saliency, Mask) chạy mỗi 5 frame để bảo vệ ANE, giữ vững 60 FPS không nóng máy.
    2. *Hệ trục tọa độ chuẩn*: Đồng nhất hệ tọa độ Upright Screen (y=0 ở đỉnh trên, y=1 ở đáy dưới) trên toàn bộ pipeline; điểm neo mắt/đầu người tại `y = minY + height * 0.28` (dải Y ~ 0.33 - 0.39).
    3. *Quán tính chủ thể (Subject Persistence)*: Thưởng điểm +0.25 duy trì cho chủ thể frame trước; triệt tiêu ưu tiên của khuôn mặt nhỏ ở xa khi có chủ thể lớn ở tiền cảnh.
    4. *Horizon X/Y Decoupling*: Nếu cảnh phẳng không có điểm tụ ngang, đặt `P_grid.x = S_anchor.x` ($\Delta X = 0$) để chỉ dẫn chỉnh góc ngẩng/cúi mà không ép lia ngang vô lý.
    5. *Đóng gói SceneCompositionEvidence*: Truyền trực tiếp `primarySubjectRect`, `focalSaliencyRatio`, `edgeClutterScore` sang Phase 4.
  - **Triết lý Phase 4 - Đấu loại Khung cắt Ảo Đa Tỷ lệ (`evaluateVirtualCropZooms`) & Vá 4 Lỗi Toán học**:
    - Mô phỏng các khung cắt ảo $W(Z)$ tương ứng với các mức zoom quang học $\{1x, 2x, 3x\}$.
    - **Sửa Lỗi 1 (Linear Occupancy 1D thay vì Diện tích 2D)**: Đánh giá độ lấp đầy theo kích thước tuyến tính 1D ($baseLinearSize_{1x} = height$ cho người/chân dung, $\max(w, h, \sqrt{area})$ cho vật thể/động vật) để tránh việc người đứng chiếm 60% chiều cao (diện tích 12%) bị ép zoom quá đà làm tràn khung. Mức tối ưu: $0.40 - 0.65$ (chân dung/vật thể), $0.20 - 0.40$ (toàn cảnh).
    - **Sửa Lỗi 2 (Chuẩn hóa về Hệ Quy chiếu 1x Gốc)**: $baseLinearSize_{1x} = size / currentZoom$; tỷ lệ phóng đại tương đối khi thử zoom $Z$ là $relativeScale = Z / currentZoom$.
    - **Sửa Lỗi 3 (Mô phỏng Toàn vẹn Chủ thể SAU KHI Căn Khớp P_grid* & Tinh chỉnh Bán thân)**: Tính vị trí bounding box sau khi dịch neo về $P_{grid}^*$ với tỷ lệ $k = relativeScale$:
      $placedMinY = P_{grid}^*.y - topOffset \cdot k$, $placedMaxY = P_{grid}^*.y + bottomOffset \cdot k$, $placedMinX = P_{grid}^*.x - leftOffset \cdot k$, $placedMaxX = P_{grid}^*.x + rightOffset \cdot k$.
      - *Đỉnh trên & Hai biên*: Kiểm tra Headroom ($placedMinY \ge 0.04$) và an toàn viền trái/phải $[0.03 \dots 0.97]$, phạt nặng ($-1.80$ đến $-2.50$) cho mọi thể loại chủ thể.
      - *Cạnh dưới ($placedMaxY > 0.97$)*: Phạt nặng cho Khuôn mặt, Động vật, Vật thể; **riêng Thân người (`human`)**: miễn phạt tràn đáy cho phần chân để cho phép AI zoom $2x/3x$ chụp **Chân dung Bán thân (Medium / Half-body Shot)**, chỉ phạt nếu ngực trên ($P_{grid}^*.y + 0.18 > 0.96$) bị cắt; giới hạn phần thân trên ảo ($projectedLinearSize 	imes 0.45 \le 0.85$).
    - **Sửa Lỗi 4 (Pre-Zoom Target Projection theo Hình học Quang học)**:
      $$Target.x = S_{anchor}.x - rac{P_{grid}^*.x - 0.5}{k}$$
      $$Target.y = S_{anchor}.y - rac{P_{grid}^*.y - 0.5}{k}$$
      với $k = \max(0.5, Z^* / currentZoom)$. (Chứng minh: Khi người dùng căn $(0.5, 0.5)$ vào Target, neo dịch đến $0.5 + (P_{grid}^* - 0.5)/k$. Khi ống kính zoom quang học $k	imes$ quanh tâm $(0.5, 0.5)$, tọa độ giãn nở $k$ lần và đáp chính xác $100\%$ vào $P_{grid}^*$).
    - *Quán tính Chống Nhảy Zoom (Zoom Momentum / Hysteresis)*: Thưởng +0.22 cho mức zoom hiện tại; mức zoom mới chỉ thắng khi vượt trội rõ rệt.
  - **Đồng bộ Hard Lock (Phase 1) với Zoom (Phase 4)**:
    Khi người dùng đưa tâm trắng khớp vào Target (chốt cứng Target tại tâm 0.5, 0.5), hệ thống lập tức kích hoạt zoom quang học chuyển mượt đến mức $Z^*$ do AI chỉ định.

#### `CompositionPureCalculations.swift`
- **Chức năng cốt lõi**:
  - Tập hợp toàn bộ các hàm toán học thuần túy (Pure Functions), độc lập hoàn toàn với camera và UI.
  - `decodeYOLORawBox`: Giải mã box từ tâm (cx, cy) và kích thước (w, h) không clamp bừa bãi.
  - `validateAndClipBox`: Xác thực tính hợp lệ và tỷ lệ hiển thị của box ($\ge 75\%$).
  - `visionToUprightRect` & `uprightToVisionRect`: Chuyển đổi qua lại giữa hệ tọa độ Vision (gốc dưới-trái) và hệ tọa độ Upright (gốc trên-trái).
  - `calculateIntrinsics`: Tính tiêu cự $f_x, f_y$ chính xác từ góc nhìn camera `videoFieldOfView` và tỷ lệ khung hình.
  - `calculateContinuousIdealZoom`: Công thức tính zoom lý tưởng liên tục có giới hạn an toàn mép màn hình (`edgeSafetyMargin = 0.05`).
  - `slerpPose` & `interpolateHistoricalPose`: Nội suy quaternion slerp an toàn có chốt chặn chống chia cho 0 (`minDt = 1e-6`) và kiểm tra khoảng cách mẫu IMU.

#### `CompositionTuning.swift`
- **Chức năng cốt lõi**:
  - Bảng hằng số và ngưỡng giá trị tập trung cho toàn dự án:
    - Ngưỡng YOLO confidence: `0.48`.
    - Trục tỷ lệ vàng: `0.36` và `0.64`.
    - Đường mắt chân dung chuẩn: `0.36`.
    - Hệ số nhìn Lead Room: `0.15`.
    - Diện tích mong muốn: Chân dung `0.28`, Cận cảnh `0.32`, Nhóm `0.36`, Phong cảnh `0.15`.
    - Góc nhìn camera mặc định: Wide `69.0°`, UltraWide `120.0°`, Telephoto `30.0°`, Front `70.0°`.
    - Ngưỡng Mahalanobis: `16.0` và `25.0`.

#### `CompositionPlanning.swift`
- **Chức năng cốt lõi**:
  - Tạo và tinh chỉnh các đề xuất bố cục (`photographicProposals`).
  - `CompositionAimGeometry`: Tính góc lệch quaternion giữa hướng bám của chủ thể và góc ngắm điện ảnh được chọn.
  - `CompositionCropProtection`: Bảo vệ thân mình cho ảnh chân dung, bảo vệ toàn bộ nhóm bạn đi cùng (`protectedBounds`) và loại trừ các đối tượng ngẫu nhiên (`incidentalBounds`).

#### `CameraViewModel.swift`
- **Chức năng cốt lõi**:
  - Trục điều phối trung tâm MVVM trên `@MainActor`.
  - Quản lý toàn bộ cỗ máy trạng thái `aiSessionState`.
  - Lắng nghe và điều phối luồng ảnh từ `CameraServiceDelegate`, luồng con quay hồi chuyển từ `DeviceMotionService`, và luồng bám bắt từ `SpatialTrackingEngine`.
  - `pinTargetAndStartMotion`: Điểm khởi đầu ghim mục tiêu và chuyển động. (Được bảo vệ nghiêm ngặt bởi `TrackingBoundary.json`).
  - `evaluateAlignment(at:)`: Đánh giá khoảng cách căn tâm giữa tâm quang học và điểm ngắm bố cục, kích hoạt `AlignmentCaptureGate`.
    - **Cơ chế Khóa Cứng & Chống Trôi Target (Phase 1 Fix Lỗi 2)**:
      - Thuộc tính: isTargetLocked: Bool, lockedTargetPosition: CGPoint = (0.5, 0.5), lockedDevicePose: simd_quatd?, 	argetUnlockAngleThreshold: Double = 0.10 rad (~5.73°).
      - Khi isPerfectAlignment đạt (khoảng cách tâm <= snapThreshold): Kích hoạt lockHardTarget(), chốt cứng currentTargetPoint = (0.5, 0.5), phát rung HapticFeedbackService.shared.triggerMagneticSnap(), và đóng băng toạ độ UI hoàn toàn khỏi các cập nhật trôi dạt của AI/Tracking.
      - Điều kiện mở khóa an toàn unlockHardTargetLock(): Tự động mở khi chụp xong ảnh (didCapturePhoto), khi huỷ/reset phiên (startAISession, cancelAISession, suspendSpatialTracking, pinTargetAndStartMotion, userDidTapToFocus, unlockAEAF), hoặc khi người dùng chủ động lia máy đi chỗ khác với góc quay tích lũy Gyro >= 0.10 rad (hasUserPannedAwayFromLock()).
    - **Bộ Lọc Làm Mượt Chống Nhảy Target & Deadband (Phase 2 Fix Lỗi 1)**:
      - ilterSmoothedTargetPoint(newPoint:dt:gyroSpeed:):
        1. **Deadband chống rung vi mô**: Nếu độ lệch $\\Delta d < 0.004$ và vận tốc góc Gyro $< 0.15$ rad/s, giữ nguyên vị trí cũ prev, triệt tiêu hoàn toàn rung lắc li ti do nhiễu pixel.
        2. **Slew-Rate Limiter & Adaptive Clamping**: Khi máy tĩnh/chậm mà mục tiêu từ AI nhảy đột ngột, giới hạn bước dịch chuyển mỗi frame (vận tốc tối đa 0.60 units/s theo dt) để tâm lướt êm ái thay vì nhảy cóc; khi người dùng vẩy máy nhanh ($\\ge 0.35$ rad/s), tốc độ giới hạn tự động nâng cao theo vận tốc Gyro để bắt kịp chuyển động lia máy.
  - `savePhotoToLibrary`: Lưu ảnh vào PhotoKit với kiến trúc tài nguyên kép (Dual-Resource Asset) - tệp RAW DNG nguyên bản kèm JPEG xem trước chuẩn Display P3 vào Album "Align Studio".

---

### 2.4. Tầng Giao diện (Views/HUD)

#### `ARFramingOverlayView.swift`
- **Chức năng cốt lõi**:
  - Vẽ lớp phủ đồ họa AR: Lưới bố cục tỷ lệ vàng, khung nhận diện chủ thể `CornerBracketsShape`, vòng tròn mục tiêu vàng di động (`TargetCircleView`), tâm ngắm trắng cố định (`CurrentCenterCrosshair`), đường ray dẫn đường (`GuidanceRayLine`).
  - Hiển thị Focus Peaking viền nét mờ, thước đo cân bằng chân trời (`HorizonLevelerView`), hộp ngắm vàng kèm thanh trượt phơi sáng hình mặt trời.
  - Hiệu ứng `ZoomRevealOverlay`: Hiển thị khung cắt trung tâm và làm mờ viền ngoài mượt mà trước khi kích hoạt ống kính zoom vật lý.
- **Cơ chế fix lỗi gần đây**:
  - Ẩn hoàn toàn dấu chấm tròn / tâm ngắm khi ở trạng thái nghỉ (`idle`) để không gây vướng mắt khi người dùng chưa bật tính năng AI.

#### `CameraMainView.swift`
- **Chức năng cốt lõi**:
  - Giao diện chính theo phong cách Obsidian Minimalist Pro.
  - `CameraFormFactorLayout`: Tính toán bố cục giao diện co giãn theo giới hạn màn hình (Screen-Bounded Responsive Layout), hỗ trợ mượt mà từ iPhone SE 2/3 (375x667) đến iPhone 16 Pro Max (430x932).
  - Tách biệt rõ ràng tỷ lệ Viewfinder: 4:3 cho chế độ Chụp Ảnh và 16:9 cho chế độ Quay Video (chuẩn cảm biến 4K/1080P, tuyệt đối không bị méo).

#### `CameraControlsView.swift`
- **Chức năng cốt lõi**:
  - Cụm nút điều khiển 3 cột đối xứng: Cột trái (Nút xem Album), Cột giữa (Nút chụp màn trập tối giản căn chính giữa trục màn hình), Cột phải (Nút lật camera trước/sau).
  - Hàng thứ 2: Nút AI (Asset `nutAI`), Bộ chuyển chế độ ẢNH / VIDEO, và Nút mở khay màu phim.

#### `LiveColorHistogramHUDView.swift`
- **Chức năng cốt lõi**:
  - Hiển thị biểu đồ Waveform phổ màu RGB liên tục (SwiftUI Canvas) với 3 đường cong Red, Green, Blue và các sợi chỉ phổ màu (Spectral Needles).
  - Cho phép chạm để chuyển đổi nhanh định dạng ảnh giữa RAW DNG, HEIF và JPEG.

---

## 3. CÁC QUY ƯỚC KỸ THUẬT VÀ NGUYÊN TẮC BẢO VỆ MÃ NGUỒN

### 3.1. Quy ước Luồng & Quản lý Hàng Đợi (Threading & Queues)

| Tài nguyên / Tác vụ | Hàng đợi quản lý (Queue) | Quy tắc an toàn |
| :--- | :--- | :--- |
| `AVCaptureSession`, cấu hình camera | `CameraService.sessionQueue` (serial) | Mọi truy cập `AVCaptureDevice` phải qua `scheduleDeviceConfiguration`, không block main |
| Nhận dữ liệu frame camera thô | `CameraService.videoDataQueue` (serial) | Luôn drop frame muộn, không bao giờ xử lý nặng trực tiếp trên hàng đợi này |
| Xử lý Vision & Tracking quang học | `VisionFramingEngine.visionQueue` (serial) | `autoreleaseFrequency: .workItem`, cờ hủy `cancellation` kiểm tra thường xuyên |
| Dữ liệu con quay hồi chuyển CoreMotion | `DeviceMotionService.queue` (serial) | Bảo vệ bằng `NSRecursiveLock`, callback phát ngoài lock, không đợi MainActor |
| Chấm điểm bố cục chuyên sâu (SAMP/Charm) | `Task.detached` / Worker Queue | Tuần tự hóa, giải phóng model SigLIP trước khi nạp SAMP/Charm |
| Cập nhật trạng thái hiển thị SwiftUI | `CameraViewModel` (`@MainActor`) | Chỉ cập nhật `@Published` trên MainActor |

### 3.2. Quản lý Bộ nhớ và Tài nguyên GPU/ANE

1. **Không tạo rò rỉ bộ đệm CVPixelBuffer**: Mọi thao tác truy cập địa chỉ cơ sở (`CVPixelBufferGetBaseAddress`) bắt buộc phải có `defer { CVPixelBufferUnlockBaseAddress(...) }`.
2. **Tái sử dụng CIContext**: Không khởi tạo `CIContext` mới trong mỗi khung hình. Sử dụng context dùng chung gắn với Metal device (`CIContext(mtlDevice: options:)`).
3. **Giải phóng mô hình Core ML**: Các mô hình nặng (`SigLIPBaseImage`, `Charm`, `SAMPComposition`) chỉ được nạp khi có yêu cầu phân tích một chạm (one-shot), giải phóng ngay khi hoàn thành để nhường RAM cho hệ điều hành.

### 3.3. Quy ước Hệ Tọa Độ & Hình Học

- **Hệ tọa độ Vision**: Gốc $(0, 0)$ ở góc **Dưới - Trái**, $x$ sang phải $[0, 1]$, $y$ hướng lên $[0, 1]$.
- **Hệ tọa độ Upright (Chuẩn nội bộ dự án)**: Gốc $(0, 0)$ ở góc **Trên - Trái**, $x$ sang phải $[0, 1]$, $y$ hướng xuống $[0, 1]$.
- **Chuyển đổi qua lại**:
  $$y_{\text{upright}} = 1.0 - y_{\text{vision}} - \text{height}$$
  $$y_{\text{vision}} = 1.0 - y_{\text{upright}} - \text{height}$$
- **Hệ tọa độ màn hình (Screen Space)**: Áp dụng phép chiếu tương thích tỷ lệ tràn viền AspectFill qua `TrackingGeometry.screenPoint`.

### 3.4. Ranh giới Khóa Mã Nguồn (Boundary Protection Manifests)

Dự án cài đặt hệ thống kiểm tra tự động mã băm SHA-256 qua script `scripts/verify_tracking_boundary.py`.
- **`tests/TrackingBoundary.json`**: Bảo vệ 17 khối mã nguồn cốt lõi của hệ thống tracking và cổng căn tâm (VisionFramingEngine, SpatialTrackingEngine, TargetPatchFlow, TrackingGeometry, CameraService, v.v.).
- **`tests/PhotographicDetectionBoundary.json`**: Bảo vệ 3 khối mã nguồn của hệ thống nhận diện và gom nhóm chủ thể.
- **Yêu cầu nghiêm ngặt**: Khi chỉnh sửa code, **TUYỆT ĐỐI KHÔNG** làm thay đổi bất kỳ ký tự nào trong các vùng được bảo vệ, trừ khi có yêu cầu nâng cấp được phê duyệt rõ ràng kèm theo việc cập nhật hash manifest.

---

## 4. DANH MỤC LỆNH KIỂM TRA HỒI QUY (VERIFICATION SUITE)

Mọi thay đổi trong dự án phải được kiểm chứng qua các lệnh sau trên môi trường máy tính:

```powershell
# 1. Kiểm tra ranh giới mã nguồn được bảo vệ (Bắt buộc PASS 100%)
python scripts/verify_tracking_boundary.py

# 2. Kiểm tra cân bằng dấu ngoặc trong toàn bộ 64 file Swift
python scripts/check_swift_brackets.py

# 3. Kiểm tra tính toán bố cục co giãn trên 4 kích thước iPhone
python scripts/check_responsive_layout.py

# 4. Chạy toàn bộ 68 ca test hồi quy tính toán thuần túy
python scripts/run_regressions.py
```
---

## 5. LỊCH SỬ PHÁT HÀNH & KẾT QUẢ CI/CD BUILD RELEASE

### Bản phát hành gần nhất: `v1.0.0-build.494`
- **Thời gian hoàn tất**: Tháng 10/2026 (CI Run ID: `39568246961`, Commit: `6b31eed`).
- **Nền tảng build**: macOS-15 runner, Xcode 16.0, Swift 6 compatible.
- **Trạng thái**: **100% PASS (Exit Code 0, 0 Errors, 0 Warnings)**.
- **Tập tin phát hành**:
  - `AISmartFramingCamera.ipa` (Đã tích hợp đầy đủ 5 mô hình CoreML: YOLO12s, YOLO12n, SigLIP, SAMP-Net, Charm).
  - `AISmartFramingCamera-SourceCode.zip`.
  - Link tải tốc độ cao: `https://gh-proxy.com/https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/download/v1.0.0-build.494/AISmartFramingCamera.ipa`.
- **Tóm tắt tính năng được xác thực**:
  1. *Phase 1*: Hard Lock chốt tâm $(0.5, 0.5)$ khi căn khớp, chống trôi mục tiêu, góc quay Gyro dynamic thoát khóa theo Zoom/FOV.
  2. *Phase 2*: Bộ lọc làm mượt Dynamic EMA + Deadband vi mô $< 0.004$ + Slew-rate limiter theo vận tốc Gyro.
  3. *Phase 3*: Đa giả thuyết bố cục cạnh tranh động (`evaluateHypotheses`), ANE Cadence Throttling (Fast 60fps vs Slow 4-5Hz), Upright coordinate, Quán tính chủ thể +0.25 IoU, Horizon Decoupling $\Delta X = 0$.
  4. *Phase 4*: Đấu loại khung cắt ảo đa tỷ lệ (`evaluateVirtualCropZooms`), kích thước tuyến tính chuẩn hóa 1D `linearOccupancy`, chuẩn hóa 1x, mô phỏng toàn vẹn sau căn khớp kèm **quy tắc chân dung bán thân Medium Shot**, Pre-Zoom Target Projection theo quang học.
