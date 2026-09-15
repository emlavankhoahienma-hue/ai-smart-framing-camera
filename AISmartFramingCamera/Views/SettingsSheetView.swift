import SwiftUI
import UIKit

// MARK: - Settings Tab Category
public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case capture = "Chụp ảnh"
    case ai = "AI & Bố cục"
    case advanced = "Nâng cao"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .capture: return "camera.fill"
        case .ai: return "sparkles"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - Main Settings View
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var selectedTab: SettingsSheetTab = .capture
    @State private var searchText: String = ""

    // Gemini API Key State
    @State private var geminiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var selectedModel: AIVisionModel = .autoStrongest
    @State private var customModelInput: String = ""
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    @State private var showDeleteKeyConfirmation: Bool = false

    // Diagnostics & Reset
    @State private var showResetSessionConfirmation: Bool = false
    @State private var showDevConsole: Bool = false

    // Unified Toast Message
    @State private var toastMessage: String? = nil

    private let haptic = UISelectionFeedbackGenerator()

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.06)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // MARK: - Top Segmented Pill Bar
                    tabSelectorPills
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 12)

                    // MARK: - Content Scroll Area
                    ScrollView {
                        VStack(spacing: 16) {
                            if !searchText.isEmpty {
                                searchResultsView
                            } else {
                                switch selectedTab {
                                case .capture:
                                    PhotoCaptureSettingsSection(viewModel: viewModel)
                                case .ai:
                                    AIFramingSettingsSection(
                                        viewModel: viewModel,
                                        geminiKeyInput: $geminiKeyInput,
                                        isKeyVisible: $isKeyVisible,
                                        selectedModel: $selectedModel,
                                        isTestingKey: $isTestingKey,
                                        testResult: $testResult,
                                        showDeleteKeyConfirmation: $showDeleteKeyConfirmation,
                                        toastMessage: $toastMessage
                                    )
                                case .advanced:
                                    AdvancedSettingsSection(
                                        viewModel: viewModel,
                                        showResetSessionConfirmation: $showResetSessionConfirmation,
                                        showDevConsole: $showDevConsole,
                                        toastMessage: $toastMessage
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }

                // MARK: - Toast Banner Notification
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        ToastBanner(message: msg)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationBarTitle("Cài đặt", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") {
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.yellow)
            )
            .searchable(text: $searchText, prompt: "Tìm kiếm thông số, cài đặt...")
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Xác nhận xóa OpenRouter API Key?",
                isPresented: $showDeleteKeyConfirmation,
                titleVisibility: .visible
            ) {
                Button("Xóa API Key", role: .destructive) {
                    viewModel.geminiService.apiKey = ""
                    geminiKeyInput = ""
                    showToast("Đã xóa an toàn API Key khỏi Keychain")
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("API Key sẽ bị xóa hoàn toàn khỏi Keychain bảo mật của thiết bị.")
            }
            .confirmationDialog(
                "Đặt lại phiên căn bố cục hiện tại?",
                isPresented: $showResetSessionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Đặt lại phiên", role: .destructive) {
                    viewModel.cancelAISession()
                    showToast("Đã đặt lại trạng thái phiên AI về ban đầu")
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Thao tác này sẽ hủy khóa chủ thể hiện tại, dừng theo dõi con quay và đưa camera về trạng thái ngắm tự do.")
            }
            .onAppear {
                selectedModel = viewModel.geminiService.selectedModel
                customModelInput = viewModel.geminiService.customModelName
            }
        }
    }

    // MARK: - Segmented Tab Selector Pills
    private var tabSelectorPills: some View {
        HStack(spacing: 8) {
            ForEach(SettingsSheetTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                        haptic.selectionChanged()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                    }
                    .foregroundColor(isSelected ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.yellow : Color(red: 0.08, green: 0.08, blue: 0.09))
                    )
                    .overlay(
                        Capsule()
                            .stroke(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Search Results View
    @ViewBuilder
    private var searchResultsView: some View {
        let q = searchText.lowercased()
        VStack(spacing: 16) {
            if "định dạng ảnh raw jpeg heic dng live photo lưu ảnh gốc".contains(q) {
                PhotoCaptureSettingsSection(viewModel: viewModel)
            }
            if "bố cục tỷ lệ vàng 1/3 tam giác xoắn ốc ai zoom bám chủ thể".contains(q) {
                AIFramingSettingsSection(
                    viewModel: viewModel,
                    geminiKeyInput: $geminiKeyInput,
                    isKeyVisible: $isKeyVisible,
                    selectedModel: $selectedModel,
                    isTestingKey: $isTestingKey,
                    testResult: $testResult,
                    showDeleteKeyConfirmation: $showDeleteKeyConfirmation,
                    toastMessage: $toastMessage
                )
            }
            if "openrouter gemini api key model trực tuyến đám mây quota".contains(q) {
                AIFramingSettingsSection(
                    viewModel: viewModel,
                    geminiKeyInput: $geminiKeyInput,
                    isKeyVisible: $isKeyVisible,
                    selectedModel: $selectedModel,
                    isTestingKey: $isTestingKey,
                    testResult: $testResult,
                    showDeleteKeyConfirmation: $showDeleteKeyConfirmation,
                    toastMessage: $toastMessage
                )
            }
            if "chẩn đoán nhật ký donate ủng hộ góp ý feedback".contains(q) {
                AdvancedSettingsSection(
                    viewModel: viewModel,
                    showResetSessionConfirmation: $showResetSessionConfirmation,
                    showDevConsole: $showDevConsole,
                    toastMessage: $toastMessage
                )
            }
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            toastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - 1. Photo Capture Settings Section
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 14) {
            // Card: Định dạng ảnh & Lưu
            SettingsSectionCard(title: "CHỤP ẢNH & ĐỊNH DẠNG", icon: "camera.fill") {
                VStack(spacing: 12) {
                    SettingsPickerRow(title: "Định dạng lưu ảnh", icon: "doc.badge.gearshape") {
                        Picker("", selection: $viewModel.selectedPhotoFormat) {
                            ForEach(PhotoSaveFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Live Photo",
                        subtitle: "Ghi lại khoảnh khắc động kèm âm thanh trước và sau khi bấm",
                        icon: "livephoto",
                        isOn: $viewModel.isLivePhotoEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Lưu ảnh gốc không chỉnh",
                        subtitle: "Giữ file ảnh nguyên bản không áp dụng bộ lọc màu film",
                        icon: "photo.on.rectangle.angled",
                        isOn: $viewModel.isSaveOriginalPhotoEnabled
                    )
                }
            }

            // Card: Video & Codec
            SettingsSectionCard(title: "QUAY PHIM (VIDEO)", icon: "video.fill") {
                VStack(spacing: 12) {
                    SettingsPickerRow(title: "Độ phân giải & FPS", icon: "speedometer") {
                        Picker("", selection: $viewModel.selectedVideoFormatOption) {
                            ForEach(VideoFormatOption.allCases) { opt in
                                Text(opt.rawValue).tag(opt)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }

                    Divider().background(Color.white.opacity(0.08))

                    SettingsPickerRow(title: "Bộ giải mã (Codec)", icon: "film") {
                        Picker("", selection: $viewModel.selectedVideoCodec) {
                            ForEach(VideoCodec.allCases) { codec in
                                Text(codec.rawValue).tag(codec)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                }
            }

            // Card: Video Pro Manual Specs
            SettingsSectionCard(title: "THÔNG SỐ PHẦN CỨNG VIDEO PRO", icon: "slider.horizontal.3") {
                VStack(spacing: 10) {
                    specRow(label: "Khẩu độ ống kính", value: "f/\(String(format: "%.1f", viewModel.proVideoService.hardwareLensAperture)) · Cố định")
                    specRow(label: "Độ nhạy ISO", value: viewModel.proVideoService.isAutoISO ? "AUTO (\(Int(viewModel.proVideoService.measuredLiveISO)))" : "\(Int(viewModel.proVideoService.currentISO))")
                    specRow(label: "Tốc độ màn trập", value: viewModel.proVideoService.isAutoShutter ? "AUTO" : "1/\(Int(viewModel.proVideoService.currentShutterSpeed))s")
                    specRow(label: "Bù phơi sáng EV", value: String(format: "%+.1f EV", viewModel.proVideoService.currentEVBias))
                }
            }

            // Card: Màu sắc film
            SettingsSectionCard(title: "BỘ MÀU FILM NGHỆ THUẬT", icon: "paintpalette.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Tự động phân tích màu theo cảnh",
                        subtitle: "AI nhận diện bối cảnh để cân chỉnh độ tương phản và nhiệt độ màu",
                        icon: "wand.and.stars",
                        isOn: $viewModel.isAIFullColorEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsPickerRow(title: "Màu film đang chọn", icon: "camera.filters") {
                        Picker("", selection: $viewModel.selectedFilmPreset) {
                            ForEach(FilmPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: viewModel.selectedFilmPreset) { newPreset in
                            viewModel.selectPreset(newPreset)
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    Text("DANH SÁCH MẪU FILM:")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.gray)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilmPreset.allCases) { preset in
                                let isSelected = viewModel.selectedFilmPreset == preset

                                Button(action: {
                                    let generator = UISelectionFeedbackGenerator()
                                    generator.prepare()
                                    generator.selectionChanged()
                                    viewModel.selectPreset(preset)
                                }) {
                                    HStack(spacing: 6) {
                                        if preset.isAIFullAuto {
                                            Image(systemName: "wand.and.stars")
                                                .font(.system(size: 11, weight: .bold))
                                        } else if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .heavy))
                                        }

                                        Text(preset.displayName)
                                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                                    }
                                    .foregroundColor(isSelected ? .black : .white.opacity(0.9))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Color.yellow : Color.white.opacity(0.08))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // Card: Khung ngắm & HUD
            SettingsSectionCard(title: "KHUNG NGẮM & CHỈ BÁO HUD", icon: "viewfinder") {
                VStack(spacing: 12) {
                    SettingsToggleRow(
                        title: "Cân bằng đường chân trời",
                        subtitle: "Hiển thị thước đo góc nghiêng gyro hỗ trợ giữ thẳng khung hình",
                        icon: "gyroscope",
                        isOn: $viewModel.isHorizonLevelerEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Focus peaking (Báo nét)",
                        subtitle: "Tô sáng viền tương phản của các điểm đang nằm trong vùng nét",
                        icon: "scope",
                        isOn: $viewModel.isFocusPeakingEnabled
                    )

                    if viewModel.isFocusPeakingEnabled {
                        SettingsPickerRow(title: "Màu viền báo nét", icon: "circle.circle.fill") {
                            Picker("", selection: $viewModel.focusPeakingColor) {
                                ForEach(FocusPeakingColor.allCases) { color in
                                    HStack {
                                        Circle().fill(color.swiftUIColor).frame(width: 8, height: 8)
                                        Text(color.rawValue)
                                    }.tag(color)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Hiển thị khung nhận diện chủ thể",
                        subtitle: "Hiện bounding box xung quanh người, khuôn mặt hoặc đồ vật",
                        icon: "boundingbox",
                        isOn: $viewModel.showDetectionBoxes
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Thanh thông số & Biểu đồ HUD",
                        subtitle: "Hiển thị Shutter, ISO, Định dạng và Histogram trên màn hình chính",
                        icon: "chart.bar.fill",
                        isOn: $viewModel.showHistogramInViewfinder
                    )

                    if viewModel.showHistogramInViewfinder {
                        Divider().background(Color.white.opacity(0.08))

                        SettingsToggleRow(
                            title: "Mở rộng 32 cột màu báo cháy sáng",
                            subtitle: "Hiển thị dải quang phổ RGB và cảnh báo clipping ở vùng sáng",
                            icon: "waveform.path.ecg",
                            isOn: $viewModel.isHistogramBarExpanded
                        )
                    }
                }
            }
        }
    }

    private func specRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - 2. AI Framing Settings Section
struct AIFramingSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var geminiKeyInput: String
    @Binding var isKeyVisible: Bool
    @Binding var selectedModel: AIVisionModel
    @Binding var isTestingKey: Bool
    @Binding var testResult: String?
    @Binding var showDeleteKeyConfirmation: Bool
    @Binding var toastMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            // Card: Bố cục thông minh
            SettingsSectionCard(title: "QUY TẮC BỐ CỤC THÔNG MINH", icon: "wand.and.stars") {
                VStack(spacing: 12) {
                    SettingsPickerRow(title: "Bố cục mặc định", icon: viewModel.activeCompositionRule.iconName) {
                        Picker("", selection: $viewModel.activeCompositionRule) {
                            ForEach(CompositionRule.allCases) { rule in
                                HStack {
                                    Image(systemName: rule.iconName)
                                    Text(rule.displayNameVietnamese)
                                }.tag(rule)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Tự động zoom theo chủ thể",
                        subtitle: "Tự điều chỉnh độ phóng đại camera để đạt tỷ lệ bố cục chuẩn nhất",
                        icon: "arrow.up.left.and.down.right.magnifyingglass",
                        isOn: $viewModel.isAutoZoomEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Tự chụp khi khớp bố cục",
                        subtitle: "Tự động kích hoạt màn trập ngay khi vòng tròn đạt độ khớp hoàn hảo",
                        icon: "camera.badge.ellipsis",
                        isOn: $viewModel.isAutoCaptureOnAlignEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Hiển thị tia hướng dẫn",
                        subtitle: "Vẽ đường định hướng nối từ tâm camera tới vị trí vàng đề xuất",
                        icon: "line.diagonal",
                        isOn: $viewModel.isGuidanceRayEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsPickerRow(title: "Độ nhạy bám chủ thể", icon: "bolt.badge.clock.fill") {
                        Picker("", selection: $viewModel.trackingSensitivity) {
                            ForEach(TrackingSensitivityPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                }
            }

            // Card: AI Cloud & Gemini API Key
            SettingsSectionCard(title: "AI CLOUD & BẢO MẬT API KEY", icon: "lock.shield.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Phân tích trực tuyến (OpenRouter AI)",
                        subtitle: "Gửi 1 khung hình chất lượng cao lên OpenRouter để AI phân tích bố cục & màu sắc",
                        icon: "network",
                        isOn: $viewModel.useGeminiForAnalysis
                    )

                    Divider().background(Color.white.opacity(0.08))

                    // API Status & Model Picker
                    HStack {
                        Label("Trạng thái API Key", systemImage: "key.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text("Đã lưu Keychain").font(.system(size: 12, weight: .bold)).foregroundColor(.green)
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle().fill(Color.gray).frame(width: 7, height: 7)
                                Text("Chưa thiết lập").font(.system(size: 12)).foregroundColor(.gray)
                            }
                        }
                    }

                    SettingsPickerRow(title: "Mô hình OpenRouter", icon: "cpu") {
                        Picker("", selection: $selectedModel) {
                            ForEach(AIVisionModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: selectedModel) { newModel in
                            viewModel.geminiService.selectedModel = newModel
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    // Key Input / Management
                    if viewModel.geminiService.hasAPIKey {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("OpenRouter API Key")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                Text("••••••••••••••••••••••••")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            }

                            Spacer()

                            Button(role: .destructive, action: {
                                showDeleteKeyConfirmation = true
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash.fill")
                                    Text("Xóa")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.12))
                                .cornerRadius(8)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                SecureField("Dán OpenRouter API Key (sk-or-...) tại đây", text: $geminiKeyInput)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(8)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(8)

                                Button("Lưu") {
                                    let trimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        viewModel.geminiService.apiKey = trimmed
                                        geminiKeyInput = ""
                                        withAnimation {
                                            toastMessage = "Đã lưu an toàn API Key vào Keychain!"
                                        }
                                    }
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.yellow)
                                .cornerRadius(8)
                            }
                        }
                    }

                    // Test Connection Button (Async)
                    Button(action: {
                        isTestingKey = true
                        testResult = nil
                        Task {
                            let (_, msg) = await viewModel.geminiService.testAPIKey()
                            await MainActor.run {
                                isTestingKey = false
                                testResult = msg
                            }
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isTestingKey {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(isTestingKey ? "Đang gửi ping kiểm tra..." : "Kiểm tra kết nối OpenRouter")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.yellow)
                        .padding(.vertical, 6)
                    }

                    if let res = testResult {
                        Text(res)
                            .font(.system(size: 11))
                            .foregroundColor(res.contains("❌") ? .red : .green)
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(6)
                    }

                    Text("🔒 Quyền riêng tư: OpenRouter API Key được mã hóa lưu trữ độc quyền trong Apple Keychain của máy. Chỉ gửi 1 frame xem trước duy nhất khi người dùng ấn nút AI Compose. Không lưu trữ ảnh người dùng.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineSpacing(2)
                }
            }
        }
    }
}

// MARK: - 3. Advanced Settings Section
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showResetSessionConfirmation: Bool
    @Binding var showDevConsole: Bool
    @Binding var toastMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            // Card: Mở rộng tiện ích
            SettingsSectionCard(title: "TÍNH NĂNG MỞ RỘNG", icon: "gearshape.2.fill") {
                VStack(spacing: 12) {
                    SettingsToggleRow(
                        title: "Chế độ đi đường (Street Tracking)",
                        subtitle: "Tăng cường độ mượt và bù trừ rung lắc khi vừa đi bộ vừa chụp",
                        icon: "figure.walk",
                        isOn: $viewModel.isStreetTrackingModeEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Rung phản hồi khi căn đúng",
                        subtitle: "Phát nhịp rung Haptics thông minh khi tâm camera hút vào điểm tỷ lệ vàng",
                        icon: "hand.tap.fill",
                        isOn: $viewModel.isProximityHapticsEnabled
                    )

                    Divider().background(Color.white.opacity(0.08))

                    SettingsToggleRow(
                        title: "Giữ màn hình luôn sáng",
                        subtitle: "Ngăn thiết bị tự động khóa màn hình trong suốt buổi chụp ảnh",
                        icon: "sun.max.fill",
                        isOn: $viewModel.isKeepScreenAwakeEnabled
                    )
                }
            }

            // Card: Chẩn đoán & Quản trị hệ thống (Collapsible)
            SettingsSectionCard(title: "CHẨN ĐOÁN & ENGINE HỆ THỐNG", icon: "cross.case.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    diagRow(label: "Động cơ thị giác", value: "Apple Vision + Optical Flow + Gyro Fusion")
                    diagRow(label: "AI Neural Engine", value: "AlignAI 114MB + CoreML YOLO")
                    diagRow(label: "Model hoạt động", value: viewModel.activeModelUsedName.isEmpty ? "Cục bộ on-device (A-Series Neural Engine)" : viewModel.activeModelUsedName)
                    diagRow(label: "Độ trễ phân tích", value: viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms (Realtime 60fps)")

                    Divider().background(Color.white.opacity(0.08))

                    Button(role: .destructive, action: {
                        showResetSessionConfirmation = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                            Text("Đặt lại phiên căn bố cục hiện tại")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.orange)
                    }

                    DisclosureGroup("Nhật ký kỹ thuật (Debug Console)", isExpanded: $showDevConsole) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let err = viewModel.geminiError {
                                Text("Lỗi ghi nhận: \(err)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.red)
                            } else {
                                Text("✓ Hệ thống đang chạy ổn định. Không có cảnh báo lỗi.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            // Card: Hỗ trợ, Đóng góp & Thông tin
            SettingsSectionCard(title: "HỖ TRỢ & THÔNG TIN", icon: "info.circle.fill") {
                VStack(spacing: 12) {
                    NavigationLink(destination: FeedbackView()) {
                        HStack {
                            Label("Gửi góp ý & phản hồi", systemImage: "envelope.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    NavigationLink(destination: SupportDeveloperView()) {
                        HStack {
                            Label("Ủng hộ tác giả ☕", systemImage: "cup.and.saucer.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.yellow)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                    }

                    Divider().background(Color.white.opacity(0.08))

                    diagRow(label: "Tác giả", value: "VanKhoa (Trần Văn Trình)")
                    diagRow(label: "Liên hệ", value: "tranvantrinhhd@gmail.com")
                    diagRow(label: "Phiên bản", value: "AlignAI Studio v1.0.0 (Build 133)")
                }
            }
        }
    }

    private func diagRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Dedicated Support Developer View (Ủng Hộ Tác Giả)
public struct SupportDeveloperView: View {
    @State private var toastMessage: String? = nil
    @State private var showVietQR: Bool = false
    @State private var qrReloadID = UUID()

    private let vietQRURLString = "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header Note
                VStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.yellow)
                        .padding(.bottom, 4)

                    Text("Ủng hộ tác giả")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Nếu bạn yêu thích AlignAI Camera và thấy ứng dụng hỗ trợ đắc lực trong nhiếp ảnh, bạn có thể mời tác giả một ly cà phê để tiếp thêm năng lượng phát triển các tính năng mới.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 12)
                }
                .padding(.top, 12)
                .padding(.bottom, 6)

                // MB Bank Card
                SettingsSectionCard(title: "NGÂN HÀNG QUÂN ĐỘI (MB BANK)", icon: "building.columns.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TRAN VAN TRINH")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                            Text("STK: 0344197212")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.yellow)
                        }

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = "0344197212"
                            showToast("Đã chép STK MB Bank: 0344197212")
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Sao chép")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.yellow)
                            .cornerRadius(8)
                        }
                    }
                }

                // VietQR Toggle & Card with .failure handling
                SettingsSectionCard(title: "MÃ VIETQR CHUYỂN KHOẢN NHANH", icon: "qrcode.viewfinder") {
                    VStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showVietQR.toggle()
                            }
                        }) {
                            HStack {
                                Image(systemName: showVietQR ? "qrcode.viewfinder" : "qrcode")
                                Text(showVietQR ? "Thu gọn mã QR" : "Hiện mã VietQR tự động điền số tiền")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                                Image(systemName: showVietQR ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.yellow)
                        }

                        if showVietQR {
                            AsyncImage(url: URL(string: vietQRURLString)) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 240)
                                        .cornerRadius(12)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                case .failure:
                                    VStack(spacing: 8) {
                                        Image(systemName: "wifi.slash")
                                            .font(.system(size: 32))
                                            .foregroundColor(.gray)
                                        Text("Không thể tải mã VietQR (Vui lòng kiểm tra kết nối mạng)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                        Button("Thử lại") {
                                            qrReloadID = UUID()
                                        }
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.yellow)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(Color.yellow.opacity(0.15))
                                        .cornerRadius(6)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(20)
                                default:
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                                        .padding(24)
                                }
                            }
                            .id(qrReloadID)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea())
        .navigationTitle("Ủng hộ tác giả")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(
            Group {
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        ToastBanner(message: msg)
                            .padding(.bottom, 24)
                    }
                }
            }
        )
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            toastMessage = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if toastMessage == msg {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - Reusable UI Components

// 1. SettingsSectionCard
public struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    public init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.yellow.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.yellow)
                }

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.gray)

                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}

// 2. SettingsToggleRow
public struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    @Binding var isOn: Bool

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.yellow)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.yellow)
        }
    }
}

// 3. SettingsPickerRow
public struct SettingsPickerRow<Content: View>: View {
    let title: String
    let icon: String
    let picker: Content

    public init(title: String, icon: String, @ViewBuilder picker: () -> Content) {
        self.title = title
        self.icon = icon
        self.picker = picker()
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.yellow)
                .frame(width: 24)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            Spacer()

            picker
        }
    }
}

// 4. ToastBanner
public struct ToastBanner: View {
    let message: String

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 10, x: 0, y: 4)
        )
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
