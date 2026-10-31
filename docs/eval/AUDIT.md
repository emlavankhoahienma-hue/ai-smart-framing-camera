# AUDIT (BƯỚC 0) — Python mirror của pipeline AI Target & Zoom

Trạng thái: **chỉ đọc code, chưa viết code mirror.** Mọi `file:dòng` bên dưới đã grep xác nhận ngày 2026-10-31
(đánh dấu ✔ = grep lại hôm nay; ◐ = đọc ở phiên trước, chưa grep lại; ✖ = KHÔNG TÌM THẤY / chưa xác minh).
Đường dẫn Swift tính từ `AISmartFramingCamera/Services/`.

## a) Các tầng ảnh → target/zoom/crop

| # | Tầng | File:dòng | Vào → Ra |
|---|------|-----------|----------|
| 1 | Entry one-shot | `NeuralSubjectIntelligenceEngine.swift:243` `analyzeComposition` ✔ | pixelBuffer, frame, pose, allowedZooms → `LocalCompositionAnalysis` |
| 2 | Phát hiện/ngữ cảnh | `NeuralSubjectIntelligenceEngine.swift:382` `analyzeCapturedFrame` ✔ (private) | pixelBuffer → `NeuralAnalysisOutput` (candidates, scene, raster, semantic) |
| 2a | Vision requests | `NeuralSubjectIntelligenceEngine.swift:385-397` ✔ | xem bảng C |
| 2b | YOLO | `YOLODetectionEngine.swift:78` `detectPhotographicObjects` ✔, decode 292-359 ◐/✔ | ảnh → `[NeuralSubjectCandidate]` |
| 2c | Raster/bằng chứng ảnh | `CompositionImageEvidence.swift:63` `raster` ✔, `:129` `extractRANSACVanishingPoint` ✔ | ảnh+saliency → `CompositionRaster` |
| 2d | Gộp/xếp hạng | `NeuralSubjectIntelligenceEngine.swift:614` `rankedDistinct` ✔, `:646` `coherentGroup` ✔ | candidates → hero |
| 2e | SigLIP | `NeuralSubjectIntelligenceEngine.swift:45-75` `SemanticCropRanker.sceneEvidence` ✔ | ảnh 224 → semantics/guidance |
| 3 | Đề xuất bố cục | `CompositionPlanning.swift:571` `photographicProposals(subject:intents:…)` ✔, `:603` `proposals(subjects:intents:…)` ✔, `:842` `preferredPlacement` ✔, `:1033` `dynamicZooms` ✔ | subject+calibration → `[CompositionProposal]` |
| 4 | Zoom lý tưởng | `CompositionPureCalculations.swift:163` `calculateContinuousIdealZoom` ✔ | → zoom_ideal |
| 5 | Chấm thẩm mỹ + chọn | `CompositionAestheticSearch.swift:27` `run` ✔; `PhotographicCompositionModel.swift:30` `assess` ✔; `CharmPhotographicModel.swift:33` `assess` ✔ | proposals → best view |
| 6 | Crop | **SỬA (2026-10-31, ✔ đọc lại):** `CompositionPlanning.swift:728-732` KHÔNG phải hàm crop dùng lại được: đó là đoạn inline tính `sourceViewport` từ `rawCornerPoints` (dòng 696), chỉ nằm trong nhánh `if let poseProfile` để tính phạt giải phẫu. `CompositionProposal.sourceCorners` (dòng 535, gán ở 746) là `observedCornerPoints = observedSourceQuad(...)` (dòng 703), khác `rawCornerPoints`; góc thô có thể nằm ngoài khung nguồn tới margin −0.36 (dòng 647). **Không có hàm có sẵn trả về `crop_rect`.** | → crop_rect: xem SCHEMA.md / câu hỏi mở |

**Sửa lại so với ghi chú phiên trước:** chữ ký `photographicProposals` thật là `(subject:intents:…)` (dòng 571), KHÔNG phải `(detection:calibration:…)`. Tầng 3 cần đọc lại kỹ khi port.
Hằng số lấy từ `CompositionTuning.swift` ✔ (vd. `defaultCameraFOVWide=69.0` dòng 79, `yoloConfidenceThreshold=0.32` dòng 10, `fallbackBufferAspectRatio=0.75` dòng 94).

## b) Phân loại

**(A) Toán thuần → port 1:1** (không cần model): `CompositionPureCalculations.swift`, `CompositionTuning.swift`, `TrackingGeometry.swift` (`TrackingCalibration.fallback` dòng 24 ✔), phần lớn `CompositionPlanning.swift` (1300 dòng), `CompositionAestheticSearch.swift` (logic chọn, trừ gọi model), `rankedDistinct`/`coherentGroup`, `calculateYOLOProminenceScore` (`YOLODetectionEngine.swift:609` ✔), giải mã/NMS YOLO (`:292-359`: ngưỡng lớp 0.52 cho id 0/2/3, area ∈[0.006,0.95], NMS IoU>0.45 tại dòng 359 ✔).

**(B) Model chạy được bằng PyTorch/ONNX trên Windows**
| Model | Nguồn gốc | Kiểm chứng trong repo |
|---|---|---|
| YOLO12s/12n (80 lớp COCO) | `https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo12{s,n}.pt`, SHA-256 12s `e915c2c4…5f58`, 12n `419ff3dc…9e6` (`.github/workflows/ios-build.yml` ~dòng 96-100 ✔) | Có URL+SHA. Export CoreML dùng `nms=True, half=True` → **NMS nằm trong model CoreML** (đầu ra `confidence`, `YOLODetectionEngine.swift:228` ✔). |
| SigLIP-base-patch16-224 | HF `google/siglip-base-patch16-224` rev `7fd15f06…61ed`; mean=std=0.5; 224×224 (`scripts/export_siglip_coreml.py:20-21,75,81` ✔) | Có script + prompts (`PROMPTS`, dòng 23) |
| SAMP-Net | `scripts/composition_model.py`: rev `b8f80be3…`, `samp_net.pth` (Dropbox, SHA `d3d02f36…f603`), ảnh 224, mean/std ImageNet, saliency phổ (`spectral_saliency` dòng 82) ✔ | Có sẵn reference PyTorch `composition_model.py` + `export_composition_coreml.py` |
| Charm-PARA (DINOv2-small) | `scripts/charm_model.py`: HF `FatemehBehrad/Charm` rev `7feb3237…`, `para_charm.pth` (SHA `d7ce85f6…`), `dino_small_pos.pt`, bounded ≤336px, patch 14 ✔ | Có reference PyTorch (`tokens`, `bounded_image`) |

Không có file `.pt/.onnx` YOLO12/SigLIP/SAMP/Charm trong repo (chỉ `models/yolov26-engine/weights/yolov26_trained.pt` + mlpackage, **không phải YOLO12s mà app ưu tiên**, `YOLODetectionEngine.swift:28` ✔ thứ tự `yolo12s, yolo12n, yolov26_ane…`). → **Cần tải về** (mạng) và kiểm SHA. Chưa tải gì.

**✖ Chưa xác minh được từ repo:** ngưỡng `confidenceThreshold`/`iouThreshold` mà ultralytics nhúng vào NMS CoreML khi `export(..., nms=True)` (mặc định ultralytics, không viết trong repo). Cách kiểm: đọc `ultralytics==8.4.178` hoặc tra metadata sau khi tải. Cần bạn đồng ý cho tôi cài/đọc.

**(C) Chỉ có trên Apple** (`NeuralSubjectIntelligenceEngine.swift`)
| Request (dòng) | Dùng để | Thay thế đề xuất (Windows) | Độ lệch dự kiến |
|---|---|---|---|
| `VNDetectHumanRectanglesRequest` (385) | hộp người | YOLO12s class `person` (đã có) | Trung bình; thân người khác định nghĩa hộp |
| `VNDetectFaceLandmarksRequest` (387) | mặt, mắt, pose đầu | MediaPipe FaceLandmarker hoặc `insightface`/`opencv` Haar → mất yaw/pitch/pupil chính xác | **Cao** cho Portrait |
| `VNRecognizeAnimalsRequest` (388) | mèo/chó | YOLO12s `cat`/`dog` | Thấp–TB |
| `VNGenerateObjectnessBasedSaliencyImageRequest` (389) | saliency vật thể | Không có tương đương; ứng viên: spectral residual (`cv2.saliency`) hoặc U²-Net/BASNet | **Cao** (ảnh hưởng raster/ranking) |
| `VNGenerateAttentionBasedSaliencyImageRequest` (390) | saliency chú ý | Spectral residual / DeepGaze-like | **Cao** |
| `VNClassifyImageRequest` (391) | nhãn cảnh | CLIP/SigLIP zero-shot hoặc ImageNet/Places classifier | Cao (taxonomy khác) |
| `VNDetectHorizonRequest` (392) | đường chân trời | Hough/LSD (OpenCV) | TB |
| `VNDetectContoursRequest` (393) | contour cho RANSAC | `cv2.findContours` + Canny | TB |
| `VNGeneratePersonSegmentationRequest` (397) | mask người | `rembg`/MediaPipe SelfieSegmentation/torchvision DeepLab | TB |
| `VNDetectHumanBodyPoseRequest` (289) | pose thân | MediaPipe Pose / YOLO-pose | TB |
| `VNCalculateImageAestheticsScoresRequest` (`CompositionImageEvidence.swift:52`) | điểm thẩm mỹ Apple | **Không có tương đương** → để `null` hoặc bỏ | Không xác định |

⚠ Tầng (C) quyết định **hero subject** và **raster**, nên Python mirror sẽ chỉ là *xấp xỉ*. Điểm eval của mirror ≠ điểm app thật. Mọi xấp xỉ sẽ ghi vào `docs/eval/APPROXIMATIONS.md`.

## c) Nguồn trọng số/preprocess
Xem bảng (B). Thiếu/chưa xác minh: (1) YOLO `.pt` chưa tải; (2) NMS thresholds CoreML (✖); (3) preprocess SigLIP đã rõ (0.5/0.5, 224); (4) SAMP/Charm có reference PyTorch nhưng cần tải weights Dropbox/HF; (5) `VNImageRequestHandler` resize/`.scaleFit` vs `.scaleFill` (`YOLODetectionEngine.swift:460` ✔: photographic dùng `.scaleFit` → letterbox) cần khớp.

## d) Giả định ảnh tĩnh (khớp `tests/CompositionModelValidation.swift:171` ◐)
attitude = identity quaternion, FOV = `defaultCameraFOVWide` 69.0, zoom hiện tại = 1, `allowedZooms=[1,2,3]`, preferences `[:]`. Bỏ: HeroIdentitySelector, Kalman, IMU, AlignmentCaptureGate. Không có random trong pipeline ◐ (RANSAC dùng vòng lặp tất định, `CompositionImageEvidence.swift:182-183` ◐). Cổng nhiệt/low-power (`YOLODetectionEngine.swift:82` ✔) không có trên Windows → mirror luôn ở chế độ "nominal".

## e) Môi trường
Windows 10, CPU. Python hệ thống: `C:\Users\admin\AppData\Local\Programs\Python\Python312\python3.exe` (✔ tồn tại; `python` trong PATH là `C:\Windows\system32\python`, nghi stub Store — chưa chạy được). Chưa có `.venv`, chưa có `data/GAICD/`. Sẽ tạo venv, gọi `python -m pip`, in `sys.executable` trước khi cài.

## Điểm dừng — cần bạn quyết định trước khi viết mirror
1. Duyệt bảng thay thế (C) (hoặc chọn từng dòng). Đặc biệt saliency và face landmarks.
2. Cho phép tải: ultralytics `.pt` (GitHub), SigLIP/Charm (HF), SAMP-Net (Dropbox), cài torch CPU, transformers, v.v.
3. Chấp nhận mirror là xấp xỉ, hay muốn thay vào đó chạy Swift thật trên macOS/CI (chính xác hơn, không port).
