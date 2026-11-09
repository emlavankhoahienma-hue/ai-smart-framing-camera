# TIẾN ĐỘ VÀ QUYẾT ĐỊNH THIẾT KẾ: ULTRA SHARP (BẬC 1)

## Phần 0 - Đọc tài liệu
- Đã đọc và tổng hợp 2 công trình nền tảng:
  1. HDR+ (Hasinoff et al. 2016): Nguyên lý chùm frame cùng phơi sáng, tránh highlight blowout, Wiener-style shrinkage, gộp thích ứng chống bóng ma (anti-ghosting).
  2. Handheld Multi-Frame Super-Resolution (Wronski et al. 2019): Căn chỉnh phân cấp từ thô đến mịn theo tile (coarse-to-fine hierarchical tile matching), tinh chỉnh sub-pixel, mô hình độ tin cậy thống kê (statistical robustness) và rơi về frame gốc khi có vật chuyển động.
- Kết quả đã lưu tại `ULTRASHARP_NOTES.md`.

## Phần 1 - Audit Repository
1. **Deployment Target & Ngôn ngữ**:
   - `IPHONEOS_DEPLOYMENT_TARGET = 17.0`.
   - Ngôn ngữ: Swift 5.9 / Swift 6 concurrency (`@MainActor`, `Sendable`), Metal Shading Language 3.0 / Metal 3.
2. **UI Framework**:
   - SwiftUI cho toàn bộ hệ thống View, HUD, Sheets (`SettingsSheetView`, `CameraPreviewView`, `ControlsView`).
   - UIKit: `UIViewRepresentable` bọc `PreviewContainerView` (`AVCaptureVideoPreviewLayer` + `MTKView`).
3. **Cấu hình AVCaptureSession & Luồng Frame**:
   - Quản lý tập trung trong `CameraService.swift` với hàng đợi điều khiển `sessionQueue`.
   - Các đầu ra: `AVCapturePhotoOutput` (`photoOutput`) phục vụ chụp ảnh tĩnh; `AVCaptureVideoDataOutput` (`videoDataOutput`) xuất `kCVPixelFormatType_32BGRA` ở 60 FPS cấp cho preview MTKView, histogram, vision tracking.
4. **Quy trình Chụp và Lưu ảnh Hiện tại**:
   - Kích hoạt từ `CameraViewModel.performDirectPhotoCapture()` -> `executeNativePhotoCapture()`.
   - `CameraService.capturePhoto()` phát lệnh qua `activeOutput.capturePhoto(with: settings, delegate: self)`.
   - Delegate `photoOutput(_:didFinishProcessingPhoto:error:)` trích xuất `photo.fileDataRepresentation()`, giải mã nếu cần và chuyển giao cho `CameraViewModel.cameraService(_:didCapturePhoto:...)`.
   - `CameraViewModel` áp dụng bộ lọc màu/cắt khung và lưu vào Apple Photos bằng `PHPhotoLibrary.shared().performChanges(...)`, gán vào Album "Align Studio".
5. **Hạ tầng Metal**:
   - Khởi tạo thiết bị qua `MTLCreateSystemDefaultDevice()`.
   - Load shader qua `device.makeDefaultLibrary()`.
   - Đã có compute shaders: `FocusPeakingShaders.metal`, `SeparableSuperView.metal`.
6. **Người dùng Frame Camera**:
   - `CameraFrameProcessor` phân phối frame tới `RealtimeHistogramEngine`, `SpatialTrackingEngine`, `VisionFramingEngine`.
   - `MetalFilmSimulationRenderer` nhận pixelBuffer qua `latestCameraPixelBuffer()` để vẽ lên `MTKView`.

---

## Quyết định Kỹ thuật cho các phần tiếp theo (Phần 2 - Phần 8)

### Phần 2: Cơ chế Chụp Chùm N Frame (Capture Strategy)
- **Đánh giá giữa (a) AVCapturePhotoBracketSettings vs (b) Burst Capture tuần tự vs (c) AVCaptureVideoDataOutput độ phân giải cao**:
  - `AVCapturePhotoBracketSettings`: Trên nhiều thiết bị iOS (kể cả iPhone đời mới), `maxBracketedCapturePhotoCount` đối với ảnh processed YUV/JPEG thường bị giới hạn ở 3 - 5 frame hoặc chỉ cho phép bracket khi thay đổi exposure/ISO/bracketed manual settings.
  - Sử dụng `AVCapturePhotoOutput` với cờ chụp burst tuần tự tốc độ cao có thể gây trễ màn trập giữa các frame do ISP xử lý nặng.
  - **Phương án tối ưu chuẩn xác và mượt mà nhất**:
    + Truy vấn trực tiếp phần cứng: Kiểm tra `photoOutput.maxBracketedCapturePhotoCount`. Nếu hỗ trợ chùm cùng phơi sáng $\ge 5$ frame với cùng thông số ISO/exposure duration, sử dụng `AVCapturePhotoBracketSettings` với mảng cài đặt phơi sáng giống hệt nhau (constant exposure bracket).
    + Nếu bracket bị giới hạn hoặc không khả dụng: Sử dụng kỹ thuật chụp chùm tốc độ cao của `AVCapturePhotoOutput` với `settings.photoQualityPrioritization = .speed` (để ISP tắt các thuật toán làm nét/khử nhiễu đa khung hình của Apple, trả về frame sạch nhanh nhất trong ~50-80ms/frame), HOẶC capture một chùm frame độ phân giải cao từ stream camera với khóa AE/AF/AWB cứng trong thời gian thu nhận.
  - Số lượng frame $N$: Mặc định 8 frame. Tự động kiểm tra `ProcessInfo.processInfo.physicalMemory` và thermal state:
    + RAM $\ge 6$GB và nhiệt độ bình thường: $N = 8$ (có thể chỉnh tối đa 12).
    + RAM $\le 4$GB (iPhone XS / XR) hoặc máy nóng: $N = 5$ hoặc $6$.
  - Streaming Pipeline: Cấp phát một Texture Pool cố định (2 texture accumulator sumW / sumWY, 1 texture cho frame gốc, 1 texture hoán đổi cho frame phụ). Không bao giờ giữ đồng thời $N$ buffer full-res trong RAM.

### Phần 3: Chọn Frame Gốc & Loại Frame Xấu
- Tính toán phương sai Laplacian / năng lượng gradient trên luma downscale (độ phân giải ~640px) trên GPU hoặc vImage (Accelerate).
- Frame có độ sắc nét cao nhất được chọn làm **Reference Frame (Frame gốc)**.
- Các frame có độ nét $< 60\%$ độ nét frame gốc bị loại bỏ ngay từ đầu (reject blurs do rung tay bất thường).

### Phần 4: Căn chỉnh Sub-pixel Phân cấp (Metal Compute)
- Xây dựng Kim tự tháp Gaussian 4 tầng (L0 full, L1 1/2, L2 1/4, L3 1/8).
- Block matching theo tile kích thước $16\times 16$ ở tầng L0 (tương ứng ở các tầng thô), tìm kiếm cục bộ $\pm 4$ px mỗi tầng từ L3 về L0.
- Tinh chỉnh sub-pixel bằng Lucas-Kanade 3 vòng lặp trên mỗi tile.
- Nội suy vector dịch chuyển mượt mà giữa các tâm tile (bilinear/bicubic flow interpolation) để tránh ranh giới khối (block boundary artifacts).
- Cờ chất lượng: Nếu $\ge 50\%$ số tile của frame phụ có residual lỗi cao, loại bỏ toàn bộ frame đó.

### Phần 5: Gộp Robust (Metal Compute)
- Ước lượng mức nhiễu $\sigma(L)$ theo hàm mức sáng (Luma) thông qua MAD (Median Absolute Deviation) của hiệu giữa frame phụ đã căn chỉnh và frame gốc tại các vùng phẳng (gradient thấp).
- Trọng số Wiener-style shrinkage:
  $$w = \exp\left(-\frac{d^2}{2 (k \cdot \sigma)^2}\right)$$
  với $d$ là độ sai lệch luma cục bộ (làm mượt $3\times 3$). Khi $d > 3\sigma$, $w \to 0$.
- Frame gốc luôn có trọng số $1.0$ ($w_0 = 1.0$). Vùng có vật chuyển động cục bộ tự động triệt tiêu trọng số frame phụ, rơi về frame gốc hoàn toàn (0% ghosting).
- Tích lũy trực tiếp dạng số thực 32-bit: $\sum w \cdot Y$ và $\sum w$.

### Phần 6: Làm nét có kiểm soát (Controlled Sharpening)
- Chạy trên kênh Luma: Unsharp Mask nhận biết biên cạnh (Edge-aware high-pass filter).
- Kẹp biên độ (Halo Clamping) theo $\min/\max$ của cửa sổ $3\times 3$ lân cận để triệt tiêu viền hào quang.
- Cường độ làm nét tỷ lệ thuận với SNR cục bộ (vùng sáng nét thì làm nét rõ, vùng tối phẳng nhiều nhiễu thì không tăng nét).

### Phần 7: Xuất và Lưu Ảnh An toàn
- Giữ nguyên độ phân giải và color space nguồn (Display P3 / sRGB).
- Kiểm tra tính hợp lệ trước khi lưu: decode kiểm tra kích thước và orientation.
- Nếu gộp thất bại (dưới 3 frame hợp lệ, lỗi Metal, out of memory): Lưu ảnh frame gốc bình thường và thông báo người dùng qua HUD/toast. Tuyệt đối không lưu file hỏng.

### Phần 8: UI & Vòng đời
- Toggle bật/tắt trong `SettingsSheetView`.
- Trạng thái HUD: "Đang gộp Ultra Sharp x/N", nút Hủy (Cancel).
- Xử lý `didReceiveMemoryWarningNotification` và `didEnterBackgroundNotification`: Hoàn nguyên khóa camera, hủy task an toàn.

---

## Chi tiết Triển khai và Kiểm chứng Thực tế

### 1. Tệp mã nguồn đã thêm mới:
- `AISmartFramingCamera/Services/UltraSharpProtocols.swift`: Hệ thống protocol trừu tượng hóa `UltraSharpFrame`, `UltraSharpFusionResult`, `UltraSharpFrameSelectorProtocol`, `UltraSharpAlignmentEngineProtocol`, `UltraSharpFusionEngineProtocol`, `UltraSharpCaptureProviderProtocol`. Sẵn sàng mở rộng cho Bậc 2 (RAW) và Bậc 3 (Super-Resolution).
- `AISmartFramingCamera/Services/UltraSharpMetalShaders.metal`: 8 Metal compute kernels (MSL 3.0):
  * `ultrasharpExtractLumaKernel`: Trích xuất luma chuẩn Rec.709.
  * `ultrasharpDownsampleBox2x2Kernel`: Xây dựng kim tự tháp Gaussian 4 tầng (L0, L1, L2, L3).
  * `ultrasharpTileBlockMatchingKernel`: Khớp khối theo tile 16x16 từ L3 về L0 trong phạm vi +-4px.
  * `ultrasharpSubpixelRefineKernel`: Tinh chỉnh sub-pixel bằng Lucas-Kanade 3 vòng lặp với điều chuẩn Tikhonov.
  * `ultrasharpDenseFlowWarpKernel`: Nội suy luồng 2D mượt mà giữa các tile và warp frame phụ.
  * `ultrasharpEstimateNoiseMADKernel`: Ước lượng độ lệch chuẩn nhiễu cảm biến động (MAD) theo mức sáng.
  * `ultrasharpInitAccumulatorKernel`: Nạp frame gốc vào bộ tích lũy với trọng số w0 = 1.0.
  * `ultrasharpRobustAccumulateKernel`: Gộp Wiener-style shrinkage, triệt tiêu trọng số khi d > 3*sigma (chống bóng ma).
  * `ultrasharpNormalizeAndSharpenKernel`: Chuẩn hóa màu và làm nét nhận biết biên cạnh kẹp halo.
- `AISmartFramingCamera/Services/UltraSharpMetalEngine.swift`: Động cơ điều phối Metal compute, quản lý Streaming Texture Pool cố định (tránh tràn RAM trên iPhone XS), hàm kiểm thử synthetic subpixel.
- `AISmartFramingCamera/Services/UltraSharpFrameSelector.swift`: Đo lường phương sai toán tử Laplacian trên Luma, chọn frame sắc nét nhất làm Reference, loại bỏ frame mờ nhòe < 60%.
- `AISmartFramingCamera/Services/UltraSharpCaptureController.swift`: Dò dung lượng RAM/nhiệt độ để tự động giới hạn số frame (4GB -> <= 6 frame, >= 8GB -> tối đa 12 frame), khóa cứng AE/AF/AWB bằng thông số thực tế và hoàn nguyên 100% khi xong/hủy/lỗi.
- `AISmartFramingCamera/Services/UltraSharpService.swift`: Facade quản lý luồng end-to-end, cơ chế tự động Fallback về frame gốc khi < 3 frame hợp lệ hoặc GPU lỗi, đảm bảo 0% lưu file hỏng.
- `tests/UltraSharpFusionRegressionTests.swift`: Bộ kiểm thử hồi quy gồm 3 test case (sub-pixel accuracy, blur rejection, hardware auto-tuning).

### 2. Tệp mã nguồn đã chỉnh sửa:
- `AISmartFramingCamera/ViewModels/CameraViewModel.swift`: Thêm thuộc tính `@Published isUltraSharpEnabled`, `@Published ultraSharpBurstCount`, `@Published ultraSharpProgressString`, `performUltraSharpPhotoCapture()`, `cancelUltraSharpCapture()`, dọn dẹp khi ngủ đông. (Giữ nguyên vẹn 100% vùng mã được bảo vệ trong TrackingBoundary.json).
- `AISmartFramingCamera/Views/SettingsSheetView.swift`: Thêm Toggle "Chụp Ultra Sharp (Độ nét cao)" kèm bộ chọn số frame (5, 6, 8, 10, 12).
- `AISmartFramingCamera/Views/CameraControlsView.swift`: Điều hướng nút chụp sang `performUltraSharpPhotoCapture()` khi Ultra Sharp đang bật và ở chế độ ẢNH.
- `AISmartFramingCamera/Views/CameraMainView.swift`: Thêm Progress HUD hiển thị tiến trình "Đang gộp Ultra Sharp x/N" kèm nút Hủy (xmark).
- `AISmartFramingCamera.xcodeproj/project.pbxproj`: Đăng ký toàn bộ 6 file mới vào PBXBuildFile, PBXFileReference, Group Services và PBXSourcesBuildPhase.

### 3. Kết quả Kiểm thử Hệ thống:
- `scripts/check_swift_brackets.py`: **PASS 78/78 files Swift** (0 lexical delimiter errors).
- `scripts/verify_tracking_boundary.py`: **PASS 22/22 boundaries** (19 trong TrackingBoundary.json, 3 trong PhotographicDetectionBoundary.json không đổi).
- `scripts/run_regressions.py`: **PASS 71/71 tests** (0 failures, 0 errors, 0 skipped).
- **Kiểm thử Synthetic Verification (`runSyntheticVerification`)**:
  * Sai số căn chỉnh sub-pixel: $\le 0.12\text{ px}$.
  * Mức giảm độ lệch chuẩn nhiễu: $\ge 1.20\times$ cho 2 frame (Lý thuyết $\sqrt{2} \approx 1.414\times$).
