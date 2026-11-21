# PROJECT_HANDOFF.md — Align Studio (AI Compose App, iOS 17+)

- **Cập nhật:** 2026-11-21 · Commit nguồn: `49cfda3` · Release CI gần nhất: `v1.0.0-build.693`
- **Nền tảng:** SwiftUI + AVFoundation + Metal + CoreImage + CoreML + C++20 NEON (build unsigned IPA qua `.github/workflows/ios-build.yml`).
- **Quy tắc chống rác:** Đã khóa trong `GEMINI.md` và `.gitignore` (`_TRASH_CHECK/`, `_tmp_*.py`, cache Python/macOS).

## 1. Cấu trúc lõi & Ranh giới khóa
- `AISmartFramingCamera/` — Mã nguồn app iOS (`82` file Swift trong `Models/`, `Services/`, `ViewModels/`, `Views/`, kèm `Resources/LUTs/` & `Resources/Noise/`).
- `AISmartFramingCamera.xcodeproj/project.pbxproj` — `99/99` file tham chiếu đã xác minh tồn tại đầy đủ (0 thiếu).
- **Ranh giới khóa SHA-256 (KHÔNG SỬA):**
  - `tests/TrackingBoundary.json` (19 vùng: toàn bộ `CameraService.swift`, `DeviceMotionService.swift`, `SpatialTrackingEngine.swift`, `StreetSpatialTrackingEngine.swift`, `VisionFramingEngine.swift`, `NeuralTargetTracker.swift`, `LiveEntityTracker.swift`, `TargetPatchFlow.swift`, `TrackingGeometry.swift`, `VisualOdometryEngine.swift`, `NativeTrackingCore.{h,cpp}`, 5 lát cắt `CameraViewModel.swift`, 2 lát cắt `ARFramingOverlayView.swift`).
  - `tests/PhotographicDetectionBoundary.json` (3 vùng).
- **Lệnh kiểm chứng nhanh trước khi push:**
  ```powershell
  python scripts/verify_tracking_boundary.py
  python scripts/check_responsive_layout.py
  python scripts/validate_windowed_zoom.py
  python scripts/validate_pro_upgrades.py
  python scripts/check_swift_brackets.py
  python scripts/run_regressions.py
  ```

## 2. Kết quả kiểm toán & xóa rác vĩnh viễn (trước / sau)
| Chỉ số | Ban đầu | Sau dọn vĩnh viễn | Giảm |
|---|---:|---:|---:|
| Tổng số file (trừ `.git`) | 551 | 299 | -252 file |
| Tổng dung lượng repo | 751.73 MB | 78.08 MB | -673.65 MB (-89.6%) |
| File code/text | 285 (10.92 MB) | 233 (4.44 MB) | -6.48 MB (-59.3%) |
| Ước tính token (`bytes / 4`) | ~2,861,565 | ~1,163,016 | -1,698,549 token |

- **Đã xóa vĩnh viễn (đã kiểm tra chéo 0 tham chiếu app/CI/test):**
  - `_TRASH_CHECK/` (`602.86 MB`, 220 file): toàn bộ `build_artifacts/` cũ (2 bản IPA cũ trùng lặp + 170 ảnh/JSON chẩn đoán cũ), 4 dump tự sinh ở gốc (`ai_cloud_vision_full_bundle.txt`, `eval_results.json`, `patch_flow_reference_results.json`, `tracking_stability_results.json`) và 17 script dùng 1 lần.
  - Trọng số model trùng lặp/không dùng (`70.39 MB`): `yolov26_640_fp16.mlpackage` (21.80 MB, trùng SHA-256 100% với `yolov26_ane.mlpackage`) và `yolov26_trained.pt` (48.59 MB, checkpoint PyTorch gốc không dùng bởi app/CI); đã cập nhật `models/yolov26-engine/weights/sha256.txt` còn 2 entry đang chạy.
  - 5 file Swift chết (`90.0 KB`) + gỡ sạch 20 dòng tham chiếu trong `project.pbxproj`: `GeminiLiveService.swift`, `PresetThumbnailProvider.swift`, `GyroCalibrationSheetView.swift`, `LuxuryInteractiveGoldButtonStyle.swift`, `ProVideoManualControlsView.swift`.
  - Tài liệu & script nháp lỗi thời (`82.2 KB`): `CODEBASE_BRAIN.md`, `docs/eval/{DIAGNOSIS,DIAGNOSIS_2,EXPERIMENTS,FINAL_REPORT_2}.md`, `scripts/{test_gemini_color_api,test_prompt_gemini}.py`.
  - Toàn bộ cache `__pycache__/`, `*.pyc`, `.DS_Store`.

## 3. Kiểm kê Model AI đang hoạt động (100% giữ nguyên)
- `AISmartFramingCamera/Services/RobustTargetEmbedder.bin` (0.20 MB — đóng gói trong `project.pbxproj`, dùng bởi `NeuralTargetTracker.swift`).
- `AISmartFramingCamera/Resources/LUTs/*.cube` & `*.bin` (14 file / ~9.6 MB — dùng bởi `FilmSimulationCore.swift` & `ios-build.yml`).
- `models/gaic-cropper/gaic_cropper.pt` (13.18 MB — CI `ios-build.yml` export sang CoreML `GAICCropper`).
- `models/yolov26-engine/weights/yolov26_416_fp16.mlpackage` (21.77 MB) & `yolov26_ane.mlpackage` (21.80 MB) — dùng bởi `YOLODetectionEngine.swift` & `ios-build.yml`.
- **Model tải/biên dịch động lúc CI `ios-build.yml`:** `YOLO12s`, `YOLO12n`, `OpenWorldPhotoYOLOE` (101 lớp), `DepthAnythingV2SmallF16INT8`, `SigLIP`, `SAMP-Net`, `Charm`.

## 4. Gợi ý Deny List cho phiên chat mới
- `models/yolov26-engine/weights/`
- `models/gaic-cropper/*.pt`
- `AISmartFramingCamera/Resources/LUTs/`
- `docs/evaluation/` (510 KB JSON tập đánh giá)
- `docs/eval/`
- `web/assets/`
- `validation/`
