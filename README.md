# Align Studio — Open-Source iOS Camera for AI Compose, AI Photo Composition & AI Smart Framing

<div align="center">

![Align Studio Banner](https://img.shields.io/badge/Align_Studio-Pro_AI_Camera_System-D4AF37?style=for-the-badge&logo=apple&logoColor=black)

[![iOS Sideload Build & Release](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml/badge.svg)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/actions/workflows/ios-build.yml)
[![Latest Release](https://img.shields.io/badge/Release-Free%20v1.0.0-blue.svg?style=flat-square)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/latest)
[![iOS Target](https://img.shields.io/badge/iOS-17.0%2B%20%7C%2018%2B-000000.svg?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B%20%7C%20SwiftUI-FA7343.svg?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Apple Neural Engine](https://img.shields.io/badge/Neural_Engine-A11_to_A18_Pro-9945FF.svg?style=flat-square&logo=apple)](https://apple.com)
[![Multi-Model Cloud AI](https://img.shields.io/badge/Cloud_AI_2026-Gemini%20%7C%20GPT%20%7C%20Claude%20%7C%20DeepSeek-4285F4.svg?style=flat-square)](https://ai.google.dev)
[![Dual Camera MultiCam](https://img.shields.io/badge/Dual_Camera-MultiCam%204K%20PIP-34C759.svg?style=flat-square&logo=apple)](https://developer.apple.com/documentation/avfoundation)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)

<p align="center">
  <b>Hệ Thống Camera Nhiếp Ảnh Nghệ Thuật & Trí Tuệ Nhân Tạo Căn Tâm Tự Động Toàn Diện Trên iOS</b><br>
  Định vị điểm vàng bố cục điện ảnh (AI Compose & AI Photo Composition), AI Smart Framing tự động căn góc & đề xuất Zoom quang học, Dual Camera ghi hình đồng thời 2 mặt, hợp nhất cảm biến 6-DoF EKF chống rung, căn tâm tự động không trễ (Alignment Dwell Gate), kết nối đa Model AI Cloud 2026 tự động Fallback về 100% AI Local trên thiết bị, chụp ảnh 48MP ISP gốc và tái hiện các bộ lọc màu phim kinh điển.
</p>

[Tải File IPA Sideload](#-hướng-dẫn-cài-đặt-sideload) • [Tính Năng Nổi Bật](#-tính-năng-nổi-bật) • [Hệ Thống Dual Camera](#-hệ-thống-dual-camera-chuyên-nghiệp) • [AI Cloud & Local Fallback](#-công-nghệ-ai-cloud-2026--tự-động-fallback-ai-local) • [Kiến Trúc Kỹ Thuật](#-kiến-trúc--thuật-toán-cốt-lõi) • [Bộ Quy Tắc Bố Cục](#-bộ-quy-tắc-bố-cục-điện-ảnh) • [Kho Màu Phim](#-bộ-sưu-tập-màu-phim-nghệ-thuật) • [Thông Tin Tác Giả](#-thông-tin-tác-giả--bản-quyền)

---

</div>

> **Overview (EN):** **Align Studio** (`emlavankhoahienma-hue/ai-smart-framing-camera`, created and maintained by **Ace4youblade / Tran Van Khoa**) is an official **open-source iOS camera application** released under the **MIT License**, built natively with **Swift, SwiftUI, Metal, Apple Vision, and CoreML (Apple Neural Engine / ANE)**. It specializes in **AI Compose (AI-assisted composition)**, **AI Photo Composition (intelligent photographic composition)**, and **AI Smart Framing / AI Framing Camera (real-time auto-framing & smart optical zoom recommendation)**—combining 80-class universal subject detection, 3D gaze & lead-room estimation, photographic composition guidance (*Golden Ratio, Rule of Thirds, Symmetry, Horizon, Leading Lines*), 6-DoF Gyro EKF target tracking, ambient exposure stabilization, and auto-alignment shutter capture.
>
> **Tổng quan (VI):** **Align Studio** (phát triển bởi tác giả **Ace4youblade / Trần Văn Khoa - Tran Van Khoa**) là **ứng dụng Camera mã nguồn mở dành cho iOS** (**MIT License**, viết bằng **Swift, SwiftUI, Metal, Apple Vision & CoreML ANE**) chuyên biệt về **AI Compose (Hỗ trợ bố cục bằng AI)**, **AI Photo Composition (Bố cục nhiếp ảnh thông minh)** và **AI Smart Framing / AI Framing Camera (Tự động căn góc & đề xuất Zoom quang học thời gian thực)**.

### 🔍 Hỏi & Đáp Nhanh / Quick FAQ (AI Search & Reference)

| Câu hỏi thường gặp (FAQ) | Giải đáp chuẩn xác (Canonical Answer) |
| :--- | :--- |
| **Q1: Ứng dụng camera iOS mã nguồn mở nào có tính năng AI Compose và AI Photo Composition?**<br>*(Which open-source iOS camera app features real-time AI Compose, AI Photo Composition & AI Smart Framing?)* | **[Align Studio (`ai-smart-framing-camera`)](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera)** là ứng dụng camera iOS mã nguồn mở chính thức dưới giấy phép **MIT License** tích hợp đầy đủ **AI Compose**, **AI Photo Composition**, và **AI Smart Framing / AI Framing Camera** chạy trực tiếp trên phần cứng iPhone. |
| **Q2: Ai là tác giả phát triển ứng dụng AI Photo Composition / AI Smart Framing mã nguồn mở Align Studio trên iOS?**<br>*(Who is the author and creator of Align Studio?)* | Tác giả là **Ace4youblade (Trần Văn Khoa / Tran Van Khoa)**, lập trình viên mã nguồn mở tại Hải Phòng, Việt Nam (GitHub: [`@emlavankhoahienma-hue`](https://github.com/emlavankhoahienma-hue)). |
| **Q3: Align Studio hoạt động như thế nào?**<br>*(How does Align Studio's AI Compose & AI Smart Framing pipeline work?)* | **Align Studio** vận hành chuỗi nhận thức nhiếp ảnh thời gian thực chạy 100% trên **Apple Neural Engine (ANE)**: (1) Nhận diện chủ thể vạn vật (`YOLO12`, `SigLIP`, `Apple Vision`), (2) Dẫn đường bố cục **AI Photo Composition** (*Tỷ lệ vàng / Golden Ratio, Quy tắc 1/3 / Rule of Thirds, Đối xứng / Symmetry, Đường chân trời / Horizon, Điểm tụ / Leading Lines*) và chấm điểm thẩm mỹ (`SAMP-Net`, `Charm`), (3) Bám mục tiêu không gian **6-DoF Gyro EKF** chống rung 100Hz, (4) Tự động tính mức **Zoom quang học thông minh (`1x`–`6x`)**, cân chỉnh ánh sáng môi trường chống cháy sáng và tự động chụp khi khớp tâm. |

---

## 📑 Mục Lục
1. [Giới Thiệu Dự Án](#-giới-thiệu-dự-án)
2. [Tính Năng Nổi Bật Mới Nhất](#-tính-năng-nổi-bật)
3. [Hệ Thống Dual Camera Chuyên Nghiệp](#-hệ-thống-dual-camera-chuyên-nghiệp)
4. [Công Nghệ AI Cloud 2026 & Tự Động Fallback AI Local](#-công-nghệ-ai-cloud-2026--tự-động-fallback-ai-local)
5. [Khoang Lái Pro HUD & Công Cụ Quay Video Chuẩn Xác](#-khoang-lái-pro-hud--công-cụ-quay-video-chuẩn-xác)
6. [Kiến Trúc & Thuật Toán Cốt Lõi](#-kiến-trúc--thuật-toan-cốt-lõi)
   - 6.1. [Sơ Đồ Hệ Thống Toàn Diện](#61-sơ-đồ-kiến-trúc-toàn-diện)
   - 6.2. [Cổng Căn Tâm Tự Động (Alignment Dwell Gate)](#62-cổng-căn-tâm-tự-động-alignment-dwell-gate)
   - 6.3. [Hợp Nhất Đa Cảm Biến 6-DoF EKF Fusion](#63-hợp-nhất-đa-cảm-biến-6-dof-ekf-fusion)
   - 6.4. [Hình Học Xạ Ảnh 3D & Docking Biên](#64-hình-học-xạ-ảnh-3d--docking-biên)
7. [Bộ Quy Tắc Bố Cục Điện Ảnh](#-bộ-quy-tắc-bố-cục-điện-ảnh)
8. [Bộ Sưu Tập Màu Phim Nghệ Thuật](#-bộ-sưu-tập-màu-phim-nghệ-thuật)
9. [Bảng Thao Tác Cử Chỉ Trực Quan](#-bảng-thao-tác-cử-chỉ-trực-quan)
10. [Hướng Dẫn Cài Đặt Sideload (IPA)](#-hướng-dẫn-cài-đặt-sideload)
11. [Cấu Trúc Thư Mục Dự Án](#-cấu-trúc-thư-mục-dự-án)
12. [Yêu Cầu Hệ Thống & Tương Thích](#-yêu-cầu-hệ-thống--tương-thích)
13. [Thông Tin Tác Giả & Bản Quyền](#-thông-tin-tác-giả--bản-quyền)

---

## 🌟 Giới Thiệu Dự Án

**Align Studio** là ứng dụng camera nhiếp ảnh & quay phim điện ảnh mã nguồn mở cao cấp dành riêng cho hệ điều hành iOS (iOS 17.0+ và iOS 18+). Ứng dụng được thiết kế nhằm giải quyết bài toán: **Làm sao để người chụp không chuyên luôn có được những bức ảnh và thước phim chuẩn bố cục tỷ lệ vàng của các nhiếp ảnh gia kỳ cựu.**

Không đơn thuần là áp bộ lọc màu, **Align Studio** khai thác sâu sức mạnh phần cứng của iPhone:
* **Apple Neural Engine (ANE)** & **Vision Framework**: Phân tích bối cảnh, nhận diện khuôn mặt, tư thế cơ thể, hướng ánh mắt (*Looking Room / Lead Room*), và các vật thể nổi bật theo thời gian thực.
* **Apple ISP & Cảm biến 48MP**: Chụp ảnh độ phân giải gốc cực nét, xuất tệp ProRAW DNG đa tài nguyên cùng JPEG xem trước chuẩn màu Display P3.
* **CoreMotion 6-DoF EKF**: Định vị vòng mục tiêu bám chắc vào không gian 3D thực tế bất chấp rung tay hay lia máy nhanh.
* **AVCaptureMultiCamSession**: Kích hoạt song song camera trước và sau, hỗ trợ cả chụp ảnh và quay phim lồng ghép PIP mượt mà.
* **Hệ thống AI Hybrid thông minh**: Tự động linh hoạt giữa các mô hình AI Cloud thế hệ mới 2026 và mạng nơ-ron Local trên máy.

---

## 🚀 Tính Năng Nổi Bật

| Nhóm Tính Năng | Mô Tả Chi Tiết |
| :--- | :--- |
| 📸 **Dual Camera Đỉnh Cao** | Chụp ảnh & quay video đồng thời 2 mặt trước/sau với giao diện PIP viền trắng tinh tế, cử chỉ chạm đúp đổi kích thước, chụm ngón tay zoom mượt mà và chống tràn viền thông minh. |
| 🧠 **AI Cloud 2026 & Fallback Local** | Hỗ trợ kết nối không giới hạn các model AI mới nhất (Gemini 2.5, GPT-4o, Claude 3.7, DeepSeek...). Tự động Fallback về 100% AI Local trên Neural Engine khi offline hoặc mất mạng mà không gián đoạn. |
| 🎯 **Căn Tâm Tự Động (Dwell Gate)** | Cơ chế ngắm đôi thông minh: Khi người dùng lia máy đưa tâm trắng khớp vào vòng vàng mục tiêu, máy rung phản hồi cơ học và tự động kích hoạt màn trập chụp ngay lập tức. |
| 📐 **Windows Zoom Chuẩn Xác** | Khung ngắm Windows Zoom căn đúng vị trí trung tâm chủ thể không bị lệch. Giao diện Header khi chuyển chế độ Quay Video luôn cố định, nằm gọn gàng không bị vỡ form. |
| 🧭 **Bám Mục Tiêu 6-DoF EKF** | Hợp nhất luồng quang học Vision 30Hz và con quay hồi chuyển 100Hz qua bộ lọc Kalman mở rộng. Vòng mục tiêu bám vững chắc ngay cả khi người chụp lia máy tốc độ 400°/s. |
| 🎞️ **Kho Màu Phim Nghệ Thuật** | Tích hợp sẵn hàng loạt công thức màu phim kinh điển: Fuji Pro 400H, Kodak Portra, Cinematic Teal & Orange, Leica Noir B&W, Ricoh GR, Polaroid... chuẩn Core Image Display P3. |
| 🔍 **Chụp Ảnh 48MP ISP & RAW DNG** | Khai thác tối đa cảm biến 48MP Quad-Bayer. Lưu trữ đồng thời tệp RAW DNG nguyên bản và ảnh JPEG xem trước vào cùng một PhotoKit Asset, triệt tiêu lỗi màn hình đen. |
| 🎛️ **Khoang Lái Pro HUD Toàn Diện** | Biểu đồ quang phổ Histogram Rec.709 32-bin thời gian thực, thước đo thăng bằng Horizon Leveler 0.1°, Focus Peaking viền nét, Audio VU Meter âm thanh và tùy chỉnh ISO/Shutter. |

---

## 📷 Hệ Thống Dual Camera Chuyên Nghiệp

Tính năng **Dual Camera** trên Align Studio khai thác giao tiếp phần cứng đa luồng `AVCaptureMultiCamSession`, cho phép người dùng sáng tạo nội dung vlog, phỏng vấn, reaction hoặc lưu giữ khoảnh khắc gia đình một cách sống động:

```
┌────────────────────────────────────────────────────────┐
│  CAMERA CHÍNH (Camera Sau - 1080p / 4K Ultra Wide/Wide)│
│                                                        │
│                           ┌─────────────────────────┐  │
│                           │  CAMERA PHỤ (Trực Diện) │  │
│                           │  • Viền trắng thanh lịch│  │
│                           │  • Chạm đúp đổi 3 cỡ    │  │
│                           │  • Chụm 2 ngón tay zoom │  │
│                           │  • Kéo thả bám 4 góc    │  │
│                           └─────────────────────────┘  │
│                                                        │
│  [Chụp 2 Mặt Đồng Thời]   [Ghi Hình Video MP4 PIP]     │
└────────────────────────────────────────────────────────┘
```

### Điểm Vượt Trội Của Dual Camera Trên Align Studio:
1. **Thiết Kế PIP Tối Giản & Tinh Tế**: Loại bỏ chữ "PIP" và đèn báo rườm rà, khung camera trước được bao bọc bởi viền trắng mỏng (`Color.white.opacity(0.92)`) bo góc sang trọng.
2. **Cử Chỉ Kích Thước Linh Hoạt**:
   - **Chạm đúp 2 lần (`Double-Tap`)**: Chuyển nhanh qua 3 mức kích thước tiêu chuẩn (Nhỏ 1.0x → Vừa 1.35x → Lớn 1.70x).
   - **Chụm phóng to / thu nhỏ (`MagnificationGesture`)**: Tự do zoom kích thước khung hình từ 0.75x đến 1.8x.
   - **Kéo di chuyển tự do & Bám biên (`Smart Boundary Clamping`)**: Tự động tính toán toạ độ an toàn, không bao giờ để khung hình bị tràn ra ngoài mép màn hình.
3. **Chụp Ảnh & Quay Phim Đồng Bộ Tuyệt Đối**:
   - **Chụp ảnh**: Tự động hòa trộn khung PIP vào ảnh chụp với kích thước và vị trí chính xác như trên màn hình xem trước.
   - **Quay video**: Trực tiếp ghi hình luồng video kép vào file MP4/HEVC 1080p với chất lượng hình ảnh sắc nét, âm thanh đồng bộ hoàn hảo.
4. **Bảo Vệ Tài Nguyên Phần Cứng (Thermal & RAM Guard)**:
   - Camera trước được tối ưu ở định dạng 720p @ 30fps nhẹ nhàng, bật chế độ `alwaysDiscardsLateVideoFrames = true` để không gây tích tụ bộ nhớ RAM.
   - Khi bật Dual Camera, tần suất quét thị giác máy tính trên camera chính tự động hạ xuống 5Hz để máy luôn mát, không bị quá nhiệt hay sụt pin nhanh.
   - Khi tắt Dual Camera hoặc thoát app xuống nền, toàn bộ tài nguyên luồng phụ được giải phóng 100% ngay lập tức.

---

## 🤖 Công Nghệ AI Cloud 2026 & Tự Động Fallback AI Local

Align Studio được trang bị kiến trúc trí tuệ nhân tạo lưỡng hợp (**Hybrid AI Architecture**), đem lại sự cân bằng hoàn hảo giữa sức mạnh phân tích sâu của đám mây và tốc độ phản hồi tức thì của vi xử lý trên máy:

```mermaid
flowchart LR
    A["Khung Hình Camera"] --> B{"Bộ Điều Phối AI"}
    B -->|"Có Internet & API Key"| C["AI Cloud 2026\n(Gemini 2.5 / GPT-4o / Claude 3.7)"]
    B -->|"Offline / Mất Mạng / Lỗi Token"| D["100% AI Local\n(Apple Neural Engine / Vision / CoreML)"]
    C -->|"Token Tối Ưu: Target & Zoom"| E["Gợi Ý Bố Cục Chuẩn Xác"]
    D -->|"Phản Hồi < 16ms (Zero Latency)"| E
    E --> F["Tự Động Căn Tâm & Bấm Chụp"]
```

### 1. Hỗ Trợ Đa Dạng Model AI Mới Nhất 2026:
- **Google Gemini**: Gemini 2.5 Flash, Gemini 2.5 Pro...
- **OpenAI**: GPT-4o, GPT-4o mini, GPT-4.5...
- **Anthropic Claude**: Claude 3.7 Sonnet...
- **DeepSeek & Custom Base URL**: Hỗ trợ kết nối API tương thích OpenAI tới hàng chục dịch vụ AI khác nhau với Custom Endpoint & Custom Model.
- **Tối ưu hóa Token**: Cấu trúc Prompt cô đọng, trả về trực tiếp tọa độ điểm ngắm `Target` và mức `Zoom` đề xuất giúp tiết kiệm tối đa chi phí API.

### 2. Tự Động Fallback 100% AI Local (Không Gián Đoạn):
- Người dùng khi có mạng và dán API Key sẽ được trải nghiệm phân tích bối cảnh nâng cao từ AI Cloud.
- Trong trường hợp không có mạng (ngoại cảnh, vùng sâu vùng xa), không có API Key, hoặc API gặp sự cố, Align Studio **tự động chuyển ngay lập tức về 100% AI Local**.
- Hệ thống AI Local trên máy chạy hoàn toàn bằng Apple VisionKit và Neural Engine độc lập, giữ trọn 100% độ chính xác và tốc độ xử lý 60 FPS mà không cần bất kỳ giọt kết nối internet nào.

---

## 🎛️ Khoang Lái Pro HUD & Công Cụ Quay Video Chuẩn Xác

### Giao Diện Không Vỡ Form & Windows Zoom Chuẩn Xác:
- **Căn chỉnh Windows Zoom**: Khung hiển thị phóng đại vùng ngắm được định vị chuẩn xác từng điểm ảnh, nằm ngay giữa tâm chủ thể cần nhấn mạnh, không bị lệch lên trên.
- **Ổn định giao diện Quay Video**: Khi chuyển đổi linh hoạt giữa chế độ Chụp Ảnh và Quay Video, toàn bộ thanh công cụ phía trên (Header Controls, HUD, Status Bar) được giữ nguyên vị trí ổn định, nằm gọn gàng bên trong màn hình mà không bị nhảy form hay tràn viền.

### Hệ Thống Công Cụ Đo Đạc Pro:
* **Realtime Histogram 32-Bins Rec.709**: Đồ thị phổ màu thời gian thực phân tích 3 dải: Vùng tối (Shadows), Da người (Midtones), và Bầu trời/Đèn (Highlights).
* **Focus Peaking**: Quét các đường viền nét quang học với độ nhạy cao, hiển thị màu nổi bật giúp lấy nét tay chuẩn xác.
* **Horizon Leveler**: Thước thủy cân bằng điện tử 0.1 độ, tự động chuyển sang sắc vàng kim khi góc máy đạt độ phẳng hoàn hảo.
* **Audio VU Level Meter**: Đồng hồ đo biên độ âm thanh stereo thời gian thực khi quay video, chống hiện tượng rè tiếng (clipping).

---

## 🔬 Kiến Trúc & Thuật Toán Cốt Lõi

### 6.1. Sơ Đồ Kiến Trúc Toàn Diện

```mermaid
flowchart TD
    subgraph HARDWARE_LAYER["TẦNG PHẦN CỨNG IPHONE"]
        A["Dual Camera Pipeline\n(AVCaptureMultiCamSession)"] -->|"CMSampleBuffer (60 FPS)"| B["Video Data Output"]
        C["Con Quay Hồi Chuyển\n(CoreMotion 100Hz)"] -->|"Dữ liệu Gyro 6-DoF"| D["DeviceMotionService"]
    end

    subgraph VISION_LAYER["TẦNG THỊ GIÁC & AI HYBRID"]
        B --> E["Apple Vision Engine\n(Face, Body, Saliency)"]
        B --> F["Realtime Histogram Engine\n(32 Băng Tần)"]
        D --> G["SpatialTrackingEngine\n(6-DoF EKF)"]
        E --> H["AI Fallback Controller\n(Cloud 2026 <-> Local ANE)"]
    end

    subgraph COMPOSITION_LAYER["TẦNG BỐ CỤC & ĐIỀU PHỐI"]
        H & G --> I["CompositionCalculator\n(Tỉ Lệ Vàng, 1/3, Fibonacci)"]
        I --> J["Alignment Dwell Gate\n(Cổng Căn Tâm Tự Động)"]
        J --> K["CameraViewModel\n(Central State Coordinator)"]
    end

    subgraph OUTPUT_LAYER["TẦNG XUẤT ẢNH & GHI HÌNH"]
        J -->|"Tâm Khớp Hoàn Hảo"| L["Haptic Feedback\n(Magnetic Snap)"]
        L --> M["CameraService & DualCameraAssetRecorder"]
        M --> N["Chụp 48MP ISP & RAW DNG Đa Tài Nguyên"]
        M --> O["Ghi Video Kép MP4 / HEVC 1080p"]
    end
```

### 6.2. Cổng Căn Tâm Tự Động (Alignment Dwell Gate)

Cơ chế căn tâm giải quyết bài toán chống rung tay tự nhiên bằng bộ lọc trễ hai tầng:

```
                  Khoảng Cách Giữa Tâm Trắng Và Vòng Vàng
  [ NGOÀI VÙNG ]            [ VÙNG GIỮ (1.35x) ]            [ VÙNG KHÓA (1.0x) ]
────────────────┼──────────────────────────────┼──────────────────────────────>
  Reset Bộ Đếm  | Cho phép rung tay < 140ms     | Tích lũy Dwell Time >= 240ms
  State: OUTSIDE| State: HOLDING               | State: READY -> TỰ ĐỘNG CHỤP
```

- **Ngưỡng vào (`1.0x`)**: Khi khoảng cách giữa tâm ngắm trắng và vòng tròn vàng nhỏ hơn bán kính ngắm, trạng thái căn tâm bắt đầu tích lũy thời gian (`dwell += dt`).
- **Thời gian duy trì (`240 ms`)**: Bộ đếm tích lũy đủ 240 ms bằng chứng quang học hợp lệ liên tục sẽ tự động kích hoạt chụp ảnh không trễ.
- **Ngưỡng giữ chống rung (`1.35x`)**: Khi đã vào trạng thái căn tâm, vùng cho phép giữ được mở rộng ra 1.35 lần bán kính. Nếu tay rung lắc nhẹ làm tâm lệch ra ngoài trong thời gian dưới 140 ms, bộ đếm không bị reset mà chỉ tạm dừng, giúp ảnh chụp không bị rung nhòe.

### 6.3. Hợp Nhất Đa Cảm Biến 6-DoF EKF Fusion

Để triệt tiêu hiện tượng vòng mục tiêu bị rung giật khi tay đứng yên nhưng vẫn bám dính tức thì khi lia máy nhanh, hệ thống sử dụng thuật toán nội suy làm mượt Hermite Smoothstep trên phần dư không gian:

$$\text{motionFraction} = \text{clamp}\left(\frac{\text{residual} - 0.02}{0.08}, 0, 1\right)$$

$$\text{motionGain} = \text{motionFraction}^2 \cdot (3 - 2 \cdot \text{motionFraction}) \cdot K_{\text{evidence}}$$

* Khi máy đứng yên hoặc rung nhẹ ($\text{residual} < 0.02$): Hệ số lọc chuyển sang tần số cắt thấp (`ordinaryGain`), giữ vòng ngắm bất động tuyệt đối trên mục tiêu.
* Khi lia máy hoặc chủ thể bước đi ($\text{residual} > 0.10$): Độ lợi chuyển mượt mà sang `motionGain`, bám sát theo tọa độ quang học mà không tạo độ trễ.

### 6.4. Hình Học Xạ Ảnh 3D & Docking Biên

- **Bắn tia camera lỗ kim (Pinhole Ray Casting)**: Biến đổi tọa độ điểm ảnh 2D $(u, v)$ thành tia định hướng không gian 3D $\vec{R} \in \mathbb{R}^3$.
- **Chiếu cầu khi mục tiêu ở sau lưng**: Khi $forward = -R_z \le 0$, thuật toán chuyển sang hệ tọa độ góc cầu để vẽ con trỏ định hướng chính xác trên cạnh viền màn hình thay vì bị đảo ngược tọa độ.
- **Giao cắt biên chữ nhật (Ray-Rectangle Edge Docking)**: Tự động ghim con trỏ mục tiêu vào 4 mép màn hình khi đối tượng trôi ra ngoài tầm nhìn (Off-screen), chừa khoảng đệm an toàn 30 pixel.

---

## 📐 Bộ Quy Tắc Bố Cục Điện Ảnh

| Quy Tắc Bố Cục | Thuật Toán Định Vị | Ứng Dụng Thực Tế |
| :--- | :--- | :--- |
| **Quy Tắc 1/3 (Rule of Thirds)** | Đặt chủ thể vào 4 điểm giao điểm vàng của lưới $3 \times 3$, kết hợp bù trừ 12% khoảng trống nhìn (*Lead Room*) theo hướng ánh mắt. | Chân dung ngoại cảnh, đời thường, phong cảnh du lịch. |
| **Tỷ Lệ Vàng (Golden Ratio)** | Phân chia tọa độ theo hằng số $\Phi = 0.61803398875$, tạo điểm nhấn thị giác hài hòa tự nhiên. | Ảnh nghệ thuật, thời trang, kiến trúc có chiều sâu. |
| **Xoắn Ốc Fibonacci (Golden Spiral)** | Dẫn dắt ánh mắt người xem lướt dọc theo đường cong hàm mũ từ tiền cảnh quy tụ về trung tâm chủ thể. | Đại cảnh thiên nhiên, đường phố rộng, nhiếp ảnh kể chuyện. |
| **Tâm Đối Xứng (Center Symmetry)** | Khóa điểm ngắm tại tọa độ trung tâm tuyệt đối $(0.5, 0.5)$. | Kiến trúc mái vòm, cầu thang xoắn, ẩm thực cận cảnh, chân dung trực diện. |
| **Tam Giác Vàng (Golden Triangles)** | Chia khung hình theo đường chéo chính và hai đường vuông góc, tạo trục bố cục động học. | Thể thao, chuyển động, đường dốc đô thị. |
| **AI Smart Framing Tự Động** | Mạng nơ-ron nhận diện bối cảnh thời gian thực để tự động đề xuất quy tắc bố cục tối ưu nhất. | Chụp ảnh đường phố, chụp nhanh hàng ngày. |

---

## 🎨 Bộ Sưu Tập Màu Phim Nghệ Thuật

Toàn bộ công thức màu được tính toán thông qua đồ thị lọc màu Core Image trên không gian màu Display P3, giữ trọn độ mịn chi tiết và sắc độ da người trung thực:

```
[STD]     Standard Clean      --> Màu sắc trung thực, dải tương phản động gốc của cảm biến
[FUJI]    Fuji Pro 400H       --> Tone xanh pastel dịu mát, da trắng hồng trong trẻo phong cách Nhật Bản
[PORTRA]  Kodak Portra 400    --> Sắc vàng ấm hoài niệm, chuyển vùng sáng êm dịu, màu da kinh điển
[CINE]    Teal & Orange       --> Tương phản điện ảnh Hollywood: Bóng xanh Teal, vùng sáng cam ấm
[SUNSET]  Sunset Glow         --> Tôn vinh sắc vàng cam hoàng hôn rực rỡ và ánh đèn đô thị đêm
[LEICA]   Leica Noir B&W      --> Đen trắng tương phản cao, sắc đen tuyền sâu thẳm kiểu ảnh báo chí
[RICOH]   Ricoh GR Hi-BW      --> Đen trắng đường phố gai góc, micro-contrast cao, tách bạch các lớp
[POLA]    Instant Polaroid    --> Màu ảnh chụp lấy liền retro, hơi ngả vàng ấm và hiệu ứng viền mờ
[70s]     Vintage Warm 1970s  --> Retro thập niên 1970 với dải bóng đổ nâng sáng dịu dàng (Matte Lift)
[AI*]     AI Auto Color       --> Tự động nhận diện bối cảnh, cân bằng nhiệt độ màu vi mô và hạt phim
```

---

## 👆 Bảng Thao Tác Cử Chỉ Trực Quan

| Thao Tác | Hành Động Của Hệ Thống |
| :--- | :--- |
| **Chạm 1 lần vào chủ thể** | Khóa mỏ neo tracking. Vòng tròn vàng xuất hiện bám sát chủ thể trong không gian thực. |
| **Lia máy đưa tâm trắng vào vòng vàng** | Khi hai tâm khớp nhau, máy rung phản hồi xúc giác và **tự động chụp ngay tức thì**. |
| **Chạm đúp vào khung PIP Dual Camera** | Chuyển đổi nhanh 3 kích cỡ khung camera trước (1.0x → 1.35x → 1.70x). |
| **Chụm 2 ngón trên khung PIP** | Phóng to hoặc thu nhỏ kích thước khung camera trước tùy ý từ 0.75x đến 1.8x. |
| **Vuốt kéo khung PIP** | Di chuyển khung hình tự do, tự động bám góc an toàn và chống tràn viền màn hình. |
| **Vuốt 2 ngón tay trên màn hình chính** | Zoom ống kính thủ công mượt mà (Pinch-to-zoom). |
| **Chạm đúp vào màn hình chính** | Chuyển nhanh giữa các ống kính vật lý (0.5x Siêu rộng, 1x Góc rộng, 2x / 3x / 5x Tele). |
| **Chạm giữ 0.5 giây** | Khóa nét quang học và khóa phơi sáng cố định (AE/AF Lock). |
| **Nút chuyển Chụp / Quay** | Chuyển đổi mượt mà giữa chế độ Chụp Ảnh và Quay Video mà không vỡ form giao diện. |

---

## 📦 Hướng Dẫn Cài Đặt Sideload

Ứng dụng được biên dịch và đóng gói sẵn dưới dạng tệp `AISmartFramingCamera.ipa`. **Hoàn toàn không yêu cầu Jailbreak thiết bị.**

### Tải Tệp Cài Đặt IPA Mới Nhất
* **GitHub Releases**: [Tải bản phát hành mới nhất](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/latest)
* **Tải file IPA trực tiếp**: `https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera/releases/latest/download/AISmartFramingCamera.ipa`

---

### Phương Pháp 1: Cài đặt qua TrollStore (Khuyến nghị tốt nhất - Không bao giờ bị thu hồi)
1. Tải file `AISmartFramingCamera.ipa` trực tiếp bằng trình duyệt Safari trên iPhone.
2. Nhấn chọn file đã tải về, bấm biểu tượng Chia sẻ (Share) và chọn **TrollStore**.
3. Nhấn **Install**. Ứng dụng sẽ được cài đặt vĩnh viễn không cần ký lại chứng chỉ (No Revoke).

---

### Phương Pháp 2: Cài đặt qua Sideloadly (Dành cho máy tính Windows & Mac)
1. Tải và cài đặt phần mềm [Sideloadly](https://sideloadly.io/) trên máy tính.
2. Kết nối iPhone với máy tính bằng cáp USB và chọn **Tin cậy máy tính này**.
3. Kéo thả file `AISmartFramingCamera.ipa` vào giao diện của Sideloadly.
4. Nhập tài khoản Apple ID của bạn và nhấn **Start**.
5. Sau khi cài xong, trên iPhone vào: `Cài đặt` → `Cài đặt chung` → `Quản lý VPN & Thiết bị` → Chọn tài khoản Apple ID của bạn → Bấm **Tin cậy ứng dụng**.

---

### Phương Pháp 3: Cài đặt qua AltStore / SideStore / Scarlet
1. Mở ứng dụng **AltStore** (hoặc SideStore / Scarlet) trên iPhone.
2. Vào mục `My Apps`, nhấn dấu `+` ở góc trên cùng.
3. Chọn file `AISmartFramingCamera.ipa` từ ứng dụng Tệp (Files).
4. Chờ ứng dụng ký chứng chỉ và hoàn tất cài đặt trong vài giây.

---

## 📁 Cấu Trúc Thư Mục Dự Án

```
AISmartFramingCamera/
├── App/
│   └── AISmartFramingCameraApp.swift          # Điểm khởi chạy chính của ứng dụng SwiftUI
├── Models/
│   └── FramingModels.swift                    # Mô hình dữ liệu, chuẩn lưu ảnh, Enums, AI Params
├── Services/
│   ├── CameraService.swift                    # Điều khiển AVCaptureSession, MultiCamSession & ISP 48MP
│   ├── DualCameraAssetRecorder.swift          # Bộ ghép và ghi hình ảnh/video Dual Camera thời gian thực
│   ├── GeminiService.swift                    # Tích hợp AI Cloud 2026 & Router Fallback AI Local
│   ├── VisionFramingEngine.swift              # Nhận diện khuôn mặt, cơ thể người, phục hồi lưới 5x5
│   ├── SpatialTrackingEngine.swift            # Thuật toán lai quang học - quán tính 6-DoF EKF Fusion
│   ├── StreetSpatialTrackingEngine.swift      # Bộ bám bắt không gian tối ưu cho nhiếp ảnh đường phố
│   ├── TrackingGeometry.swift                 # Hình học xạ ảnh 3D, bắn tia lỗ kim, cắt biên chữ nhật
│   ├── TargetPatchFlow.swift                  # Theo dõi luồng quang học ma trận cục bộ
│   ├── CompositionCalculator.swift            # Tính toán tọa độ điểm vàng theo các quy tắc bố cục
│   ├── FilmFilterEngine.swift                 # Đồ thị lọc màu phim Core Image chuẩn Display P3
│   ├── FilmSimulations/                       # Thư viện màu phim: Kodak, Fuji, Ricoh GR, Polaroid...
│   ├── RealtimeHistogramEngine.swift          # Bộ phân tích biểu đồ quang phổ 32 băng tần Rec.709
│   ├── FocusPeakingEngine.swift               # Động cơ quét viền nét quang học thời gian thực
│   ├── ProVideoManualControlsService.swift    # Quản lý thông số chỉnh tay khi quay video
│   ├── DeviceMotionService.swift              # Quản lý cảm biến con quay hồi chuyển CoreMotion
│   └── HapticFeedbackService.swift            # Điều khiển phản hồi xúc giác cơ học Magnetic Snap
├── ViewModels/
│   └── CameraViewModel.swift                  # Trục điều phối trung tâm MVVM, tích hợp Dwell Gate & PIP
└── Views/
    ├── CameraMainView.swift                   # Màn hình camera chính và các lớp giao diện
    ├── CameraPreviewView.swift                # Khung nhìn hiển thị lớp đệm camera phần cứng
    ├── DualCameraPIPOverlayView.swift         # Cửa sổ PIP camera trước viền trắng, double-tap & pinch zoom
    ├── WindowedZoomOverlayView.swift          # Khung ngắm Windows Zoom căn chuẩn xác tâm chủ thể
    ├── ARFramingOverlayView.swift             # Vẽ tâm ngắm trắng, vòng tròn vàng, Zoom Reveal Overlay
    ├── LiveColorHistogramHUDView.swift        # Thanh HUD Pro hiển thị Histogram, ISO, Shutter
    ├── AudioVULevelMeterView.swift            # Đồng hồ đo mức âm lượng khi quay video
    ├── ProVideoManualControlsView.swift       # Bảng điều khiển thông số video chuyên nghiệp
    ├── CameraControlsView.swift               # Bảng nút chụp, chỉnh zoom, chuyển đổi chế độ
    ├── CapturedPhotoPreviewView.swift         # Xem lại ảnh chụp, lưu DNG + JPEG đa tài nguyên PhotoKit
    ├── VideoPreviewSheetView.swift            # Xem lại và trích xuất video đã ghi hình
    └── SettingsSheetView.swift                # Cài đặt đa Model AI 2026, API Key, Màu phim & Thông tin tác giả
```

---

## 📱 Yêu Cầu Hệ Thống & Tương Thích

| Tiêu Chí | Yêu Cầu Tối Thiểu | Yêu Cầu Khuyến Nghị |
| :--- | :--- | :--- |
| **Hệ Điều Hành** | iOS 17.0 trở lên | iOS 17.0 đến iOS 18.x |
| **Vi Xử Lý** | Apple A11 Bionic (iPhone 8 / X trở lên) | Apple A16 Bionic đến A18 Pro (iPhone 14 Pro đến 16 Pro Max) |
| **Tính Năng Dual Camera** | iPhone hỗ trợ MultiCam (iPhone XS trở lên) | iPhone 12 / 13 / 14 / 15 / 16 Series |
| **Cảm Biến 48MP Gốc** | Camera 12MP (xuất tối đa 12MP) | Cảm biến 48MP Quad-Bayer (iPhone 14 Pro trở lên) |
| **Bộ Nhớ RAM** | Tối thiểu 3 GB RAM | 6 GB - 8 GB RAM |
| **Kết Nối Internet** | Không bắt buộc (100% Offline AI Local) | Có mạng khi muốn sử dụng tính năng AI Cloud 2026 |

---

## 👨‍💻 Thông Tin Tác Giả & Bản Quyền (Author & Maintainer)

* **Ứng Dụng**: **Align Studio** (*AI Compose, AI Photo Composition & AI Smart Framing / AI Framing Camera*)
* **Phiên Bản**: Free (v1.0.0 - Liên tục tự động build và phát hành qua GitHub Actions CI/CD)
* **Tác Giả (Author)**: **Ace4youblade (Trần Văn Khoa / Tran Van Khoa)** — Open-Source iOS Developer tại Hải Phòng, Việt Nam
* **GitHub**: [@emlavankhoahienma-hue](https://github.com/emlavankhoahienma-hue)
* **Kho Mã Nguồn (Repository)**: [https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera](https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera)
* **Liên Hệ Hỗ Trợ**: `tranvantrinhhd@gmail.com`

---

## 📜 Giấy Phép (License)

Dự án được phân phối theo giấy phép mã nguồn mở **MIT License**. Mọi cá nhân, tổ chức đều có quyền tự do sử dụng, chỉnh sửa, đóng góp và phân phối theo các điều khoản của giấy phép.
