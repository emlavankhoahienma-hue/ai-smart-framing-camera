# 📸 AI Smart Framing Camera (iOS 16 - 18)

[![iOS Sideload Build & Release](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml/badge.svg)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml)
[![iOS Target](https://img.shields.io/badge/iOS-16.0%2B%20%7C%2017%20%7C%2018-black.svg?style=flat&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B%20%7C%20SwiftUI-orange.svg?style=flat&logo=swift)](https://swift.org)
[![Neural Engine](https://img.shields.io/badge/Apple%20Neural%20Engine-A11%20to%20A18-purple.svg)](https://apple.com)

Ứng dụng Camera thông minh tích hợp trí tuệ nhân tạo (AI & Neural Engine) trên iOS, tự động phân tích bố cục nghệ thuật, tính toán góc chụp vàng (Rule of Thirds, Golden Ratio), dẫn hướng bằng vòng tròn mục tiêu AR và áp dụng các công thức màu film đỉnh cao thời gian thực.

---

## 🌟 Tính Năng Nổi Bật

### 1. 🧠 AI Scene & Subject Analysis (Vision + Neural Engine)
- **Face & Human Pose Detection**: Nhận diện khuôn mặt, các điểm mốc (landmarks), tỷ lệ dáng người để xác định trọng tâm thị giác và hướng nhìn (Lead Room / Looking Room).
- **Attention Saliency**: Tự động phát hiện các chủ thể nổi bật trong ảnh phong cảnh hoặc tĩnh vật khi không có người.
- **Scene Classification**: Nhận diện bối cảnh (Sunset, Portrait, Landscape, Architecture, Food, Night Scene...) để tự động gợi ý công thức màu film tối ưu.

### 2. 🎯 AR Composition Guide (Vòng Tròn Mục Tiêu & Tia Chỉ Dẫn)
- Tính toán vị trí vàng chuẩn nghệ thuật theo **Quy tắc 1/3 (Rule of Thirds)** hoặc **Tỷ lệ vàng (Golden Ratio 1.618)**.
- Hiển thị **Target Circle** phát sáng radar tại điểm tối ưu kèm **Guidance Ray (Tia chỉ dẫn)** từ tâm camera đến tâm mục tiêu.

### 3. ⚡ Auto-Alignment & Magnetic Snap Haptics
- Phản hồi rung tinh tế qua `HapticFeedbackService` khi tâm camera khóa hoàn toàn vào vòng tròn mục tiêu ($\le 3.5\%$ dung sai).
- Hỗ trợ **Auto-Zoom** tự động căn chỉnh mức phóng đại ($1.0x, 2.0x, 3.0x, 5.0x$) dựa trên tỷ lệ diện tích của chủ thể trong khung hình.

### 4. 🎞️ CoreImage Film Simulation Recipes
- **Fuji Pro 400H**: Tone xanh pastel thanh lịch, nâng sáng và tôn màu da.
- **Kodak Portra 400**: Sắc ấm vàng dịu, chuyển màu highlight mượt mà.
- **Teal & Orange**: Phân tách màu điện ảnh Hollywood tương phản cao.
- **Sunset Glow**: Rực rỡ và ấm áp, tối ưu cho giờ vàng (Golden Hour).
- **Noir High Contrast**: Đen trắng tương phản cao nghệ thuật đường phố.
- **Vintage Warm 70s & Street Classic**: Chất retro hoài niệm với độ chi tiết cao.

---

## 🏛️ Kiến Trúc Dự Án (Clean MVVM + Engine Architecture)

```
AISmartFramingCamera/
├── App/
│   └── AISmartFramingCameraApp.swift          # Entry point SwiftUI
├── Models/
│   └── FramingModels.swift                   # Data models, Enums, State structures
├── Services/
│   ├── CameraService.swift                   # AVFoundation 4K/Photo capture & Zoom
│   ├── VisionFramingEngine.swift             # Real-time Neural Engine Vision pipeline
│   ├── CompositionCalculator.swift           # Thuật toán tính toán góc vàng & Auto-zoom
│   ├── FilmFilterEngine.swift                # Bộ lọc màu CoreImage GPU Metal
│   ├── HapticFeedbackService.swift           # Điều khiển phản hồi xúc giác Haptics
│   └── ARCompositionSession.swift            # ARKit 3D geometry (Tuân thủ Rule 1)
├── ViewModels/
│   └── CameraViewModel.swift                 # Main Actor State Orchestration
├── Views/
│   ├── CameraMainView.swift                  # Giao diện chính Apple Pro style
│   ├── CameraPreviewView.swift               # AVFoundation live preview layer
│   ├── ARFramingOverlayView.swift            # Lưới bố cục, Target Circle, Guidance Ray
│   ├── AIStatusHUDView.swift                 # Capsule HUD Dynamic Island
│   ├── CameraControlsView.swift              # Pro Shutter, Zoom Pills, Film Drawer
│   ├── CapturedPhotoPreviewView.swift        # So sánh Before/After và xuất ảnh
│   └── SettingsSheetView.swift               # Cài đặt thông số AI & ANE
├── Assets.xcassets/                          # App Icons & Colors
├── Info.plist                                # Quyền riêng tư Camera & Photo Library
├── AISmartFramingCamera.xcodeproj/           # Tuân thủ Rule 2 Asset Catalog
└── .github/workflows/ios-build.yml           # CI/CD tự động (Tuân thủ Rule 3)
```

---

## 🚀 Hướng Dẫn Cài Đặt (Sideloading qua Sideloadly)

1. Truy cập tab **Releases** trên GitHub repository này và tải về tệp `AISmartFramingCamera.ipa`.
2. Kết nối iPhone/iPad với máy tính qua cáp USB và mở ứng dụng **Sideloadly** (hoặc AltStore).
3. Kéo tệp `AISmartFramingCamera.ipa` vào giao diện Sideloadly.
4. Nhập tài khoản Apple ID của bạn và nhấn **Start**.
5. Trên thiết bị iOS:
   - Vào **Cài đặt (Settings)** > **Cài đặt chung (General)** > **Quản lý VPN & Thiết bị (VPN & Device Management)**.
   - Nhấn vào chứng chỉ nhà phát triển của bạn và chọn **Tin cậy (Trust)**.
6. Mở ứng dụng **AI Smart Camera** và tận hưởng trải nghiệm chụp ảnh thông minh!

---

## 🛠️ Quy Chuẩn Kỹ Thuật Đạt Chuẩn CI/CD

- **Rule 1**: ARKit mesh accessing native Swift collections: `geometry.vertices`, `geometry.textureCoordinates`, `geometry.triangleIndices`, and `.vertices.count`.
- **Rule 2**: PBXProj configured with `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO` & `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = NO`.
- **Rule 3**: GitHub Actions YAML configured with `permissions: contents: write` for automated IPA artifact packaging and release distribution.
