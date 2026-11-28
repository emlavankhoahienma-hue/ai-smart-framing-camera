//
//  SettingsSheetView.swift
//  AISmartFramingCamera
//
//  Created by AlignAI Studio on 2026-11-04.
//  Leica Studio Obsidian Glass Edition - Unified 3-Tab Settings Architecture
//  100% Feature-Complete Restoration of Optical Telemetry, Gyro Calibrations,
//  Multi-Provider Cloud AI Engine, Film Presets, System Diagnostics & Author Support.
//

import SwiftUI
import UIKit
import PhotosUI

// MARK: - Settings Tab Category
public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case capture = "Chụp"
    case ai = "Bố cục"
    case advanced = "Nâng cao"

    public var id: String { rawValue }

    public var shortTitle: String { rawValue }

    public var icon: String {
        switch self {
        case .capture: return "camera"
        case .ai: return "viewfinder"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

// MARK: - Main Settings View (Monochrome Carbon & Smoked Glass Edition)
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab
    @Namespace private var tabNamespace

    // Multi-Provider 2026 API & Model State
    @State private var geminiKeyInput: String = ""
    @State private var isKeyVisible: Bool = false
    @State private var selectedModel: AIVisionModel = .freeVision
    @State private var customModelInput: String = ""
    @State private var customEndpointInput: String = ""
    @State private var profileLabelInput: String = ""
    @State private var modelSearchFilter: String = ""
    @State private var isTestingKey: Bool = false
    @State private var testResult: String? = nil
    @State private var showDeleteKeyConfirmation: Bool = false

    // Diagnostics & Reset
    @State private var showResetSessionConfirmation: Bool = false

    // Unified Toast Notification
    @State private var toastMessage: String? = nil

    private let hapticSelection = UISelectionFeedbackGenerator()
    private let hapticImpact = UIImpactFeedbackGenerator(style: .medium)

    // Unified Monochrome + Warm Titanium Tokens
    private let canvasBackground = AlignTheme.studioCanvas
    private let cardBackground = AlignTheme.studioSurface
    private let cardBorder = AlignTheme.studioHairline
    private let accentTone = AlignTheme.studioAccent

    public init(viewModel: CameraViewModel, initialTab: SettingsSheetTab = .capture) {
        self.viewModel = viewModel
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                canvasBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 1. Navigation Header ("Cài đặt" on Left, "Xong" on Right)
                    navigationHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                    // 2. Leica Studio Segmented Tab Bar (Chụp • AI Bố cục • Nâng cao)
                    tabSelectorPills
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)

                    // 3. Scrollable Settings Content
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            switch selectedTab {
                            case .capture:
                                PhotoCaptureSettingsSection(
                                    viewModel: viewModel,
                                    toastMessage: $toastMessage
                                )
                                .transition(.opacity.combined(with: .offset(y: 8)))

                            case .ai:
                                AIFramingSettingsSection(
                                    viewModel: viewModel,
                                    geminiKeyInput: $geminiKeyInput,
                                    isKeyVisible: $isKeyVisible,
                                    selectedModel: $selectedModel,
                                    customModelInput: $customModelInput,
                                    customEndpointInput: $customEndpointInput,
                                    profileLabelInput: $profileLabelInput,
                                    modelSearchFilter: $modelSearchFilter,
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
                                    toastMessage: $toastMessage
                                )
                                .transition(.opacity.combined(with: .offset(y: 8)))
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
                    .allowsHitTesting(false)
                }
            }
            .onChangeCompatible(of: toastMessage) { newMsg in
                guard let newMsg = newMsg, !newMsg.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if toastMessage == newMsg {
                            toastMessage = nil
                        }
                    }
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
                geminiKeyInput = viewModel.geminiService.apiKey
                selectedModel = viewModel.geminiService.selectedModel
                customModelInput = viewModel.geminiService.customModelName
                customEndpointInput = viewModel.geminiService.customEndpointURL
                if viewModel.geminiService.hasAPIKey && viewModel.geminiService.discoveredModels.isEmpty {
                    Task {
                        await viewModel.geminiService.fetchAvailableModels()
                    }
                }
            }
        }
    }

    // MARK: - Navigation Header ("Cài đặt" on Left, Quiet Glass "Xong" Pill on Right)
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Text("Cài đặt")
                .font(.system(size: 21, weight: .semibold, design: .default))
                .foregroundColor(AlignTheme.studioInkPrimary)

            Spacer()

            Button(action: {
                hapticImpact.prepare()
                hapticImpact.impactOccurred()
                dismiss()
            }) {
                Text("Xong")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6.5)
                    .background(
                        Capsule()
                            .fill(AlignTheme.studioElevated)
                            .overlay(
                                Capsule()
                                    .stroke(AlignTheme.studioHairline, lineWidth: 0.65)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng cài đặt")
        }
    }

    // MARK: - Segmented Tab Selector (Chụp · Bố cục · Nâng cao)
    private var tabSelectorPills: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSheetTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    hapticSelection.prepare()
                    hapticSelection.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? accentTone : AlignTheme.studioInkSecondary)

                        Text(tab.shortTitle)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.11))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                                )
                                .matchedGeometryEffect(id: "active_studio_tab", in: tabNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(cardBorder, lineWidth: 0.65)
                }
        )
        .frame(height: 44)
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
            toastMessage = msg
        }
    }
}

// MARK: - Dedicated Row Icon Component (Quiet Monochrome Squircle 28x28)
public struct SettingsRowIcon: View {
    let icon: String
    let isActive: Bool

    public init(_ icon: String, isActive: Bool = false) {
        self.icon = icon
        self.isActive = isActive
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                .frame(width: 28, height: 28)

            Image(systemName: icon)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(isActive ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.78))
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Card Surface Component (16px CornerRadius, 0.65pt Hairline Border)
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
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(AlignTheme.studioInkSecondary)

                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(AlignTheme.studioInkSecondary)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AlignTheme.studioSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AlignTheme.studioHairline, lineWidth: 0.65)
                )
        )
    }
}

// MARK: - Settings Toggle Row
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
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .fixedSize()
                .tint(AlignTheme.studioAccent)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Picker Row
public struct SettingsPickerRow<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var selectedValueString: String = ""
    let picker: Content

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
            SettingsRowIcon(icon, isActive: !selectedValueString.isEmpty)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .lineLimit(1)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            picker
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Action Row
public struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var badgeText: String? = nil
    let action: () -> Void

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
                SettingsRowIcon(icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        .lineLimit(1)

                    if let sub = subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.48))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(AlignTheme.studioAccentSoft)
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
            }
            .padding(.vertical, 6)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Focus Peaking Color Circle Button
struct PeakingColorCircleButton: View {
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
                    .stroke(isPicked ? Color.white : Color.clear, lineWidth: 1.8)
                    .padding(-2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composition Rule Card Component
struct CompositionRuleCard: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void

    private var compactTitle: String {
        switch rule {
        case .diagonal: return "Đường chéo / Tam giác"
        default: return rule.displayNameVietnamese
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkTertiary)
                    .frame(width: 18)

                Text(compactTitle)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 2)

                if isSelected {
                    Circle()
                        .fill(AlignTheme.studioAccent)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(AlignTheme.studioAccentSoft) : AnyShapeStyle(AlignTheme.studioElevated))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 0.9 : 0.65)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tracking Sensitivity Pill Component
struct SensitivityPill: View {
    let preset: TrackingSensitivityPreset
    let isPicked: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(preset.shortName)
                .font(.system(size: 12.5, weight: isPicked ? .semibold : .medium, design: .rounded))
                .foregroundColor(isPicked ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Capsule()
                        .fill(isPicked ? AnyShapeStyle(AlignTheme.studioAccentSoft) : AnyShapeStyle(Color.white.opacity(0.055)))
                )
                .overlay(
                    Capsule()
                        .stroke(isPicked ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SECTION 1: PHOTO & VIDEO DEEP SETTINGS (TAB 1)
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var toastMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    private let presetDevices = ["ALIGN STUDIO", "XIAOMI 15 ULTRA", "LEICA M11-P", "IPHONE 16 PRO"]

    var body: some View {
        VStack(spacing: 16) {
            photoStillCard
            viewfinderHUDCard
            masterWatermarkCard
        }
    }

    // Card 1: Ảnh tĩnh & Cấu hình sâu Ultra Sharp (Định dạng ảnh, bật/tắt Ultra Sharp, Chất lượng & Mã hóa Video nằm ở Bảng 6 chấm)
    private var photoStillCard: some View {
        SettingsSectionCard(title: "Ảnh & Độ nét Ultra Sharp", icon: "camera.fill") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Lưu kèm bản gốc",
                    subtitle: "Giữ ảnh nguyên bản cảm biến khi áp màu AI hoặc bộ lọc phim",
                    icon: "photo.on.rectangle.angled",
                    isOn: $viewModel.isSaveOriginalPhotoEnabled
                )

                dividerLine

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Số khung hình gộp Ultra Sharp")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                        Spacer()
                        Text("\(viewModel.ultraSharpBurstCount) frames")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                    }

                    Text("Áp dụng khi bật Ultra Sharp trong Bảng điều khiển (6 chấm)")
                        .font(.system(size: 11))
                        .foregroundColor(AlignTheme.studioInkSecondary)

                    HStack(spacing: 6) {
                        ForEach([5, 6, 8, 10, 12], id: \.self) { count in
                            pillSelectButton("\(count)", isSelected: viewModel.ultraSharpBurstCount == count) {
                                UISelectionFeedbackGenerator().selectionChanged()
                                viewModel.ultraSharpBurstCount = count
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 10)
            }
        }
    }

    // Card 2: Khung ngắm, Báo nét & Kiểm màu (Bật/tắt Biểu đồ nằm ở Bảng 6 chấm)
    private var viewfinderHUDCard: some View {
        let peakingAvail = viewModel.featureAvailability(.focusPeaking)
        return SettingsSectionCard(title: "Khung ngắm & Hỗ trợ", icon: "viewfinder") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Focus peaking (Báo nét)",
                    subtitle: peakingAvail.isAvailable
                        ? "Tô sáng viền tương phản của các điểm đang nằm trong vùng nét"
                        : (peakingAvail.detailReason ?? "Không khả dụng ở chế độ hiện tại"),
                    icon: "scope",
                    isOn: $viewModel.isFocusPeakingEnabled
                )
                .disabled(!peakingAvail.isAvailable)
                .opacity(peakingAvail.isAvailable ? 1.0 : 0.45)

                if viewModel.isFocusPeakingEnabled && peakingAvail.isAvailable {
                    peakingColorPickerRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                dividerLine

                SettingsToggleRow(
                    title: "Khung nhận diện chủ thể",
                    subtitle: "Hiện bounding box xung quanh người, khuôn mặt hoặc đồ vật",
                    icon: "viewfinder.rectangular",
                    isOn: $viewModel.showDetectionBoxes
                )

                dividerLine

                SettingsToggleRow(
                    title: "Biểu đồ Pro RGB",
                    subtitle: "Mở hộp quang phổ RGB + Luma chi tiết kèm chỉ số SH / AVG / HI và EV",
                    icon: "waveform.path.ecg",
                    isOn: $viewModel.isHistogramBarExpanded
                )

                dividerLine

                SettingsToggleRow(
                    title: "Quét mã QR thông minh",
                    subtitle: "Tự nhận diện mọi mã QR, VietQR, Wi-Fi (kể cả mã nhỏ, thiếu sáng hoặc đảo màu)",
                    icon: "qrcode.viewfinder",
                    isOn: $viewModel.isQRScannerEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Thước đo âm thanh (VU)",
                    subtitle: "Hiển thị thanh đo mức tín hiệu stereo kèm biểu tượng mic khi quay video",
                    icon: "waveform",
                    isOn: $viewModel.showAudioLevelMeter
                )
            }
        }
    }

    // Card 3: Tùy biến Khung Chữ Ký Master (Bật/tắt nhanh nằm ở nút Master trong Bảng 6 chấm)
    private var masterWatermarkCard: some View {
        let hasCustomLogo = viewModel.masterWatermarkCustomLogoImage != nil
        let isCustomStyle = viewModel.masterWatermarkLogoStyle == .customImage

        return SettingsSectionCard(title: "Tùy biến Khung Master (Ảnh & Video)", icon: "seal") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(AlignTheme.studioAccent)
                    Text("Bật hoặc tắt nhanh Khung Master tại nút Master trong Bảng điều khiển (6 chấm).")
                        .font(.system(size: 11.5))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)

                dividerLine

                SettingsToggleRow(
                    title: "Khung Master cho Video",
                    subtitle: "Ghép khung dưới đáy giữ nguyên độ phân giải, FPS và âm thanh gốc",
                    icon: "video.badge.checkmark",
                    isOn: $viewModel.isVideoMasterFrameEnabled
                )

                dividerLine

                // Tên thiết bị / Chữ ký
                VStack(alignment: .leading, spacing: 8) {
                    Text("TÊN THIẾT BỊ / CHỮ KÝ")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkTertiary)

                    TextField("Nhập chữ ký...", text: $viewModel.masterWatermarkDeviceName)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AlignTheme.studioElevated)
                        .cornerRadius(8)
                        .foregroundColor(AlignTheme.studioInkPrimary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(presetDevices, id: \.self) { name in
                                Button(action: {
                                    viewModel.masterWatermarkDeviceName = name
                                }) {
                                    Text(name)
                                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(viewModel.masterWatermarkDeviceName == name ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                                        .foregroundColor(viewModel.masterWatermarkDeviceName == name ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // Biểu tượng Logo
                VStack(alignment: .leading, spacing: 8) {
                    Text("BIỂU TƯỢNG LOGO")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkTertiary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            logoOptionButton("Logo App", style: .alignStudio, icon: "viewfinder")
                            logoOptionButton("Apple", style: .appleIcon, icon: "apple.logo")
                            logoOptionButton("Ống kính", style: .aperturePro, icon: "camera.aperture")
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                HStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(hasCustomLogo ? "Đã chọn" : "Tự chọn")
                                        .font(.system(size: 11, weight: isCustomStyle ? .bold : .medium, design: .rounded))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(isCustomStyle ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                                )
                                .foregroundColor(isCustomStyle ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                            }
                            .onChangeCompatible(of: selectedPhotoItem) { item in
                                guard let item else { return }
                                Task { @MainActor in
                                    if let data = try? await item.loadTransferable(type: Data.self),
                                       let img = UIImage(data: data) {
                                        viewModel.setMasterWatermarkCustomLogo(img)
                                    }
                                }
                            }
                            logoOptionButton("Ẩn", style: .none, icon: "slash.circle")
                        }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // Giao diện Khung
                VStack(alignment: .leading, spacing: 8) {
                    Text("GIAO DIỆN KHUNG")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkTertiary)

                    HStack(spacing: 8) {
                        Button(action: {
                            viewModel.masterWatermarkTheme = .white
                        }) {
                            HStack(spacing: 6) {
                                Circle().fill(Color.white).frame(width: 12, height: 12)
                                Text("Trắng Leica")
                                    .font(.system(size: 12, weight: viewModel.masterWatermarkTheme == .white ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(viewModel.masterWatermarkTheme == .white ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                            .foregroundColor(viewModel.masterWatermarkTheme == .white ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(viewModel.masterWatermarkTheme == .white ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                            )
                            .cornerRadius(9)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            viewModel.masterWatermarkTheme = .black
                        }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(white: 0.14))
                                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.6))
                                    .frame(width: 12, height: 12)
                                Text("Đen Studio")
                                    .font(.system(size: 12, weight: viewModel.masterWatermarkTheme == .black ? .semibold : .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(viewModel.masterWatermarkTheme == .black ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                            .foregroundColor(viewModel.masterWatermarkTheme == .black ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(viewModel.masterWatermarkTheme == .black ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                            )
                            .cornerRadius(9)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    // Helper: Peaking color picker row
    @ViewBuilder
    private var peakingColorPickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Màu viền báo nét:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AlignTheme.studioInkSecondary)
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

            // Độ nhạy báo nét (Thuần Metal Compute Adaptive Threshold)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Độ nhạy báo nét:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                    Spacer()
                    Text("\(Int(viewModel.focusPeakingSensitivity * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.focusPeakingColor.swiftUIColor)
                }
                Slider(value: $viewModel.focusPeakingSensitivity, in: 0.1...1.0, step: 0.05)
                    .tint(viewModel.focusPeakingColor.swiftUIColor)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    // Helper: Divider line
    private var dividerLine: some View {
        Divider()
            .background(AlignTheme.studioHairlineSubtle)
    }

    // Helper: Pill select button
    private func pillSelectButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 0.9 : 0.6)
                )
        }
        .buttonStyle(.plain)
    }

    // Helper: Logo option button
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
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
            )
            .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SECTION 2: AI FRAMING & CLOUD ENGINE (TAB 2 — Native iOS Clean Form)
struct AIFramingSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var geminiService = GeminiService.shared
    @Binding var geminiKeyInput: String
    @Binding var isKeyVisible: Bool
    @Binding var selectedModel: AIVisionModel
    @Binding var customModelInput: String
    @Binding var customEndpointInput: String
    @Binding var profileLabelInput: String
    @Binding var modelSearchFilter: String
    @Binding var isTestingKey: Bool
    @Binding var testResult: String?
    @Binding var showDeleteKeyConfirmation: Bool
    @Binding var toastMessage: String?

    @State private var showCustomModelField: Bool = false
    @State private var isSyncingInputsFromProvider: Bool = false

    private let primaryProviders: [AICloudProvider] = [.googleGemini, .groq, .openRouter, .pollinations]
    private let commercialProviders: [AICloudProvider] = [.openAI, .anthropic, .deepSeek, .xAI, .custom]
    private let quickRules: [CompositionRule] = [.goldenRatio, .ruleOfThirds, .centerSymmetry, .leadingLines]

    var body: some View {
        VStack(spacing: 16) {
            compositionRulesCard
            aiAutoBehaviorCard
            aiEngineCloudCard
        }
        .onAppear {
            syncLocalInputsWithActiveProvider()
        }
    }

    // Card 1: Bố cục & Khung ngắm
    private var compositionRulesCard: some View {
        SettingsSectionCard(title: "Bố cục & Khung ngắm", icon: "viewfinder") {
            VStack(spacing: 0) {
                // 1. Quy tắc bố cục mặc định (Native Menu + Quick 4-Rule Strip)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        SettingsRowIcon(viewModel.activeCompositionRule.iconName, isActive: true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quy tắc bố cục")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            Text("Khung tham chiếu mặc định khi căn góc")
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            ForEach(CompositionRule.allCases) { rule in
                                Button(action: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    viewModel.activeCompositionRule = rule
                                }) {
                                    HStack {
                                        Label(rule.displayNameVietnamese, systemImage: rule.iconName)
                                        if viewModel.activeCompositionRule == rule {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(viewModel.activeCompositionRule.displayNameVietnamese)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioAccent)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioInkTertiary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6.5)
                            .background(
                                Capsule()
                                    .fill(AlignTheme.studioElevated)
                                    .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                            )
                        }
                    }

                    // Dải chọn nhanh 4 quy tắc phổ biến nhất
                    HStack(spacing: 6) {
                        ForEach(quickRules) { rule in
                            let isPicked = viewModel.activeCompositionRule == rule
                            Button(action: {
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                    viewModel.activeCompositionRule = rule
                                }
                            }) {
                                Text(rule.displayNameVietnamese)
                                    .font(.system(size: 11.5, weight: isPicked ? .semibold : .medium, design: .rounded))
                                    .foregroundColor(isPicked ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isPicked ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(isPicked ? Color.white.opacity(0.22) : AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // 2. Tia dẫn hướng
                SettingsToggleRow(
                    title: "Hiển thị tia hướng dẫn",
                    subtitle: "Vẽ đường dẫn nối tâm camera tới vị trí bố cục đề xuất",
                    icon: "line.diagonal",
                    isOn: $viewModel.isGuidanceRayEnabled
                )

                dividerLine

                // 3. Độ nhạy bám chủ thể
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("scope", isActive: true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Độ nhạy bám chủ thể")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            Text(viewModel.trackingSensitivity.rawValue)
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }

                    HStack(spacing: 6) {
                        ForEach(TrackingSensitivityPreset.allCases) { preset in
                            SensitivityPill(
                                preset: preset,
                                isPicked: viewModel.trackingSensitivity == preset,
                                onSelect: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                        viewModel.trackingSensitivity = preset
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    // Card 2: Tự động hóa khi chụp
    private var aiAutoBehaviorCard: some View {
        SettingsSectionCard(title: "Tự động hóa", icon: "bolt.badge.automatic") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Tự động chụp khi đúng bố cục",
                    subtitle: "Kích hoạt màn trập ngay khi hai tâm khớp điểm vàng",
                    icon: "viewfinder.circle",
                    isOn: $viewModel.isAutoCaptureOnAlignEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Tự động zoom theo chủ thể",
                    subtitle: "Tự điều chỉnh tiêu cự để đạt tỷ lệ khung hình cân đối",
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    isOn: $viewModel.isAutoZoomEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Lớp gỡ lỗi AI Zoom (Debug)",
                    subtitle: "Hiện khung chủ thể, vùng rác, điểm clutter, zoom dự kiến & reason code",
                    icon: "ladybug",
                    isOn: $viewModel.isZoomDebugOverlayEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Lớp đo hiệu năng Tracking (Debug)",
                    subtitle: "Hiện FPS, độ trễ p50/p95 từng chặng, frame rơi, nhiệt độ & RAM (mặc định TẮT)",
                    icon: "gauge.with.dots.needle.67percent",
                    isOn: $viewModel.isTrackingPerfHUDEnabled
                )

                if viewModel.isZoomDebugOverlayEnabled || viewModel.isTrackingPerfHUDEnabled {
                    dividerLine

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "timer")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AlignTheme.studioAccent)
                            Text("Tốc độ hiệu ứng Zoom (1x → 2x)")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                            Spacer()
                            Text(String(format: "%.2fs", viewModel.debugSmoothZoomDuration))
                                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                .foregroundColor(AlignTheme.studioAccent)
                        }
                        Slider(
                            value: $viewModel.debugSmoothZoomDuration,
                            in: ZoomAnimationProfile.minConfigurableDuration...ZoomAnimationProfile.maxConfigurableDuration,
                            step: 0.05
                        )
                        .tint(AlignTheme.studioAccent)
                        HStack {
                            Text("Nhanh (0.40s)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                            Spacer()
                            Button("Mặc định 0.85s") {
                                viewModel.debugSmoothZoomDuration = ZoomAnimationProfile.defaultOneOctaveDuration
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(AlignTheme.studioAccent)
                            Spacer()
                            Text("Chậm (1.50s)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                dividerLine

                SettingsToggleRow(
                    title: "Tự động cân chỉnh màu AI",
                    subtitle: "Tối ưu tương phản và tone màu theo ánh sáng thực tế",
                    icon: "slider.horizontal.3",
                    isOn: $viewModel.isAIFullColorEnabled
                )
            }
        }
    }

    // Card 3: Động cơ AI & Kết nối Cloud (Thiết kế phẳng chuẩn iOS, tự động lưu Keychain tức thì, không rối)
    private var aiEngineCloudCard: some View {
        let isCloudReady = viewModel.useGeminiForAnalysis && geminiService.hasAPIKey
        let provider = geminiService.selectedProvider

        return SettingsSectionCard(title: "Động cơ AI & Kết nối Cloud", icon: "network") {
            VStack(alignment: .leading, spacing: 0) {
                // 1. Chuyển đổi chế độ Động cơ: Trên máy (Offline) vs Cloud AI + Tự dự phòng
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        engineModePill(
                            title: "Trên máy (Offline)",
                            icon: "cpu",
                            isSelected: !viewModel.useGeminiForAnalysis
                        ) {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.84)) {
                                viewModel.useGeminiForAnalysis = false
                            }
                        }

                        engineModePill(
                            title: "Cloud AI + Dự phòng",
                            icon: "icloud",
                            isSelected: viewModel.useGeminiForAnalysis
                        ) {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.84)) {
                                viewModel.useGeminiForAnalysis = true
                            }
                        }
                    }

                    // Thanh trạng thái trực quan gọn 1 dòng
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isCloudReady ? Color.green : (viewModel.useGeminiForAnalysis ? Color.orange : AlignTheme.studioAccent))
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 1.5) {
                            if isCloudReady {
                                HStack(spacing: 5) {
                                    Text("\(provider.shortBadge) · \(geminiService.activeModelID)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(AlignTheme.studioInkPrimary)
                                        .lineLimit(1)

                                    if geminiService.lastLatencyMs > 0 {
                                        Text("\(geminiService.lastLatencyMs)ms")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.green.opacity(0.14)))
                                    }
                                }
                                Text("Tự động chuyển về Neural Engine trên máy nếu mất mạng.")
                                    .font(.system(size: 11))
                                    .foregroundColor(AlignTheme.studioInkSecondary)
                            } else if viewModel.useGeminiForAnalysis {
                                Text("Chưa có khóa API cho \(provider.shortBadge) — Đang dùng AI trên máy")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("Dán khóa API bên dưới để kích hoạt phân tích đám mây.")
                                    .font(.system(size: 11))
                                    .foregroundColor(AlignTheme.studioInkSecondary)
                            } else {
                                Text("Neural Engine trên máy · Hoạt động 100% Offline")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioInkPrimary)
                                Text("Xử lý trực tiếp trên thiết bị, không cần mạng hay khóa API.")
                                    .font(.system(size: 11))
                                    .foregroundColor(AlignTheme.studioInkSecondary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.6)
                            )
                    )

                    if let cloudError = viewModel.geminiError, !cloudError.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(.orange)
                            Text(cloudError)
                                .font(.system(size: 11.5))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Ẩn") {
                                viewModel.geminiError = nil
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // 2. Chọn Dịch vụ Cloud (Menu gọn chuẩn iOS + 4 nút chuyển nhanh phổ biến nhất)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("server.rack", isActive: geminiService.hasAPIKey)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dịch vụ Cloud")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            Text(provider.summarySubtitle)
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            Section("Khuyên dùng (Nhanh & Có gói miễn phí)") {
                                ForEach(primaryProviders) { prov in
                                    providerMenuButton(prov)
                                }
                            }
                            Section("Thương mại & Máy chủ riêng") {
                                ForEach(commercialProviders) { prov in
                                    providerMenuButton(prov)
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(provider.shortBadge)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioAccent)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioInkTertiary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6.5)
                            .background(
                                Capsule()
                                    .fill(AlignTheme.studioElevated)
                                    .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                            )
                        }
                    }

                    // Dải chọn nhanh 4 dịch vụ phổ biến nhất (Google Gemini · Groq LPU · OpenRouter · OpenAI)
                    HStack(spacing: 6) {
                        ForEach([AICloudProvider.googleGemini, .groq, .openRouter, .openAI]) { quickProv in
                            let isPicked = provider == quickProv
                            Button(action: {
                                selectProvider(quickProv)
                            }) {
                                Text(quickProv.shortBadge)
                                    .font(.system(size: 11.5, weight: isPicked ? .semibold : .medium, design: .rounded))
                                    .foregroundColor(isPicked ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isPicked ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(isPicked ? Color.white.opacity(0.22) : AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if provider == .custom {
                        TextField("https://api.example.com/v1/chat/completions", text: $customEndpointInput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AlignTheme.studioElevated)
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65))
                            )
                            .onChangeCompatible(of: customEndpointInput) { newVal in
                                guard !isSyncingInputsFromProvider else { return }
                                geminiService.customEndpointURL = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // 3. Khóa API (Tự động lưu vào Apple Keychain ngay khi nhập hoặc bấm Dán 1 chạm)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                            Text("Khóa API (\(provider.shortBadge))")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                        }

                        Spacer()

                        if geminiService.hasAPIKey {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10))
                                Text("Đã lưu Keychain")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.green)
                        } else {
                            Text("Tự động lưu khi nhập")
                                .font(.system(size: 11))
                                .foregroundColor(AlignTheme.studioInkTertiary)
                        }
                    }

                    HStack(spacing: 6) {
                        Group {
                            if isKeyVisible {
                                TextField(provider.keyPlaceholder, text: $geminiKeyInput)
                            } else {
                                SecureField(provider.keyPlaceholder, text: $geminiKeyInput)
                            }
                        }
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkPrimary)
                        .tint(AlignTheme.studioAccent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(AlignTheme.studioElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                                )
                        )
                        .onChangeCompatible(of: geminiKeyInput) { newVal in
                            guard !isSyncingInputsFromProvider else { return }
                            applyEditedAPIKey(newVal, announceToast: false)
                        }

                        // Nút Dán 1 chạm từ Clipboard (Tự động nhận diện hãng API)
                        Button(action: pasteAPIKeyFromClipboard) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 11.5, weight: .medium))
                                Text("Dán")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.09))
                            )
                        }
                        .buttonStyle(.plain)

                        // Nút Hiện / Ẩn khóa
                        Button(action: { isKeyVisible.toggle() }) {
                            Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 13))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .frame(width: 36, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)

                        // Nút Xóa khóa
                        if geminiService.hasAPIKey {
                            Button(action: { showDeleteKeyConfirmation = true }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red.opacity(0.85))
                                    .frame(width: 36, height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.red.opacity(0.12))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // 4. Mô hình phân tích (Gộp gọn trong 1 hàng Menu chuẩn iOS, không xếp chồng 3 ô tìm kiếm)
                VStack(alignment: .leading, spacing: 8) {
                    let curatedModels = AIVisionModel.models(for: provider)
                    let apiModels = geminiService.discoveredModels

                    HStack(spacing: 12) {
                        SettingsRowIcon("cpu", isActive: true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mô hình phân tích")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            Text(geminiService.customModelName.isEmpty
                                 ? selectedModel.subtitle
                                 : (geminiService.discoveredModelDescriptions[geminiService.customModelName] ?? "Mã mô hình tùy chỉnh: \(geminiService.customModelName)"))
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            Section("Đề xuất cho \(provider.shortBadge)") {
                                ForEach(curatedModels) { model in
                                    Button(action: {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        selectedModel = model
                                        geminiService.selectedModel = model
                                        geminiService.customModelName = ""
                                        customModelInput = ""
                                        showCustomModelField = false
                                    }) {
                                        HStack {
                                            Text(model.displayName)
                                            if selectedModel == model && geminiService.customModelName.isEmpty {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            if !apiModels.isEmpty {
                                Section("Từ tài khoản API (\(apiModels.count))") {
                                    ForEach(apiModels.prefix(50), id: \.self) { modelID in
                                        Button(action: {
                                            UISelectionFeedbackGenerator().selectionChanged()
                                            customModelInput = modelID
                                            geminiService.customModelName = modelID
                                            if let matched = AIVisionModel.allCases.first(where: { $0.rawValue == modelID }) {
                                                selectedModel = matched
                                                geminiService.selectedModel = matched
                                            }
                                        }) {
                                            HStack {
                                                if let desc = geminiService.discoveredModelDescriptions[modelID], !desc.isEmpty {
                                                    Text("\(modelID) · \(desc)")
                                                } else {
                                                    Text(modelID)
                                                }
                                                if geminiService.activeModelID == modelID {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Section {
                                Button(action: {
                                    Task {
                                        let (_, msg) = await geminiService.fetchAvailableModels()
                                        await MainActor.run {
                                            toastMessage = msg
                                        }
                                    }
                                }) {
                                    Label(
                                        apiModels.isEmpty ? "Đồng bộ danh sách từ API" : "Làm mới danh sách API (\(apiModels.count))",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                }

                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showCustomModelField.toggle()
                                    }
                                }) {
                                    Label(
                                        showCustomModelField ? "Ẩn ô nhập mã model" : "Nhập mã model tùy chỉnh...",
                                        systemImage: "character.cursor.ibeam"
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if geminiService.isFetchingModels {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .tint(AlignTheme.studioAccent)
                                }
                                Text(geminiService.customModelName.isEmpty ? selectedModel.shortName : geminiService.customModelName)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioAccent)
                                    .lineLimit(1)
                                    .frame(maxWidth: 135, alignment: .trailing)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioInkTertiary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6.5)
                            .background(
                                Capsule()
                                    .fill(AlignTheme.studioElevated)
                                    .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                            )
                        }
                    }

                    if showCustomModelField || !geminiService.customModelName.isEmpty {
                        HStack(spacing: 6) {
                            TextField("Nhập mã Model ID (tự động lưu)...", text: $customModelInput)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(.horizontal, 10)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(AlignTheme.studioElevated)
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65))
                                )
                                .onChangeCompatible(of: customModelInput) { newVal in
                                    guard !isSyncingInputsFromProvider else { return }
                                    geminiService.customModelName = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                }

                            if !customModelInput.isEmpty {
                                Button(action: {
                                    customModelInput = ""
                                    geminiService.customModelName = ""
                                    showCustomModelField = false
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(AlignTheme.studioInkTertiary)
                                        .frame(width: 32, height: 36)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)

                dividerLine

                // 5. Kiểm tra kết nối & Độ trễ thực tế
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: runConnectionDiagnostics) {
                        HStack(spacing: 8) {
                            if isTestingKey {
                                ProgressView()
                                    .scaleEffect(0.78)
                                    .tint(AlignTheme.studioInkPrimary)
                            } else {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(AlignTheme.studioAccent)
                            }

                            Text(isTestingKey ? "Đang kiểm tra phản hồi từ \(provider.shortBadge)..." : "Kiểm tra kết nối & độ trễ")
                                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            Spacer()

                            if !isTestingKey {
                                Text(geminiService.activeModelID)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(AlignTheme.studioInkTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingKey)

                    if let res = testResult {
                        let isSuccess = res.contains("thành công") || res.contains("✅")
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(isSuccess ? .green : .orange)
                                .padding(.top, 1)

                            Text(res.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
                                .font(.system(size: 11.5))
                                .foregroundColor(isSuccess ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill((isSuccess ? Color.green : Color.orange).opacity(0.10))
                        )
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Helper Subviews & Actions

    private func engineModePill(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.22) : AlignTheme.studioHairlineSubtle, lineWidth: 0.65)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func providerMenuButton(_ prov: AICloudProvider) -> some View {
        Button(action: {
            selectProvider(prov)
        }) {
            HStack {
                Text(prov.displayName)
                if geminiService.selectedProvider == prov {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func selectProvider(_ provider: AICloudProvider) {
        UISelectionFeedbackGenerator().selectionChanged()
        isSyncingInputsFromProvider = true
        geminiService.activeProfileID = nil
        geminiService.selectedProvider = provider
        geminiKeyInput = geminiService.apiKey
        selectedModel = geminiService.selectedModel
        customModelInput = geminiService.customModelName
        customEndpointInput = geminiService.customEndpointURL
        testResult = nil
        DispatchQueue.main.async {
            self.isSyncingInputsFromProvider = false
        }
        if geminiService.hasAPIKey {
            Task {
                _ = await geminiService.fetchAvailableModels()
            }
        }
    }

    private func syncLocalInputsWithActiveProvider() {
        isSyncingInputsFromProvider = true
        geminiKeyInput = geminiService.apiKey
        selectedModel = geminiService.selectedModel
        customModelInput = geminiService.customModelName
        customEndpointInput = geminiService.customEndpointURL
        DispatchQueue.main.async {
            self.isSyncingInputsFromProvider = false
        }
    }

    private func applyEditedAPIKey(_ raw: String, announceToast: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           geminiService.selectedProvider != .custom,
           geminiService.selectedProvider != .pollinations,
           let detected = AICloudProvider.detectProvider(fromKey: trimmed),
           detected != geminiService.selectedProvider {
            geminiService.selectedProvider = detected
            selectedModel = geminiService.selectedModel
        }
        if geminiService.apiKey != trimmed {
            geminiService.apiKey = trimmed
        }
        if !trimmed.isEmpty {
            if !viewModel.useGeminiForAnalysis {
                viewModel.useGeminiForAnalysis = true
            }
            if announceToast {
                toastMessage = "Đã lưu khóa \(geminiService.selectedProvider.shortBadge) vào Keychain"
            }
        } else if announceToast {
            toastMessage = "Đã xóa khóa API"
        }
    }

    private func pasteAPIKeyFromClipboard() {
        guard let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else {
            toastMessage = "Bộ nhớ tạm đang trống"
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        isSyncingInputsFromProvider = true
        geminiKeyInput = pasted
        applyEditedAPIKey(pasted, announceToast: true)
        selectedModel = geminiService.selectedModel
        testResult = nil
        DispatchQueue.main.async {
            self.isSyncingInputsFromProvider = false
        }
        Task {
            _ = await geminiService.fetchAvailableModels()
        }
    }

    private func runConnectionDiagnostics() {
        // Đảm bảo mọi nội dung vừa gõ chưa kịp đóng bàn phím đều được lưu trước khi kiểm tra
        let trimmedKey = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey != geminiService.apiKey {
            applyEditedAPIKey(trimmedKey, announceToast: false)
        }
        let trimmedModel = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModel != geminiService.customModelName {
            geminiService.customModelName = trimmedModel
        }
        let trimmedURL = customEndpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL != geminiService.customEndpointURL {
            geminiService.customEndpointURL = trimmedURL
        }

        isTestingKey = true
        testResult = nil
        Task {
            let (ok, msg) = await geminiService.testAPIKey()
            await MainActor.run {
                isTestingKey = false
                testResult = msg
                if ok {
                    viewModel.geminiError = nil
                    if !viewModel.useGeminiForAnalysis {
                        viewModel.useGeminiForAnalysis = true
                    }
                }
            }
        }
    }

    private var dividerLine: some View {
        Divider().background(AlignTheme.studioHairlineSubtle)
    }
}

// MARK: - SECTION 3: ADVANCED & SYSTEM (TAB 3)
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showResetSessionConfirmation: Bool
    @Binding var toastMessage: String?
    @State private var showPreviousLogSheet: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            crashDiagnosticsAndStressCard
            systemMotionCard
            supportInfoCard
        }
        .sheet(isPresented: $showPreviousLogSheet) {
            PreviousSessionLogSheetView(viewModel: viewModel)
        }
    }

    // Card 0: Chẩn đoán Crash, Log phiên trước & Stress Test (>= 30 vòng)
    private var crashDiagnosticsAndStressCard: some View {
        SettingsSectionCard(title: "Chẩn đoán Crash & Stress Test", icon: "waveform.path.ecg.rectangle.fill") {
            VStack(spacing: 0) {
                SettingsActionRow(
                    title: "Xem & Chia sẻ Log phiên trước",
                    subtitle: CameraLogger.didPreviousSessionExitUncleanly
                        ? "Phát hiện phiên trước thoát bất thường — bấm xem các dòng log cuối"
                        : "Xem vòng đời Session/Model/Metal, RAM mỗi giây & MetricKit",
                    icon: "doc.text.magnifyingglass"
                ) {
                    showPreviousLogSheet = true
                }

                dividerLine

                SettingsActionRow(
                    title: viewModel.isRunningStressTest ? "Đang chạy Stress Test…" : "Chạy Stress Test (32 vòng)",
                    subtitle: "Tự động vào/ra Camera + chạy Local AI 32 vòng liên tiếp và đo RAM mỗi vòng",
                    icon: "bolt.heart.fill"
                ) {
                    viewModel.runLifecycleStressTest(cycles: 32)
                }

                if CameraLogger.didPreviousSessionExitUncleanly {
                    dividerLine
                    Text(CameraLogger.lastCrashHeadlineSummary())
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                if !viewModel.stressTestReportText.isEmpty {
                    dividerLine
                    Text(viewModel.stressTestReportText)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                dividerLine

                VStack(spacing: 6) {
                    infoRow(
                        label: "RAM hiện tại",
                        value: String(
                            format: "%.1f MB · Trống %d MB",
                            CameraLogger.currentMemoryFootprintMB(),
                            CameraLogger.currentAvailableMemoryMB()
                        )
                    )
                    infoRow(
                        label: "Phiên trước",
                        value: CameraLogger.didPreviousSessionExitUncleanly ? "Thoát bất thường (Unclean)" : "Đóng sạch (Clean)"
                    )
                }
                .padding(.vertical, 8)
            }
        }
    }

    // Card 1: Hệ thống & Chuyển động
    private var systemMotionCard: some View {
        SettingsSectionCard(title: "Hệ thống & Chuyển động", icon: "gearshape.fill") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Chế độ đi đường",
                    subtitle: "Tăng cường độ mượt và bù trừ rung lắc khi vừa đi bộ vừa chụp",
                    icon: "figure.walk",
                    isOn: $viewModel.isStreetTrackingModeEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Âm thanh & Rung căn góc",
                    subtitle: "Phát nhịp rung Haptics thông minh khi tâm camera hút vào điểm vàng",
                    icon: "hand.tap.fill",
                    isOn: $viewModel.isProximityHapticsEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Giữ màn hình luôn sáng",
                    subtitle: "Ngăn thiết bị tự động khóa màn hình trong suốt buổi chụp ảnh",
                    icon: "sun.max.fill",
                    isOn: $viewModel.isKeepScreenAwakeEnabled
                )

                dividerLine

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

    // Card 2: Hỗ trợ & Thông tin bản quyền
    private var supportInfoCard: some View {
        let appShortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let appBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2026"
        return SettingsSectionCard(title: "Hỗ trợ & Thông tin", icon: "info.circle.fill") {
            VStack(spacing: 0) {
                NavigationLink(destination: FeedbackView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("envelope.fill")

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Góp ý & Hỗ trợ")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                            Text("Báo lỗi, đề xuất tính năng và gửi kèm log")
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkTertiary)
                    }
                    .frame(minHeight: 54)
                }

                dividerLine

                NavigationLink(destination: SupportDeveloperView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("cup.and.saucer.fill")

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ủng hộ tác giả")
                                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioAccent)
                            Text("Mời tác giả một ly cà phê qua MB Bank / VietQR")
                                .font(.system(size: 11.5))
                                .foregroundColor(AlignTheme.studioInkSecondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkTertiary)
                    }
                    .frame(minHeight: 54)
                }

                dividerLine

                VStack(spacing: 8) {
                    infoRow(label: "Tác giả", value: "ace4youblade (VanKhoa)")
                    infoRow(label: "Liên hệ", value: "tranvantrinhhd@gmail.com")
                    infoRow(label: "Phiên bản", value: "v\(appShortVersion) (Build \(appBuildNumber))")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AlignTheme.studioInkSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private var dividerLine: some View {
        Divider().background(AlignTheme.studioHairlineSubtle)
    }
}

// MARK: - SUPPORT DEVELOPER VIEW (MB BANK & DYNAMIC VIETQR)
public struct SupportDeveloperView: View {
    @State private var toastMessage: String? = nil
    @State private var showVietQR: Bool = false
    @State private var qrReloadID = UUID()

    private let vietQRURLString = "https://img.vietqr.io/image/mbbank-0344197212-compact2.png?amount=50000&addInfo=Donate%20AlignAI%20Camera&accountName=TRAN%20VAN%20TRINH"

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Calm Monochrome Studio Hero Card
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(AlignTheme.studioElevated)
                            .frame(width: 60, height: 60)
                            .overlay(
                                Circle().stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                            )

                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(AlignTheme.studioAccent)
                    }

                    Text("Ủng hộ tác giả")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(AlignTheme.studioInkPrimary)

                    Text("Nếu Align Studio hỗ trợ tốt trong quá trình chụp và quay của bạn, bạn có thể mời tác giả một ly cà phê để tiếp thêm động lực phát triển.")
                        .font(.system(size: 12.5))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(AlignTheme.studioSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.7)
                        )
                )

                // MB Bank Card
                SettingsSectionCard(title: "NGÂN HÀNG QUÂN ĐỘI (MB BANK)", icon: "building.columns.fill") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TRAN VAN TRINH")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                            Text("0344197212")
                                .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(AlignTheme.studioAccent)
                        }

                        Spacer()

                        Button(action: {
                            UIPasteboard.general.string = "0344197212"
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showToast("Đã sao chép STK MB Bank: 0344197212")
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Sao chép")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(AlignTheme.studioInkPrimary))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // VietQR Card with Retry Logic
                SettingsSectionCard(title: "MÃ VIETQR CHUYỂN KHOẢN NHANH", icon: "qrcode.viewfinder") {
                    VStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                showVietQR.toggle()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: showVietQR ? "qrcode.viewfinder" : "qrcode")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(AlignTheme.studioAccent)
                                Text(showVietQR ? "Thu gọn mã QR" : "Hiện mã VietQR chuyển khoản nhanh")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioInkPrimary)
                                Spacer()
                                Image(systemName: showVietQR ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioInkTertiary)
                            }
                        }
                        .buttonStyle(.plain)

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
                                                .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                                        )
                                case .failure:
                                    VStack(spacing: 8) {
                                        Image(systemName: "wifi.slash")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(AlignTheme.studioInkTertiary)
                                        Text("Không thể tải mã VietQR — vui lòng kiểm tra kết nối mạng")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(AlignTheme.studioInkSecondary)
                                            .multilineTextAlignment(.center)
                                        Button("Thử lại") {
                                            qrReloadID = UUID()
                                        }
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundColor(AlignTheme.studioInkPrimary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            Capsule()
                                                .fill(AlignTheme.studioElevated)
                                                .overlay(Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.65))
                                        )
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(20)
                                default:
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
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
        .background(AlignTheme.studioCanvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
                    .allowsHitTesting(false)
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

// MARK: - TOAST BANNER NOTIFICATION (Smoked Frosted Glass)
public struct ToastBanner: View {
    let message: String

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AlignTheme.studioAccent)
                .font(.system(size: 13, weight: .semibold))

            Text(message)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(AlignTheme.studioInkPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(StudioGlassCapsule(tintOpacity: 0.72, borderOpacity: 0.16))
        .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
    }
}

// MARK: - ACTIVITY SHARE VIEW (UIActivityViewController Representable)
struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - PREVIOUS SESSION & CRASH DIAGNOSTICS LOG VIEWER
public struct PreviousSessionLogSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLogTab: Int = CameraLogger.hasPreviousSessionLog ? 0 : 1
    @State private var previousLogText: String = ""
    @State private var currentLogText: String = ""
    @State private var shareFileURL: URL? = nil
    @State private var isSharingFile: Bool = false
    @State private var copyFeedback: String? = nil

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                statusHeader

                Picker("Nguồn log", selection: $selectedLogTab) {
                    Text("Log phiên trước").tag(0)
                    Text("Log phiên hiện tại").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    Text(selectedLogTab == 0 ? previousLogText : currentLogText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(white: 0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)

                actionToolbar
            }
            .padding(.vertical, 10)
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle("Chẩn đoán & Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AlignTheme.studioAccent)
                }
            }
            .onAppear {
                CameraLogger.lifecycle("VIEW_APPEAR", detail: "PreviousSessionLogSheetView", category: .general)
                reloadLogs()
            }
            .onDisappear {
                CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "PreviousSessionLogSheetView", category: .general)
            }
            .sheet(isPresented: $isSharingFile) {
                if let url = shareFileURL {
                    ActivityShareView(activityItems: [url])
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: CameraLogger.didPreviousSessionExitUncleanly ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .foregroundColor(CameraLogger.didPreviousSessionExitUncleanly ? .orange : .green)
                Text(
                    CameraLogger.didPreviousSessionExitUncleanly
                        ? "Phiên trước thoát bất thường (Crash / Jetsam OOM)"
                        : "Phiên trước đóng bình thường"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                Spacer()
            }
            if CameraLogger.didPreviousSessionExitUncleanly {
                Text(CameraLogger.lastCrashHeadlineSummary())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !viewModel.stressTestReportText.isEmpty {
                Text(viewModel.stressTestReportText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(AlignTheme.studioAccent)
            }
            if let feedback = copyFeedback {
                Text(feedback)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var actionToolbar: some View {
        HStack(spacing: 10) {
            Button {
                if let url = CameraLogger.exportCombinedDiagnosticsFileURL() {
                    shareFileURL = url
                    isSharingFile = true
                }
            } label: {
                Label("Chia sẻ Log", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(AlignTheme.studioAccent)
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                UIPasteboard.general.string = (selectedLogTab == 0
                    ? CameraLogger.readPreviousSessionQuickCopy(maxLines: 120)
                    : currentLogText)
                copyFeedback = "Đã sao chép log pháp y vào bộ nhớ tạm"
            } label: {
                Label("Sao chép", systemImage: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.10))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                reloadLogs()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(10)
                    .background(Color.white.opacity(0.10))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button {
                CameraLogger.clearLogs()
                reloadLogs()
                copyFeedback = "Đã xóa log cũ"
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(10)
                    .background(Color.red.opacity(0.22))
                    .foregroundColor(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
    }

    private func reloadLogs() {
        DispatchQueue.global(qos: .userInitiated).async {
            let prev = CameraLogger.readPreviousSessionLogTail(maxLines: 300)
            let curr = CameraLogger.readCurrentSessionLogTail(maxLines: 260)
            DispatchQueue.main.async {
                previousLogText = prev
                currentLogText = curr
            }
        }
    }
}
