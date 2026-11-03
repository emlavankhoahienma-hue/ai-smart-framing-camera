import SwiftUI
import UIKit
import PhotosUI

// MARK: - Settings Tab Category
public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case capture = "Chụp"
    case ai = "AI Bố cục"
    case advanced = "Nâng cao"

    public var id: String { rawValue }

    public var shortTitle: String { rawValue }

    public var icon: String {
        switch self {
        case .capture: return "camera"
        case .ai: return "sparkles"
        case .advanced: return "gearshape"
        }
    }
}

// MARK: - Main Settings View (Leica & Obsidian Minimalist Studio)
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab = .capture
    @Namespace private var tabNamespace

    // Multi-Provider 2026 API & Model State
    @State private var geminiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var selectedModel: AIVisionModel = .freeVision
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    @State private var showDeleteKeyConfirmation: Bool = false

    // Unified Toast Message
    @State private var toastMessage: String? = nil

    private let hapticSelection = UISelectionFeedbackGenerator()
    private let hapticImpact = UIImpactFeedbackGenerator(style: .medium)

    // Design Tokens (Align Studio & Xiaomi 15 Ultra Leica)
    private let canvasBg = Color(red: 12/255, green: 12/255, blue: 14/255)   // #0C0C0E
    private let cardBg = Color(red: 24/255, green: 24/255, blue: 27/255)     // #18181B
    private let cardBorder = Color(red: 39/255, green: 39/255, blue: 42/255)  // #27272A
    private let accentCyan = Color(red: 56/255, green: 189/255, blue: 248/255) // #38BDF8

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Navigation Header
                    navigationHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    // 2. Segmented Tab Control (Chụp | AI Bố cục | Nâng cao)
                    tabSelectorPills
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    // 3. Scrollable Content for Selected Tab
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 14) {
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
                                    toastMessage: $toastMessage
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }

                // Toast Notification
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        ToastBanner(message: msg)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .allowsHitTesting(false)
                }
            }
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Xác nhận xóa API Key?",
                isPresented: $showDeleteKeyConfirmation,
                titleVisibility: .visible
            ) {
                Button("Xóa API Key", role: .destructive) {
                    viewModel.geminiService.apiKey = ""
                    geminiKeyInput = ""
                    showToast("Đã xóa API Key an toàn khỏi Keychain")
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("API Key của hãng \(viewModel.geminiService.selectedProvider.shortBadge) sẽ bị xóa khỏi Apple Keychain bảo mật.")
            }
            .onAppear {
                geminiKeyInput = viewModel.geminiService.apiKey
                selectedModel = viewModel.geminiService.selectedModel
            }
            .sheet(isPresented: $viewModel.isShowingGyroCalibration) {
                GyroCalibrationSheetView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Navigation Header (Left: "Cài đặt", Right: "Xong")
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Text("Cài đặt")
                .font(.system(size: 18, weight: .semibold, design: .default))
                .foregroundColor(.white)

            Spacer()

            Button("Xong") {
                hapticImpact.prepare()
                hapticImpact.impactOccurred()
                dismiss()
            }
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundColor(accentCyan)
            .accessibilityLabel("Đóng cài đặt")
        }
    }

    // MARK: - Segmented Tab Selector (Chụp | AI Bố cục | Nâng cao)
    private var tabSelectorPills: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSheetTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    hapticSelection.prepare()
                    hapticSelection.selectionChanged()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.shortTitle)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .lineLimit(1)
                        .foregroundColor(isSelected ? .white : Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(cardBorder)
                                    .matchedGeometryEffect(id: "active_settings_tab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBg)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(cardBorder, lineWidth: 1)
                }
        )
        .frame(height: 42)
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

// MARK: - Reusable Dedicated Row Icon (28x28 Flat Monochrome)
public struct SettingsRowIcon: View {
    let icon: String
    let isActive: Bool

    public init(_ icon: String, isActive: Bool = false) {
        self.icon = icon
        self.isActive = isActive
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(red: 36/255, green: 36/255, blue: 41/255))
                .frame(width: 28, height: 28)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isActive ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color(red: 228/255, green: 228/255, blue: 231/255))
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Reusable Settings Section Card (#18181B, bo góc 16px, viền 1px solid #27272A)
public struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))

                Text(title.uppercased())
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.85))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Card Body
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 24/255, green: 24/255, blue: 27/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
                )
        )
    }
}

// MARK: - Reusable Settings Toggle Row
public struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    @Binding var isOn: Bool

    public var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon, isActive: isOn)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// MARK: - ==========================================
// MARK: - TAB 1: CHỤP ẢNH & QUAY PHIM
// MARK: - ==========================================
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    private let presetDevices = ["ALIGN STUDIO", "XIAOMI 15 ULTRA", "LEICA M11-P", "IPHONE 16 PRO"]

    var body: some View {
        VStack(spacing: 14) {
            photoStillCard
            videoCaptureCard
            masterWatermarkCard
        }
    }

    // Nhóm 1: Ảnh tĩnh
    @ViewBuilder
    private var photoStillCard: some View {
        SettingsSectionCard(title: "Ảnh tĩnh", icon: "camera") {
            VStack(spacing: 0) {
                // Định dạng chụp (1 dòng: HEIF / JPEG / RAW)
                HStack(spacing: 12) {
                    SettingsRowIcon("photo")

                    Text("Định dạng chụp")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        pillSelectButton("HEIF", isSelected: viewModel.selectedPhotoFormat == .heif) {
                            viewModel.selectedPhotoFormat = .heif
                        }
                        pillSelectButton("JPEG", isSelected: viewModel.selectedPhotoFormat == .jpeg) {
                            viewModel.selectedPhotoFormat = .jpeg
                        }
                        pillSelectButton("RAW", isSelected: viewModel.selectedPhotoFormat == .dng) {
                            viewModel.selectedPhotoFormat = .dng
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(minHeight: 48)

                dividerLine

                // Độ phân giải 48MP
                SettingsToggleRow(
                    title: "Độ phân giải 48MP",
                    subtitle: "Khai thác tối đa điểm ảnh cảm biến",
                    icon: "sparkles.rectangle.stack",
                    isOn: $viewModel.isSuperResolutionRAWEnabled
                )

                dividerLine

                // Live Photo
                SettingsToggleRow(
                    title: "Live Photo",
                    icon: "livephoto",
                    isOn: $viewModel.isLivePhotoEnabled
                )

                dividerLine

                // Lưu kèm bản gốc
                SettingsToggleRow(
                    title: "Lưu kèm bản gốc",
                    subtitle: "Giữ ảnh gốc khi áp màu phim",
                    icon: "photo.on.rectangle.angled",
                    isOn: $viewModel.isSaveOriginalPhotoEnabled
                )
            }
        }
    }

    // Nhóm 2: Quay Video
    @ViewBuilder
    private var videoCaptureCard: some View {
        SettingsSectionCard(title: "Quay Video", icon: "video") {
            VStack(spacing: 0) {
                // Chất lượng Video (1 dòng duy nhất)
                HStack(spacing: 12) {
                    SettingsRowIcon("film")

                    Text("Chất lượng Video")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Menu {
                        ForEach(viewModel.supportedVideoFormatOptions) { opt in
                            Button(action: { viewModel.selectedVideoFormatOption = opt }) {
                                HStack {
                                    Text(videoFormatCleanTitle(opt))
                                    if viewModel.selectedVideoFormatOption == opt {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(videoFormatCleanTitle(viewModel.selectedVideoFormatOption))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
                                .lineLimit(1)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.40))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
                .padding(.vertical, 8)
                .frame(minHeight: 48)

                dividerLine

                // Chuẩn mã hóa (H.264 / HEVC)
                HStack(spacing: 12) {
                    SettingsRowIcon("gearshape")

                    Text("Chuẩn mã hóa")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        pillSelectButton("H.264", isSelected: viewModel.selectedVideoCodec == .h264) {
                            viewModel.selectedVideoCodec = .h264
                        }
                        pillSelectButton("HEVC", isSelected: viewModel.selectedVideoCodec == .hevc) {
                            viewModel.selectedVideoCodec = .hevc
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(minHeight: 48)
            }
        }
    }

    // Nhóm 3: Khung Chữ Ký Master (Leica Style Watermark)
    @ViewBuilder
    private var masterWatermarkCard: some View {
        SettingsSectionCard(title: "Khung Chữ Ký Master", icon: "viewfinder.circle") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Đóng khung Master",
                    subtitle: "Tự động thêm chữ ký Leica quang học vào ảnh",
                    icon: "viewfinder",
                    isOn: $viewModel.isMasterWatermarkEnabled
                )

                if viewModel.isMasterWatermarkEnabled {
                    dividerLine

                    // Tên thiết bị / Chữ ký
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TÊN THIẾT BỊ / CHỮ KÝ")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))

                        TextField("Nhập chữ ký...", text: $viewModel.masterWatermarkDeviceName)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                            .cornerRadius(8)
                            .foregroundColor(.white)

                        HStack(spacing: 6) {
                            ForEach(presetDevices, id: \.self) { name in
                                Button(action: {
                                    viewModel.masterWatermarkDeviceName = name
                                }) {
                                    Text(name)
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(viewModel.masterWatermarkDeviceName == name ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.20) : Color.white.opacity(0.06))
                                        .foregroundColor(viewModel.masterWatermarkDeviceName == name ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.70))
                                        .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    dividerLine

                    // Biểu tượng Logo
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BIỂU TƯỢNG LOGO")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))

                        HStack(spacing: 6) {
                            logoOptionButton("Logo App", style: .alignStudio, icon: "viewfinder")
                            logoOptionButton("Apple", style: .appleIcon, icon: "apple.logo")
                            logoOptionButton("Ống kính", style: .aperturePro, icon: "camera.aperture")
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                HStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(viewModel.masterWatermarkCustomLogoImage != nil ? "Đã chọn" : "Tự chọn")
                                        .font(.system(size: 11, weight: viewModel.masterWatermarkLogoStyle == .customImage ? .bold : .medium, design: .rounded))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(viewModel.masterWatermarkLogoStyle == .customImage ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18) : Color.white.opacity(0.06))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.masterWatermarkLogoStyle == .customImage ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.60) : Color.clear, lineWidth: 1)
                                )
                                .foregroundColor(viewModel.masterWatermarkLogoStyle == .customImage ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.70))
                            }
                            .onChangeCompatible(of: selectedPhotoItem) { item in
                                guard let item else { return }
                                Task {
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let img = UIImage(data: data) {
                                        viewModel.setMasterWatermarkCustomLogo(img)
                                    }
                                }
                            }
                            logoOptionButton("Ẩn", style: .none, icon: "slash.circle")
                        }
                    }
                    .padding(.vertical, 8)

                    dividerLine

                    // Tông màu khung
                    HStack(spacing: 12) {
                        SettingsRowIcon("circle.lefthalf.filled")

                        Text("Tông màu khung")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        HStack(spacing: 4) {
                            pillSelectButton("Trắng Gallery", isSelected: viewModel.masterWatermarkTheme == .white) {
                                viewModel.masterWatermarkTheme = .white
                            }
                            pillSelectButton("Đen Studio", isSelected: viewModel.masterWatermarkTheme == .black) {
                                viewModel.masterWatermarkTheme = .black
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(minHeight: 48)
                }
            }
        }
    }

    private var dividerLine: some View {
        Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))
    }

    private func pillSelectButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.60))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.60) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func logoOptionButton(_ title: String, style: WatermarkLogoStyle, icon: String) -> some View {
        let isSelected = viewModel.masterWatermarkLogoStyle == style
        return Button(action: {
            viewModel.masterWatermarkLogoStyle = style
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.60) : Color.clear, lineWidth: 1)
            )
            .foregroundColor(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.70))
        }
        .buttonStyle(.plain)
    }

    private func videoFormatCleanTitle(_ opt: VideoFormatOption) -> String {
        switch opt {
        case .uhd60: return "4K · 60 fps"
        case .uhd30: return "4K · 30 fps"
        case .hd60:  return "1080p · 60 fps"
        case .hd30:  return "1080p · 30 fps"
        }
    }
}

// MARK: - ==========================================
// MARK: - TAB 2: AI BỐ CỤC
// MARK: - ==========================================
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
            aiEngineCloudCard
            aiAutoBehaviorCard
        }
    }

    // Nhóm 1: Động cơ AI & Kết nối Cloud
    @ViewBuilder
    private var aiEngineCloudCard: some View {
        SettingsSectionCard(title: "Động cơ AI & Kết nối Cloud", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                // Trạng thái kết nối
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.geminiService.hasAPIKey ? Color.green : Color(red: 56/255, green: 189/255, blue: 248/255))
                        .frame(width: 8, height: 8)

                    Text(viewModel.geminiService.hasAPIKey
                         ? "Ưu tiên: AI Cloud (\(viewModel.geminiService.selectedProvider.shortBadge))"
                         : "Đang dùng: AI Local (Apple Neural Engine)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }

                Text("Khi có API Key và kết nối mạng, ứng dụng ưu tiên dùng AI Cloud để phân tích bố cục; khi không có mạng hoặc chưa nhập Key, ứng dụng tự động dùng AI Local (ANE) trên máy.")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Thanh chọn Hãng AI (Provider)
                VStack(alignment: .leading, spacing: 6) {
                    Text("HÃNG AI (PROVIDER)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.45))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach([AICloudProvider.googleGemini, .openRouter, .groq, .openAI, .anthropic, .custom], id: \.self) { prov in
                                let isSelected = viewModel.geminiService.selectedProvider == prov
                                Button(action: {
                                    viewModel.geminiService.selectedProvider = prov
                                    geminiKeyInput = viewModel.geminiService.apiKey
                                    testResult = nil
                                }) {
                                    Text(prov.shortBadge)
                                        .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                                        .foregroundColor(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.60))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18) : Color.white.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.60) : Color.clear, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Duy nhất 1 ô dán API Key cho hãng đang chọn
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API KEY (\(viewModel.geminiService.selectedProvider.shortBadge.uppercased()))")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            Button("Xóa Key") {
                                showDeleteKeyConfirmation = true
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red.opacity(0.85))
                        }
                    }

                    HStack(spacing: 8) {
                        Group {
                            if isKeyVisible {
                                TextField("Dán API Key tại đây...", text: $geminiKeyInput)
                            } else {
                                SecureField("Dán API Key tại đây...", text: $geminiKeyInput)
                            }
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                        .cornerRadius(8)

                        Button(action: { isKeyVisible.toggle() }) {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(Color.white.opacity(0.6))
                                .frame(width: 32, height: 32)
                                .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        Button(action: {
                            let clean = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            viewModel.geminiService.apiKey = clean
                            toastMessage = "Đã lưu API Key an toàn vào Apple Keychain"
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                Text("Lưu Key")
                            }
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(red: 56/255, green: 189/255, blue: 248/255))
                            .cornerRadius(7)
                        }

                        Button(action: {
                            let clean = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !clean.isEmpty else {
                                testResult = "⚠️ Hãy dán API Key trước khi kiểm tra"
                                return
                            }
                            isTestingKey = true
                            testResult = nil
                            viewModel.geminiService.apiKey = clean
                            let modelToTest = viewModel.geminiService.selectedModel
                            viewModel.geminiService.testAPIKeyConnection(key: clean, model: modelToTest) { success, msg in
                                DispatchQueue.main.async {
                                    isTestingKey = false
                                    testResult = msg
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if isTestingKey {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Kiểm tra")
                            }
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(7)
                        }

                        Spacer()
                    }

                    if let res = testResult {
                        Text(res)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(res.contains("thành công") ? Color.green : Color.orange)
                            .padding(.top, 2)
                    }
                }

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Thanh chọn Model 2026
                HStack(spacing: 12) {
                    SettingsRowIcon("cpu")

                    Text("Model AI 2026")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    let availableModels = AIVisionModel.models(for: viewModel.geminiService.selectedProvider)
                    Menu {
                        ForEach(availableModels) { m in
                            Button(action: {
                                viewModel.geminiService.selectedModel = m
                                selectedModel = m
                            }) {
                                HStack {
                                    Text(m.displayName)
                                    if viewModel.geminiService.selectedModel == m {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(viewModel.geminiService.selectedModel.displayName.components(separatedBy: " (").first ?? viewModel.geminiService.selectedModel.rawValue)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
                                .lineLimit(1)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.40))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // Nhóm 2: Hành vi Tự động
    @ViewBuilder
    private var aiAutoBehaviorCard: some View {
        SettingsSectionCard(title: "Hành vi Tự động", icon: "wand.and.stars") {
            VStack(spacing: 0) {
                // Tự động chụp khi khớp tâm
                SettingsToggleRow(
                    title: "Tự động chụp khi khớp tâm (Auto-Capture 300ms)",
                    subtitle: "Kích hoạt màn trập khi căn đúng điểm vàng",
                    icon: "target",
                    isOn: $viewModel.isAutoCaptureOnAlignEnabled
                )

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Tự động chuyển mức Zoom thông minh
                SettingsToggleRow(
                    title: "Tự động chuyển mức Zoom thông minh",
                    subtitle: "Điều chỉnh độ phóng đại tối ưu theo chủ thể",
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    isOn: $viewModel.isAutoZoomEnabled
                )

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Tự động gợi ý Màu phim & Độ sáng
                SettingsToggleRow(
                    title: "Tự động gợi ý Màu phim & Độ sáng",
                    subtitle: "Nhận diện ngữ cảnh để cân chỉnh màu sắc và bù sáng",
                    icon: "paintpalette",
                    isOn: $viewModel.isAIFullColorEnabled
                )
            }
        }
    }
}

// MARK: - ==========================================
// MARK: - TAB 3: NÂNG CAO
// MARK: - ==========================================
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var toastMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            viewfinderAssistCard
            appInfoCard
        }
    }

    // Nhóm 1: Công cụ Kính ngắm (Viewfinder Assist)
    @ViewBuilder
    private var viewfinderAssistCard: some View {
        SettingsSectionCard(title: "Công cụ Kính ngắm", icon: "viewfinder") {
            VStack(spacing: 0) {
                // Focus Peaking (Viền Laser báo nét)
                SettingsToggleRow(
                    title: "Focus Peaking (Viền Laser báo nét)",
                    subtitle: "Tô viền laser sáng rực tại các cạnh đang lấy nét",
                    icon: "scope",
                    isOn: $viewModel.isFocusPeakingEnabled
                )

                if viewModel.isFocusPeakingEnabled {
                    Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                    HStack {
                        Text("MÀU TIA LASER")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))

                        Spacer()

                        HStack(spacing: 12) {
                            ForEach(FocusPeakingColor.allCases) { color in
                                let isSelected = viewModel.focusPeakingColor == color
                                Button(action: {
                                    viewModel.focusPeakingColor = color
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(color.swiftUIColor)
                                            .frame(width: 22, height: 22)

                                        if isSelected {
                                            Circle()
                                                .stroke(Color.white, lineWidth: 2)
                                                .frame(width: 26, height: 26)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Khóa đường chân trời 360° (Horizon Lock)
                SettingsToggleRow(
                    title: "Khóa đường chân trời 360° (Horizon Lock)",
                    subtitle: "Tự động giữ thẳng đường chân trời dù xoay máy",
                    icon: "gyroscope",
                    isOn: $viewModel.isHorizonLockEnabled
                )

                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))

                // Biểu đồ quang phổ RGB (Histogram)
                SettingsToggleRow(
                    title: "Biểu đồ quang phổ RGB (Histogram)",
                    subtitle: "Theo dõi phân bổ độ sáng và màu sắc thời gian thực",
                    icon: "chart.bar.xaxis",
                    isOn: $viewModel.showHistogramInViewfinder
                )
            }
        }
    }

    // Nhóm 2: Thông tin Ứng dụng (Flat minimalist card)
    @ViewBuilder
    private var appInfoCard: some View {
        SettingsSectionCard(title: "Thông tin ứng dụng", icon: "info.circle") {
            VStack(spacing: 10) {
                appInfoRow(label: "Ứng dụng", value: "Align Studio")
                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))
                appInfoRow(label: "Phiên bản", value: "Free")
                Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))
                appInfoRow(label: "Tác giả", value: "ace4youblade (VanKhoa)")
            }
            .padding(.vertical, 4)
        }
    }

    private func appInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.60))

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(minHeight: 28)
    }
}
