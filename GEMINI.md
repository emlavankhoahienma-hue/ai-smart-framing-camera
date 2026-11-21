# GEMINI.md — Quy tắc làm việc cho dự án Align Studio (iOS)

Mọi agent/AI thao tác trên repo này **bắt buộc** tuân thủ các quy tắc chống rác và tiết kiệm ngữ cảnh sau:

## 1. Cấm đẻ rác
- **KHÔNG** tự ý tạo thêm file `.md` (nhật ký, kế hoạch, báo cáo tiến độ, tóm tắt), script dùng 1 lần (`scripts/package_*`, `scripts/build_*prompt*`), hoặc file backup/dump (`*.bak`, `*.tmp`, `*_bundle.txt`, `eval_results.json`) khi người dùng chưa yêu cầu rõ.
- Nếu cần script kiểm tra/dọn dẹp tạm, chỉ dùng 1 file `_tmp_*.py` và **xóa ngay** khi chạy xong.
- Không lưu bản build `.ipa`, báo cáo `.json`/`.jpg` xuất thử vào repo; nếu phải dọn file nghi thừa thì chuyển vào `_TRASH_CHECK/` thay vì xóa vĩnh viễn.

## 2. Tiết kiệm token & đọc code có mục tiêu
- **KHÔNG** đọc nguyên file dài `> 300` dòng vào context (ví dụ `CameraViewModel.swift`, `CameraService.swift`, `CameraMainView.swift`, `FramingModels.swift`, `project.pbxproj`).
- Luôn dùng lệnh tìm kiếm (`grep` / `Select-String`) lấy đúng số dòng rồi chỉ đọc đoạn cần thiết (`StartLine`–`EndLine`).

## 3. An toàn trước khi sửa code
- **Bắt buộc kiểm tra mọi nơi gọi (call sites)** trên toàn repo trước khi đổi tên, tham số, hoặc hành vi của hàm/struct/enum.
- **Tuyệt đối không chỉnh sửa** các file/khối mã bị khóa SHA-256 trong `tests/TrackingBoundary.json` (19 vùng) và `tests/PhotographicDetectionBoundary.json` (3 vùng) — đặc biệt `CameraService.swift`, `DeviceMotionService.swift`, `SpatialTrackingEngine.swift`, `YOLODetectionEngine.swift`, và các lát cắt khóa trong `CameraViewModel.swift`, `ARFramingOverlayView.swift`.
- Sau mỗi thay đổi Swift/UI, luôn chạy `python scripts/verify_tracking_boundary.py`, `python scripts/validate_pro_upgrades.py`, `python scripts/check_responsive_layout.py`, và `python scripts/check_swift_brackets.py`.
- Không động vào các file trọng số model AI (`.mlpackage`, `.mlmodel`, `.pt`, `.bin`, `.onnx`) nếu không có yêu cầu trực tiếp.
