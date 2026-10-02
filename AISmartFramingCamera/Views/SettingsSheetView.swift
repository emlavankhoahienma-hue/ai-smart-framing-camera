import SwiftUI
import UIKit

// MARK: - Settings Tab Category
public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case capture = "Chụp ảnh & Quay phim"
    case ai = "AI Bố cục & Cloud"
    case advanced = "Nâng cao & Hệ thống"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .capture: return "Chụp"
        case .ai: return "AI Bố cục"
        case .advanced: return "Nâng cao"
        }
    }

    public var icon: String {
        switch self {
        case .capture: return "camera.fill"
        case .ai: return "sparkles"
        case .advanced: return "gearshape.2.fill"
        }
    }
}

// MARK: - Main Settings View (Obsidian Glass Camera Edition)
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab = .capture
    @Namespace private var tabNamespace
    @State private var searchText: String = ""

    // OpenRouter API Key State
    @State private var geminiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var selectedModel: AIVisionModel = .freeVision
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

    // Design System Tokens (Obsidian Glass Camera)
    private let canvasBackground = Color(red: 0.031, green: 0.035, blue: 0.047) // #08090C
    private let cardBackground = Color(red: 0.075, green: 0.082, blue: 0.102)   // #13151A
    private let textPrimary = Color(white: 0.96)                                 // Trắng ngà
    private let textSecondary = Color(red: 0.58, green: 0.60, blue: 0.66)        // Xám lạnh
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)           // #D9A441

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Navigation Header (Title "Cài đặt" on Left, "Xong" on Right)
                    navigationHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    // 1.1 In-Sheet Search Bar (Mockup 3)
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    // 2. Fluid Segmented Tab Bar (Chụp | AI Bố cục | Nâng cao)
                    tabSelectorPills
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

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
                                        customModelInput: $customModelInput,
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

    // MARK: - Navigation Header ("Cài đặt" on Left, "Xong" on Right)
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Text("Cài đặt")
                .font(.system(size: 26, weight: .bold, design: .default))
                .foregroundColor(textPrimary)

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

    // MARK: - In-Sheet Search Bar (Mockup 3)
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(textSecondary)
                .font(.system(size: 15, weight: .semibold))

            TextField("Tìm kiếm cài đặt", text: $searchText)
                .font(.system(size: 15))
                .foregroundColor(textPrimary)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Fluid Segmented Tab Selector (Chụp | AI Bố cục | Nâng cao)
    private var tabSelectorPills: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSheetTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    hapticSelection.prepare()
                    hapticSelection.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.shortTitle)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .black : textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(amberGold)
                                    .matchedGeometryEffect(id: "active_obsidian_tab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(cardBackground)
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }
        )
        .frame(height: 44)
    }

    // MARK: - Search Results Dynamic Filter View
    @ViewBuilder
    private var searchResultsView: some View {
        let q = searchText.lowercased()
        VStack(spacing: 16) {
            if "định dạng ảnh raw jpeg heic dng siêu nét đa khung drizzle super-res live photo lưu ảnh gốc video codec 4k 1080p fps film màu fuji kodak leica horizon focus peaking histogram hiệu chuẩn con quay gyro cân đối xứng âm thanh audio vu meter micro".contains(q) {
                PhotoCaptureSettingsSection(viewModel: viewModel)
            }
            if "bố cục tỷ lệ vàng 1/3 tam giác xoắn ốc ai zoom bám chủ thể tự chụp tia hướng dẫn openrouter api key gemini model ping latency".contains(q) {
                AIFramingSettingsSection(
                    viewModel: viewModel,
                    geminiKeyInput: $geminiKeyInput,
                    isKeyVisible: $isKeyVisible,
                    selectedModel: $selectedModel,
                    customModelInput: $customModelInput,
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

// MARK: - Dedicated Row Icon Component
public struct SettingsRowIcon: View {
    let icon: String
    let color: Color

    public init(_ icon: String, color: Color = Color(red: 0.85, green: 0.64, blue: 0.25)) {
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.14))
                .frame(width: 30, height: 30)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Sub-component: Film Preset Pill
private struct FilmPresetPill: View {
    let preset: FilmPreset
    let isSelected: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

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
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

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
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

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

// MARK: - 1. Photo Capture Settings Section (Obsidian Glass Camera)
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        VStack(spacing: 16) {
            photoCaptureCard
            videoRecordingCard
            aiAndCalibrationCard
            filmColorCard
            viewfinderHUDCard
            cameraHardwareSpecsCard
        }
    }

    // Card 1: Chụp ảnh (Mockup 3)
    @ViewBuilder
    private var photoCaptureCard: some View {
        SettingsSectionCard(title: "Chụp ảnh", icon: "camera.fill") {
            VStack(spacing: 0) {
                SettingsPickerRow(
                    title: "Độ phân giải",
                    subtitle: "Định dạng lưu ảnh và độ phân giải cảm biến",
                    icon: "camera.badge.ellipsis",
                    selectedValueString: photoResolutionLabel
                ) {
                    Picker("", selection: $viewModel.selectedPhotoFormat) {
                        Text("HEIF Tối đa (48MP)").tag(PhotoSaveFormat.heif)
                        Text("HEIC Chuẩn (12MP)").tag(PhotoSaveFormat.heic)
                        Text("JPEG").tag(PhotoSaveFormat.jpeg)
                        Text("RAW (DNG)").tag(PhotoSaveFormat.dng)
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Tỷ lệ khung hình",
                    subtitle: "Tỷ lệ khung ngắm và ảnh chụp",
                    icon: "aspectratio",
                    selectedValueString: viewModel.windowedZoomAspectRatio.rawValue == "3:4" ? "4:3" : viewModel.windowedZoomAspectRatio.rawValue
                ) {
                    Picker("", selection: $viewModel.windowedZoomAspectRatio) {
                        Text("4:3").tag(WindowedZoomAspectRatio.ratio3_4)
                        Text("16:9").tag(WindowedZoomAspectRatio.ratio16_9)
                        Text("1:1").tag(WindowedZoomAspectRatio.ratio1_1)
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Chống rung quang học (OIS)",
                    subtitle: "Ổn định cảm biến chống rung khi cầm tay",
                    icon: "hand.raised.fill",
                    isOn: $viewModel.isOpticalStabilizationEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Live Photo",
                    subtitle: "Ghi lại chuyển động ngắn trước và sau khi bấm máy",
                    icon: "livephoto",
                    isOn: $viewModel.isLivePhotoEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Lưu ảnh gốc không chỉnh",
                    subtitle: "Giữ file ảnh nguyên bản cảm biến không áp bộ lọc màu film",
                    icon: "photo.on.rectangle.angled",
                    isOn: $viewModel.isSaveOriginalPhotoEnabled
                )
            }
        }
    }

    private var photoResolutionLabel: String {
        switch viewModel.selectedPhotoFormat {
        case .heif:
            return viewModel.isSuperResolutionRAWEnabled ? "HEIF Tối đa (48MP)" : "HEIF (24MP)"
        case .heic:
            return "HEIC Chuẩn (12MP)"
        case .jpeg:
            return "JPEG"
        case .dng:
            return "RAW (DNG)"
        }
    }

    // Card 2: Quay video (Mockup 3)
    @ViewBuilder
    private var videoRecordingCard: some View {
        SettingsSectionCard(title: "Quay video", icon: "video.fill") {
            VStack(spacing: 0) {
                SettingsPickerRow(
                    title: "Độ phân giải & Tốc độ",
                    subtitle: "Độ nét và số khung hình trên giây",
                    icon: "video.fill",
                    selectedValueString: viewModel.selectedVideoFormatOption.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedVideoFormatOption) {
                        ForEach(VideoFormatOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Định dạng",
                    subtitle: "Chuẩn nén video tối ưu phần cứng",
                    icon: "cylinder.split.1x2.fill",
                    selectedValueString: viewModel.selectedVideoCodec.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedVideoCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Khóa cân bằng trắng",
                    subtitle: "Giữ cố định nhiệt độ màu trong suốt cảnh quay",
                    icon: "lock.fill",
                    isOn: $viewModel.isWhiteBalanceLocked
                )
            }
        }
    }

    // Card 3: AI và hiệu chuẩn (Mockup 3)
    @ViewBuilder
    private var aiAndCalibrationCard: some View {
        SettingsSectionCard(title: "AI và hiệu chuẩn", icon: "cpu") {
            VStack(spacing: 0) {
                SettingsActionRow(
                    title: "Động cơ AI",
                    subtitle: "Mạng nơ-ron nhận diện bố cục và chủ thể thời gian thực",
                    icon: "brain.head.profile",
                    badgeText: "YOLOv26 (ANE)"
                ) {
                    // Hiển thị thông số engine
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Lưới bố cục",
                    subtitle: "Hiển thị đường lưới căn chỉnh trên khung ngắm",
                    icon: "grid",
                    isOn: $viewModel.isCompositionGridVisible
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsActionRow(
                    title: "Hiệu chuẩn chân trời",
                    subtitle: viewModel.lastGyroCalibrationDate != nil
                        ? "Đã cân bằng (Bù lệch Roll: \(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°)"
                        : "Cân bằng cảm biến con quay gyro 6-DoF",
                    icon: "gyroscope",
                    badgeText: viewModel.lastGyroCalibrationDate != nil ? "Tự động" : "Cần cân"
                ) {
                    viewModel.isShowingGyroCalibration = true
                }
            }
        }
    }

    // Card 3: Thông số phần cứng Camera
    @ViewBuilder
    private var cameraHardwareSpecsCard: some View {
        SettingsSectionCard(title: "Thông số quang học", icon: "slider.horizontal.3") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                telemetryBadge(title: "Khẩu độ", value: "f/\(String(format: "%.1f", viewModel.proVideoService.hardwareLensAperture))")
                telemetryBadge(title: "Độ nhạy ISO", value: viewModel.proVideoService.isAutoISO ? "AUTO (\(Int(viewModel.proVideoService.measuredLiveISO)))" : "\(Int(viewModel.proVideoService.currentISO))")
                telemetryBadge(title: "Màn trập", value: viewModel.proVideoService.isAutoShutter ? "AUTO" : "1/\(Int(viewModel.proVideoService.currentShutterSpeed))s")
                telemetryBadge(title: "Bù sáng EV", value: String(format: "%+.1f", viewModel.proVideoService.currentEVBias))
            }
            .padding(.vertical, 4)
        }
    }

    // Card 4: Màu sắc & Preset Film
    @ViewBuilder
    private var filmColorCard: some View {
        SettingsSectionCard(title: "Màu sắc & Giả lập phim", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Tự động phân tích màu theo cảnh",
                    subtitle: "AI nhận diện bối cảnh để cân chỉnh độ tương phản và nhiệt độ màu",
                    icon: "wand.and.stars",
                    isOn: $viewModel.isAIFullColorEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsPickerRow(
                    title: "Preset mặc định",
                    subtitle: "Áp dụng phong cách màu cho ảnh và video",
                    icon: "camera.filters",
                    selectedValueString: viewModel.selectedFilmPreset.displayName
                ) {
                    Picker("", selection: $viewModel.selectedFilmPreset) {
                        ForEach(FilmPreset.selectablePresets) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                    .onChangeCompatible(of: viewModel.selectedFilmPreset) { newPreset in
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
        SettingsSectionCard(title: "Khung ngắm & Báo nét", icon: "viewfinder") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Cân bằng đường chân trời",
                    subtitle: "Hiển thị thước đo góc nghiêng gyro hỗ trợ giữ thẳng khung hình",
                    icon: "gyroscope",
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
                    isOn: $viewModel.showDetectionBoxes
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Thanh thông số & Biểu đồ HUD",
                    subtitle: "Hiển thị Shutter, ISO, Định dạng và Histogram trên màn hình chính",
                    icon: "chart.bar.fill",
                    isOn: $viewModel.showHistogramInViewfinder
                )

                if viewModel.showHistogramInViewfinder {
                    Divider().background(Color.white.opacity(0.06))

                    SettingsToggleRow(
                        title: "Mở rộng 32 cột màu báo cháy sáng",
                        subtitle: "Hiển thị dải quang phổ RGB và cảnh báo clipping ở vùng sáng",
                        icon: "waveform.path.ecg",
                        isOn: $viewModel.isHistogramBarExpanded
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Thước đo âm thanh (Audio VU Meter)",
                    subtitle: "Hiển thị 2 thanh đo mức tín hiệu âm thanh trực tiếp trong khung ngắm",
                    icon: "waveform",
                    isOn: $viewModel.showAudioLevelMeter
                )
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

// MARK: - 2. AI Framing Settings Section (Obsidian Glass Camera)
struct AIFramingSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var geminiKeyInput: String
    @Binding var isKeyVisible: Bool
    @Binding var selectedModel: AIVisionModel
    @Binding var customModelInput: String
    @Binding var isTestingKey: Bool
    @Binding var testResult: String?
    @Binding var showDeleteKeyConfirmation: Bool
    @Binding var toastMessage: String?
    @State private var showDeleteFeedbackConfirmation = false
    @State private var feedbackRevision = 0
    @State private var feedbackExportURL: URL?

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        VStack(spacing: 16) {
            compositionRulesCard
            compositionFeedbackCard
            aiCloudCard
        }
    }

    private var compositionFeedbackCard: some View {
        SettingsSectionCard(title: "Học thói quen bố cục", icon: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI ghi nhớ kiểu khung bạn chọn để điều chỉnh nhẹ các gợi ý sau. File chỉ chứa ý đồ bố cục, vị trí và kích thước tương đối; không chứa ảnh, GPS hoặc đặc trưng khuôn mặt.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.72))
                if let url = feedbackExportURL {
                    ShareLink(item: url) {
                        Label("Xuất dữ liệu lựa chọn", systemImage: "square.and.arrow.up")
                    }
                    .id(feedbackRevision)
                }
                Button(role: .destructive) {
                    showDeleteFeedbackConfirmation = true
                } label: {
                    Label("Xóa dữ liệu học bố cục", systemImage: "trash")
                }
            }
            .foregroundColor(.white)
            .confirmationDialog("Xóa toàn bộ lựa chọn đã lưu?",
                                isPresented: $showDeleteFeedbackConfirmation) {
                Button("Xóa dữ liệu", role: .destructive) {
                    Task {
                        let deleted = await CompositionPreferenceStore.shared.deleteAll()
                        feedbackExportURL = await CompositionPreferenceStore.shared.exportURL()
                        feedbackRevision += 1
                        toastMessage = deleted ? "Đã xóa dữ liệu học bố cục." : "Không xóa được file dữ liệu."
                    }
                }
            }
            .task { feedbackExportURL = await CompositionPreferenceStore.shared.exportURL() }
        }
    }

    @ViewBuilder
    private var compositionRulesCard: some View {
        SettingsSectionCard(title: "AI Bố cục", icon: "viewfinder") {
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
                    title: "Bật AI Bố cục",
                    subtitle: "Tự động kích hoạt màn trập ngay khi hai tâm đạt độ khớp hoàn hảo",
                    icon: "sparkles",
                    isOn: $viewModel.isAutoCaptureOnAlignEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Tự động zoom theo chủ thể",
                    subtitle: "Tự điều chỉnh độ phóng đại camera để đạt tỷ lệ bố cục chuẩn nhất",
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    isOn: $viewModel.isAutoZoomEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Hiển thị tia hướng dẫn",
                    subtitle: "Vẽ đường định hướng nối từ tâm camera tới vị trí vàng đề xuất",
                    icon: "line.diagonal",
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
        SettingsSectionCard(title: "OpenRouter API Key", icon: "key.fill") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Dùng OpenRouter Cloud",
                    subtitle: "Tắt để dùng AI cục bộ trên máy, hoàn toàn offline",
                    icon: "network",
                    isOn: $viewModel.useGeminiForAnalysis
                )

                Text("Chế độ miễn phí chỉ áp dụng model :free. Gemini 3.7 Flash và 3.1 Pro cần credits OpenRouter.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.62))

                if !viewModel.useGeminiForAnalysis {
                    Label("AI trên máy đang hoạt động, không cần cloud", systemImage: "iphone")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                }

                if let cloudError = viewModel.geminiError {
                    Text(cloudError)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().background(Color.white.opacity(0.06))

                // Masked API Key Display with Eye Toggle (Matching Mockup)
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14))
                        .foregroundColor(amberGold)

                    if viewModel.geminiService.hasAPIKey {
                        if isKeyVisible {
                            Text(viewModel.geminiService.apiKey)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("••••••••••••••••••••••••")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    } else {
                        Text("Chưa nhập API Key")
                            .font(.system(size: 13))
                            .foregroundColor(Color.white.opacity(0.40))
                    }

                    Spacer()

                    if viewModel.geminiService.hasAPIKey {
                        Button(action: {
                            isKeyVisible.toggle()
                        }) {
                            Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color.white.opacity(0.65))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive, action: {
                            showDeleteKeyConfirmation = true
                        }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.red.opacity(0.85))
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )

                // API Key Input Field (Hidden by default if key already present)
                if !viewModel.geminiService.hasAPIKey {
                    HStack(spacing: 8) {
                        SecureField("Dán OpenRouter sk-or-v1-...", text: $geminiKeyInput)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundColor(.white)
                            .tint(amberGold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        Button(action: {
                            let trimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            viewModel.geminiService.apiKey = trimmed
                            geminiKeyInput = ""
                            toastMessage = "Đã lưu an toàn API Key vào Keychain!"
                        }) {
                            Text("Lưu")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(amberGold)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.vertical, 2)
                }

                // Model Selection Row
                SettingsPickerRow(
                    title: "Mô hình thị giác",
                    subtitle: "Chọn model AI phân tích bố cục",
                    icon: "cpu",
                    selectedValueString: selectedModel.displayName
                ) {
                    Picker("", selection: $selectedModel) {
                        ForEach(AIVisionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(amberGold)
                    .onChangeCompatible(of: selectedModel) { newModel in
                        viewModel.geminiService.selectedModel = newModel
                    }
                }

                // Optional Custom OpenRouter Model ID Input
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Model OpenRouter tùy chỉnh (tùy chọn)", text: $customModelInput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )

                        Button("Lưu") {
                            viewModel.geminiService.customModelName = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            toastMessage = "Đã lưu model tùy chỉnh"
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(amberGold)
                    }

                    if !viewModel.geminiService.customModelName.isEmpty {
                        Text("Đang ưu tiên model tùy chỉnh: \(viewModel.geminiService.customModelName)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(amberGold.opacity(0.85))
                    }
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
                        Text(isTestingKey ? "Đang gửi yêu cầu kiểm tra..." : "Kiểm tra kết nối (tính 1 lượt API)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(amberGold)
                    .padding(.vertical, 4)
                }

                if let res = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: res.contains("thành công") ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(res.contains("thành công") ? .green : .red)
                        Text(res)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(res.contains("thành công") ? .green : .red)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.40))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

// MARK: - 3. Advanced Settings Section (Obsidian Glass Camera)
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showResetSessionConfirmation: Bool
    @Binding var showDevConsole: Bool
    @Binding var toastMessage: String?

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        VStack(spacing: 16) {
            featuresCard
            diagnosticsCard
            supportInfoCard
        }
    }

    @ViewBuilder
    private var featuresCard: some View {
        SettingsSectionCard(title: "Hệ thống", icon: "gearshape.fill") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Chế độ đi đường (Street Tracking)",
                    subtitle: "Tăng cường độ mượt và bù trừ rung lắc khi vừa đi bộ vừa chụp",
                    icon: "figure.walk",
                    isOn: $viewModel.isStreetTrackingModeEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Âm thanh & Rung khi căn đúng",
                    subtitle: "Phát nhịp rung Haptics thông minh khi tâm camera hút vào điểm vàng",
                    icon: "hand.tap.fill",
                    isOn: $viewModel.isProximityHapticsEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsToggleRow(
                    title: "Giữ màn hình luôn sáng",
                    subtitle: "Ngăn thiết bị tự động khóa màn hình trong suốt buổi chụp ảnh",
                    icon: "sun.max.fill",
                    isOn: $viewModel.isKeepScreenAwakeEnabled
                )

                Divider().background(Color.white.opacity(0.06))

                SettingsActionRow(
                    title: "Hiệu chuẩn con quay hồi chuyển 60Hz",
                    subtitle: viewModel.lastGyroCalibrationDate != nil
                        ? "Đã tối ưu hóa IMU (Bù lệch Roll: \(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°)"
                        : "Khử trôi (Zero-bias) và cân chỉnh 3 trục xoay cho tracking 6DoF",
                    icon: "gyroscope",
                    badgeText: viewModel.lastGyroCalibrationDate != nil ? "\(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°" : "Chưa cân"
                ) {
                    viewModel.isShowingGyroCalibration = true
                }

                Divider().background(Color.white.opacity(0.06))

                SettingsActionRow(
                    title: "Đặt lại cài đặt phiên căn góc",
                    subtitle: "Hủy khóa chủ thể và đưa camera về trạng thái ngắm tự do",
                    icon: "arrow.counterclockwise.circle.fill"
                ) {
                    showResetSessionConfirmation = true
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsCard: some View {
        SettingsSectionCard(title: "Chẩn đoán Engine", icon: "cross.case.fill") {
            VStack(alignment: .leading, spacing: 12) {
                diagRow(label: "Động cơ thị giác", value: "Apple Vision + Optical Flow + Gyro")
                diagRow(label: "AI Neural Engine", value: "AlignAI 114MB + CoreML YOLOv26")
                diagRow(label: "Model hoạt động", value: viewModel.activeModelUsedName.isEmpty ? "Cục bộ on-device (Neural Engine)" : viewModel.activeModelUsedName)
                diagRow(label: "Độ trễ phân tích", value: viewModel.geminiLatencyMs > 0 ? "\(viewModel.geminiLatencyMs) ms" : "0 ms (Realtime 60fps)")

                Divider().background(Color.white.opacity(0.06))

                DisclosureGroup("Nhật ký kỹ thuật & Chẩn đoán lỗi", isExpanded: $showDevConsole) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let crashReport = CameraLogger.readRecentCrashReport() {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Báo cáo sự cố gần nhất (Crash Report):")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.red)
                                Text(crashReport)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.9))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.red.opacity(0.15))
                                    .cornerRadius(6)
                            }
                        }

                        if let err = viewModel.geminiError {
                            Text("Lỗi AI ghi nhận: \(err)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nhật ký hệ thống gần nhất:")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(amberGold)
                            ScrollView(.vertical) {
                                Text(CameraLogger.readRecentLogText(maxChars: 3000))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.75))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                            .padding(8)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(6)
                        }

                        HStack(spacing: 8) {
                            Button(action: {
                                var fullText = ""
                                if let crash = CameraLogger.readRecentCrashReport() {
                                    fullText += crash + "\n\n"
                                }
                                fullText += CameraLogger.readRecentLogText(maxChars: 5000)
                                UIPasteboard.general.string = fullText
                                toastMessage = "Đã sao chép toàn bộ nhật ký vào bộ nhớ tạm"
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                    Text("Sao chép nhật ký")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(6)
                            }

                            Button(action: {
                                CameraLogger.clearAllLogs()
                                toastMessage = "Đã xóa sạch nhật ký"
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text("Xóa nhật ký")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red.opacity(0.85))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.12))
                                .cornerRadius(6)
                            }
                        }

                        Text("Ghi chú: Bạn có thể vào ứng dụng Tệp (Files) > Trên iPhone > AlignAI Studio để xem trực tiếp tệp alignai_crash_log.txt và alignai_debug_log.txt.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.top, 2)
                    }
                    .padding(.vertical, 6)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private var supportInfoCard: some View {
        SettingsSectionCard(title: "Hỗ trợ & Thông tin", icon: "info.circle.fill") {
            VStack(spacing: 0) {
                NavigationLink(destination: FeedbackView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("envelope.fill", color: amberGold)

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

                        Text("Ủng hộ tác giả")
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
                    diagRow(label: "Tác giả", value: "SmartVN (Trần Văn Trình)")
                    diagRow(label: "Liên hệ", value: "tranvantrinhhd@gmail.com")
                    diagRow(label: "Phiên bản", value: "AI Smart Framing Camera v1.0.0 (Build 300)")
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

// MARK: - Dedicated Support Developer View (Ủng Hộ Tác Giả)
public struct SupportDeveloperView: View {
    @State private var toastMessage: String? = nil
    @State private var showVietQR: Bool = false
    @State private var qrReloadID = UUID()

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)
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

                    Text("Nếu bạn yêu thích AI Smart Framing Camera và thấy ứng dụng hỗ trợ đắc lực trong nhiếp ảnh, bạn có thể mời tác giả một ly cà phê để tiếp thêm năng lượng phát triển.")
                        .font(.system(size: 13))
                        .foregroundColor(Color.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 6)

                // MB Bank Card
                SettingsSectionCard(title: "NGÂN HÀNG QUÂN ĐỘI (MB BANK)", icon: "building.columns.fill") {
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
        .background(Color(red: 0.031, green: 0.035, blue: 0.047).ignoresSafeArea())
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

// MARK: - Reusable UI Components (Obsidian Glass Camera Style)

// 1. SettingsSectionCard
public struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Card Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(amberGold)

                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Card Body
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.075, green: 0.082, blue: 0.102)) // #13151A
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// 2. SettingsToggleRow
public struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    @Binding var isOn: Bool

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon, color: amberGold)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(amberGold)
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// 3. SettingsPickerRow
public struct SettingsPickerRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var selectedValueString: String = ""
    let picker: Content

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        selectedValueString: String = "",
        @ViewBuilder picker: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.selectedValueString = selectedValueString
        self.picker = picker()
    }

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon, color: amberGold)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
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
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// 4. SettingsActionRow
public struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var badgeText: String? = nil
    let action: () -> Void

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(
        title: String,
        subtitle: String? = nil,
        icon: String,
        badgeText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.badgeText = badgeText
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsRowIcon(icon, color: amberGold)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(amberGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(amberGold.opacity(0.15))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
            }
            .frame(minHeight: 48)
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
