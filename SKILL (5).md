---
name: redesign-settings-feedback-alignai
description: Thiết kế lại SettingsSheetView & FeedbackView cho app "AI Smart Framing Camera" (AlignAI) theo đúng design language Pro-camera tối màu hiện có, đồng thời sửa các lỗi/rủi ro trong code và bổ sung tính năng. Dùng skill này khi cần chỉnh sửa 2 file trên hoặc bất kỳ màn hình dạng "form" nào khác trong app.
---

# Redesign Settings & Feedback — AlignAI Camera

## 0. Bối cảnh dự án
Repo: `github.com/emlavankhoahienma-hue/ai-smart-framing-camera`
Kiến trúc: SwiftUI + AVFoundation, MVVM + Engine (CameraViewModel là state trung tâm).

File cần sửa:
- `AISmartFramingCamera/Views/SettingsSheetView.swift` (548 dòng, 10 Section)
- `AISmartFramingCamera/Views/FeedbackView.swift` (159 dòng)

Hai file này hiện dùng `NavigationView { Form { Section { ... } } }` **mặc định của SwiftUI**, trong khi phần lõi của app (`CameraMainView.swift`, `CameraControlsView.swift`) lại tự vẽ UI hoàn toàn tuỳ biến kiểu "Pro camera" (giống Halide/Apple ProCamera). Kết quả: mở Camera thấy app cao cấp, mở Settings thấy giao diện Cài đặt iOS mặc định → **không đồng bộ, mất cảm giác "designer chuyên nghiệp"**.

## 1. Design tokens đã tồn tại trong app — PHẢI tái sử dụng, không bịa mới
Trích từ `CameraMainView.swift` / `CameraControlsView.swift`:

| Token | Giá trị hiện dùng |
|---|---|
| Nền chính | `Color(red: 0.05, green: 0.05, blue: 0.06)` (gần đen) |
| Nền phụ / card | `Color(red: 0.08, green: 0.08, blue: 0.09)` |
| Accent | System `.yellow` (dùng cho trạng thái chọn/active) |
| Trạng thái tắt/phụ | `.white.opacity(0.85–0.9)`, `.gray` |
| Bo góc | 12–16pt (`RoundedRectangle(cornerRadius: 12/16)`) |
| Pill lựa chọn | `Capsule()`; chọn = `Color.yellow` fill, chữ đen; chưa chọn = `Color.black.opacity(0.45)`, chữ trắng |
| Glow khi active | `.shadow(color: .yellow.opacity(0.4), radius: 6)` |
| Font | `.system(size:weight:design: .rounded)`, weight từ `.medium` đến `.black`, cỡ 8.5–24 |
| Chế độ màu | Ép cứng `.preferredColorScheme(.dark)` toàn app |

Bất kỳ view mới nào (kể cả Settings/Feedback) đều phải dùng đúng bộ token này, không tạo màu/bo góc/kiểu chữ mới tùy tiện.

## 2. Vấn đề cụ thể đã phát hiện trong code hiện tại

**UI/UX**
1. Dùng `Form` mặc định → nền xám hệ thống, không match nền đen 0.05/0.05/0.06 của Camera. Cần `.scrollContentBackground(.hidden)` (iOS 16+) + set nền thủ công.
2. 10 Section dồn vào 1 màn hình dài (Chụp ảnh, Bố cục, Khung ngắm, Màu sắc, Video, Video Pro, AI & Quyền riêng tư, Nâng cao, Chẩn đoán, Hỗ trợ) — không phân cấp ưu tiên, người dùng thường (không phải dev) bị choáng ngợp bởi mục "Chẩn đoán", "Nhật ký kỹ thuật", "Web Report Server".
3. Không có icon nhất quán: một số Picker có icon (`rule.iconName`), phần lớn Toggle không có gì để quét mắt nhanh.
4. Phần donate (số tài khoản MoMo/MB Bank) nhét chung với "Hỗ trợ & Giới thiệu" — nên tách riêng, không để lẫn với hỗ trợ kỹ thuật.
5. Feedback form chỉ cho đính kèm **1 ảnh**, không có bộ đếm ký tự, không có trạng thái loading rõ ràng khi soạn mail, không có cách dismiss bàn phím khi gõ trong `TextEditor`.
6. Route lỗi (`AsyncImage` load QR) gộp `.empty` và `.failure` vào cùng nhánh `default:` → **khi tải QR lỗi (mất mạng) sẽ quay `ProgressView` vô hạn**, không báo lỗi, không có nút thử lại.

**Code / kiến trúc**
7. API key Gemini lưu **plain text trong `UserDefaults`** (`GeminiService.swift`, key `"gemini_api_key"`) — không mã hoá, dễ đọc được nếu máy jailbreak hoặc backup bị lộ. Cần chuyển sang **Keychain**.
8. Nút "Xóa" API key xoá ngay lập tức, không có `confirmationDialog` xác nhận.
9. Toàn bộ state phụ (`geminiKeyInput`, `testResult`, `donateCopiedMessage`, `webURLCopiedMessage`...) khai báo trực tiếp trong View 548 dòng → khó test, khó tái sử dụng, vi phạm single responsibility.
10. Pattern hiện "đã copy" lặp lại **4 lần gần giống hệt nhau** (`DispatchQueue.main.asyncAfter(deadline: .now()+2) { ... = nil }`) cho Momo, MB Bank, web URL, API key → nên rút thành 1 component Toast dùng chung.
11. Callback kiểu cũ `testAPIKey { success, message in }` thay vì `async/await`, không đồng bộ với style Swift concurrency hiện đại.
12. Không có bản dịch tiếng Anh — toàn bộ string hard-code tiếng Việt trong khi vài nhãn kỹ thuật (`AI Vision Model`...) đã lẫn tiếng Anh, gây thiếu nhất quán ngôn ngữ.

## 3. Cách sửa lại UI cho "đẹp, chuyên nghiệp" (thực hiện theo thứ tự)

1. **Giữ `Form` nhưng "lột xác" nền:**
   ```swift
   Form { ... }
       .scrollContentBackground(.hidden)
       .background(Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea())
   ```
2. **Tạo `SettingsSectionCard`** — 1 view dùng chung cho mọi Section, bo góc 16, nền `Color(red:0.08,0.08,0.09)`, tiêu đề section in hoa nhỏ màu `.gray`, icon SF Symbol màu vàng đặt trong khung vuông bo góc 6 (giống style icon app Cài đặt của Apple) để tăng khả năng quét mắt.
3. **Tạo `SettingsToggleRow(icon:title:isOn:)` và `SettingsPickerRow(icon:title:selection:)`** dùng chung cho tất cả Toggle/Picker — đảm bảo mọi hàng đều có icon, khoảng cách, cỡ chữ giống hệt nhau.
4. **Rút gọn nhóm hiển thị mặc định còn 3 tab lớn** bằng `Picker(.segmented)` hoặc custom segmented pill (dùng lại Capsule style có sẵn): **"Chụp ảnh"**, **"AI & Bố cục"**, **"Nâng cao"** — nhóm "Chẩn đoán/Nhật ký/Web Server" gộp vào "Nâng cao" và collapse mặc định bằng `DisclosureGroup`.
5. **Tách "Ủng hộ tác giả" ra khỏi Settings chính** → đưa thành 1 màn hình riêng `SupportDeveloperView`, chỉ để 1 dòng "Ủng hộ tác giả ☕" dẫn sang trong Settings.
6. **Tạo `ToastBanner` component** (nền `.ultraThinMaterial`, bo góc 12, tự ẩn sau 2s) thay cho 4 đoạn code lặp lại "đã chép..." → giảm ~40 dòng trùng lặp.
7. **Sửa `AsyncImage` QR** thêm nhánh `.failure`:
   ```swift
   AsyncImage(url: qrURL) { phase in
       switch phase {
       case .success(let image): image.resizable().scaledToFit()
       case .failure: VStack { Image(systemName: "wifi.slash"); Button("Thử lại") { /* reload */ } }
       default: ProgressView()
       }
   }
   ```
8. **Thêm `confirmationDialog`** trước khi xoá API key.
9. **Feedback form:** thêm bộ đếm ký tự dưới `TextEditor`, cho chọn nhiều ảnh (`PhotosPicker(maxSelectionCount: 3)`), thêm `.toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Xong") { hideKeyboard() } } }`.

## 4. Cải thiện code / kiến trúc

- Tách `SettingsSheetView` thành các subview nhỏ theo từng nhóm: `PhotoSettingsSection`, `CompositionSettingsSection`, `ColorSettingsSection`, `VideoSettingsSection`, `AISettingsSection`, `AdvancedSettingsSection`, `SupportSection` — mỗi file/struct riêng để dễ preview (`#Preview`) và test độc lập.
- Tạo `SettingsViewModel` (hoặc mở rộng `CameraViewModel`) để chứa toàn bộ `@State` phụ hiện đang nằm trong View (key input, test result, toast message...) → View chỉ còn nhiệm vụ render.
- **Bảo mật:** chuyển `apiKey` trong `GeminiService.swift` từ `UserDefaults` sang Keychain (dùng `Security` framework hoặc wrapper nhẹ, không cần thư viện ngoài). Không log giá trị key ra console/log file (`CameraLogger`) trong bất kỳ trường hợp nào.
- Đổi `testAPIKey(completion:)` sang `func testAPIKey() async -> (Bool, String)` để đồng bộ concurrency với phần còn lại của codebase.
- Thêm `.accessibilityLabel` / `.accessibilityHint` cho các nút chỉ có icon (nút Sao chép, nút QR toggle...).
- Chuẩn bị Localization: chuyển string sang `Localizable.xcstrings` để mở đường hỗ trợ tiếng Anh (repo đã hướng tới người dùng sideload quốc tế qua Sideloadly/AltStore).

## 5. Tính năng nên bổ sung

- **Tìm kiếm trong Settings** (`.searchable`) khi danh sách đã dài như hiện tại.
- **Reset về mặc định** theo từng nhóm (nút nhỏ góc mỗi SectionCard).
- **Xuất/nhập cấu hình dạng JSON** để chia sẻ bộ preset màu + bố cục giữa các máy.
- **Xem trước trực tiếp** khi đổi Film Preset / màu focus peaking ngay trong Settings (mini live preview), không cần thoát ra Camera mới thấy hiệu ứng.
- **Khoá Face ID/Touch ID** riêng cho mục API Key / phân tích trực tuyến vì đây là phần nhạy cảm.
- **Đổi màu accent** (không chỉ vàng) — theme picker đơn giản 3–4 màu.
- **"Có gì mới" (changelog)** hiện 1 lần sau khi cập nhật build.
- Feedback: cho phép đính kèm **video ngắn** hoặc nhiều ảnh, thêm loại góp ý (Bug/Đề xuất/Khác) dạng chip chọn nhanh trước khi gõ nội dung.

## 6. Bug cụ thể cần fix ngay (ưu tiên cao)
1. `AsyncImage` QR không xử lý `.failure` → treo `ProgressView` vô hạn khi mất mạng.
2. API key lưu plain text UserDefaults → chuyển Keychain.
3. Xoá API key không có xác nhận.
4. Nút "Đặt lại phiên làm việc hiện tại" trong Chẩn đoán không có mô tả hệ quả/xác nhận trước khi bấm.
5. Form/Settings không đồng bộ nền màu với Camera chính (thiếu `.scrollContentBackground(.hidden)`).

## 7. Checklist thực thi cho AI code agent
- [ ] Đọc `CameraMainView.swift` + `CameraControlsView.swift` để lấy đúng token màu/font/bo góc trước khi viết code mới.
- [ ] Tạo các component dùng chung: `SettingsSectionCard`, `SettingsToggleRow`, `SettingsPickerRow`, `ToastBanner`.
- [ ] Refactor `SettingsSheetView.swift` thành các subview theo mục 4, dùng component ở trên.
- [ ] Chuyển `apiKey` sang Keychain trong `GeminiService.swift`, cập nhật mọi nơi gọi.
- [ ] Sửa `AsyncImage` QR thêm case `.failure`.
- [ ] Thêm `confirmationDialog` cho hành động xoá key / reset phiên AI.
- [ ] Cập nhật `FeedbackView.swift`: đa ảnh, bộ đếm ký tự, toolbar bàn phím.
- [ ] Build lại, kiểm tra Dark Mode (app luôn dark) trên thiết bị thật hoặc simulator iOS 16–18.
- [ ] Không đổi hành vi nghiệp vụ (AI framing, capture pipeline) — chỉ chạm vào 2 file Views nêu trên và phần lưu trữ API key.
