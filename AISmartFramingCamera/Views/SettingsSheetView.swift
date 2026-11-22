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
            mechanicalShutterCard
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

    // Card 1b: Màn trập cơ học & Rung (CoreHaptics + AVAudioEngine Tổng hợp PCM thực)
    private var mechanicalShutterCard: some View {
        SettingsSectionCard(title: "Màn trập cơ học & Rung", icon: "camera.aperture") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Chất âm màn trập")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                        Spacer()
                        Text(viewModel.mechanicalShutterProfile.shortLabel)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)
                    }

                    Text(viewModel.mechanicalShutterProfile.hardwareSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(AlignTheme.studioInkSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(MechanicalShutterProfile.allCases) { prof in
                                let isSel = viewModel.mechanicalShutterProfile == prof
                                Button(action: {
                                    viewModel.previewMechanicalShutter(prof)
                                }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: prof.iconName)
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(prof.shortLabel)
                                            .font(.system(size: 11.5, weight: isSel ? .bold : .medium, design: .rounded))
                                    }
                                    .foregroundColor(isSel ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(isSel ? AlignTheme.studioAccentSoft : Color.white.opacity(0.055))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(isSel ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSel ? 0.9 : 0.6)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 4)

                dividerLine

                // Âm lượng màn trập
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Âm lượng tiếng màn trập")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkSecondary)
                        Spacer()
                        Text("\(Int(round(viewModel.shutterSoundVolume * 100)))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                    Slider(value: $viewModel.shutterSoundVolume, in: 0...1, step: 0.05)
                        .tint(AlignTheme.studioAccent)
                }

                // Cường độ rung cơ học CoreHaptics
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cường độ rung cơ học (Taptic)")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkSecondary)
                        Spacer()
                        Text("\(Int(round(viewModel.mechanicalHapticIntensity * 100)))%")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                    Slider(value: $viewModel.mechanicalHapticIntensity, in: 0...1, step: 0.05)
                        .tint(AlignTheme.studioAccent)
                }

                dividerLine

                SettingsToggleRow(
                    title: "Tôn trọng công tắc gạt im lặng",
                    subtitle: "Tắt khi muốn tiếng màn trập cơ phát ngay cả khi đang gạt im lặng",
                    icon: "bell.slash",
                    isOn: $viewModel.shutterRespectsSilentSwitch
                )

                dividerLine

                SettingsToggleRow(
                    title: "Rung nửa cò chụp",
                    subtitle: "Tạo khấc nhấn nhẹ ngay khi vừa chạm ngón tay vào nút chụp",
                    icon: "hand.tap",
                    isOn: $viewModel.enableShutterHalfPressHaptic
                )

                dividerLine

                SettingsToggleRow(
                    title: "Tiếng tách bánh răng tiêu cự",
                    subtitle: "Mô phỏng vòng khẩu độ / zoom cơ học khi chạm các nấc 0.5x – 3x",
                    icon: "dial.medium",
                    isOn: $viewModel.enableMechanicalDialTicks
                )

                Button(action: {
                    viewModel.previewMechanicalShutter()
                    toastMessage = "Đang thử màn trập: \(MechanicalShutterEngine.shared.effectiveResolvedProfile.displayName)"
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Bấm thử âm thanh & rung màn trập")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AlignTheme.studioAccent)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
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

// MARK: - SECTION 2: AI FRAMING & CLOUD ENGINE (TAB 2)
struct AIFramingSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
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

    @State private var showDeleteFeedbackConfirmation = false
    @State private var feedbackRevision = 0
    @State private var feedbackExportURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            compositionRulesCard
            aiAutoBehaviorCard
            aiEngineCloudCard
            compositionFeedbackCard
        }
    }

    // Card 1: AI Bố cục & Quy tắc căn khung
    private var compositionRulesCard: some View {
        SettingsSectionCard(title: "AI Bố cục", icon: "viewfinder") {
            VStack(spacing: 12) {
                // Visual Composition Cards Grid (2 Cột)
                VStack(alignment: .leading, spacing: 8) {
                    Text("QUY TẮC BỐ CỤC MẶC ĐỊNH:")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
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

                dividerLine

                SettingsToggleRow(
                    title: "Hiển thị tia hướng dẫn",
                    subtitle: "Vẽ đường định hướng nối từ tâm camera tới vị trí vàng đề xuất",
                    icon: "line.diagonal",
                    isOn: $viewModel.isGuidanceRayEnabled
                )

                dividerLine

                // Tracking Sensitivity Segmented Control
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("scope", isActive: true)

                        Text("Độ nhạy bám chủ thể")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(viewModel.trackingSensitivity.shortName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)
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

    // Card 2: Hành vi Tự động
    private var aiAutoBehaviorCard: some View {
        SettingsSectionCard(title: "Hành vi Tự động", icon: "bolt.badge.automatic") {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: "Tự động chụp khi đúng bố cục",
                    subtitle: "Kích hoạt màn trập ngay khi hai tâm đạt độ khớp hoàn hảo",
                    icon: "viewfinder.circle",
                    isOn: $viewModel.isAutoCaptureOnAlignEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Tự động zoom theo chủ thể",
                    subtitle: "Tự điều chỉnh tiêu cự để đạt tỷ lệ bố cục chuẩn nhất",
                    icon: "arrow.up.left.and.down.right.magnifyingglass",
                    isOn: $viewModel.isAutoZoomEnabled
                )

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

    // Card 3: Động cơ AI & Kết nối Cloud (Multi-Provider 2026)
    private var aiEngineCloudCard: some View {
        SettingsSectionCard(title: "Động cơ AI & Kết nối Cloud", icon: "network") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Ưu tiên Cloud AI (Tự chuyển)",
                    subtitle: "Dùng Cloud AI khi có mạng & Key; tự chuyển sang Local AI trên máy nếu mất mạng",
                    icon: "icloud",
                    isOn: $viewModel.useGeminiForAnalysis
                )

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.useGeminiForAnalysis && viewModel.geminiService.hasAPIKey ? Color.green : AlignTheme.studioAccent)
                        .frame(width: 7, height: 7)
                    Text(viewModel.useGeminiForAnalysis && viewModel.geminiService.hasAPIKey
                         ? "Đang hoạt động: \(viewModel.geminiService.selectedProvider.shortBadge) • \(viewModel.geminiService.activeModelID) (Tự dự phòng Local)"
                         : "Đang chạy AI Cục bộ trên máy (Neural Engine Offline 100%)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.88))
                }

                if let cloudError = viewModel.geminiError {
                    Text(cloudError)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                dividerLine

                // 1. Selector Nhà cung cấp API (6 Providers)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Nhà cung cấp API", systemImage: "server.rack")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(viewModel.geminiService.selectedProvider.displayName)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(AICloudProvider.allCases) { provider in
                            let isSelected = viewModel.geminiService.selectedProvider == provider
                            Button(action: {
                                UISelectionFeedbackGenerator().selectionChanged()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    viewModel.geminiService.activeProfileID = nil
                                    viewModel.geminiService.selectedProvider = provider
                                    geminiKeyInput = viewModel.geminiService.apiKey
                                    let available = AIVisionModel.models(for: provider)
                                    if !available.contains(selectedModel) {
                                        let def = AIVisionModel.defaultModel(for: provider)
                                        selectedModel = def
                                        viewModel.geminiService.selectedModel = def
                                    }
                                    if viewModel.geminiService.hasAPIKey {
                                        Task {
                                            await viewModel.geminiService.fetchAvailableModels()
                                        }
                                    }
                                }
                            }) {
                                HStack(spacing: 4) {
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text(provider.shortBadge)
                                        .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundColor(isSelected ? .white : Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.85))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .background(
                                    isSelected ? AlignTheme.studioAccent.opacity(0.24) : AlignTheme.studioElevated
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSelected ? AlignTheme.studioAccent.opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Custom Endpoint URL nếu chọn Custom
                if viewModel.geminiService.selectedProvider == .custom || !customEndpointInput.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BASE URL / ENDPOINT TÙY CHỈNH (OPENAI-COMPATIBLE):")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.50))
                        HStack(spacing: 8) {
                            TextField("https://api.example.com/v1/chat/completions", text: $customEndpointInput)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(.white)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(8)
                                .background(AlignTheme.studioElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 1)
                                )

                            Button("Lưu URL") {
                                viewModel.geminiService.customEndpointURL = customEndpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                toastMessage = "Đã cập nhật Endpoint URL"
                            }
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(AlignTheme.studioAccent.opacity(0.30))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                // 2. Ô Nhập API Key Thông Minh
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Khóa API \(viewModel.geminiService.selectedProvider.shortBadge)", systemImage: "key.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        if viewModel.geminiService.hasAPIKey {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10))
                                Text("Đã lưu Keychain")
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                            .foregroundColor(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                        } else {
                            Text("Chưa có Key")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.40))
                        }
                    }

                    HStack(spacing: 8) {
                        Group {
                            if isKeyVisible {
                                TextField(viewModel.geminiService.selectedProvider.keyPlaceholder, text: $geminiKeyInput)
                            } else {
                                SecureField(viewModel.geminiService.selectedProvider.keyPlaceholder, text: $geminiKeyInput)
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .tint(AlignTheme.studioAccent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(AlignTheme.studioElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 1)
                        )

                        // Nút Hiện/Ẩn
                        Button(action: { isKeyVisible.toggle() }) {
                            Image(systemName: isKeyVisible ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.70))
                                .padding(9)
                                .background(Color.white.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        // Nút Lưu Key
                        Button("Lưu") {
                            let trimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            viewModel.geminiService.apiKey = trimmed
                            toastMessage = trimmed.isEmpty ? "Đã xóa API Key" : "Đã lưu Key & đang tải danh sách Model từ API..."
                            if !trimmed.isEmpty {
                                Task {
                                    await viewModel.geminiService.fetchAvailableModels()
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(AlignTheme.studioAccent.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Nút Xóa Key
                        if viewModel.geminiService.hasAPIKey {
                            Button(action: { showDeleteKeyConfirmation = true }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red.opacity(0.85))
                                    .padding(9)
                                    .background(Color.red.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }

                // 3. Chọn Model AI & Model Tùy chỉnh
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Model AI", systemImage: "cpu.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: {
                            Task {
                                let (_, msg) = await viewModel.geminiService.fetchAvailableModels()
                                await MainActor.run {
                                    toastMessage = msg
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                if viewModel.geminiService.isFetchingModels {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                        .tint(AlignTheme.studioAccent)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(viewModel.geminiService.isFetchingModels
                                     ? "Đang tải..."
                                     : (viewModel.geminiService.discoveredModels.isEmpty ? "Tải Model từ API" : "Làm mới (\(viewModel.geminiService.discoveredModels.count))"))
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AlignTheme.studioAccent.opacity(0.16))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Text(viewModel.geminiService.activeModelID)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                            .lineLimit(1)
                    }

                    // Danh sách Model tiêu chuẩn của Provider + Model tải trực tiếp từ API
                    let models = AIVisionModel.models(for: viewModel.geminiService.selectedProvider)
                    let apiModels = viewModel.geminiService.discoveredModels
                    if !models.isEmpty || !apiModels.isEmpty {
                        Menu {
                            Section("Model đề xuất chuẩn 2026") {
                                ForEach(models) { model in
                                    Button(action: {
                                        selectedModel = model
                                        viewModel.geminiService.selectedModel = model
                                        viewModel.geminiService.customModelName = ""
                                        customModelInput = ""
                                    }) {
                                        HStack {
                                            Text(model.displayName)
                                            if selectedModel == model && viewModel.geminiService.customModelName.isEmpty {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }

                            if !apiModels.isEmpty {
                                Section("Model tải từ API (\(apiModels.count))") {
                                    ForEach(apiModels.prefix(60), id: \.self) { modelID in
                                        Button(action: {
                                            customModelInput = modelID
                                            viewModel.geminiService.customModelName = modelID
                                            if let matched = AIVisionModel.allCases.first(where: { $0.rawValue == modelID }) {
                                                selectedModel = matched
                                                viewModel.geminiService.selectedModel = matched
                                            }
                                            toastMessage = "Đã chọn model API: \(modelID)"
                                        }) {
                                            HStack {
                                                if let desc = viewModel.geminiService.discoveredModelDescriptions[modelID], !desc.isEmpty {
                                                    Text("\(modelID) — \(desc)")
                                                } else {
                                                    Text(modelID)
                                                }
                                                if viewModel.geminiService.activeModelID == modelID {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(viewModel.geminiService.customModelName.isEmpty ? selectedModel.shortName : "API Model: \(viewModel.geminiService.customModelName)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    Text(viewModel.geminiService.customModelName.isEmpty
                                         ? selectedModel.subtitle
                                         : (viewModel.geminiService.discoveredModelDescriptions[viewModel.geminiService.customModelName] ?? "Model chọn trực tiếp từ danh sách API"))
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color.white.opacity(0.40))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AlignTheme.studioElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 1)
                            )
                        }
                    }

                    // Tùy chỉnh tên Model (OpenRouter / Custom Model ID)
                    HStack(spacing: 8) {
                        TextField("Hoặc nhập mã Model tùy chỉnh...", text: $customModelInput)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(8)
                            .background(AlignTheme.studioElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 1)
                            )

                        Button("Lưu Model") {
                            let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            viewModel.geminiService.customModelName = trimmed
                            toastMessage = trimmed.isEmpty ? "Đã chuyển về model mặc định" : "Đã kích hoạt model: \(trimmed)"
                        }
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(AlignTheme.studioAccent.opacity(0.30))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if !viewModel.geminiService.discoveredModels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Tìm nhanh trong \(viewModel.geminiService.discoveredModels.count) model từ API...", text: $modelSearchFilter)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white)
                                .textInputAutocapitalization(.never)
                                .padding(6)
                                .background(Color.black.opacity(0.35))
                                .cornerRadius(6)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    let filtered = viewModel.geminiService.discoveredModels.filter { modelID in
                                        if modelSearchFilter.isEmpty { return true }
                                        let desc = viewModel.geminiService.discoveredModelDescriptions[modelID] ?? ""
                                        return modelID.localizedCaseInsensitiveContains(modelSearchFilter)
                                            || desc.localizedCaseInsensitiveContains(modelSearchFilter)
                                    }.prefix(80)
                                    ForEach(Array(filtered), id: \.self) { modelID in
                                        let isPicked = viewModel.geminiService.activeModelID == modelID
                                        Button(action: {
                                            customModelInput = modelID
                                            viewModel.geminiService.customModelName = modelID
                                            if let matched = AIVisionModel.allCases.first(where: { $0.rawValue == modelID }) {
                                                selectedModel = matched
                                                viewModel.geminiService.selectedModel = matched
                                            }
                                            toastMessage = "Đã chọn model: \(modelID)"
                                        }) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(modelID)
                                                    .font(.system(size: 10.5, weight: isPicked ? .bold : .medium, design: .monospaced))
                                                    .foregroundColor(isPicked ? .white : Color.white.opacity(0.85))
                                                if let desc = viewModel.geminiService.discoveredModelDescriptions[modelID], !desc.isEmpty {
                                                    Text(desc)
                                                        .font(.system(size: 9, weight: .regular))
                                                        .foregroundColor(isPicked ? Color.white.opacity(0.85) : Color.white.opacity(0.50))
                                                        .lineLimit(1)
                                                }
                                            }
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(isPicked ? AlignTheme.studioAccent.opacity(0.35) : Color.white.opacity(0.09))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(isPicked ? AlignTheme.studioAccent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                // 4. Kiểm tra kết nối (Async Ping)
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
                            ProgressView().scaleEffect(0.8).tint(.white)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTestingKey ? "Đang kiểm tra kết nối..." : "Kiểm tra kết nối & độ trễ API")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(AlignTheme.studioAccent)
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

    // Card 4: Học thói quen bố cục (Composition Habit Store)
    private var compositionFeedbackCard: some View {
        SettingsSectionCard(title: "Học thói quen bố cục", icon: "square.and.pencil") {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI ghi nhớ kiểu khung bạn chọn để điều chỉnh nhẹ các gợi ý sau. File chỉ chứa ý đồ bố cục, vị trí và kích thước tương đối; không chứa ảnh, GPS hoặc đặc trưng khuôn mặt.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.65))

                if let url = feedbackExportURL {
                    ShareLink(item: url) {
                        Label("Xuất dữ liệu lựa chọn", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                    .id(feedbackRevision)
                }

                Button(role: .destructive) {
                    showDeleteFeedbackConfirmation = true
                } label: {
                    Label("Xóa dữ liệu học bố cục", systemImage: "trash")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                }
            }
            .padding(.vertical, 4)
            .confirmationDialog(
                "Xóa toàn bộ lựa chọn đã lưu?",
                isPresented: $showDeleteFeedbackConfirmation
            ) {
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

    private var dividerLine: some View {
        Divider().background(AlignTheme.studioHairlineSubtle)
    }
}

// MARK: - SECTION 3: ADVANCED, SYSTEM & LOGS (TAB 3)
struct AdvancedSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var showResetSessionConfirmation: Bool
    @Binding var toastMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            systemMotionCard
            systemLogsCard
            supportInfoCard
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

    // Card 2: Nhật ký hệ thống & Gỡ lỗi
    private var systemLogsCard: some View {
        SettingsSectionCard(title: "Nhật ký hệ thống & Gỡ lỗi", icon: "terminal.fill") {
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
                        .foregroundColor(.white)
                    ScrollView(.vertical) {
                        Text(CameraLogger.readRecentLogText(maxChars: 4000))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .padding(8)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(6)
                }

                Toggle(isOn: Binding(
                    get: { CompositionTuning.isDebugOverlayEnabled },
                    set: { CompositionTuning.isDebugOverlayEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hiển thị Debug Overlay bố cục")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Text("Hiện HUD đo zoom, target, face box và thông số AI trên kính ngắm")
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.55))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: AlignTheme.studioAccent))
                .padding(.vertical, 4)

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

                    Spacer()
                }

                Text("Ghi chú: Bạn có thể vào ứng dụng Tệp (Files) > Trên iPhone > AlignAI Studio để xem trực tiếp tệp alignai_crash_log.txt và alignai_debug_log.txt.")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color.white.opacity(0.45))
                    .padding(.top, 2)
            }
        }
    }

    // Card 3: Hỗ trợ & Thông tin bản quyền
    private var supportInfoCard: some View {
        SettingsSectionCard(title: "Hỗ trợ & Thông tin", icon: "info.circle.fill") {
            VStack(spacing: 0) {
                NavigationLink(destination: FeedbackView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("envelope.fill")

                        Text("Gửi góp ý & phản hồi")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                    .frame(minHeight: 52)
                }

                dividerLine

                NavigationLink(destination: SupportDeveloperView()) {
                    HStack(spacing: 12) {
                        SettingsRowIcon("cup.and.saucer.fill")

                        Text("Ủng hộ tác giả")
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                    .frame(minHeight: 52)
                }

                dividerLine

                VStack(spacing: 8) {
                    infoRow(label: "Tác giả", value: "ace4youblade ( VanKhoa )")
                    infoRow(label: "Liên hệ", value: "tranvantrinhhd@gmail.com")
                    infoRow(label: "Phiên bản", value: "Free (Build 2026.3)")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.70))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
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
        ScrollView {
            VStack(spacing: 16) {
                // Hero Header
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(AlignTheme.studioAccent.opacity(0.18))
                            .frame(width: 72, height: 72)

                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(AlignTheme.studioAccent)
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
                                .foregroundColor(AlignTheme.studioAccent)
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
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AlignTheme.studioAccent.opacity(0.25))
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
                            .foregroundColor(.white)
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
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.18))
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(20)
                                default:
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
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
