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
    case ai = "AI Bố cục"
    case advanced = "Nâng cao"

    public var id: String { rawValue }

    public var shortTitle: String { rawValue }

    public var icon: String {
        switch self {
        case .capture: return "camera.fill"
        case .ai: return "sparkles"
        case .advanced: return "gearshape.2.fill"
        }
    }
}

// MARK: - Main Settings View (Leica Studio Obsidian Edition)
public struct SettingsSheetView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsSheetTab = .capture
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

    // Design System Tokens (Leica Studio Obsidian)
    private let canvasBackground = Color(red: 12/255, green: 12/255, blue: 14/255)   // #0C0C0E
    private let cardBackground = Color(red: 24/255, green: 24/255, blue: 27/255)     // #18181B
    private let cardBorder = Color(red: 39/255, green: 39/255, blue: 42/255)         // #27272A
    private let accentCyan = Color(red: 56/255, green: 189/255, blue: 248/255)       // #38BDF8

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
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
            .sheet(isPresented: $viewModel.isShowingGyroCalibration) {
                GyroCalibrationSheetView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Navigation Header ("Cài đặt" on Left, "Xong" on Right)
    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Text("Cài đặt")
                .font(.system(size: 22, weight: .bold, design: .default))
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

    // MARK: - Segmented Tab Selector (Chụp • AI Bố cục • Nâng cao)
    private var tabSelectorPills: some View {
        HStack(spacing: 4) {
            ForEach(SettingsSheetTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    hapticSelection.prepare()
                    hapticSelection.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))

                        Text(tab.shortTitle)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? .white : Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 39/255, green: 39/255, blue: 42/255))
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
                        .stroke(cardBorder, lineWidth: 1)
                }
        )
        .frame(height: 46)
    }

    private func showToast(_ msg: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            toastMessage = msg
        }
    }
}

// MARK: - Dedicated Row Icon Component (Flat Vector SF Symbol 28x28)
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

// MARK: - Card Surface Component (16px CornerRadius, 1px Border #27272A)
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

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
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

            HStack(spacing: 4) {
                picker
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.35))
            }
        }
        .padding(.vertical, 6)
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.15))
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

// MARK: - Film Preset Pill Component
struct FilmPresetPill: View {
    let preset: FilmPreset
    let isSelected: Bool
    let onSelect: () -> Void

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
            .foregroundColor(isSelected ? .white : Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.24)) : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
            )
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
                    .stroke(isPicked ? Color.white : Color.clear, lineWidth: 2)
                    .padding(-2)
            )
            .shadow(color: isPicked ? color.swiftUIColor.opacity(0.60) : Color.clear, radius: 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Composition Rule Card Component
struct CompositionRuleCard: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.40))
                    .frame(width: 18)

                Text(rule.displayNameVietnamese)
                    .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.60))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 2)

                if isSelected {
                    Circle()
                        .fill(Color(red: 56/255, green: 189/255, blue: 248/255))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18)) : AnyShapeStyle(Color(red: 36/255, green: 36/255, blue: 41/255)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.70) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
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
                .font(.system(size: 13, weight: isPicked ? .bold : .medium, design: .rounded))
                .foregroundColor(isPicked ? .white : Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Capsule()
                        .fill(isPicked ? AnyShapeStyle(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.24)) : AnyShapeStyle(Color.white.opacity(0.06)))
                )
                .overlay(
                    Capsule()
                        .stroke(isPicked ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SECTION 1: PHOTO & VIDEO CAPTURE (TAB 1)
struct PhotoCaptureSettingsSection: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var toastMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    private let presetDevices = ["ALIGN STUDIO", "XIAOMI 15 ULTRA", "LEICA M11-P", "IPHONE 16 PRO"]

    var body: some View {
        VStack(spacing: 16) {
            photoStillCard
            videoCaptureCard
            cameraHardwareSpecsCard
            filmColorCard
            viewfinderHUDCard
            masterWatermarkCard
        }
    }

    // Card 1: Ảnh tĩnh & Định dạng
    private var photoStillCard: some View {
        SettingsSectionCard(title: "Ảnh tĩnh", icon: "camera.fill") {
            VStack(spacing: 0) {
                // Định dạng chụp: HEIF / JPEG / RAW
                HStack(spacing: 12) {
                    SettingsRowIcon("photo.fill", isActive: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Định dạng chụp")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255))
                        Text("Chuẩn lưu trữ hình ảnh cảm biến")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.48))
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 4) {
                        ForEach(PhotoSaveFormat.allCases) { format in
                            let label = (format == .dng ? "RAW" : format.rawValue)
                            pillSelectButton(label, isSelected: viewModel.selectedPhotoFormat == format) {
                                $viewModel.selectedPhotoFormat.wrappedValue = format
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(minHeight: 48)

                dividerLine

                SettingsToggleRow(
                    title: "Độ phân giải 48MP",
                    subtitle: "Khai thác tối đa điểm ảnh cảm biến nếu camera hỗ trợ",
                    icon: "sparkles.rectangle.stack.fill",
                    isOn: $viewModel.isSuperResolutionRAWEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Live Photo",
                    subtitle: "Ghi lại chuyển động ngắn trước và sau khi chụp",
                    icon: "livephoto",
                    isOn: $viewModel.isLivePhotoEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Lưu kèm bản gốc",
                    subtitle: "Giữ ảnh nguyên bản cảm biến không áp bộ lọc màu film",
                    icon: "photo.on.rectangle.angled",
                    isOn: $viewModel.isSaveOriginalPhotoEnabled
                )
            }
        }
    }

    // Card 2: Quay Video & Codec
    private var videoCaptureCard: some View {
        SettingsSectionCard(title: "Quay Video", icon: "video.fill") {
            VStack(spacing: 0) {
                SettingsPickerRow(
                    title: "Độ phân giải & Tốc độ",
                    subtitle: "Chuẩn video ghi hình cảm biến camera",
                    icon: "video.badge.waveform.fill",
                    selectedValueString: videoFormatCleanTitle(viewModel.selectedVideoFormatOption)
                ) {
                    Picker("", selection: $viewModel.selectedVideoFormatOption) {
                        ForEach(viewModel.supportedVideoFormatOptions) { opt in
                            Text(videoFormatCleanTitle(opt)).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
                }

                dividerLine

                SettingsPickerRow(
                    title: "Định dạng nén Codec",
                    subtitle: "Chuẩn mã hóa tối ưu phần cứng Apple",
                    icon: "cylinder.split.1x2.fill",
                    selectedValueString: viewModel.selectedVideoCodec.rawValue
                ) {
                    Picker("", selection: $viewModel.selectedVideoCodec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
                }
            }
        }
    }

    // Card 3: Thông số quang học (Hardware Optical Telemetry)
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
    private var filmColorCard: some View {
        SettingsSectionCard(title: "Màu sắc & Giả lập phim", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Tự động phân tích màu theo cảnh",
                    subtitle: "AI nhận diện bối cảnh để cân chỉnh độ tương phản và nhiệt độ màu",
                    icon: "wand.and.stars",
                    isOn: $viewModel.isAIFullColorEnabled
                )

                dividerLine

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
                    .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
                    .onChangeCompatible(of: viewModel.selectedFilmPreset) { newPreset in
                        viewModel.selectPreset(newPreset)
                    }
                }

                dividerLine

                Text("DANH SÁCH MẪU FILM NHANH:")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
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

    // Card 5: Khung ngắm & Báo nét HUD
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
                    dividerLine

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

                dividerLine

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

                dividerLine

                SettingsToggleRow(
                    title: "Khung nhận diện chủ thể",
                    subtitle: "Hiện bounding box xung quanh người, khuôn mặt hoặc đồ vật",
                    icon: "boundingbox",
                    isOn: $viewModel.showDetectionBoxes
                )

                dividerLine

                SettingsToggleRow(
                    title: "Thanh thông số & Biểu đồ HUD",
                    subtitle: "Hiển thị Shutter, ISO, Định dạng và Histogram trên màn hình chính",
                    icon: "chart.bar.fill",
                    isOn: $viewModel.showHistogramInViewfinder
                )

                if viewModel.showHistogramInViewfinder {
                    dividerLine

                    SettingsToggleRow(
                        title: "Mở rộng 32 cột màu báo cháy sáng",
                        subtitle: "Hiển thị dải quang phổ RGB và cảnh báo clipping ở vùng sáng",
                        icon: "waveform.path.ecg",
                        isOn: $viewModel.isHistogramBarExpanded
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                dividerLine

                SettingsToggleRow(
                    title: "Thước đo âm thanh (Audio VU Meter)",
                    subtitle: "Hiển thị 2 thanh đo mức tín hiệu âm thanh trực tiếp trong khung ngắm",
                    icon: "waveform",
                    isOn: $viewModel.showAudioLevelMeter
                )
            }
        }
    }

    // Card 6: Khung Chữ Ký Master (Watermark)
    private var masterWatermarkCard: some View {
        let hasCustomLogo = viewModel.masterWatermarkCustomLogoImage != nil
        let isCustomStyle = viewModel.masterWatermarkLogoStyle == .customImage

        return SettingsSectionCard(title: "Khung Chữ Ký Master", icon: "viewfinder.circle") {
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
                                    Text(hasCustomLogo ? "Đã chọn" : "Tự chọn")
                                        .font(.system(size: 11, weight: isCustomStyle ? .bold : .medium, design: .rounded))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isCustomStyle ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18) : Color.white.opacity(0.06))
                                )
                                .foregroundColor(isCustomStyle ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white.opacity(0.70))
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
                    .padding(.vertical, 8)

                    dividerLine

                    // Giao diện Khung
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GIAO DIỆN KHUNG")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.45))

                        HStack(spacing: 8) {
                            Button(action: {
                                viewModel.masterWatermarkTheme = .white
                            }) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.white).frame(width: 12, height: 12)
                                    Text("Cổ điển (Trắng)")
                                        .font(.system(size: 12, weight: viewModel.masterWatermarkTheme == .white ? .bold : .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(viewModel.masterWatermarkTheme == .white ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.20) : Color.white.opacity(0.06))
                                .foregroundColor(viewModel.masterWatermarkTheme == .white ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                viewModel.masterWatermarkTheme = .black
                            }) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(white: 0.15)).frame(width: 12, height: 12)
                                    Text("Đen nhám (Dark)")
                                        .font(.system(size: 12, weight: viewModel.masterWatermarkTheme == .black ? .bold : .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(viewModel.masterWatermarkTheme == .black ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.20) : Color.white.opacity(0.06))
                                .foregroundColor(viewModel.masterWatermarkTheme == .black ? Color(red: 56/255, green: 189/255, blue: 248/255) : Color.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // Helper: Peaking color picker row
    @ViewBuilder
    private var peakingColorPickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Màu viền báo nét:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 228/255, green: 228/255, blue: 231/255).opacity(0.75))
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

    // Helper: Telemetry badge
    private func telemetryBadge(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.48))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 36/255, green: 36/255, blue: 41/255))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
                )
        )
    }

    // Helper: Divider line
    private var dividerLine: some View {
        Divider()
            .background(Color(red: 39/255, green: 39/255, blue: 42/255))
    }

    // Helper: Pill select button
    private func pillSelectButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? .white : Color.white.opacity(0.60))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.24) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.70) : Color.clear, lineWidth: 1)
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

    // Helper: Clean title for video format option
    private func videoFormatCleanTitle(_ opt: VideoFormatOption) -> String {
        switch opt {
        case .uhd60: return "4K · 60 fps"
        case .uhd30: return "4K · 30 fps"
        case .hd60:  return "1080p · 60 fps"
        case .hd30:  return "1080p · 30 fps"
        @unknown default:
            return opt.rawValue
        }
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Độ nhạy bám chủ thể", systemImage: "bolt.badge.clock.fill")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Spacer()
                        Text(viewModel.trackingSensitivity.shortName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                    icon: "sparkles",
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
                    icon: "wand.and.stars",
                    isOn: $viewModel.isAIFullColorEnabled
                )
            }
        }
    }

    // Card 3: Động cơ AI & Kết nối Cloud (Multi-Provider 2026)
    private var aiEngineCloudCard: some View {
        SettingsSectionCard(title: "Động cơ AI & Kết nối Cloud", icon: "network.badge.shield.half.filled") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Ưu tiên Cloud AI (Tự động Fallback)",
                    subtitle: "Dùng Cloud AI khi có mạng & Key; tự chuyển sang Local AI trên máy nếu mất mạng",
                    icon: "sparkles.tv.fill",
                    isOn: $viewModel.useGeminiForAnalysis
                )

                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.useGeminiForAnalysis && viewModel.geminiService.hasAPIKey ? Color.green : Color(red: 56/255, green: 189/255, blue: 248/255))
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
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                                    isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.24) : Color(red: 36/255, green: 36/255, blue: 41/255)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSelected ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.70) : Color.white.opacity(0.08), lineWidth: 1)
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
                                .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
                                )

                            Button("Lưu URL") {
                                viewModel.geminiService.customEndpointURL = customEndpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                toastMessage = "Đã cập nhật Endpoint URL"
                            }
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.30))
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
                        .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
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
                        .background(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.35))
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
                                        .tint(Color(red: 56/255, green: 189/255, blue: 248/255))
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(viewModel.geminiService.isFetchingModels
                                     ? "Đang tải..."
                                     : (viewModel.geminiService.discoveredModels.isEmpty ? "Tải Model từ API" : "Làm mới (\(viewModel.geminiService.discoveredModels.count))"))
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.16))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Text(viewModel.geminiService.activeModelID)
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                            .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
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
                            .background(Color(red: 36/255, green: 36/255, blue: 41/255))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
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
                        .background(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.30))
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
                                                    .fill(isPicked ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.35) : Color.white.opacity(0.09))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(isPicked ? Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
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
                    .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
        Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))
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
                    title: "Chế độ đi đường (Street Tracking)",
                    subtitle: "Tăng cường độ mượt và bù trừ rung lắc khi vừa đi bộ vừa chụp",
                    icon: "figure.walk",
                    isOn: $viewModel.isStreetTrackingModeEnabled
                )

                dividerLine

                SettingsToggleRow(
                    title: "Âm thanh & Rung khi căn đúng",
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
                    title: "Hiệu chuẩn con quay hồi chuyển 60Hz",
                    subtitle: viewModel.lastGyroCalibrationDate != nil
                        ? "Đã tối ưu hóa IMU (Bù lệch Roll: \(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°)"
                        : "Khử trôi (Zero-bias) và cân chỉnh 3 trục xoay cho tracking 6DoF",
                    icon: "gyroscope",
                    badgeText: viewModel.lastGyroCalibrationDate != nil ? "\(String(format: "%+.1f", viewModel.gyroRollOffsetDegrees))°" : "Chưa cân"
                ) {
                    viewModel.isShowingGyroCalibration = true
                }

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
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 56/255, green: 189/255, blue: 248/255)))
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
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))

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
        Divider().background(Color(red: 39/255, green: 39/255, blue: 42/255))
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
                            .fill(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.18))
                            .frame(width: 72, height: 72)

                        Image(systemName: "cup.and.saucer.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                                .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
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
                            .background(Color(red: 56/255, green: 189/255, blue: 248/255).opacity(0.25))
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
        .background(Color(red: 12/255, green: 12/255, blue: 14/255).ignoresSafeArea())
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

// MARK: - TOAST BANNER NOTIFICATION
public struct ToastBanner: View {
    let message: String

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(red: 56/255, green: 189/255, blue: 248/255))
                .font(.system(size: 13, weight: .bold))

            Text(message)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(red: 24/255, green: 24/255, blue: 27/255))
                .overlay(
                    Capsule()
                        .stroke(Color(red: 39/255, green: 39/255, blue: 42/255), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 12, y: 6)
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
