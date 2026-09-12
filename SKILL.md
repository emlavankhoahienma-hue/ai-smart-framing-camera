---
name: alignai-quiet-pro-camera-ui
description: Redesign toàn bộ giao diện AlignAI Studio thành camera chuyên nghiệp, tối giản, dễ dùng, không bị AI hóa; giữ nguyên camera engine, AI framing, tracking, photo, video và Pro Video.
---

# AlignAI Quiet Pro Camera UI

## Vai trò

Bạn là Senior iOS Engineer, SwiftUI Engineer và Product Designer.

Hãy trực tiếp làm việc trên repository `ai-smart-framing-camera`, ứng dụng iOS SwiftUI tên AlignAI Studio / AI Smart Framing Camera.

Mục tiêu là làm lại UX/UI của camera screen, các overlay, form Settings, màn hình preview ảnh/video và permission screen theo hướng:

- Cao cấp
- Tối giản
- Dễ dùng
- Phù hợp với camera chuyên nghiệp
- Không bị “AI hóa”
- Không giống dashboard kỹ thuật
- Không giống giao diện quảng cáo AI
- Giữ nguyên chức năng camera, AI framing, tracking, video và Pro Video hiện có
- Build được trên iOS 16+

Không chỉ trả lời bằng phân tích. Hãy đọc code, chỉnh sửa code thật, build kiểm tra và báo cáo kết quả.

---

## 1. Phạm vi code cần đọc trước khi sửa

### UI

Đọc toàn bộ các file:

- `AISmartFramingCamera/Views/CameraMainView.swift`
- `AISmartFramingCamera/Views/CameraControlsView.swift`
- `AISmartFramingCamera/Views/AIStatusHUDView.swift`
- `AISmartFramingCamera/Views/ARFramingOverlayView.swift`
- `AISmartFramingCamera/Views/LiveColorHistogramHUDView.swift`
- `AISmartFramingCamera/Views/ProVideoManualControlsView.swift`
- `AISmartFramingCamera/Views/SettingsSheetView.swift`
- `AISmartFramingCamera/Views/CapturedPhotoPreviewView.swift`
- `AISmartFramingCamera/Views/VideoPreviewSheetView.swift`
- `AISmartFramingCamera/Views/FeedbackView.swift`

### State và model

- `AISmartFramingCamera/ViewModels/CameraViewModel.swift`
- `AISmartFramingCamera/Models/FramingModels.swift`

### Service cần hiểu để không làm hỏng behavior

- `AISmartFramingCamera/Services/CameraService.swift`
- `AISmartFramingCamera/Services/GeminiService.swift`
- `AISmartFramingCamera/Services/ProVideoManualControlsService.swift`
- `AISmartFramingCamera/Services/FilmFilterEngine.swift`
- `AISmartFramingCamera/Services/CompositionCalculator.swift`

Trước khi sửa, hãy lập bản đồ:

- State đang có
- Action đang có
- View nào gọi action nào
- Setting nào được lưu
- Tính năng nào đang hoạt động thật
- Tính năng nào không được phép tạo UI giả

---

## 2. Quy tắc bắt buộc

### 2.1. Không phá camera và AI engine

Không tự ý viết lại hoặc thay đổi thuật toán trong:

- `CameraService`
- `VisionFramingEngine`
- `YOLODetectionEngine`
- `NeuralSubjectIntelligenceEngine`
- `SpatialTrackingEngine`
- `StreetSpatialTrackingEngine`
- `ARCompositionSession`
- `FilmFilterEngine`
- `CompositionCalculator`
- `GeminiService`

Ưu tiên chỉ sửa các file trong thư mục `Views`.

Chỉ sửa `ViewModel` hoặc service khi thật sự cần để:

- Bổ sung state mới có behavior thật
- Sửa compile error do UI mới
- Bảo vệ API key
- Wire đúng một setting mới

Giữ nguyên public API hiện tại nếu không bắt buộc phải thay đổi.

### 2.2. Không xóa chức năng

Các chức năng sau phải tiếp tục hoạt động:

- Camera preview
- Tap to focus
- Long press khóa AE/AF
- Exposure adjustment
- Pinch to zoom
- Zoom buttons
- Photo mode
- Video mode
- Pro Video mode
- Live Photo
- Flash
- AI framing
- AI tracking
- Composition rules
- Auto zoom
- Film presets
- Histogram
- ISO
- Shutter speed
- White balance
- EV
- Focus peaking
- Horizon leveler
- Street tracking
- Chụp ảnh
- Quay video
- Lưu ảnh/video
- Chia sẻ
- Preview ảnh
- Preview video
- Gemini configuration
- Feedback
- Web report nếu người dùng chủ động bật

### 2.3. Không tạo UI giả

Không được thêm:

- Toggle không có state
- Button không có action
- Setting chỉ để trang trí
- Loading giả
- Progress giả
- Trạng thái AI giả
- Text nói tính năng đã hoạt động khi chưa wire

Nếu một setting chưa có state/action:

- Hoặc bổ sung đầy đủ state và behavior
- Hoặc không hiển thị setting đó
- Không được tạo control vô dụng

### 2.4. Không thêm package

Chỉ sử dụng framework hiện có:

- SwiftUI
- UIKit
- AVFoundation
- Photos
- CoreGraphics
- Các framework đã có trong project

Không thêm thư viện UI bên ngoài.

### 2.5. Không đổi branch hoặc phá repository

- Làm việc trên branch hiện tại
- Không tạo branch mới
- Không xóa `.git`
- Không commit hoặc push nếu chưa được yêu cầu
- Không xóa file nguồn chỉ vì muốn viết lại nhanh

---

## 3. Hướng thiết kế: Quiet Pro Camera

AI phải hoạt động âm thầm phía sau. Người dùng chỉ nên thấy:

- Bố cục
- Chủ thể
- Hướng dẫn
- Trạng thái ngắn gọn
- Kết quả ảnh
- Điều khiển cần thiết

Không để camera screen giống bảng debug, dashboard AI hoặc trang marketing công nghệ.

### 3.1. Màu sắc

Dùng bảng màu tiết chế:

- Background: đen than gần `#0B0B0C`
- Card: xám/đen đậm, opacity vừa phải
- Text chính: trắng ngà
- Text phụ: xám trung tính
- Accent: vàng champagne hoặc amber
- Thành công: xanh lá dịu
- Cảnh báo: cam
- Lỗi: đỏ
- Đang quay: đỏ

Không lạm dụng:

- Cyan neon
- Purple neon
- Gradient vàng-cyan
- Glow
- Shadow mạnh
- Border phát sáng

Chỉ dùng gradient tối nhẹ ở vùng bottom camera khi cần tăng độ tương phản.

### 3.2. Typography

- Dùng font hệ thống iOS
- Không viết toàn bộ chữ in hoa
- Không dùng emoji trong tiêu đề Settings
- Không dùng monospaced cho toàn bộ UI
- Chỉ dùng monospaced cho ISO, shutter, FPS, latency và technical ID
- Text phụ không nhỏ hơn 12–13pt nếu có thể
- Touch target tối thiểu 44x44pt
- Row height khoảng 50–56pt
- Padding ngang 16–20pt
- Card corner radius 14–18pt

---

## 4. Làm lại Camera Screen

### 4.1. Layout mục tiêu

Camera screen nên có cấu trúc:

```text
┌─────────────────────────────────────┐
│  Flash          Trạng thái       ⚙  │
│                                     │
│      Bố cục thông minh · Tự động     │
│                                     │
│          CAMERA PREVIEW             │
│                                     │
│       Focus / Target / Guide        │
│         chỉ hiện khi cần            │
│                                     │
│          1x   2x   3x   5x          │
│                                     │
│           Ảnh  Video  Pro           │
│                                     │
│     Thư viện     Nút chụp     Màu   │
└─────────────────────────────────────┘
```

### 4.2. Top bar Photo Mode

Chỉ hiển thị:

- Flash
- Status ngắn
- Settings

Không để tất cả các nút sau cùng xuất hiện ở top bar:

- AI
- Rule
- AR
- Engine source
- Gemini
- Model
- Confidence
- Tracking quality
- Focus peaking badge
- Leica badge

Live Photo, Rule và AR chuyển vào quick sheet hoặc Settings.

### 4.3. Top bar Video Mode

Hiển thị:

- Flash hoặc Torch
- Timer
- Resolution/FPS
- Settings

Ví dụ:

```text
[Đèn]          00:12 · 4K 30          [Cài đặt]
```

Không dùng nhiều capsule lồng nhau.

### 4.4. Một nút chụp chính

Trong Photo Mode không dùng hai nút lớn ngang hàng là nút AI và nút chụp thủ công.

Chỉ giữ một nút chụp chính.

Bố cục thông minh là control phụ:

```text
Bố cục thông minh · Tự động
```

Khi chạm vào, mở sheet:

- Tự động
- Quy tắc 1/3
- Tỷ lệ vàng
- Xoắn ốc Fibonacci
- Tâm đối xứng
- Nút `Bắt đầu căn bố cục`

### 4.5. Mode selector

Giữ ba mode:

- Ảnh
- Video
- Pro

Dùng segmented control hoặc text selector tối giản.

### 4.6. Zoom

Giữ các mức zoom có thật trên thiết bị:

- 1x
- 2x
- 3x
- 5x

Vẫn hỗ trợ pinch zoom.

Khi pinch giữa các mức, hiển thị giá trị thực tế như `2.7x`.

Không hiển thị 10x như ống kính thật nếu đó chỉ là digital zoom và chưa được giải thích rõ.

### 4.7. Bottom controls

Photo:

```text
[Thư viện]      [Nút chụp]      [Màu]
```

Video:

```text
[Thư viện]      [Nút quay]      [Màu]
```

Pro:

```text
[Thư viện]      [Nút quay]      [Điều khiển]
```

---

## 5. Làm lại AI framing

Không dùng quá nhiều chữ AI.

### Trạng thái cần hiển thị

Idle:

```text
Bố cục thông minh
```

Analyzing:

```text
Đang tìm chủ thể…
```

Target placed:

```text
Đã khóa chủ thể
Di chuyển máy đến vòng tròn
```

Tracking degraded:

```text
Đang tìm lại chủ thể…
```

Perfect alignment:

```text
Đã khớp
Giữ máy ổn định
```

Capturing:

```text
Đang chụp…
```

Done:

```text
Đã lưu ảnh
```

Không dùng câu quá kỹ thuật.

### Auto capture

Nếu hệ thống có tự động chụp khi căn đúng, phải có setting thật:

```text
Tự chụp khi khớp
Bật / Tắt
```

Không tạo UI nếu chưa có state/action thật.

Không để app tự chụp bất ngờ mà người dùng không biết.

### AI Status HUD

Thay HUD nhiều badge bằng một status bar ngắn.

Chỉ hiển thị một trạng thái chính ở mỗi thời điểm.

Các thông tin sau chỉ được phép xuất hiện trong `Chẩn đoán`:

- Model
- Engine
- Confidence
- Latency
- Gemini
- YOLO
- NPU
- Local model

---

## 6. Quản lý overlay

`ARFramingOverlayView` hiện có nhiều overlay. Không để tất cả cùng xuất hiện.

### Overlay ưu tiên cao

- Focus square
- Target circle
- Center crosshair
- Horizon leveler

### Overlay chỉ hiển thị khi cần

- Grid
- Guidance ray
- Countdown
- AE/AF lock
- Focus peaking

### Overlay chỉ hiển thị khi người dùng bật hoặc trong debug

- Face detection box
- Subject highlight box
- Engine source
- Confidence
- Tracking quality
- Gemini warning kỹ thuật

Nếu AI framing đang chạy, ưu tiên target và guidance.

Không để grid, face box, subject box, focus peaking, horizon, target và countdown cùng làm rối preview.

---

## 7. Film preset

Khi người dùng bấm Màu, mở bottom sheet có ảnh mẫu.

Tên hiển thị:

| Tên hiện tại | Tên mới |
|---|---|
| Standard Clean | Tự nhiên |
| Fuji Pro 400H | Pastel dịu |
| Kodak Portra 400 | Ấm áp |
| Teal & Orange | Điện ảnh |
| Sunset Glow | Hoàng hôn |
| Noir High Contrast | Đen trắng |
| Vintage Warm 70s | Hoài niệm |
| Street Classic | Đường phố |
| AI Full Auto Color | Tự động theo cảnh |

Không dùng `AI✦`, `LEICA` hoặc `Hasselblad` làm điểm nhấn chính.

Có thể giữ thông tin kỹ thuật trong phần mô tả nhỏ.

---

## 8. Histogram và Pro Video

### Histogram

Không hiển thị histogram đầy đủ ở mọi chế độ.

- Photo thường: ẩn
- Video thường: chỉ hiện ISO/Shutter nhỏ nếu cần
- Pro Video: hiện đầy đủ
- Chạm vào exposure info để mở histogram nếu cần

### Pro Video

Mặc định chỉ hiển thị:

```text
ISO Auto | 1/60 Auto | EV 0 | WB Auto
```

Chạm từng mục mới mở panel chỉnh.

Giữ nguyên service/action hiện có.

Khẩu độ iPhone là khẩu độ phần cứng cố định. Hiển thị:

```text
Khẩu độ f/1.8 · Cố định
```

Tách riêng với:

```text
Bù phơi sáng EV
```

Không làm người dùng tưởng rằng họ đang thay đổi aperture thật.

---

## 9. Làm lại Settings Form

`SettingsSheetView` phải được tổ chức thành các nhóm sau.

### Header

```text
Cài đặt                                      Xong
```

Không đặt Developer hoặc Donate ở đầu.

### 1. Chụp ảnh

- Định dạng ảnh
- Live Photo
- Lưu ảnh gốc
- Rung khi căn đúng
- Giữ màn hình sáng
- Tự chụp khi khớp

### 2. Bố cục thông minh

- Bố cục mặc định
- Tự động tìm chủ thể
- Tự động zoom
- Tự chụp khi khớp
- Hiển thị đường hướng dẫn
- Độ nhạy bám chủ thể

### 3. Khung ngắm

- Lưới bố cục
- Cân bằng đường chân trời
- Focus peaking
- Màu viền báo nét
- Hiển thị vùng nhận diện
- Histogram

### 4. Màu sắc

- Màu mặc định
- Tự động theo cảnh
- Preset màu hiện tại
- Bộ màu có preview image

### 5. Video

- Độ phân giải
- FPS
- Codec

Không gộp thành chuỗi khó đọc như `1080P 60FPS` nếu có thể tách thành:

```text
Độ phân giải       1080p
Tần số             60 fps
Codec              HEVC
```

### 6. Video Pro

- ISO mặc định
- Shutter mặc định
- EV mặc định
- White balance mặc định

### 7. AI & Quyền riêng tư

- Phân tích trực tuyến
- Trạng thái API
- Mô hình
- Quản lý API Key
- Xóa API Key
- Dữ liệu nào được gửi ra ngoài

Mô tả cần có:

```text
Khi bật phân tích trực tuyến, một khung hình có thể
được gửi đến dịch vụ bên ngoài để nhận gợi ý bố cục
và màu sắc.

Khi tắt, ứng dụng chỉ sử dụng xử lý trên thiết bị.
```

API key không được hiển thị full.

### 8. Nâng cao

- Street Tracking
- Không gian 3D
- Web Report Server

Web Report Server không được chiếm vị trí nổi bật.

### 9. Chẩn đoán

- Model đang dùng
- Độ trễ gần nhất
- Kiểm tra kết nối
- Xuất log
- Xóa dữ liệu phiên
- Developer console

### 10. Hỗ trợ & Giới thiệu

- Hướng dẫn nhanh
- Gửi góp ý
- Báo lỗi
- Ủng hộ tác giả
- Chính sách riêng tư
- Phiên bản ứng dụng

Các nội dung sau không được nằm đầu Settings:

- Developer profile
- Email developer
- Hotline
- MoMo
- MB Bank
- VietQR
- Model ID
- Web server
- Debug console

Đưa chúng vào Hỗ trợ & Giới thiệu, Ủng hộ tác giả, Nâng cao hoặc Chẩn đoán.

Không dùng emoji trong title Settings.

Không dùng section title toàn chữ in hoa.

---

## 10. AI & Privacy UI

Hiển thị trạng thái API dạng:

- Đã kết nối
- Chưa thiết lập

Không hiển thị API key dạng plain text.

Trong `GeminiService.swift`, nếu API key đang lưu ở `UserDefaults`, không được để UI làm lộ giá trị. Có thể lập kế hoạch chuyển sang Keychain nếu cần, nhưng không được phá behavior hiện tại.

---

## 11. Photo Preview

`CapturedPhotoPreviewView` cần có hierarchy:

```text
Ảnh lớn

Gốc | Đã chỉnh

Tự nhiên · Chân dung
Tỷ lệ vàng · 96%

[Chỉnh màu] [Lưu] [Chia sẻ]

Chi tiết ảnh >
```

Giữ:

- So sánh ảnh gốc/ảnh chỉnh
- Kéo thanh chia đôi
- Lưu
- Chia sẻ
- Metadata

Đổi:

```text
Tối ưu màu bằng AI Studio (Gemini + Metal GPU)
```

thành:

```text
Chỉnh màu
```

hoặc:

```text
Tự cân màu
```

Không đặt Gemini, Metal GPU, Leica hoặc Hasselblad trong CTA chính.

---

## 12. Video Preview

Giữ:

- Video player
- Lưu video
- Chia sẻ
- Chỉnh màu

Dùng CTA ngắn:

- Chỉnh màu video
- Lưu video
- Chia sẻ

Không dùng câu marketing dài.

---

## 13. Permission screen

Thiết kế theo hướng thân thiện:

```text
Cho phép camera để bắt đầu

AlignAI Studio cần camera để hiển thị bản xem trước,
lấy nét và hỗ trợ căn bố cục.

[Cho phép Camera]
```

Nếu quyền bị từ chối:

```text
Camera đang bị tắt

[Mở Cài đặt]
```

Không dùng cụm quá kỹ thuật như Neural Engine hoặc AI pipeline.

---

## 14. Text mapping

Đổi text kỹ thuật thành text thân thiện:

| Text cũ | Text mới |
|---|---|
| AI | Bố cục |
| AI Session | Phiên căn bố cục |
| AI Full Auto Color | Tự động theo cảnh |
| LEICA | Màu tự nhiên |
| Gemini AI Live | Đang phân tích |
| AI Studio | Chỉnh màu |
| AI 114MB | Trên thiết bị |
| Cloud AI | Trực tuyến |
| DỰ ĐOÁN | Đang ước lượng |
| TÌM LẠI | Đang tìm chủ thể |
| HỦY AI | Dừng căn bố cục |
| BỘ MÀU FILM NGHỆ THUẬT | Màu sắc |
| VIDEO PRO | Pro |
| KHÓA AE/AF | Đã khóa sáng và nét |
| Alignment perfect | Đã khớp |
| Capturing | Đang chụp |

Không dùng quá nhiều chữ in hoa.

---

## 15. Accessibility và responsive

Bắt buộc:

- Button nào cũng có accessibility label
- Touch target tối thiểu 44x44
- Không chỉ dùng màu để biểu thị trạng thái
- Trạng thái quan trọng có text hoặc icon
- Settings hỗ trợ Dynamic Type
- Không cắt mất text quan trọng
- Không overflow trên màn hình nhỏ
- Không che safe area
- Có Reduce Motion fallback
- Có VoiceOver label
- Không dùng font quá nhỏ
- Sheet không tràn khỏi màn hình

Cần kiểm tra:

- iPhone màn hình nhỏ
- iPhone Pro Max
- Photo mode
- Video mode
- Pro Video mode
- AI analyzing
- Target placed
- Alignment perfect
- Capturing
- Settings
- Film sheet
- Photo preview
- Video preview

---

## 16. Tổ chức code

Có thể tách các component reusable:

- `SettingsRow`
- `SettingsSection`
- `QuickActionButton`
- `CameraStatusBar`
- `CameraBottomControls`
- `ColorPresetSheet`
- `CompositionRuleSheet`
- `ProControlsSheet`
- `AIStatusView`

Không tạo kiến trúc phức tạp không cần thiết.

Không duplicate state.

Không tạo nhiều state cho cùng một setting.

Tái sử dụng action hiện có như:

- `startAISession()`
- `cancelAISession()`
- `takePhotoManual()`
- `toggleVideoRecording()`
- `toggleFlash()`
- `toggleLivePhoto()`
- `toggleARMode()`
- `togglePhotoFormat()`
- `toggleVideoCodec()`
- `toggleVideoFormat()`
- `selectRule()`
- `selectPreset()`
- `setZoomFromButton()`
- `setZoomContinuous()`
- `finishZoomGesture()`
- `userDidTapToFocus()`
- `userDidLongPressToLockAEAF()`
- `adjustSunExposureBias()`

---

## 17. Quy trình triển khai

### Bước 1

Đọc code và lập bản đồ state/action.

### Bước 2

Làm lại:

- `CameraMainView`
- `TopCameraBar`
- `CameraControlsView`

### Bước 3

Làm lại:

- `AIStatusHUDView`
- Overlay priority trong `ARFramingOverlayView`

### Bước 4

Làm lại:

- Film preset sheet
- Histogram behavior
- Pro controls

### Bước 5

Tổ chức lại toàn bộ `SettingsSheetView`.

### Bước 6

Làm lại:

- `CapturedPhotoPreviewView`
- `VideoPreviewSheetView`
- Permission screen

### Bước 7

Kiểm tra:

- Dark mode
- Safe area
- Dynamic Type
- Accessibility
- Small screen
- Pro Max screen

### Bước 8

Build project bằng scheme phù hợp.

### Bước 9

Chạy:

```bash
git diff --check
```

### Bước 10

Báo cáo:

- File đã sửa
- Component đã tạo
- Chức năng đã giữ nguyên
- Setting mới
- Build result
- Warning còn lại nếu có
- Việc chưa hoàn thành nếu có

---

## 18. Acceptance criteria

Chỉ coi là hoàn thành khi:

1. Camera screen không còn giống dashboard AI.
2. Photo Mode chỉ có một nút chụp chính.
3. Bố cục thông minh được mở từ control rõ ràng.
4. Không còn nhiều AI badge cùng lúc.
5. Histogram không chiếm chỗ trong Photo Mode bình thường.
6. Pro controls không che preview mặc định.
7. Settings được chia section rõ ràng.
8. Developer/Donate/Debug không còn nằm đầu Settings.
9. API key không hiển thị plain text.
10. Không có button hoặc toggle giả.
11. Không xóa chức năng cũ.
12. Photo/Video/Pro vẫn hoạt động.
13. AI framing vẫn hoạt động.
14. Tap focus, AE/AF lock và zoom vẫn hoạt động.
15. Photo preview và Video preview vẫn hoạt động.
16. Giao diện chạy được trên màn hình nhỏ.
17. Không thêm package ngoài.
18. Build thành công.
19. Không có lỗi compile.
20. Không thay đổi camera/AI algorithm nếu không bắt buộc.

Bắt đầu bằng việc đọc code và lập bản đồ state/action. Sau đó trực tiếp sửa code theo skill này, không chỉ đưa ra hướng dẫn lý thuyết.
