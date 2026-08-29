# 📸 AlignAI Studio (AI Smart Framing Camera) — iOS 16 - 18

<div align="center">

![AlignAI Studio Banner](https://img.shields.io/badge/AlignAI_Studio-Pro_AI_Camera-FFD700?style=for-the-badge&logo=apple&logoColor=black)

[![iOS Sideload Build & Release](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml/badge.svg)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml)
[![Latest Release](https://img.shields.io/github/v/release/emlavankhoahienma-hue/ai-smart-framing-camera?color=blue&label=Latest%20IPA&style=flat-square)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/latest)
[![iOS Target](https://img.shields.io/badge/iOS-16.0%2B%20%7C%2017%20%7C%2018-000000.svg?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B%20%7C%20SwiftUI-FA7343.svg?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Apple Neural Engine](https://img.shields.io/badge/Neural_Engine-A11_to_A18_Pro-9945FF.svg?style=flat-square&logo=apple)](https://apple.com)
[![Google Gemini](https://img.shields.io/badge/Google_Gemini-2.5_Flash_%2F_Pro-4285F4.svg?style=flat-square&logo=google)](https://ai.google.dev)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

<p align="center">
  <b>Ứng dụng Camera AI Nhiếp Ảnh Nghệ Thuật Thế Hệ Mới Dành Cho iOS</b><br>
  Tự động tính toán góc chụp vàng theo tỷ lệ nghệ thuật, bám mục tiêu bằng thuật toán lai Optical + Gyro 60Hz, lấy nét thông minh chuẩn Apple Camera, mô phỏng màu phim Leica / Hasselblad tự nhiên thời gian thực.
</p>

[Tải File IPA Mới Nhất](#-hướng-dẫn-tải--cài-đặt-chi-tiết) • [Hành Trình 41 Build](#-hành-trình-41-bản-build--những-gian-khó-vượt-qua) • [Tính Năng Nổi Bật](#-tính-năng-nổi-bật) • [Hướng Dẫn Sử Dụng](#-hướng-dẫn-sử-dụng-chi-tiết) • [Kiến Trúc Kỹ Thuật](#-kiến-trúc-hệ-thống)

---

</div>

## 🌟 Tổng Quan Dự Án

**AlignAI Studio** là ứng dụng camera nhiếp ảnh thông minh tiên phong kết hợp sức mạnh phần cứng **Apple Neural Engine (ANE)** trên chip Apple Silicon và trí tuệ nhân tạo đa phương thức **Google Gemini Cloud AI**.

Ứng dụng biến chiếc iPhone của bạn thành một chuyên gia nhiếp ảnh cá nhân:
- **Nhìn và hiểu cảnh vật**: Nhận diện khuôn mặt, dáng người, hướng ánh nhìn (Lead Room), nhận diện cảnh quan (Hoàng hôn, Chân dung, Phong cảnh, Kiến trúc, Ẩm thực, Đêm...).
- **Tìm điểm vàng bố cục**: Tự động tính toán tọa độ vàng theo **Quy tắc 1/3 (Rule of Thirds)**, **Tỷ lệ vàng Fibonacci (1:1.618)**, **Xoắn ốc vàng (Golden Spiral)**, hoặc **Tâm đối xứng (Center Pro)**.
- **Dẫn hướng người chụp**: Chiếu vòng tròn mục tiêu vàng và tia chỉ dẫn; khi bạn lia camera đưa tâm ngắm trắng trùng khớp với vòng tròn vàng, app sẽ rung phản hồi **Magnetic Snap** và **Tự động chụp hoàn hảo**.

---

## 🧗‍♂️ Hành Trình 41 Bản Build — Những Gian Khó Vượt Qua

Để đạt được độ mượt mà, chính xác và ổn định ở **Build 41**, đội ngũ phát triển đã trải qua một hành trình kỹ thuật vô cùng gian nan với hàng loạt bài toán hóc búa ở tầng hệ điều hành và phần cứng iOS:

```
[Build 1-13: Khởi tạo ý tưởng] ──> [Build 14-32: Khủng hoảng Tracking & Rung giật]
                                                 │
[Build 41: Bám dính hoàn hảo & Tối ưu pin] <── [Build 37-40: Xung đột Camera & Đứng hình]
```

### 1. Cuộc chiến bám mục tiêu: Khử rung vi mô (Micro-Jitter) & Hiện tượng trôi target
- **Vấn đề ban đầu (Build 14 - 32)**: Khi AI đặt vòng tròn vàng, target liên tục bị rung lắc hoặc trôi dạt khi người dùng lia máy. Nếu dùng thuần `VNTrackObjectRequest`, tracker dễ bị bắt nhầm vào nền phía sau. Nếu dùng thuần cảm biến con quay hồi chuyển, góc quay bị sai lệch khi người dùng zoom ống kính.
- **Giải pháp**: Xây dựng thuật toán dung hợp không gian đa tầng (**Hybrid Optical + 60Hz Gyro Inertial Fusion**):
  - **Mắt quang học (`VNTrackObjectRequest`)**: Khóa chặt vào cấu trúc pixel và viền chi tiết của chủ thể thực tế.
  - **Mỏ neo quán tính (`DeviceMotionService` 60Hz)**: Giữ góc quán tính trong không gian 3D khi lia máy siêu nhanh.
  - **Bộ lọc EMA Smoothing thích ứng**: Khử triệt để 100% rung giật vi mô, giữ vòng tròn êm như lụa.

### 2. Thử thách chống che khuất (Occlusion Handling & Outlier Rejection)
- **Vấn đề (Build 33 - 36)**: Khi có người khác hoặc đồ vật vô tình đi ngang qua che khuất chủ thể trong tích tắc, thuật toán tracking quang học bị "bắt nhầm" sang vật che và kéo vòng tròn chạy lung tung.
- **Giải pháp (Build 41)**: 
  - Tích hợp **State Machine Ngoại suy Vận tốc (`smoothedVelocity`)**: Khi mất dấu quang học, hệ thống tự động chuyển sang trạng thái `.predicting` và `.reacquiring`, dùng quán tính vận tốc và gyro để "cầm cự" dự đoán vị trí trong 0.8s - 3.0s.
  - Tích hợp **Outlier Rejection**: Bỏ qua ngay lập tức các khung hình có độ nhảy vị trí bất thường (`maxJumpPerFrame > 0.12`).
  - Khi mất dấu hẳn (`.lost`), app phát tín hiệu rung cảnh báo Haptic và hiển thị thông báo *"Chạm để đặt lại mục tiêu"*.

### 3. Xung đột phần cứng Camera: AVCaptureSession vs ARSession
- **Vấn đề nghẹt thở (Build 37 - 39)**: Khi bấm nút AI, màn hình camera bị đóng băng (đứng hình ở frame cuối). Nguyên nhân là do `ARSession` chạy ngầm cố chiếm quyền camera sau cùng lúc với `AVCaptureSession`, khiến iOS ngắt luồng video (`videoDeviceInUseByAnotherClient`).
- **Giải pháp dứt điểm (Build 40)**: Loại bỏ hoàn toàn sự phụ thuộc vào `ARSession` phần cứng, chuyển 100% việc tracking sang chạy trực tiếp trên luồng `CMSampleBuffer` của `AVCaptureVideoDataOutput`, đồng thời thêm cơ chế tự phục hồi Interruption (`AVCaptureSession.wasInterruptedNotification`). Camera từ đó hoạt động liên tục 60 FPS, không bao giờ bị đơ.

### 4. Bù trừ góc xoay Gyroscope theo độ phóng đại Zoom quang học
- **Vấn đề**: Khi zoom 2x, 3x, 5x, góc nhìn camera bị hẹp lại. Cùng một góc xoay tay thực tế sẽ làm điểm ảnh trên màn hình bay xa hơn gấp nhiều lần, khiến gyro dự đoán bị lệch vị trí.
- **Giải pháp**: Nhân hệ số bù trừ zoom động:
  $$\Delta_{\text{screen}} = \Delta_{\text{gyro}} \times \max(1.0, \text{currentZoom})$$

---

## ✨ Tính Năng Nổi Bật

### 1. 🧠 Dual AI Engine (Google Gemini Cloud + Apple Neural Engine)
- **Gemini 2.5 Flash / Pro Multimodal**: Gửi ảnh chất lượng cao lên Google Gemini để nhận diện bố cục chuyên sâu, nhận phân tích nghệ thuật bằng tiếng Việt và nhận công thức màu độc bản.
- **Apple Neural Engine (Cục bộ)**: Tự động chạy offline 100% trên chip A11 - A18 Pro nếu không có mạng hoặc chưa nhập API Key. Nhận diện khuôn mặt, mắt, dáng người và phân loại bối cảnh theo thời gian thực.

### 2. 📐 5 Quy Tắc Bố Cục Nghệ Thuật
- **Quy tắc 1/3 (Rule of Thirds)**: Tối ưu cho ảnh phong cảnh, chân dung ngoại cảnh, có tính toán khoảng trống phía trước hướng nhìn (Looking Room).
- **Tỷ lệ vàng (Golden Ratio 1.618)**: Giao điểm tỷ lệ vàng chuẩn mực nghệ thuật cổ điển.
- **Xoắn ốc Fibonacci (Golden Spiral)**: Dẫn dắt ánh mắt người xem theo đường cong thị giác tự nhiên.
- **Tâm đối xứng (Center Pro)**: Tạo chiều sâu thị giác đối xứng cho kiến trúc và ẩm thực.
- **AI Tự động (Dynamic AI)**: AI tự phân tích thể loại ảnh để kích hoạt quy tắc tối ưu nhất.

### 3. 🎯 Bám Mục Tiêu Thông Minh 4 Cấp Độ (Tracking Quality)
| Trạng thái | Biểu hiện trên màn hình | Hành vi của Camera |
| :--- | :--- | :--- |
| **`Locked`** | Vòng tròn vàng/xanh liền nét, radar sóng | Bám dính 100% vào vật thể, sẵn sàng Auto-Capture |
| **`Predicting`** | Vòng tròn nét đứt màu cam (Amber Dash) | Đang bị che khuất ngắn hạn, tự dự đoán bằng vận tốc + Gyro |
| **`Reacquiring`** | Vòng tròn cam + Nhãn *"Đang tìm lại..."* | Mất dấu quang học, giữ mỏ neo tại vị trí cuối cùng |
| **`Lost`** | Vòng tròn đỏ + Nhãn *"Chạm để đặt lại"* | Rung Haptic cảnh báo, cho phép chạm màn hình để khóa lại |

### 4. 🔍 Lấy Nét Thông Minh (Smart Autofocus Pro - Apple Camera Style)
- Tự động ưu tiên lấy nét theo phân cấp: **AI Target (nếu có) > Khuôn mặt gần nhất > Vật thể nổi bật (Saliency) > Tâm giữa**.
- Hiển thị ô vuông lấy nét màu vàng với 4 góc kẻ vạch đặc trưng của iOS.
- Tự động lấy nét lại tức thì khi bối cảnh thay đổi (`subjectAreaDidChangeNotification`).

### 5. 🎞️ Kho Màu Phim Điện Ảnh & Leica Natural Color
- **Leica / Hasselblad AI Natural Color**: Tự động cân bằng độ no màu, tương phản nhẹ, giữ tone da hồng hào tự nhiên.
- **Fuji Pro 400H**: Tone xanh pastel thanh khiết, tôn da trắng sáng.
- **Kodak Portra 400**: Tone ấm vàng vintage, chuyển màu vùng sáng mịn màng.
- **Teal & Orange Hollywood**: Tương phản mạnh mẽ giữa da người và hậu cảnh.
- **Sunset Glow**: Rực rỡ, nhấn mạnh ánh sáng giờ vàng (Golden Hour).
- **Noir High Contrast**: Đen trắng tương phản cao nghệ thuật đường phố.
- **Vintage 70s & Street Classic**: Hoài niệm thập niên 70 với độ sắc nét ấn tượng.

### 6. 📱 Đầy Đủ Chức Năng Camera Pro
- Chụp ảnh độ phân giải gốc cảm biến (lưu nguyên vẹn tỷ lệ crop của AI Zoom).
- Quay video Full HD / 4K chống rung Cinematic Extended.
- Hỗ trợ chụp **Live Photo** chuẩn Apple.
- Điều khiển đèn Flash (Auto, On, Off).
- Bù trừ sáng thủ công (Exposure Bias $\pm 2.0$ EV).
- Chạm bất kỳ điểm nào trên khung hình để đặt/khóa lại Target.
- Lưu ảnh trực tiếp vào ứng dụng Ảnh (Photos Library) với 1 chạm.

---

## 📱 Hướng Dẫn Sử Dụng Chi Tiết

### Cách 1: Chụp Ảnh với Bố Cục AI Thông Minh (Khuyên dùng)
1. Mở ứng dụng **AlignAI Studio**.
2. Hướng camera về phía chủ thể hoặc cảnh bạn muốn chụp.
3. Nhấn vào **Nút AI màu vàng** (hoặc biểu tượng cây đũa thần ở góc trên).
4. AI sẽ phân tích trong chớp mắt và đặt **Vòng tròn mục tiêu màu vàng** tại vị trí bố cục đẹp nhất.
5. Bạn nhẹ nhàng lia điện thoại theo **Tia chỉ dẫn (Guidance Ray)** để đưa **Tâm ngắm trắng** ở giữa màn hình đè khớp lên **Vòng tròn vàng**.
6. Khi 2 tâm trùng khớp:
   - Điện thoại sẽ rung **Magnetic Snap**.
   - Vòng tròn chuyển sang màu xanh lá cây rực rỡ.
   - Đồng hồ đếm ngược tự động kích hoạt ($1s$) và **Tự động chụp bức ảnh hoàn hảo**!
7. Xem lại ảnh đã chụp kèm công thức màu AI và nhấn **"Lưu vào máy"**.

### Cách 2: Đặt Lại Target Thủ Công Khi Muốn Đổi Chủ Thể
- Nếu AI chọn chủ thể mà bạn muốn hướng vào đối tượng khác, bạn chỉ cần **chạm ngón tay trực tiếp vào điểm mong muốn trên màn hình**. Vòng tròn target sẽ lập tức dời đến đó và khóa chặt vào đối tượng mới.

### Cách 3: Chụp Ảnh Nhanh Thủ Công (Không Cần AI)
- Bạn có thể nhấn **Nút chụp màu trắng lớn** ở giữa bất kỳ lúc nào để chụp ảnh ngay lập tức như ứng dụng Camera mặc định của Apple.

### Cách 4: Tinh Chỉnh Trong Cài Đặt (Biểu Tượng Bánh Răng)
- **Nhập Gemini API Key**: Dán khóa API Google Gemini miễn phí của bạn để mở khóa phân tích AI Cloud.
- **Chọn Mô Hình AI**: Tự động chuyển đổi thông minh giữa `Gemini 2.5 Flash`, `Gemini 2.5 Pro`, `Gemini 1.5 Flash`...
- **Độ nhạy bám mục tiêu (Tracking)**: Chọn mức *Thấp* (ổn định cao), *Vừa* (tiêu chuẩn), hoặc *Cao* (phản hồi siêu nhanh).
- **Bật/Tắt Auto-Zoom**: Cho phép AI tự động phóng to ống kính theo tỷ lệ chủ thể.

---

## 📥 Hướng Dẫn Tải & Cài Đặt Chi Tiết

Bạn có thể cài đặt **AlignAI Studio** lên mọi thiết bị iPhone/iPad (chạy iOS 16.0 đến iOS 18+) hoàn toàn miễn phí mà không cần Jailbreak.

### 📦 Tải File Cài Đặt (IPA)
👉 **[Truy cập trang GitHub Releases để tải file `AISmartFramingCamera.ipa` bản mới nhất](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/latest)**

---

### Phương Pháp 1: Cài đặt qua Sideloadly (Khuyên dùng — Cực kỳ dễ trên Windows & Mac)

1. Tải và cài đặt phần mềm **[Sideloadly](https://sideloadly.io/)** trên máy tính Windows hoặc macOS.
2. Mở Sideloadly và kết nối iPhone của bạn với máy tính bằng cáp sạc USB.
3. Nhấn **"Tin cậy máy tính này" (Trust This Computer)** trên màn hình iPhone nếu được hỏi.
4. Kéo tệp `AISmartFramingCamera.ipa` vừa tải ở trên thả vào ô vuông lớn trong Sideloadly.
5. Nhập tài khoản **Apple ID** của bạn vào ô *Apple ID* (để ký chứng chỉ cá nhân miễn phí).
6. Nhấn nút **Start** và đợi khoảng 30 - 60 giây cho đến khi hiện thông báo `Done!`.
7. **Kích hoạt ứng dụng trên iPhone**:
   - Mở iPhone vào **Cài đặt (Settings)** > **Cài đặt chung (General)** > **Quản lý VPN & Thiết bị (VPN & Device Management)**.
   - Nhấn vào email Apple ID của bạn trong mục *Ứng dụng của nhà phát triển*.
   - Nhấn **Tin cậy (Trust)**.
8. Trở về màn hình chính và mở **AlignAI Studio** để bắt đầu sáng tạo!

---

### Phương Pháp 2: Cài đặt qua AltStore (Trực tiếp không dây)

1. Mở ứng dụng **AltStore** trên iPhone của bạn.
2. Vào tab **My Apps**, nhấn vào dấu **`+`** ở góc trên bên trái.
3. Chọn tệp `AISmartFramingCamera.ipa` đã tải trong thư mục Tệp (Files).
4. AltStore sẽ tự động cài đặt ứng dụng vào máy của bạn.

---

### Phương Pháp 3: Cài đặt qua TrollStore (Dành cho máy có TrollStore)

1. Tải file `AISmartFramingCamera.ipa` về iPhone qua Safari.
2. Mở file trong ứng dụng **Tệp (Files)** > Nhấn **Chia sẻ (Share)** > Chọn **TrollStore**.
3. TrollStore sẽ cài đặt vĩnh viễn không bao giờ bị hết hạn chứng chỉ 7 ngày!

---

## 🏛️ Kiến Trúc Hệ Thống (Clean MVVM Architecture)

```
AISmartFramingCamera/
├── App/
│   └── AISmartFramingCameraApp.swift          # Entry point SwiftUI
├── Models/
│   └── FramingModels.swift                   # Data models, TrackingQuality, FilmPresets, ColorParams
├── Services/
│   ├── CameraService.swift                   # AVFoundation 4K Photo Capture, Continuous AF/AE & Recovery
│   ├── VisionFramingEngine.swift             # Neural Engine Pipeline (Face, Pose, Saliency, VNTrackObject)
│   ├── DeviceMotionService.swift             # 60Hz Gyroscope Inertial Odometry & Attitude Math
│   ├── CompositionCalculator.swift           # Thuật toán tính góc vàng Rule of Thirds / Golden Ratio
│   ├── FilmFilterEngine.swift                # Metal GPU CoreImage Color Grading Recipes
│   ├── HapticFeedbackService.swift           # Hệ thống xúc giác Magnetic Snap & Tracking Warning
│   ├── GeminiService.swift                   # Google Gemini Multimodal Cloud AI Integration
│   └── ARCompositionSession.swift            # AR state manager (Non-intrusive safe lifecycle)
├── ViewModels/
│   └── CameraViewModel.swift                 # Main Actor State Machine Orchestration
├── Views/
│   ├── CameraMainView.swift                  # Giao diện chính Apple Camera Pro
│   ├── CameraPreviewView.swift               # AVCaptureVideoPreviewLayer UIViewRepresentable
│   ├── ARFramingOverlayView.swift            # Lưới bố cục, Target Circle động, Focus Square
│   ├── AIStatusHUDView.swift                 # Dynamic Island Status Pill & % Confidence Badge
│   ├── CameraControlsView.swift              # Nút chụp Pro, Zoom Selector, Thanh chọn Film
│   ├── CapturedPhotoPreviewView.swift        # AI Color Studio, Before/After & Lưu ảnh
│   └── SettingsSheetView.swift               # Menu Cài đặt, Nhập Key Gemini, Độ nhạy Tracking
├── Assets.xcassets/                          # Icons, App Assets
├── Info.plist                                # Quyền Privacy Camera, Microphone & Photo Library
└── .github/workflows/ios-build.yml           # CI/CD tự động build unsigned IPA trên macOS runner
```

---

## ⚙️ Yêu Cầu Thiết Bị

- **Hệ điều hành**: iOS 16.0, iOS 17.0, iOS 18.0 trở lên.
- **Phần cứng hỗ trợ**: iPhone trang bị vi xử lý Apple Silicon từ **A11 Bionic** đến **A18 Pro** (iPhone 8, iPhone X, XS, 11, 12, 13, 14, 15, 16 Series).
- **RAM**: Tối thiểu 3GB RAM để xử lý mượt mà đồng thời Neural Engine và CoreImage Metal.

---

## 👨‍💻 Thông Tin Tác Giả & Hỗ Trợ

<div align="center">

**Lead iOS & AI Camera Engineer: VanKhoa**

📧 **Email:** [tranvantrinhhd@gmail.com](mailto:tranvantrinhhd@gmail.com)  
📱 **Hotline / Zalo:** `+84 344 197 212`  
🐙 **GitHub:** [@emlavankhoahienma-hue](https://github.com/emlavankhoahienma-hue)

---

*AlignAI Studio — Mang đẳng cấp nhiếp ảnh chuyên nghiệp vào tầm tay bạn.*

</div>
