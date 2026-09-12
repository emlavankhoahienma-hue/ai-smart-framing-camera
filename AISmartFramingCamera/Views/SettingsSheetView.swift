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
                // MARK: - Group 1: Chụp ảnh
                Section(header: Text("Chụp ảnh")) {
                    Picker("Định dạng ảnh", selection: $viewModel.selectedPhotoFormat) {
                        ForEach(PhotoSaveFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }

                    Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)

                    Toggle("Lưu ảnh gốc không chỉnh", isOn: $viewModel.isSaveOriginalPhotoEnabled)

                    Toggle("Rung phản hồi khi căn đúng", isOn: $viewModel.isProximityHapticsEnabled)

                    Toggle("Giữ màn hình luôn sáng", isOn: $viewModel.isKeepScreenAwakeEnabled)

                    Toggle("Tự chụp khi khớp bố cục", isOn: $viewModel.isAutoCaptureOnAlignEnabled)
                }

                // MARK: - Group 2: Bố cục thông minh
                Section(header: Text("Bố cục thông minh")) {
                    Picker("Bố cục mặc định", selection: $viewModel.activeCompositionRule) {
                        ForEach(CompositionRule.allCases) { rule in
                            HStack {
                                Image(systemName: rule.iconName)
                                Text(rule.displayNameVietnamese)
                            }.tag(rule)
                        }
                    }

                    Toggle("Tự động zoom theo chủ thể", isOn: $viewModel.isAutoZoomEnabled)

                    Toggle("Tự chụp khi khớp", isOn: $viewModel.isAutoCaptureOnAlignEnabled)

                    Toggle("Hiển thị đường hướng dẫn", isOn: $viewModel.isGuidanceRayEnabled)

                    Picker("Độ nhạy bám chủ thể", selection: $viewModel.trackingSensitivity) {
                        ForEach(TrackingSensitivityPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                }

                // MARK: - Group 3: Khung ngắm
                Section(header: Text("Khung ngắm")) {
                    Toggle("Cân bằng đường chân trời", isOn: $viewModel.isHorizonLevelerEnabled)

                    Toggle("Focus peaking (Báo nét)", isOn: $viewModel.isFocusPeakingEnabled)

                    if viewModel.isFocusPeakingEnabled {
                        Picker("Màu viền báo nét", selection: $viewModel.focusPeakingColor) {
                            ForEach(FocusPeakingColor.allCases) { color in
                                HStack {
                                    Circle().fill(color.swiftUIColor).frame(width: 10, height: 10)
                                    Text(color.rawValue)
                                }.tag(color)
                            }
                        }
                    }

                    Toggle("Hiển thị vùng nhận diện", isOn: $viewModel.showDetectionBoxes)

                    Toggle("Biểu đồ quang phổ (Histogram)", isOn: $viewModel.showHistogramInViewfinder)
                }

                // MARK: - Group 4: Màu sắc
                Section(header: Text("Màu sắc")) {
                    Toggle("Tự động theo cảnh", isOn: $viewModel.isAIFullColorEnabled)

                    Picker("Preset màu hiện tại", selection: $viewModel.selectedFilmPreset) {
                        ForEach(FilmPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FilmPreset.allCases) { preset in
                                let isSelected = viewModel.selectedFilmPreset == preset
                                let thumb = PresetThumbnailProvider.shared.thumbnail(for: preset)

                                Button(action: {
                                    viewModel.selectPreset(preset)
                                }) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 96, height: 96)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                                                )

                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundColor(.yellow)
                                                    .background(Circle().fill(Color.black).padding(1))
                                                    .padding(5)
                                            }
                                        }

                                        Text(preset.displayName)
                                            .font(.caption.bold())
                                            .foregroundColor(isSelected ? .yellow : .white)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 96)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Group 5: Video
                Section(header: Text("Video")) {
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
                }

                // MARK: - Group 6: Video Pro
                Section(header: Text("Video Pro")) {
                    HStack {
                        Text("Khẩu độ phần cứng")
                        Spacer()
                        Text("f/\(String(format: "%.1f", viewModel.proVideoService.hardwareLensAperture)) · Cố định")
                            .font(.subheadline.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("ISO mặc định")
                        Spacer()
                        Text(viewModel.proVideoService.isAutoISO ? "Tự động" : "\(Int(viewModel.proVideoService.currentISO))")
                            .font(.subheadline.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Tốc độ màn trập")
                        Spacer()
                        Text(viewModel.proVideoService.isAutoShutter ? "Tự động" : "1/\(Int(viewModel.proVideoService.currentShutterSpeed)) s")
                            .font(.subheadline.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Bù phơi sáng EV")
                        Spacer()
                        Text(String(format: "%+.1f EV", viewModel.proVideoService.currentEVBias))
                            .font(.subheadline.monospaced())
                            .foregroundColor(.gray)
                    }
                }

                // MARK: - Group 7: AI & Quyền riêng tư
                Section(header: Text("AI & Quyền riêng tư")) {
                    Toggle("Phân tích trực tuyến", isOn: $viewModel.useGeminiForAnalysis)

                    HStack {
                        Text("Trạng thái API")
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Đã kết nối").font(.subheadline.bold()).foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle().fill(Color.gray).frame(width: 8, height: 8)
                                Text("Chưa thiết lập").font(.subheadline).foregroundColor(.gray)
                            }
                        }
                    }

                    Picker("Mô hình AI", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .onChange(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }

                    // API Key Management (Masked, no plain text)
                    if viewModel.geminiService.hasAPIKey {
                        HStack {
                            Text("API Key:")
                            Spacer()
                            Text("••••••••••••••••")
                                .font(.caption.monospaced())
                                .foregroundColor(.gray)
                            Button("Xóa") {
                                viewModel.geminiService.apiKey = ""
                                geminiKeyInput = ""
                                keySavedMessage = "Đã xóa API Key"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keySavedMessage = nil }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.red)
                        }
                    } else {
                        HStack(spacing: 8) {
                            SecureField("Nhập hoặc dán API Key", text: $geminiKeyInput)
                                .font(.caption.monospaced())

                            Button("Lưu") {
                                let trimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    viewModel.geminiService.apiKey = trimmed
                                    geminiKeyInput = ""
                                    keySavedMessage = "Đã lưu API Key"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { keySavedMessage = nil }
                                }
                            }
                            .font(.caption.bold())
                            .foregroundColor(.yellow)
                        }
                    }

                    // Test connection button
                    Button(action: {
                        isTestingKey = true
                        testResult = nil
                        viewModel.geminiService.testAPIKey { success, message in
                            isTestingKey = false
                            testResult = message
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isTestingKey {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(isTestingKey ? "Đang kiểm tra..." : "Kiểm tra kết nối")
                        }
                        .font(.caption.bold())
                    }

                    if let res = testResult {
                        Text(res)
                            .font(.caption2)
                            .foregroundColor(res.contains("✅") ? .green : .red)
                    }

                    if let msg = keySavedMessage {
                        Text(msg)
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Khi bật phân tích trực tuyến, một khung hình có thể được gửi đến dịch vụ bên ngoài để nhận gợi ý bố cục và màu sắc.\n\nKhi tắt, ứng dụng chỉ sử dụng xử lý trên thiết bị.")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineSpacing(2)
                    }
                    .padding(.vertical, 2)
                }

                // MARK: - Group 8: Nâng cao
                Section(header: Text("Nâng cao")) {
                    Toggle("Chế độ đi đường (Street Tracking)", isOn: $viewModel.isStreetTrackingModeEnabled)

                    Toggle("Không gian 3D ARKit", isOn: $viewModel.isARModeEnabled)

                    DisclosureGroup("Web Report Server (Đồng bộ máy tính)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Bật Server", isOn: $isReportServerEnabled)
                                .onChange(of: isReportServerEnabled) { enabled in
                                    if enabled { reportServer.startServer() } else { reportServer.stopServer() }
                                }

                            if reportServer.isRunning {
                                HStack {
                                    Text(reportServer.serverURLString)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.yellow)
                                    Spacer()
                                    Button("Sao chép") {
                                        UIPasteboard.general.string = reportServer.serverURLString
                                        webURLCopiedMessage = "Đã chép địa chỉ"
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webURLCopiedMessage = nil }
                                    }
                                    .font(.caption.bold())
                                }

                                if let msg = webURLCopiedMessage {
                                    Text(msg).font(.caption2).foregroundColor(.green)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Group 9: Chẩn đoán
                Section(header: Text("Chẩn đoán")) {
                    HStack {
                        Text("Mô hình đang dùng")
                        Spacer()
                        Text(viewModel.activeModelUsedName.isEmpty ? "Cục bộ on-device" : viewModel.activeModelUsedName)
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Động cơ thị giác")
                        Spacer()
                        Text("Apple Vision + Spatial Fusion")
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Model cục bộ")
                        Spacer()
                        Text("AlignAI 114MB + YOLO")
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Độ trễ gần nhất")
                        Spacer()
                        Text(viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms")
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }

                    Button("Đặt lại phiên làm việc hiện tại") {
                        viewModel.cancelAISession()
                    }
                    .foregroundColor(.orange)

                    DisclosureGroup("Nhật ký kỹ thuật", isExpanded: $showDevConsole) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let err = viewModel.geminiError {
                                Text("Lỗi gần nhất: \(err)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.red)
                            } else {
                                Text("Không có lỗi hệ thống.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Group 10: Hỗ trợ & Giới thiệu
                Section(header: Text("Hỗ trợ & Giới thiệu")) {
                    NavigationLink("Gửi góp ý & phản hồi", destination: FeedbackView())

                    // Donate Card
                    DisclosureGroup("Ủng hộ tác giả") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nếu thấy ứng dụng hữu ích, bạn có thể gửi tặng tác giả 1 ly cà phê.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Momo
                            HStack {
                                Image(systemName: "wallet.pass.fill")
                                    .foregroundColor(.pink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("MoMo / ZaloPay")
                                        .font(.caption.bold())
                                    Text("0344197212 - Trần Văn Trình")
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Button("Sao chép") {
                                    UIPasteboard.general.string = "0344197212"
                                    donateCopiedMessage = "Đã chép SĐT MoMo: 0344197212"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { donateCopiedMessage = nil }
                                }
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                            }

                            // MB Bank
                            HStack {
                                Image(systemName: "building.columns.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("MB Bank (Quân Đội)")
                                        .font(.caption.bold())
                                    Text("STK: 0344197212 - TRAN VAN TRINH")
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Button("Sao chép") {
                                    UIPasteboard.general.string = "0344197212"
                                    donateCopiedMessage = "Đã chép STK MB: 0344197212"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { donateCopiedMessage = nil }
                                }
                                .font(.caption.bold())
                                .foregroundColor(.yellow)
                            }

                            if let msg = donateCopiedMessage {
                                Text(msg).font(.caption2.bold()).foregroundColor(.green)
                            }

                            // QR Toggle
                            Button(action: { showVietQR.toggle() }) {
                                HStack {
                                    Image(systemName: showVietQR ? "qrcode.viewfinder" : "qrcode")
                                    Text(showVietQR ? "Ẩn mã VietQR" : "Xem mã VietQR chuyển khoản nhanh")
                                        .font(.caption.bold())
                                    Spacer()
                                    Image(systemName: showVietQR ? "chevron.up" : "chevron.down")
                                        .font(.caption2)
                                }
                                .foregroundColor(.yellow)
                            }

                            if showVietQR {
                                AsyncImage(url: URL(string: "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH")) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxHeight: 220)
                                            .cornerRadius(10)
                                    default:
                                        ProgressView().padding()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Developer info
                    HStack {
                        Text("Tác giả")
                        Spacer()
                        Text("VanKhoa (Trần Văn Trình)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Liên hệ")
                        Spacer()
                        Text("tranvantrinhhd@gmail.com")
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Phiên bản")
                        Spacer()
                        Text("AlignAI Studio v1.0.0 (Build 128)")
                            .font(.caption.monospaced())
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationBarTitle("Cài đặt", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") { presentationMode.wrappedValue.dismiss() }
                    .foregroundColor(.yellow)
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
