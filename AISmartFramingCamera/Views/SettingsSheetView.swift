import SwiftUI
import UIKit

public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode
    
    @State private var geminiKeyInput: String = ""
    @State private var showKeyInput: Bool = false
    @State private var isKeyVisible: Bool = false
    @State private var keySavedMessage: String? = nil
    @State private var selectedModel: AIVisionModel = .autoStrongest
    @State private var customModelInput: String = ""
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    @State private var showDevConsole: Bool = false
    
    // Donate & Vibe Coding State
    @State private var donateCopiedMessage: String? = nil
    @State private var showVietQR: Bool = false
    
    // Web HTML Report Server State
    @ObservedObject private var reportServer = AICloudReportServer.shared
    @State private var isReportServerEnabled: Bool = true
    @State private var webURLCopiedMessage: String? = nil
    @State private var showShareSheet: Bool = false
    @State private var shareFileURL: URL? = nil
    
    public var body: some View {
        NavigationView {
            Form {
                // MARK: - 1. Developer Profile (VanKhoa)
                Section(header: Text("👨‍💻 THÔNG TIN DEVELOPER")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "person.crop.circle.fill.badge.checkmark")
                                .font(.system(size: 28))
                                .foregroundColor(.cyan)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("VanKhoa")
                                    .font(.headline.bold())
                                    .foregroundColor(.white)
                                HStack(spacing: 4) {
                                    Image(systemName: "flame.fill")
                                        .font(.caption2.bold())
                                        .foregroundColor(.orange)
                                    Text("Vibe Coding 100%")
                                        .font(.caption.bold())
                                        .foregroundColor(.orange)
                                }
                            }
                            Spacer()
                        }
                        
                        Divider().background(Color.gray.opacity(0.3))
                        
                        HStack {
                            Label("Email:", systemImage: "envelope.fill")
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                            Spacer()
                            Text("tranvantrinhhd@gmail.com")
                                .font(.caption.monospaced())
                                .foregroundColor(.white)
                        }
                        
                        HStack {
                            Label("Hotline:", systemImage: "phone.fill")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                            Spacer()
                            Text("+84 344197212")
                                .font(.caption.bold().monospaced())
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - 2. Donate / Support Author
                Section(header: Text("☕ ỦNG HỘ & DONATE CHO TÁC GIẢ")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nếu bạn thấy app hữu ích, hãy gửi tặng tác giả 1 ly cafe để tiếp thêm động lực phát triển nhé!")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Momo
                        HStack {
                            Image(systemName: "wallet.pass.fill")
                                .foregroundColor(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ví MoMo / ZaloPay")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text("0344197212 (Trần Văn Trình)")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = "0344197212"
                                donateCopiedMessage = "Đã chép SĐT MoMo: 0344197212"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { donateCopiedMessage = nil }
                            }) {
                                Text("Sao chép")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.pink.opacity(0.2))
                                    .foregroundColor(.pink)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        
                        Divider().background(Color.gray.opacity(0.3))
                        
                        // MB Bank
                        HStack {
                            Image(systemName: "building.columns.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ngân hàng MB Bank (Quân Đội)")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Text("STK: 0344197212 - TRAN VAN TRINH")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button(action: {
                                UIPasteboard.general.string = "0344197212"
                                donateCopiedMessage = "Đã chép STK MB: 0344197212"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { donateCopiedMessage = nil }
                            }) {
                                Text("Sao chép")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        
                        if let msg = donateCopiedMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(msg)
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            }
                            .padding(.top, 2)
                            .transition(.opacity)
                        }
                        
                        // Show VietQR Toggle / Button
                        Button(action: {
                            showVietQR.toggle()
                        }) {
                            HStack {
                                Image(systemName: showVietQR ? "qrcode.viewfinder" : "qrcode")
                                Text(showVietQR ? "Ẩn mã VietQR chuyển khoản" : "Xem mã VietQR chuyển khoản nhanh")
                                    .font(.caption.bold())
                                Spacer()
                                Image(systemName: showVietQR ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundColor(.yellow)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        
                        if showVietQR {
                            VStack(spacing: 8) {
                                AsyncImage(url: URL(string: "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH")) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 260)
                                            .cornerRadius(12)
                                            .shadow(color: .black.opacity(0.4), radius: 8)
                                    case .failure:
                                        VStack(spacing: 4) {
                                            Image(systemName: "exclamationmark.triangle")
                                                .foregroundColor(.orange)
                                            Text("Không thể tải ảnh QR. Vui lòng dùng số tài khoản phía trên.")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                        .padding()
                                    default:
                                        ProgressView()
                                            .padding()
                                    }
                                }
                                
                                Text("Quét mã bằng app ngân hàng bất kỳ để ủng hộ tác giả")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - 3. Gemini AI Key & Connection
                Section(header: Text("🔑 CẤU HÌNH GOOGLE GEMINI API")) {
                    // Status row
                    HStack {
                        Label("Trạng thái", systemImage: "key.horizontal.fill")
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Đã sẵn sàng").font(.subheadline.bold()).foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("Chưa có Key").font(.subheadline.bold()).foregroundColor(.red)
                            }
                        }
                    }
                    
                    // Quick Action: Paste & Test Buttons
                    HStack(spacing: 10) {
                        Button(action: {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                geminiKeyInput = clip
                                viewModel.geminiService.apiKey = clip
                                keySavedMessage = "✅ Đã dán Key thành công!"
                                testResult = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { keySavedMessage = nil }
                            } else {
                                keySavedMessage = "⚠️ Clipboard không có văn bản"
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard.fill")
                                Text("Dán Key")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        
                        Button(action: {
                            isTestingKey = true
                            testResult = nil
                            viewModel.geminiService.testAPIKey { success, message in
                                isTestingKey = false
                                testResult = message
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isTestingKey {
                                    ProgressView().scaleEffect(0.7).padding(.trailing, 2)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                }
                                Text(isTestingKey ? "Đang thử..." : "Test Kết Nối")
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.purple.opacity(0.2))
                            .foregroundColor(.purple)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 2)
                    
                    if let res = testResult {
                        Text(res)
                            .font(.caption2.bold())
                            .foregroundColor(res.contains("✅") ? .green : .red)
                            .lineLimit(3)
                    }
                    
                    if let saved = keySavedMessage {
                        Text(saved)
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                    }
                    
                    // Input Key Accordion
                    DisclosureGroup("Xem / Nhập Key thủ công", isExpanded: $showKeyInput) {
                        VStack(spacing: 8) {
                            HStack {
                                if isKeyVisible {
                                    TextField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.caption.monospaced())
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                } else {
                                    SecureField("AIzaSy...", text: $geminiKeyInput)
                                        .font(.caption.monospaced())
                                }
                                
                                Button(action: { isKeyVisible.toggle() }) {
                                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                        .foregroundColor(.gray)
                                }
                            }
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                            
                            Button("Lưu Key") {
                                viewModel.geminiService.apiKey = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                keySavedMessage = "✅ Đã lưu!"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { keySavedMessage = nil }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.green)
                        }
                        .padding(.top, 4)
                    }
                }
                
                // MARK: - 3. Model AI & Auto-Fallback Engine
                Section(header: Text("🤖 CHỌN MÔ HÌNH & TỰ ĐỘNG LUÂN CHUYỂN")) {
                    Picker("Mô hình AI", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }
                    
                    HStack {
                        Label("Chỉ định Model ID:", systemImage: "cpu")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Spacer()
                        TextField("Tự động", text: $customModelInput)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: customModelInput) { newVal in
                                viewModel.geminiService.customModelName = newVal
                            }
                    }
                    
                    Text("💡 Tính năng tự động: Khi 1 model bị hết Quota (429) hoặc lỗi, app sẽ tự động chuyển sang model tiếp theo ngay lập tức.")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
                
                // MARK: - 4. Web Report Server (PC Live HTML Sync)
                Section(header: Text("🖥️ BÁO CÁO AI CLOUD VỀ MÁY TÍNH (WEB HTML)")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Bật Web Server Báo Cáo", isOn: $isReportServerEnabled)
                            .onChange(of: isReportServerEnabled) { enabled in
                                if enabled {
                                    reportServer.startServer()
                                } else {
                                    reportServer.stopServer()
                                }
                            }
                        
                        if reportServer.isRunning {
                            HStack {
                                Label("Trạng thái Server:", systemImage: "network")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle().fill(Color.green).frame(width: 8, height: 8)
                                    Text("Đang chạy (Cổng \(String(reportServer.serverPort)))")
                                        .font(.caption.bold())
                                        .foregroundColor(.green)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Địa chỉ Web mở trên Máy Tính:")
                                    .font(.caption.bold())
                                    .foregroundColor(.yellow)
                                HStack {
                                    Text(reportServer.serverURLString)
                                        .font(.subheadline.monospaced().bold())
                                        .foregroundColor(.cyan)
                                    Spacer()
                                    Button(action: {
                                        UIPasteboard.general.string = reportServer.serverURLString
                                        webURLCopiedMessage = "Đã chép: \(reportServer.serverURLString)"
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webURLCopiedMessage = nil }
                                    }) {
                                        Text("Sao chép")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(Color.cyan.opacity(0.2))
                                            .foregroundColor(.cyan)
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                            }
                            .padding(8)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            
                            if let msg = webURLCopiedMessage {
                                Text(msg)
                                    .font(.caption2.bold())
                                    .foregroundColor(.green)
                            }
                            
                            Text("💡 Hướng dẫn: Mở trình duyệt (Chrome/Edge/Firefox) trên máy tính cùng mạng Wi-Fi và truy cập địa chỉ trên để xem ảnh full gốc, tọa độ và toàn văn câu trả lời của AI theo thời gian thực.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineSpacing(2)
                            
                            HStack(spacing: 10) {
                                Button(action: {
                                    if let url = URL(string: reportServer.serverURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "safari")
                                        Text("Xem trên iPhone")
                                    }
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.blue.opacity(0.3))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                
                                Button(action: {
                                    if let report = reportServer.latestReport, let fileURL = reportServer.saveStandaloneHTMLReport(report: report) {
                                        shareFileURL = fileURL
                                        showShareSheet = true
                                    } else {
                                        // Tao bao cao trong neu chua chup
                                        let dummy = AICloudSessionReport(
                                            deviceIP: reportServer.deviceIP,
                                            modelUsed: "Chưa chụp",
                                            latencyMs: 0,
                                            sentPrompt: "Chưa có dữ liệu",
                                            rawAIResponseText: "{}",
                                            fullImageBase64: "",
                                            targetX: 0.5,
                                            targetY: 0.5,
                                            suggestedZoom: 1.0,
                                            sceneType: "Mặc định",
                                            compositionRule: "Tự động",
                                            explanation: "Chưa có phiên chụp nào.",
                                            colorRecipeSummary: "Chuẩn"
                                        )
                                        if let fileURL = reportServer.saveStandaloneHTMLReport(report: dummy) {
                                            shareFileURL = fileURL
                                            showShareSheet = true
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.and.arrow.up")
                                        Text("Chia sẻ file HTML")
                                    }
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.gray.opacity(0.3))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - 5. Framing, Auto-Zoom & Color Science
                Section(header: Text("🎯 TÙY CHỈNH CHỤP & BÁM MỤC TIÊU")) {
                    Picker("Quy tắc bố cục", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }
                    
                    Picker("Độ nhạy bám mục tiêu (Tracking)", selection: $viewModel.trackingSensitivity) {
                        ForEach(TrackingSensitivityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    
                    Toggle("Tự động Zoom theo AI (Auto-Zoom)", isOn: $viewModel.isAutoZoomEnabled)
                    Toggle("Màu Leica / Hasselblad Natural", isOn: $viewModel.isAIFullColorEnabled)
                    Toggle("Không gian 3D ARKit", isOn: $viewModel.isARModeEnabled)
                    Toggle("Thước Cân Bằng Chân Trời (Leveler)", isOn: $viewModel.isHorizonLevelerEnabled)
                    
                    Toggle(isOn: $viewModel.isStreetTrackingModeEnabled) {
                        HStack {
                            Image(systemName: "car.fill")
                                .foregroundColor(.yellow)
                            Text("Chế độ Đi Đường (Street Tracking)")
                        }
                    }
                    
                    if viewModel.isStreetTrackingModeEnabled {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Circle().fill(Color.yellow).frame(width: 6, height: 6)
                                Text("ĐÃ BẬT MỎ NEO SIÊU BÁM DÍNH")
                                    .font(.caption2.bold())
                                    .foregroundColor(.yellow)
                            }
                            Text("• Cơ chế: Dùng động cơ StreetSpatialTracking riêng biệt với bộ lọc Deadband triệt tiêu rung chấn động cơ/mặt đường và lọc sốc ổ gà.")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.85))
                            Text("• Nhược điểm: Target có lực ghì quán tính rất nặng, khi xoay máy nhanh sẽ có độ trễ ghì lại vị trí cũ thay vì di chuyển linh hoạt.")
                                .font(.caption2)
                                .foregroundColor(.orange.opacity(0.9))
                        }
                        .padding(8)
                        .background(Color.yellow.opacity(0.12))
                        .cornerRadius(8)
                    }
                }
                
                // MARK: - 4AA. Video Recording Settings (Format, FPS & Codec)
                Section(header: Text("📹 CẤU HÌNH QUAY VIDEO (ĐỘ PHÂN GIẢI & CODEC)")) {
                    Picker("Độ phân giải & Tần số", selection: $viewModel.selectedVideoFormatOption) {
                        ForEach(VideoFormatOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    
                    Picker("Bộ giải mã (Codec)", selection: $viewModel.selectedVideoCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    
                    Text("💡 Mẹo: Bạn cũng có thể bấm trực tiếp vào huy hiệu FPS trên đỉnh màn hình để chuyển đổi nhanh định dạng quay.")
                        .font(.caption2)
                        .foregroundColor(.cyan)
                }
                
                // MARK: - 4A. Focus Peaking (Viền Neon Báo Nét Điện Ảnh)
                Section(header: Text("🟢 FOCUS PEAKING (VIỀN BÁO NÉT ĐIỆN ẢNH)")) {
                    Toggle("Bật Focus Peaking", isOn: $viewModel.isFocusPeakingEnabled)
                    
                    if viewModel.isFocusPeakingEnabled {
                        Picker("Màu viền báo nét", selection: $viewModel.focusPeakingColor) {
                            ForEach(FocusPeakingColor.allCases) { color in
                                HStack {
                                    Circle().fill(color.swiftUIColor).frame(width: 10, height: 10)
                                    Text(color.rawValue)
                                }.tag(color)
                            }
                        }
                        
                        Text("• Cơ chế: Sử dụng thuật toán Sobel GPU Metal quét trực tiếp khung hình để tìm vùng nét căng nhất. Các chi tiết đạt độ nét chuẩn sẽ sáng bừng viền Neon.\n• Ứng dụng: Giúp bạn biết chính xác chủ thể đã nét căng 100% trước khi bấm chụp hay bấm quay video.")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.vertical, 2)
                    }
                }
                
                // MARK: - 4B. Film Presets Visual Showcase (Ảnh mẫu từng màu Film)
                Section(header: Text("🎞️ BỘ SƯU TẬP MÀU FILM & ẢNH MẪU")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(FilmPreset.allCases) { preset in
                                let isSelected = viewModel.selectedFilmPreset == preset
                                let thumb = PresetThumbnailProvider.shared.thumbnail(for: preset)
                                
                                Button(action: {
                                    viewModel.selectPreset(preset)
                                }) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 110, height: 110)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .stroke(isSelected ? (preset == .aiFullAuto ? Color.cyan : Color.yellow) : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
                                                )
                                            
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 18, weight: .bold))
                                                    .foregroundColor(preset == .aiFullAuto ? .cyan : .yellow)
                                                    .background(Circle().fill(Color.black).padding(2))
                                                    .padding(6)
                                            }
                                        }
                                        
                                        Text(preset.rawValue)
                                            .font(.caption.bold())
                                            .foregroundColor(isSelected ? (preset == .aiFullAuto ? .cyan : .yellow) : .white)
                                            .lineLimit(1)
                                        
                                        Text(preset.description)
                                            .font(.system(size: 10))
                                            .foregroundColor(.gray)
                                            .lineLimit(2)
                                            .frame(width: 110, alignment: .leading)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                
                // MARK: - 5. Developer Debug Console (Collapsible)
                Section(header: Text("🛠 NHẬT KÝ & DEV CONSOLE")) {
                    DisclosureGroup("Xem nhật ký & lỗi", isExpanded: $showDevConsole) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Model đang active:")
                                Spacer()
                                Text(viewModel.activeModelUsedName.isEmpty ? "Chưa kích hoạt" : viewModel.activeModelUsedName)
                                    .font(.caption.bold().monospaced())
                                    .foregroundColor(.yellow)
                            }
                            
                            HStack {
                                Text("Độ trễ phản hồi:")
                                Spacer()
                                Text(viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.cyan)
                            }
                            
                            if let err = viewModel.geminiError {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Lỗi gần nhất:").font(.caption.bold()).foregroundColor(.red)
                                    Text(err)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.red.opacity(0.85))
                                }
                                .padding(6)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // MARK: - 6. Feedback & Support
                Section(header: Text("💬 GÓP Ý & HỖ TRỢ")) {
                    NavigationLink("Gửi góp ý cho AlignAI", destination: FeedbackView())
                }
                
                // MARK: - 7. Hardware & App Info
                Section(header: Text("ℹ️ THÔNG TIN PHẦN CỨNG")) {
                    hardwareRow("Kiến trúc", "CPU + Neural Engine + Metal GPU + Gemini Cloud", color: .yellow)
                    hardwareRow("Thiết bị hỗ trợ", "Apple A11 đến A18 Pro Bionic")
                    HStack { Text("Ứng dụng"); Spacer(); Text("VanKhoa AI Cam v2.5").font(.caption.bold()).foregroundColor(.white) }
                }
            }
            .navigationBarTitle("Cài đặt AI Camera", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") { presentationMode.wrappedValue.dismiss() }.foregroundColor(.yellow)
            )
            .onAppear {
                selectedModel = viewModel.geminiService.selectedModel
                customModelInput = viewModel.geminiService.customModelName
                reportServer.refreshDeviceIP()
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareFileURL {
                    ActivityShareView(activityItems: [url])
                }
            }
        }
    }
    
    private func hardwareRow(_ label: String, _ value: String, color: Color = .gray) -> some View {
        HStack {
            Label(label, systemImage: "cpu")
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(color)
        }
    }
}

// MARK: - Activity Share Sheet for AirDrop & Export
struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityShareView>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityShareView>) {}
}

