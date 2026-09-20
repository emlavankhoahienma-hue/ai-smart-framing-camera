import SwiftUI
import UIKit

// MARK: - Settings Tab Category
public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case capture = "Chụp ảnh & Quay phim"
    case ai = "AI Bố cục & Cloud"
    case advanced = "Nâng cao & Hệ thống"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .capture: return "camera.fill"
        case .ai: return "sparkles"
        case .advanced: return "gearshape.2.fill"
        }
    }
}

// MARK: - Main Settings View (Dark Luxury Pro Camera Edition)
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab = .capture
    @Namespace private var tabNamespace
    @State private var searchText: String = ""

    // OpenRouter API Key State
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

    private let hapticSelection = UISelectionFeedbackGenerator()
    private let hapticImpact = UIImpactFeedbackGenerator(style: .medium)

    // Design System Tokens (Dark Luxury Pro Camera)
    private let canvasBackground = Color(red: 0.035, green: 0.039, blue: 0.051) // #090A0D
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Navigation Header (Cài đặt / Xong)
                    navigationHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    // 2. Fluid Segmented Tab Bar (Apple Capsule Material)
                    tabSelectorPills
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    // 3. Scrollable Settings Content
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            if !searchText.isEmpty {
                                searchResultsView
                            } else {
                                switch selectedTab {
                                case .capture:
                                    PhotoCaptureSettingsSection(viewModel: viewModel)
                                        .transition(.opacity.combined(with: .offset(y: 8)))
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
                                    .transition(.opacity.combined(with: .offset(y: 8)))
                                case .advanced:
                                    AdvancedSettingsSection(
                                        viewModel: viewModel,
                                        showResetSessionConfirmation: $showResetSessionConfirmation,
                                        showDevConsole: $showDevConsole,
                                        toastMessage: $toastMessage
                                    )
                                    .transition(.opacity.combined(with: .offset(y: 8)))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 36)
                    }
                }

                // Floating Toast Notification
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        ToastBanner(message: msg)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
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
                Text("API Key sẽ bị xóa hoàn toàn khỏi Apple Keychain bảo mật của thiết bị.")
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
            .sheet(isPresented: $viewModel.isShowingGyroCalibration) {
                GyroCalibrationSheetView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Navigation Header (Title + Amber Done Button)
    private var navigationHeader: some View {
        HStack {
            // Invisible spacer for symmetrical centering
            Text("Xong")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.clear)

            Spacer()

            Text("Cài đặt")
                .font(.system(size: 18, weight: .bold, design: .default))
                .foregroundColor(.white)

            Spacer()

            Button("Xong") {
                hapticImpact.prepare()
                hapticImpact.impactOccurred()
                dismiss()
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(amberGold)
            .accessibilityLabel("Đóng cài đặt")
        }
    }

    // MARK: - Fluid Segmented Tab Selector (3-Tab Pill Capsule)
    private var tabSelectorPills: some View {
        HStack(spacing: 0) {
            ForEach(Array(SettingsSheetTab.allCases.enumerated()), id: \.element.id) { index, tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    hapticSelection.prepare()
                    hapticSelection.selectionChanged()
                    withAnimation(.snappy(duration: 0.26)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.78)
                        .foregroundColor(isSelected ? .white : Color.white.opacity(0.60))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .padding(.horizontal, 4)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.72, green: 0.46, blue: 0.18),
                                                Color(red: 0.58, green: 0.36, blue: 0.14)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .matchedGeometryEffect(id: "activeTabIndicatorPill", in: tabNamespace)
                                    .overlay {
                                        Capsule()
                                            .stroke(Color(red: 1.0, green: 0.78, blue: 0.35).opacity(0.40), lineWidth: 1)
                                    }
                                    .shadow(color: amberGold.opacity(0.25), radius: 6, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)

                // Divider between inactive tabs
                if index < SettingsSheetTab.allCases.count - 1 {
                    let nextTab = SettingsSheetTab.allCases[index + 1]
                    if selectedTab != tab && selectedTab != nextTab {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1, height: 18)
                    }
                }
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        )
        .frame(height: 46)
    }

    // MARK: - Search Results Dynamic Filter View
    @ViewBuilder
    private var searchResultsView: some View {
        let q = searchText.lowercased()
        VStack(spacing: 16) {
            if "định dạng ảnh raw jpeg heic dng live photo lưu ảnh gốc video codec 4k 1080p fps film màu fuji kodak leica horizon focus peaking histogram hiệu chuẩn con quay gyro cân đối xứng".contains(q) {
                PhotoCaptureSettingsSection(viewModel: viewModel)
            }
            if "bố cục tỷ lệ vàng 1/3 tam giác xoắn ốc ai zoom bám chủ thể tự chụp tia hướng dẫn openrouter api key gemini model ping latency".contains(q) {
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
            if "hệ thống đường phố street tracking rung haptic màn hình sáng chẩn đoán engine nhật ký log debug feedback góp ý donate ủng hộ hiệu chuẩn con quay gyro 6dof".contains(q) {
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

// MARK: - Dedicated Row Icon Component (Category Colored Rounded Boxes)
public struct SettingsRowIcon: View {
    let icon: String
    let color: Color

    public init(_ icon: String, color: Color = Color(red: 1.0, green: 0.69, blue: 0.16)) {
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(0.24), lineWidth: 0.8)
                }

            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - Sub-component: Film Preset Pill
private struct FilmPresetPill: View {
    let preset: FilmPreset
    let isSelected: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: onSelect) {
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
            .foregroundColor(isSelected ? .black : Color.white.opacity(0.90))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? amberGold : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? amberGold : Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sub-component: Focus Peaking Color Button
private struct PeakingColorCircleButton: View {
    let color: FocusPeakingColor
    let isPicked: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 28, height: 28)

                if isPicked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(color == .yellow || color == .green ? Color.black : Color.white)
                }
            }
            .overlay(
                Circle()
                    .stroke(isPicked ? Color.white : Color.clear, lineWidth: 2)
                    .padding(-2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sub-component: Composition Rule Card
private struct CompositionRuleCard: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.65))
                    .frame(width: 18)

                Text(rule.displayNameVietnamese)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.80))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 2)

                if isSelected {
                    Circle()
                        .fill(amberGold)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? amberGold.opacity(0.16) : Color(red: 0.05, green: 0.05, blue: 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? amberGold.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sub-component: Sensitivity Pill
private struct SensitivityPill: View {
    let preset: TrackingSensitivityPreset
    let isPicked: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: onSelect) {
            Text(preset.shortName)
                .font(.system(size: 13, weight: isPicked ? .bold : .medium, design: .rounded))
                .foregroundColor(isPicked ? .black : Color.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Capsule()
                        .fill(isPicked ? amberGold : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(isPicked ? amberGold : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 1. Photo Capture Settings Section (Pro Camera Luxury)
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        VStack(spacing: 14) {
            photoFormatCard
            videoCodecCard
            cameraHardwareSpecsCard
            filmColorCard
            viewfinderHUDCard
        }
    }

    // Card 1: Chụp ảnh & Định dạng
    @ViewBuilder
    private var photoFormatCard: some View {
        SettingsSectionCard(title: "CHỤP ẢNH", icon: "camera.fill", iconColor: amberGold) {
            VStack(spacing: 0) {
                SettingsPickerRow(
                    title: "Định dạng ảnh",
                    subtitle: "Chọn định dạng lưu ảnh",
                    icon: "photo.fill",
                    iconColor: amberGold,
                    selectedValueString: viewModel.selectedPhotoFormat.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedPhotoFormat) {
                        ForEach(PhotoSaveFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.70))
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Live Photo",
                    subtitle: "Lưu chuyển động ngắn trước và sau khi chụp",
                    icon: "livephoto",
                    iconColor: Color(red: 0.25, green: 0.65, blue: 1.0),
                    isOn: $viewModel.isLivePhotoEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Lưu ảnh gốc không chỉnh",
                    subtitle: "Giữ file ảnh nguyên bản cảm biến không áp bộ lọc màu film",
                    icon: "photo.on.rectangle.angled",
                    iconColor: Color(red: 0.35, green: 0.75, blue: 0.85),
                    isOn: $viewModel.isSaveOriginalPhotoEnabled
                )
            }
        }
    }

    // Card 2: Quay phim (Video)
    @ViewBuilder
    private var videoCodecCard: some View {
        SettingsSectionCard(title: "QUAY VIDEO", icon: "video.fill", iconColor: Color(red: 0.72, green: 0.45, blue: 1.0)) {
            VStack(spacing: 0) {
                SettingsPickerRow(
                    title: "Độ phân giải",
                    subtitle: "Chọn độ phân giải và tốc độ khung hình",
                    icon: "video.fill",
                    iconColor: Color(red: 0.72, green: 0.45, blue: 1.0),
                    selectedValueString: viewModel.selectedVideoFormatOption.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedVideoFormatOption) {
                        ForEach(VideoFormatOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.70))
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Codec",
                    subtitle: "Chọn định dạng nén video",
                    icon: "cylinder.split.1x2.fill",
                    iconColor: Color(red: 0.30, green: 0.85, blue: 0.55),
                    selectedValueString: viewModel.selectedVideoCodec.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedVideoCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.70))
                }
            }
        }
    }

    // Card 3: Thông số phần cứng Camera (Lưới 2 cột cho màn hình nhỏ)
    @ViewBuilder
    private var cameraHardwareSpecsCard: some View {
        SettingsSectionCard(title: "THÔNG SỐ PHẦN CỨNG CAMERA", icon: "slider.horizontal.3", iconColor: Color.orange) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                telemetryBadge(title: "Khẩu độ", value: "f/\(String(format: "%.1f", viewModel.proVideoService.hardwareLensAperture))")
                telemetryBadge(title: "Độ nhạy ISO", value: viewModel.proVideoService.isAutoISO ? "AUTO (\(Int(viewModel.proVideoService.measuredLiveISO)))" : "\(Int(viewModel.proVideoService.currentISO))")
                telemetryBadge(title: "Màn trập", value: viewModel.proVideoService.isAutoShutter ? "AUTO" : "1/\(Int(viewModel.proVideoService.currentShutterSpeed))s")
                telemetryBadge(title: "Bù sáng EV", value: String(format: "%+.1f", viewModel.proVideoService.currentEVBias))
            }
            .padding(.vertical, 6)
        }
    }

    // Card 4: Màu sắc & Preset Film
    @ViewBuilder
    private var filmColorCard: some View {
        SettingsSectionCard(title: "MÀU SẮC", icon: "paintpalette.fill", iconColor: Color(red: 0.95, green: 0.45, blue: 0.65)) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Tự động phân tích màu theo cảnh",
                    subtitle: "AI nhận diện bối cảnh để cân chỉnh độ tương phản và nhiệt độ màu",
                    icon: "wand.and.stars",
                    iconColor: amberGold,
                    isOn: $viewModel.isAIFullColorEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Preset mặc định",
                    subtitle: "Áp dụng phong cách màu cho ảnh và video",
                    icon: "camera.filters",
                    iconColor: Color(red: 0.95, green: 0.45, blue: 0.65),
                    selectedValueString: viewModel.selectedFilmPreset.displayName
                ) {
                    Picker("", selection: $viewModel.selectedFilmPreset) {
                        ForEach(FilmPreset.selectablePresets) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.70))
                    .onChange(of: viewModel.selectedFilmPreset) { newPreset in
                        viewModel.selectPreset(newPreset)
                    }
                }

                Divider().background(Color.white.opacity(0.06))

                Text("DANH SÁCH MẪU FILM NHANH:")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.45))
                    .padding(.top, 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FilmPreset.selectablePresets) { preset in
                            FilmPresetPill(
                                preset: preset,
                                isSelected: viewModel.selectedFilmPreset == preset,
                                onSelect: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    viewModel.selectPreset(preset)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // Card 5: Khung ngắm & Chỉ báo HUD
    @ViewBuilder
    private var viewfinderHUDCard: some View {
        SettingsSectionCard(title: "KHUNG NGẮM & CHỈ BÁO HUD", icon: "viewfinder", iconColor: Color(red: 0.35, green: 0.75, blue: 1.0)) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Cân bằng đường chân trời",
                    subtitle: "Hiển thị thước đo góc nghiêng gyro hỗ trợ giữ thẳng khung hình",
                    icon: "gyroscope",
                    iconColor: Color(red: 1.0, green: 0.58, blue: 0.20),
                    isOn: $viewModel.isHorizonLevelerEnabled
                )

                if viewModel.isHorizonLevelerEnabled {
                    Divider().background(Color.white.opacity(0.06))

                    SettingsActionRow(
                        title: "Hiệu chuẩn con quay & Thước cân",
                        subtitle: viewModel.lastGyroCalibrationDate != nil
                            ? "Đã cân bằng (Bù lệch Roll: \(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°)"
                            : "Khử sai số ốp lưng, camera lồi và triệt tiêu trôi tĩnh",
                        icon: "slider.horizontal.2.square.on.square",
                        iconColor: amberGold,
                        badgeText: viewModel.lastGyroCalibrationDate != nil ? "\(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°" : "Cần cân"
                    ) {
                        viewModel.isShowingGyroCalibration = true
                    }
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Focus peaking (Báo nét)",
                    subtitle: "Tô sáng viền tương phản của các điểm đang nằm trong vùng nét",
                    icon: "scope",
                    iconColor: Color.green,
                    isOn: $viewModel.isFocusPeakingEnabled
                )

                if viewModel.isFocusPeakingEnabled {
                    peakingColorPickerRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Hiển thị khung nhận diện chủ thể",
                    subtitle: "Hiện bounding box xung quanh người, khuôn mặt hoặc đồ vật",
                    icon: "boundingbox",
                    iconColor: Color.yellow,
                    isOn: $viewModel.showDetectionBoxes
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Thanh thông số & Biểu đồ HUD",
                    subtitle: "Hiển thị Shutter, ISO, Định dạng và Histogram trên màn hình chính",
                    icon: "chart.bar.fill",
                    iconColor: amberGold,
                    isOn: $viewModel.showHistogramInViewfinder
                )

                if viewModel.showHistogramInViewfinder {
                    Divider().background(Color.white.opacity(0.06))

                    SettingsToggleRow(
                        title: "Mở rộng 32 cột màu báo cháy sáng",
                        subtitle: "Hiển thị dải quang phổ RGB và cảnh báo clipping ở vùng sáng",
                        icon: "waveform.path.ecg",
                        iconColor: Color.red,
                        isOn: $viewModel.isHistogramBarExpanded
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var peakingColorPickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Màu viền báo nét:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.75))
                Spacer()
                Text(viewModel.focusPeakingColor.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(viewModel.focusPeakingColor.swiftUIColor)
            }

            HStack(spacing: 14) {
                ForEach(FocusPeakingColor.allCases) { color in
                    PeakingColorCircleButton(
                        color: color,
                        isPicked: viewModel.focusPeakingColor == color,
                        onSelect: {
                            UISelectionFeedbackGenerator().selectionChanged()
                            viewModel.focusPeakingColor = color
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private func telemetryBadge(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.48))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(amberGold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

// MARK: - 2. AI Framing Settings Section (Pro Camera Luxury)
struct AIFramingSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var geminiKeyInput: String
    @Binding var isKeyVisible: Bool
    @Binding var selectedModel: AIVisionModel
    @Binding var isTestingKey: Bool
    @Binding var testResult: String?
    @Binding var showDeleteKeyConfirmation: Bool
    @Binding var toastMessage: String?

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        VStack(spacing: 14) {
            compositionRulesCard
            aiCloudCard
        }
    }

    @ViewBuilder
    private var compositionRulesCard: some View {
        SettingsSectionCard(title: "QUY TẮC BỐ CỤC THÔNG MINH", icon: "wand.and.stars", iconColor: amberGold) {
            VStack(spacing: 12) {
                // Visual Composition Cards Grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("QUY TẮC BỐ CỤC MẶC ĐỊNH:")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.45))

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(CompositionRule.allCases) { rule in
                            CompositionRuleCard(
                                rule: rule,
                                isSelected: viewModel.activeCompositionRule == rule,
                                onSelect: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                        viewModel.activeCompositionRule = rule
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.vertical, 4)

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Tự động zoom theo chủ thể",
                    subtitle: "Tự điều chỉnh độ phóng đại camera để đạt tỷ lệ bố cục chuẩn nhất",
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    iconColor: Color(red: 0.35, green: 0.75, blue: 1.0),
                    isOn: $viewModel.isAutoZoomEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Tự chụp khi khớp bố cục",
                    subtitle: "Tự động kích hoạt màn trập ngay khi hai tâm đạt độ khớp hoàn hảo",
                    icon: "camera.badge.ellipsis",
                    iconColor: Color(red: 0.30, green: 0.85, blue: 0.55),
                    isOn: $viewModel.isAutoCaptureOnAlignEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Hiển thị tia hướng dẫn",
                    subtitle: "Vẽ đường định hướng nối từ tâm camera tới vị trí vàng đề xuất",
                    icon: "line.diagonal",
                    iconColor: Color(red: 1.0, green: 0.58, blue: 0.20),
                    isOn: $viewModel.isGuidanceRayEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                // Tracking Sensitivity Segmented Control
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Độ nhạy bám chủ thể", systemImage: "bolt.badge.clock.fill")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                        Text(viewModel.trackingSensitivity.shortName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(amberGold)
                    }

                    HStack(spacing: 8) {
                        ForEach(TrackingSensitivityPreset.allCases) { preset in
                            SensitivityPill(
                                preset: preset,
                                isPicked: viewModel.trackingSensitivity == preset,
                                onSelect: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                        viewModel.trackingSensitivity = preset
                                    }
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Text(viewModel.trackingSensitivity.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.48))
                        .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var aiCloudCard: some View {
        SettingsSectionCard(title: "AI CLOUD & BẢO MẬT API KEY", icon: "lock.shield.fill", iconColor: Color(red: 0.25, green: 0.85, blue: 0.45)) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Phân tích trực tuyến (OpenRouter AI)",
                    subtitle: "Gửi 1 khung hình chất lượng cao lên OpenRouter để AI phân tích bố cục & màu sắc",
                    icon: "network",
                    iconColor: Color(red: 0.35, green: 0.55, blue: 1.0),
                    isOn: $viewModel.useGeminiForAnalysis
                )

                Divider().background(Color.white.opacity(0.06))

                // API Status Badge
                HStack {
                    Label("Trạng thái API Key", systemImage: "key.fill")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Spacer()
                    if viewModel.geminiService.hasAPIKey {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text("Đã lưu Keychain").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.green)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                    } else {
                        HStack(spacing: 5) {
                            Circle().fill(Color.gray).frame(width: 7, height: 7)
                            Text("Chưa thiết lập").font(.system(size: 12)).foregroundColor(.gray)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 2)

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Mô hình AI",
                    subtitle: "Lựa chọn model thị giác máy tính",
                    icon: "cpu",
                    iconColor: Color(red: 0.72, green: 0.45, blue: 1.0),
                    selectedValueString: selectedModel.displayName
                ) {
                    Picker("", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.white.opacity(0.70))
                    .onChange(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }
                }

                Divider().background(Color.white.opacity(0.06))

                // Key Input / Management
                if viewModel.geminiService.hasAPIKey {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("OpenRouter API Key")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("sk-or-••••••••••••••••")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = viewModel.geminiService.apiKey
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation {
                                toastMessage = "Đã sao chép API Key vào bộ nhớ tạm"
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Chép")
                            }
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Button(role: .destructive, action: {
                            showDeleteKeyConfirmation = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash.fill")
                                Text("Xóa")
                            }
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            SecureField("Dán API Key (sk-or-...)", text: $geminiKeyInput)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(10)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .background(Color.black.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )

                            Button("Lưu") {
                                let trimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    viewModel.geminiService.apiKey = trimmed
                                    geminiKeyInput = ""
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    withAnimation {
                                        toastMessage = "Đã lưu an toàn API Key vào Keychain!"
                                    }
                                }
                            }
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(amberGold)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Test Connection Button (Async Ping)
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
                            ProgressView().scaleEffect(0.8).tint(amberGold)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTestingKey ? "Đang gửi ping kiểm tra..." : "Kiểm tra kết nối OpenRouter")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(amberGold)
                    .padding(.vertical, 4)
                }

                if let res = testResult {
                    Text(res)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(res.contains("❌") ? .red : .green)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.40))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(res.contains("❌") ? Color.red.opacity(0.3) : Color.green.opacity(0.3), lineWidth: 1)
                        )
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 12))
                        .foregroundColor(amberGold)
                    Text("OpenRouter API Key được mã hóa lưu trữ độc quyền trong Apple Keychain của máy. Chỉ gửi 1 frame xem trước duy nhất khi bấm phân tích. Không lưu trữ ảnh người dùng.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.45))
                        .lineSpacing(2)
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - 3. Advanced Settings Section (Pro Camera Luxury)
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showResetSessionConfirmation: Bool
    @Binding var showDevConsole: Bool
    @Binding var toastMessage: String?

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        VStack(spacing: 14) {
            featuresCard
            diagnosticsCard
            supportInfoCard
        }
    }

    @ViewBuilder
    private var featuresCard: some View {
        SettingsSectionCard(title: "TÍNH NĂNG MỞ RỘNG", icon: "gearshape.2.fill", iconColor: Color(red: 1.0, green: 0.58, blue: 0.20)) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Chế độ đi đường (Street Tracking)",
                    subtitle: "Tăng cường độ mượt và bù trừ rung lắc khi vừa đi bộ vừa chụp",
                    icon: "figure.walk",
                    iconColor: Color(red: 1.0, green: 0.58, blue: 0.20),
                    isOn: $viewModel.isStreetTrackingModeEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Rung phản hồi khi căn đúng",
                    subtitle: "Phát nhịp rung Haptics thông minh khi tâm camera hút vào điểm tỷ lệ vàng",
                    icon: "hand.tap.fill",
                    iconColor: amberGold,
                    isOn: $viewModel.isProximityHapticsEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Giữ màn hình luôn sáng",
                    subtitle: "Ngăn thiết bị tự động khóa màn hình trong suốt buổi chụp ảnh",
                    icon: "sun.max.fill",
                    iconColor: Color.yellow,
                    isOn: $viewModel.isKeepScreenAwakeEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsActionRow(
                    title: "Hiệu chuẩn con quay hồi chuyển 60Hz",
                    subtitle: viewModel.lastGyroCalibrationDate != nil
                        ? "Đã tối ưu hóa IMU (Bù lệch Roll: \(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°)"
                        : "Khử trôi (Zero-bias) và cân chỉnh 3 trục xoay cho tracking 6DoF",
                    icon: "gyroscope",
                    iconColor: amberGold,
                    badgeText: viewModel.lastGyroCalibrationDate != nil ? "\(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°" : "Chưa cân"
                ) {
                    viewModel.isShowingGyroCalibration = true
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsCard: some View {
        SettingsSectionCard(title: "CHẨN ĐOÁN & ENGINE HỆ THỐNG", icon: "cross.case.fill", iconColor: Color(red: 0.35, green: 0.75, blue: 1.0)) {
            VStack(alignment: .leading, spacing: 12) {
                diagRow(label: "Động cơ thị giác", value: "Apple Vision + Optical Flow + Gyro")
                diagRow(label: "AI Neural Engine", value: "AlignAI 114MB + CoreML YOLO")
                diagRow(label: "Model hoạt động", value: viewModel.activeModelUsedName.isEmpty ? "Cục bộ on-device (Neural Engine)" : viewModel.activeModelUsedName)
                diagRow(label: "Độ trễ phân tích", value: viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms (Realtime 60fps)")

                Divider().background(Color.white.opacity(0.06))

                Button(role: .destructive, action: {
                    showResetSessionConfirmation = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                        Text("Đặt lại phiên căn bố cục hiện tại")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .padding(.vertical, 4)
                }

                DisclosureGroup("Nhật ký kỹ thuật (Debug Console)", isExpanded: $showDevConsole) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let err = viewModel.geminiError {
                            Text("Lỗi ghi nhận: \(err)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("✓ Hệ thống đang chạy ổn định. Không có cảnh báo lỗi.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private var supportInfoCard: some View {
        SettingsSectionCard(title: "HỖ TRỢ & THÔNG TIN", icon: "info.circle.fill", iconColor: Color(red: 0.25, green: 0.85, blue: 0.45)) {
            VStack(spacing: 0) {
                NavigationLink(destination: FeedbackView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("envelope.fill", color: Color(red: 0.35, green: 0.65, blue: 1.0))

                        Text("Gửi góp ý & phản hồi")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(.white)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                    .frame(minHeight: 52)
                }

                Divider().background(Color.white.opacity(0.06))

                NavigationLink(destination: SupportDeveloperView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("cup.and.saucer.fill", color: amberGold)

                        Text("Ủng hộ tác giả ☕")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundColor(amberGold)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                    .frame(minHeight: 52)
                }

                Divider().background(Color.white.opacity(0.06))

                VStack(spacing: 8) {
                    diagRow(label: "Tác giả", value: "VanKhoa (Trần Văn Trình)")
                    diagRow(label: "Liên hệ", value: "tranvantrinhhd@gmail.com")
                    diagRow(label: "Phiên bản", value: "AlignAI Camera v1.0.0 (Build 171)")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func diagRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.70))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(amberGold)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Dedicated Support Developer View (Ủng Hộ Tác Giả - Luxury Edition)
public struct SupportDeveloperView: View {
    @State private var toastMessage: String? = nil
    @State private var showVietQR: Bool = false
    @State private var qrReloadID = UUID()

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)
    private let vietQRURLString = "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero Header
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(amberGold.opacity(0.18))
                            .frame(width: 72, height: 72)

                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(amberGold)
                    }
                    .padding(.top, 10)

                    Text("Ủng hộ tác giả")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Nếu bạn yêu thích AlignAI Camera và thấy ứng dụng hỗ trợ đắc lực trong nhiếp ảnh, bạn có thể mời tác giả một ly cà phê để tiếp thêm năng lượng phát triển các tính năng mới.")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 6)

                // MB Bank Card
                SettingsSectionCard(title: "NGÂN HÀNG QUÂN ĐỘI (MB BANK)", icon: "building.columns.fill", iconColor: amberGold) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TRAN VAN TRINH")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("STK: 0344197212")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(amberGold)
                        }

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = "0344197212"
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showToast("Đã chép STK MB Bank: 0344197212")
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.on.doc")
                                Text("Sao chép")
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(amberGold)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                // VietQR Card with Retry Logic
                SettingsSectionCard(title: "MÃ VIETQR CHUYỂN KHOẢN NHANH", icon: "qrcode.viewfinder", iconColor: Color(red: 0.25, green: 0.85, blue: 0.45)) {
                    VStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showVietQR.toggle()
                            }
                        }) {
                            HStack {
                                Image(systemName: showVietQR ? "qrcode.viewfinder" : "qrcode")
                                Text(showVietQR ? "Thu gọn mã QR" : "Hiện mã VietQR tự động điền số tiền")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                Spacer()
                                Image(systemName: showVietQR ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(amberGold)
                        }

                        if showVietQR {
                            AsyncImage(url: URL(string: vietQRURLString)) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                case .failure:
                                    VStack(spacing: 8) {
                                        Image(systemName: "wifi.slash")
                                            .font(.system(size: 32))
                                            .foregroundColor(.gray)
                                        Text("Không thể tải mã VietQR (Vui lòng kiểm tra mạng)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                        Button("Thử lại") {
                                            qrReloadID = UUID()
                                        }
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(amberGold)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(20)
                                default:
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: amberGold))
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
        .background(Color(red: 0.035, green: 0.039, blue: 0.051).ignoresSafeArea())
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

// MARK: - Reusable UI Components (Pro Camera Luxury Style)

// 1. SettingsSectionCard
public struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    var iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16)
    let content: Content

    public init(
        title: String,
        icon: String,
        iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16),
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Uppercase Section Header
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.50))
                .tracking(0.6)
                .padding(.leading, 8)
                .padding(.bottom, 2)

            // Inset Grouped Card Body
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.075, green: 0.080, blue: 0.098))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.065), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// 2. SettingsToggleRow
public struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16)
    @Binding var isOn: Bool

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon, color: iconColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.52))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(amberGold)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// 3. SettingsPickerRow
public struct SettingsPickerRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16)
    var selectedValueString: String = ""
    let picker: Content

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16),
        selectedValueString: String = "",
        @ViewBuilder picker: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconColor = iconColor
        self.selectedValueString = selectedValueString
        self.picker = picker()
    }

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon, color: iconColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.52))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                picker
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

// 4. SettingsActionRow
public struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16)
    var badgeText: String? = nil
    let action: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        iconColor: Color = Color(red: 1.0, green: 0.69, blue: 0.16),
        badgeText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconColor = iconColor
        self.badgeText = badgeText
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsRowIcon(icon, color: iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.52))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 1.0, green: 0.69, blue: 0.16))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color(red: 1.0, green: 0.69, blue: 0.16).opacity(0.15))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// 5. ToastBanner
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
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.6), radius: 12, x: 0, y: 4)
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
