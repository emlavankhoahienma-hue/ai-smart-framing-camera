# CI_AUDIT (BƯỚC A) — chạy pipeline Swift thật trên macOS CI

Chỉ đọc code, chưa viết code Swift/CI. ✔ = đã đọc/grep hôm nay (2026-10-31).
Workflows: `.github/workflows/` có 3 file: `composition-model-validation.yml`, `ios-build.yml`, `simulator-snapshots.yml` (✔).

## 1. Runner, trigger, thời gian
| Workflow | Runner / Xcode | Trigger | Thời gian |
|---|---|---|---|
| `composition-model-validation.yml` | `macos-15`, `timeout-minutes: 60` (dòng 8-9); **không chọn Xcode**, dùng mặc định runner | chỉ `workflow_dispatch` (dòng 3-4) | 5 lần chạy gần nhất (✔ `gh run list`): ≈2.0–4.9 phút (3 success, 2 failure) |
| `ios-build.yml` | `macos-15` (dòng 21); chọn Xcode_16* mới nhất bằng `xcode-select` (dòng 32-44) | PR→main, push main + 1 nhánh arena, `workflow_dispatch` (dòng 3-16); `paths-ignore` web/README/docs | 30 lần gần nhất: thành công ≈9–16 phút, thất bại 0.7–13.8 phút |
| `simulator-snapshots.yml` | `macos-15`, 30 phút (dòng 20-21) | `workflow_dispatch` + push khi sửa chính nó | không đo |

## 2. Workflow hiện chạy gì
- `composition-model-validation.yml` (✔ dòng 25-36): tải ảnh CADB (`prepare_composition_photos.py`), export SAMP + Charm sang CoreML (Python, coremltools), `xcrun coremlc compile`, rồi `python scripts/validate_composition_photos.py --parity-only`.
  - Script này (✔ `scripts/validate_composition_photos.py:74-82`) dùng `xcrun swiftc -O` biên dịch **một CLI macOS** từ **file production nguyên bản** (`CompositionTuning, CompositionPureCalculations, CompositionExperiments, TrackingGeometry, CompositionPlanning, CompositionImageEvidence, PhotographicCompositionModel, CharmPhotographicModel, PortraitFramingEvidence, CompositionAestheticSearch, YOLODetectionEngine, CameraLogger`) + `validation/ProductionSubjectAnalysis.swift` (sinh ra: trích `NativeSubjectAnalysis` từ `NeuralSubjectIntelligenceEngine.swift`, kiểm SHA với `tests/PhotographicDetectionBoundary.json`, dòng 32-35) + `tests/CompositionModelValidation.swift`.
  - **Không phải xcodebuild test, không chạy trên iOS Simulator, không có XCTest target** (✔ `project.pbxproj` chỉ có 1 `PBXNativeTarget` loại `application`, dòng 340-354).
  - **CI hiện chỉ chạy `--parity-only`** (✔ `CompositionModelValidation.swift:97-99` return sớm; script dòng 67 bỏ copy YOLO/SigLIP). Nghĩa là **CI hiện KHÔNG chạy pipeline thật (YOLO→hero→proposals→search) trên ảnh**. Chế độ đầy đủ (✔ `searchPhoto`, `CompositionModelValidation.swift:141-239`) tồn tại nhưng không workflow nào gọi.
- `ios-build.yml`: chạy `swiftc` hồi quy (`tests/CompositionPlanningRegression.swift`, dòng 51-65), export model, `xcodebuild` iOS device (unsigned), đóng gói IPA và **tạo Release**. Không chạy ảnh thật.
- `simulator-snapshots.yml`: chỉ build iOS Simulator để chụp UI (dòng 48-66).

## 3. Model: lấy, kiểm SHA, lưu ở đâu
| Model | Bước (ios-build.yml) | Kiểm SHA | Nơi lưu trên runner |
|---|---|---|---|
| yolo12n/12s | "Export & Compile pretrained YOLO12s and YOLO12n" (~dòng 78-110): tải `.pt` từ GitHub assets v8.3.0, `export(format='coreml', nms=True, half=True)` | `shasum -a 256 --check` cho `.pt` ✔ | thư mục gốc workspace: `yolo12{n,s}.mlmodelc` (`coremlc compile ... .`) |
| SigLIP | "Export, verify and compile pinned SigLIP" (~dòng 112-120) `scripts/export_siglip_coreml.py` | revision HF ghim ✔; verify trong script | `SigLIPBaseImage.mlmodelc`, `SigLIPPrompts.json`, `SigLIPModelManifest.json` ở gốc |
| SAMP / Charm | "Export and verify pretrained SAMP-Net…" (~dòng 123-137) | SHA trong `composition_model.py`/`charm_model.py` ✔ | `SAMPComposition.mlmodelc`, `CharmAesthetics.mlmodelc`, `CharmPositionEmbedding.bin` ở gốc |
| Cache | `actions/cache@v5`, path `.model-cache`, key `composition-cadb-samp-charm-v2` (✔ ios-build ~dòng 123; cmv dòng 15-19) | — | chỉ cache file tải về, **không cache `.mlmodelc`** |
Lưu ý: `composition-model-validation.yml` **không** export YOLO12/SigLIP → muốn chạy đầy đủ phải thêm các bước đó (copy từ ios-build) vì CLI cần `yolo12s/12n/SigLIP` trong `Resources/` (script dòng 68-70).
Cách model tìm file: YOLO qua `Bundle.main.url(forResource:)` (✔ `YOLODetectionEngine.swift:44`), SAMP/Charm qua URL truyền tham số (✔ `PhotographicCompositionModel.swift:19`, `CharmPhotographicModel.swift:20`) → bundle giả `validation/photo-validation.app` đã giải quyết YOLO/SigLIP.

## 4. Phụ thuộc UIKit/AVFoundation/camera
- `NeuralSubjectIntelligenceEngine.swift:5` `import UIKit` (✔) → file này **không biên dịch được trên macOS CLI**; script hiện tại tránh bằng cách *trích* các đoạn dữ liệu/thuật toán vào file sinh ra và chỉ `import Foundation/Vision/CoreGraphics/CoreImage/CoreML/simd` (script dòng 37).
- `TrackingGeometry.swift:95-108` dùng `CMSampleBuffer` (CoreMedia, có trên macOS) ✔ — không cản trở macOS.
- Các file còn lại trong danh sách biên dịch không có `import UIKit/AVFoundation` (✔ grep; không khớp) nên biên dịch được trên macOS (CI đã chứng minh: parity-only build thành công).
- Hệ quả: phương án **macOS CLI (swiftc)** đã được chứng minh chạy; **iOS Simulator + XCTest** sẽ cần tạo test target mới trong `.pbxproj` (chưa có) — nhiều sửa đổi hơn, và Simulator không có Neural Engine (CoreML chạy CPU/GPU, kết quả số có thể lệch nhẹ so với thiết bị).

## 5. Artifact
`actions/upload-artifact@v6` đã dùng (cmv dòng 37-48; ios-build dòng 171-176, 254-258). JSON kết quả vài trăm KB; 150 ảnh đầu vào GAICD tùy kích thước (✖ chưa biết). Không đo được dung lượng artifact cũ (lệnh `gh api` lỗi quoting, chưa thử lại). Repo là **PUBLIC** (✔ `gh repo view`: `visibility: PUBLIC`) → artifact tải được bởi người có quyền đọc repo; thời hạn mặc định 90 ngày (✖ chưa xác minh cấu hình repo).

## 6. CÒN THIẾU để chạy eval 150 ảnh (phương án ít sửa nhất)
Phương án đề xuất: **mở rộng đúng CLI macOS có sẵn**, không thêm XCTest/Simulator.
1. Workflow mới (vd. `eval-pipeline.yml`, `workflow_dispatch`, macOS-15) = các bước export model của ios-build (YOLO12, SigLIP, SAMP, Charm) + gọi CLI ở chế độ đầy đủ.
2. File Swift runner mới trong `tools/eval/` (cờ/target riêng, không đụng file production), mô phỏng `searchPhoto` nhưng:
   - ✔ cần thêm: **áp EXIF orientation** (`CompositionModelValidation.swift:16-18` dùng `CGImageSourceCreateImageAtIndex` KHÔNG áp EXIF);
   - ✔ cần thêm: xuất `target_P`, `zoom_ideal`, `crop_rect`, `timing`, `scene_intent` thành `eval_results.json` (harness hiện chỉ xuất `heroBounds, selectedZoom, selectedIntent, compositionRating, aestheticRating, choices[].sourceCorners`, dòng 214-237; **không có `target_P`, `zoom_ideal`** → để `null` hoặc đọc read-only, chưa quyết);
   - ✔ không được `throw` làm dừng lô (harness hiện `throw Failure` khi crop vi phạm bảo vệ → cần `try/catch` từng ảnh để ghi `ok=false`).
3. **Đưa 150 ảnh GAICD lên runner** — chưa có đường đi: ảnh Flickr không được commit vào repo public.
4. Bước upload artifact `eval_results.json` + log.
5. Lưu ý: `prepare_composition_photos.py` hiện tải CADB; eval mới cần chế độ đọc thư mục ảnh tùy ý.

## Đính chính quan trọng về `crop_rect` (✔ đọc lại `CompositionPlanning.swift:643-647, 696, 703, 728-746`)
- `CompositionPlanning.swift:728-732` là đoạn inline trong nhánh `if let poseProfile` (chỉ để tính phạt giải phẫu), **không phải hàm dùng lại được**. Tôi đã nói sai ở phiên trước và trong bản nháp đầu của tài liệu này.
- `CompositionProposal.sourceCorners` (dòng 535, gán ở 746) = `observedCornerPoints` từ `observedSourceQuad(...)` (dòng 703), khác `rawCornerPoints`; góc thô được phép vượt khung nguồn tới margin −0.36 (dòng 646-647; chú thích code: xoay camera 3D ở 1.0x).
- Hệ quả: một "crop" của app là **tứ giác** có thể xoay và/hoặc lồi ra ngoài ảnh gốc. Hộp bao trục (AABB) của 4 góc, kẹp vào [0,1], chỉ là **xấp xỉ**, thường lớn hơn vùng thật; IoU so với crop GAICD (chữ nhật trong ảnh) sẽ bị lệch. **Không có hàm có sẵn cho crop_rect** → quy tắc "dùng hàm có sẵn" không thực hiện được; cần bạn quyết định (xem câu 6 bên dưới).

## Điểm chưa chắc — cần bạn trả lời
1. **Ảnh GAICD lên CI bằng cách nào?** (a) repo private/fork private chứa `eval_input/`; (b) release asset trong repo private; (c) bạn tự thêm bước tải từ link GAICD (không ổn định); (d) khác?
2. **Chi phí/phút macOS CI:** repo public thì phút macOS miễn phí; nếu chuyển private sẽ tính phút (macOS ×10). Bạn chọn gì?
3. **Chấp nhận vỏ macOS CLI** (CoreML trên runner macOS, CPU/GPU, không ANE) thay vì iPhone thật? Kết quả có thể lệch nhẹ so với thiết bị.
4. `target_P`/`zoom_ideal` không có trong output công khai: đồng ý để `null` ở lần đầu, hay cho phép thêm getter read-only sau cờ EVAL (không đổi công thức)? (`CompositionPlanning.swift` thuộc vùng bảo vệ bởi `PhotographicDetectionBoundary.json`/`TrackingBoundary.json`, sửa sẽ phải cập nhật hash.)
6. **`crop_rect`:** (a) runner Swift tự tính AABB của `best.proposal.sourceCorners` kẹp [0,1] (code mới nằm trong runner, không đổi công thức pipeline; ghi rõ là xấp xỉ), kèm xuất luôn 4 góc thô `source_corners` để tính IoU đa giác sau này; hay (b) `null` cho tới khi có hàm chính thức? Khuyến nghị (a).
7. Thời lượng ước tính 150 ảnh chưa đo được (không có số liệu `secondsMac` từ CI); nên chạy thử 5 ảnh trước.
