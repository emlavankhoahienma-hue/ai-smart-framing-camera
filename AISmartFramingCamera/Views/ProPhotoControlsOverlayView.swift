import SwiftUI
import UIKit

// MARK: - Top Pro Photo Telemetry Strip (Real-Time Optical, Metering & Hardware Locks)
public struct ProPhotoTelemetryHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var pro: ProPhotoManualControlsService

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        self._pro = ObservedObject(wrappedValue: viewModel.proPhotoService)
    }

    private var apertureText: String {
        String(format: "f/%.1f", pro.hardwareLensAperture)
    }

    private var formatBadgeText: String {
        switch viewModel.selectedPhotoFormat {
        case .dng: return viewModel.isSuperResolutionRAWEnabled ? "RAW·\(pro.maxPhotoMegapixels)M" : "RAW"
        case .heif, .heic: return "HEIF"
        case .jpeg: return "JPG"
        }
    }

    private var meterColor: Color {
        let absOffset = abs(pro.measuredExposureTargetOffset)
        if absOffset <= 0.35 { return AlignTheme.studioPositive }
        if absOffset >= 1.45 { return AlignTheme.studioRecordRed }
        return AlignTheme.studioAccent
    }

    private var liveShutterDisplay: String {
        let sec = pro.isAutoShutter ? pro.measuredLiveShutterSeconds : pro.currentShutterSeconds
        return ProPhotoManualControlsService.formatShutter(sec, includeUnit: true)
    }

    private var liveISODisplay: String {
        let iso = pro.isAutoISO ? pro.measuredLiveISO : pro.currentISO
        return "\(Int(round(iso)))"
    }

    private var liveKelvinDisplay: String {
        if pro.isAutoWB && !pro.isHardwareCustomWBSupported {
            return pro.isWhiteBalanceLocked ? "AWB-L" : "AWB"
        }
        let k = pro.isAutoWB ? pro.measuredLiveKelvin : pro.currentKelvin
        return "\(Int((k / 50.0).rounded() * 50))K"
    }

    public var body: some View {
        VStack(spacing: 4.5) {
            // Hàng 1: Dải thông số quang học & phơi sáng trực tiếp (Tabular Monospace)
            HStack(spacing: 6) {
                // Huy hiệu chương trình phơi sáng (AUTO / S / ISO / M / AE-L)
                Text(pro.exposureProgram.rawValue)
                    .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                    .foregroundColor(pro.exposureProgram == .auto ? AlignTheme.studioInkPrimary : .black)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2.0)
                    .background(
                        Capsule()
                            .fill(pro.exposureProgram == .auto ? Color.white.opacity(0.14) : AlignTheme.studioAccent)
                    )

                // Tiêu cự quy đổi & Khẩu độ thực
                Text("\(pro.equivalentFocalLengthMM)mm")
                    .font(.system(size: 10.0, weight: .semibold, design: .monospaced))
                    .foregroundColor(AlignTheme.studioInkPrimary)

                Text(apertureText)
                    .font(.system(size: 10.0, weight: .medium, design: .monospaced))
                    .foregroundColor(AlignTheme.studioInkSecondary)

                telemetryDivider

                // Tốc độ màn trập & ISO thực
                Text(liveShutterDisplay)
                    .font(.system(size: 10.0, weight: pro.isAutoShutter ? .medium : .bold, design: .monospaced))
                    .foregroundColor(pro.isAutoShutter ? AlignTheme.studioInkPrimary : AlignTheme.studioAccent)

                Text("ISO \(liveISODisplay)")
                    .font(.system(size: 10.0, weight: pro.isAutoISO ? .medium : .bold, design: .monospaced))
                    .foregroundColor(pro.isAutoISO ? AlignTheme.studioInkPrimary : AlignTheme.studioAccent)

                telemetryDivider

                // Nhiệt độ màu Kelvin thực
                Text(liveKelvinDisplay)
                    .font(.system(size: 10.0, weight: pro.isAutoWB ? .medium : .bold, design: .monospaced))
                    .foregroundColor(pro.isAutoWB ? AlignTheme.studioInkSecondary : AlignTheme.studioAccent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.76)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StudioGlassCapsule(tintOpacity: 0.62, borderOpacity: 0.14))

            // Hàng 2: Thanh thao tác nhanh Pro (Định dạng · AE-L · AF-L · Thước đo sáng M.M. · Cảnh báo · Reset)
            HStack(spacing: 5) {
                // Chuyển nhanh định dạng JPG / HEIF / RAW DNG
                Button(action: {
                    viewModel.attemptFeature(.photoFormat) {
                        viewModel.togglePhotoFormat()
                    }
                }) {
                    Text(formatBadgeText)
                        .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.selectedPhotoFormat == .dng ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.90))
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 3.0)
                        .background(
                            Capsule()
                                .fill(viewModel.selectedPhotoFormat == .dng ? AlignTheme.studioAccentSoft : Color.black.opacity(0.42))
                                .overlay(
                                    Capsule()
                                        .stroke(viewModel.selectedPhotoFormat == .dng ? AlignTheme.studioAccentBorder : Color.white.opacity(0.14), lineWidth: 0.6)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đổi định dạng ảnh Pro")

                // Khóa AE-L
                if pro.isExposureLockSupported {
                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        pro.toggleExposureLock()
                    }) {
                        Text("AE-L")
                            .font(.system(size: 8.8, weight: .bold, design: .monospaced))
                            .foregroundColor(pro.isExposureLocked ? .black : AlignTheme.studioInkSecondary)
                            .padding(.horizontal, 6.0)
                            .padding(.vertical, 3.0)
                            .background(
                                Capsule()
                                    .fill(pro.isExposureLocked ? AlignTheme.studioAccent : Color.black.opacity(0.42))
                                    .overlay(
                                        Capsule()
                                            .stroke(pro.isExposureLocked ? AlignTheme.studioAccent : Color.white.opacity(0.12), lineWidth: 0.6)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Khóa phơi sáng AE-L")
                }

                // Khóa AF-L
                if pro.isFocusLockSupported {
                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        pro.toggleFocusLock()
                    }) {
                        Text("AF-L")
                            .font(.system(size: 8.8, weight: .bold, design: .monospaced))
                            .foregroundColor(pro.isFocusLocked ? .black : AlignTheme.studioInkSecondary)
                            .padding(.horizontal, 6.0)
                            .padding(.vertical, 3.0)
                            .background(
                                Capsule()
                                    .fill(pro.isFocusLocked ? AlignTheme.studioAccent : Color.black.opacity(0.42))
                                    .overlay(
                                        Capsule()
                                            .stroke(pro.isFocusLocked ? AlignTheme.studioAccent : Color.white.opacity(0.12), lineWidth: 0.6)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Khóa lấy nét AF-L")
                }

                // Thước đo sáng DSLR thực (`camera.exposureTargetOffset`)
                HStack(spacing: 4) {
                    Text("M.M")
                        .font(.system(size: 8.0, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkTertiary)

                    ProLightMeterMiniBar(offsetEV: pro.measuredExposureTargetOffset)
                        .frame(width: 44, height: 10)

                    Text(ProPhotoManualControlsService.formatEV(pro.measuredExposureTargetOffset))
                        .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                        .foregroundColor(meterColor)
                        .frame(minWidth: 26, alignment: .trailing)
                }
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2.8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.46))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                )

                // Cảnh báo phơi sáng/nhiễu/thiếu sáng gọn nhẹ
                if viewModel.histogramTelemetry.isHighlightClipping {
                    proAlertPill("CHÁY", color: AlignTheme.studioRecordRed)
                } else if viewModel.histogramTelemetry.isHighNoise {
                    proAlertPill("NHIỄU", color: AlignTheme.studioAccent)
                } else if pro.isHardwareLowLightBoostActive {
                    proAlertPill("ĐÊM", color: AlignTheme.studioAccent)
                }

                // Nút khôi phục AUTO 1 chạm khi đang có thông số thủ công
                if pro.hasAnyManualOverride {
                    Button(action: {
                        HapticFeedbackService.shared.triggerLight()
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            pro.resetToFullAuto()
                        }
                    }) {
                        HStack(spacing: 2.5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 8.0, weight: .bold))
                            Text("AUTO")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(AlignTheme.studioInkPrimary)
                        .padding(.horizontal, 6.0)
                        .padding(.vertical, 3.0)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Khôi phục toàn bộ thông số Pro về Tự động")
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
    }

    private var telemetryDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 0.6, height: 9)
    }

    private func proAlertPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.2, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(color.opacity(0.16))
                    .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.6))
            )
    }
}

// MARK: - DSLR Light Meter Mini Scale (-2 .. 0 .. +2 EV)
private struct ProLightMeterMiniBar: View {
    let offsetEV: Float

    var body: some View {
        Canvas { context, size in
            let ticks = 9 // -2, -1.5, -1, -0.5, 0, +0.5, +1, +1.5, +2
            let cy = size.height * 0.5
            for i in 0..<ticks {
                let t = CGFloat(i) / CGFloat(ticks - 1)
                let x = 2.0 + t * (size.width - 4.0)
                let isCenter = (i == 4)
                let isMajor = (i % 2 == 0)
                let h: CGFloat = isCenter ? 7.5 : (isMajor ? 5.0 : 3.0)
                let rect = CGRect(x: x - 0.5, y: cy - h * 0.5, width: 1.0, height: h)
                context.fill(
                    Path(rect),
                    with: .color(isCenter ? Color.white.opacity(0.75) : Color.white.opacity(0.26))
                )
            }

            let clamped = max(-2.0, min(2.0, Double(offsetEV.isFinite ? offsetEV : 0)))
            let norm = CGFloat((clamped + 2.0) / 4.0)
            let px = 2.0 + norm * (size.width - 4.0)
            let dotColor: Color = abs(clamped) <= 0.35
                ? AlignTheme.studioPositive
                : (abs(clamped) >= 1.45 ? AlignTheme.studioRecordRed : AlignTheme.studioAccent)
            let pointer = CGRect(x: px - 2.0, y: cy - 3.5, width: 4.0, height: 7.0)
            context.fill(Path(roundedRect: pointer, cornerRadius: 1.5), with: .color(dotColor))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bottom Unified Pro Photo Manual Control Deck
public struct ProPhotoManualDeckView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var pro: ProPhotoManualControlsService

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        self._pro = ObservedObject(wrappedValue: viewModel.proPhotoService)
    }

    public var body: some View {
        VStack(spacing: 6) {
            if viewModel.isProPhotoPanelExpanded {
                ProPhotoAdjustmentDrawer(viewModel: viewModel, pro: pro)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ViewfinderZoomSelectorPill(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            ProPhotoParameterBar(viewModel: viewModel, pro: pro)
        }
        .padding(.horizontal, 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: viewModel.isProPhotoPanelExpanded)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: viewModel.selectedProPhotoTab)
    }
}

// MARK: - 7-Column Smoked Glass Pro Parameter Bar (EV · SS · ISO · WB · MF · MÀU · PRO)
private struct ProPhotoParameterBar: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var pro: ProPhotoManualControlsService

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProPhotoParameterTab.allCases) { tab in
                let isSelected = viewModel.isProPhotoPanelExpanded && viewModel.selectedProPhotoTab == tab
                let isManual = isTabOverridden(tab)

                Button(action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        if viewModel.isProPhotoPanelExpanded && viewModel.selectedProPhotoTab == tab {
                            viewModel.isProPhotoPanelExpanded = false
                        } else {
                            viewModel.selectedProPhotoTab = tab
                            viewModel.isProPhotoPanelExpanded = true
                        }
                    }
                }) {
                    VStack(spacing: 2.5) {
                        HStack(spacing: 2) {
                            Text(tab.rawValue)
                                .font(.system(size: 8.2, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)

                            if isManual {
                                Circle()
                                    .fill(AlignTheme.studioAccent)
                                    .frame(width: 3.5, height: 3.5)
                            }
                        }

                        Text(valueText(for: tab))
                            .font(.system(size: 9.8, weight: isManual || isSelected ? .bold : .medium, design: .monospaced))
                            .foregroundColor(isManual || isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkPrimary.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? AlignTheme.studioAccentSoft : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(isSelected ? AlignTheme.studioAccentBorder : Color.clear, lineWidth: 0.75)
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.vietnameseTitle): \(valueText(for: tab))")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3.5)
        .background(StudioGlassRoundedSurface(cornerRadius: 14, tintOpacity: 0.68, borderOpacity: 0.14))
    }

    private func isTabOverridden(_ tab: ProPhotoParameterTab) -> Bool {
        switch tab {
        case .ev: return abs(pro.currentEVBias) >= 0.05
        case .shutter: return !pro.isAutoShutter
        case .iso: return !pro.isAutoISO
        case .wb: return !pro.isAutoWB || pro.isWhiteBalanceLocked
        case .focus: return !pro.isAutoFocus || pro.isFocusLocked || pro.afRangeMode != .full
        case .film: return viewModel.isFilmSimulationActive || !viewModel.filmTuning.isIdentity
        case .hardware: return viewModel.selectedPhotoFormat == .dng || viewModel.isFocusPeakingEnabled || pro.torchLevel >= 0.05
        }
    }

    private func valueText(for tab: ProPhotoParameterTab) -> String {
        switch tab {
        case .ev:
            return ProPhotoManualControlsService.formatEV(pro.currentEVBias)
        case .shutter:
            let sec = pro.isAutoShutter ? pro.measuredLiveShutterSeconds : pro.currentShutterSeconds
            return ProPhotoManualControlsService.formatShutter(sec, includeUnit: false)
        case .iso:
            let iso = pro.isAutoISO ? pro.measuredLiveISO : pro.currentISO
            return "\(Int(round(iso)))"
        case .wb:
            if pro.isAutoWB && !pro.isHardwareCustomWBSupported {
                return pro.isWhiteBalanceLocked ? "AWB-L" : "AWB"
            }
            let k = pro.isAutoWB ? pro.measuredLiveKelvin : pro.currentKelvin
            return ProPhotoManualControlsService.formatKelvinShort(k)
        case .focus:
            if pro.isFocusLocked { return "AF-L" }
            if pro.isAutoFocus {
                return pro.afRangeMode == .full ? "AF" : pro.afRangeMode.shortLabel
            }
            return pro.currentLensPosition >= 0.96 ? "∞" : String(format: "%.2f", pro.currentLensPosition)
        case .film:
            if viewModel.isFilmSimulationActive {
                return viewModel.selectedFilmPreset.shortTitle
            }
            return viewModel.filmTuning.isIdentity ? "GỐC" : "TÙY"
        case .hardware:
            switch viewModel.selectedPhotoFormat {
            case .dng: return "RAW"
            case .heif, .heic: return "HEIF"
            case .jpeg: return "JPG"
            }
        }
    }
}

/// Các trục tinh chỉnh công thức giả lập phim (dùng chung cho cả Chế độ Pro và Ngăn kéo Màu Phim).
public enum FilmTuningAxis: String, CaseIterable, Identifiable, Sendable {
    case intensity = "Cường độ"
    case contrast = "Tương phản"
    case saturation = "Bão hòa"
    case warmth = "Độ ấm"
    case highlights = "Vùng sáng"
    case shadows = "Vùng tối"
    case fade = "Độ phai"
    case halation = "Quầng sáng"
    case grain = "Hạt phim"
    case vignette = "Viền tối"

    public var id: String { rawValue }

    public var isBipolar: Bool {
        switch self {
        case .intensity, .fade, .halation, .grain, .vignette: return false
        default: return true
        }
    }

    public func normalizedValue(intensity: Double, tuning: FilmSimulationTuning) -> Double {
        switch self {
        case .intensity: return max(0, min(1, (intensity - 0.1) / 0.9))
        case .contrast: return max(0, min(1, (Double(tuning.contrast) + 0.35) / 0.70))
        case .saturation: return max(0, min(1, (Double(tuning.saturation) + 0.50) / 1.00))
        case .warmth: return max(0, min(1, (Double(tuning.warmth) + 0.50) / 1.00))
        case .highlights: return max(0, min(1, (Double(tuning.highlights) + 0.40) / 0.80))
        case .shadows: return max(0, min(1, (Double(tuning.shadows) + 0.40) / 0.80))
        case .fade: return max(0, min(1, Double(tuning.fade)))
        case .halation: return max(0, min(1, Double(tuning.halation)))
        case .grain: return max(0, min(1, Double(tuning.grain)))
        case .vignette: return max(0, min(1, Double(tuning.vignette)))
        }
    }

    @MainActor
    public func applyNormalized(_ norm: Double, to viewModel: CameraViewModel) {
        let t = max(0.0, min(1.0, norm))
        switch self {
        case .intensity:
            let val = 0.1 + t * 0.9
            viewModel.filmSimulationIntensity = (val * 20.0).rounded() / 20.0
        case .contrast:
            let v = Float(-0.35 + t * 0.70)
            viewModel.filmTuning.contrast = abs(v) < 0.015 ? 0 : v
        case .saturation:
            let v = Float(-0.50 + t * 1.00)
            viewModel.filmTuning.saturation = abs(v) < 0.02 ? 0 : v
        case .warmth:
            let v = Float(-0.50 + t * 1.00)
            viewModel.filmTuning.warmth = abs(v) < 0.02 ? 0 : v
        case .highlights:
            let v = Float(-0.40 + t * 0.80)
            viewModel.filmTuning.highlights = abs(v) < 0.015 ? 0 : v
        case .shadows:
            let v = Float(-0.40 + t * 0.80)
            viewModel.filmTuning.shadows = abs(v) < 0.015 ? 0 : v
        case .fade:
            viewModel.filmTuning.fade = t < 0.02 ? 0 : Float(t)
        case .halation:
            viewModel.filmTuning.halation = t < 0.02 ? 0 : Float(t)
        case .grain:
            viewModel.filmTuning.grain = t < 0.02 ? 0 : Float(t)
        case .vignette:
            viewModel.filmTuning.vignette = t < 0.02 ? 0 : Float(t)
        }
    }

    public func displayValue(intensity: Double, tuning: FilmSimulationTuning) -> String {
        switch self {
        case .intensity:
            return "\(Int(round(intensity * 100)))%"
        case .contrast:
            let p = Int(round(tuning.contrast * 100))
            return p == 0 ? "0" : String(format: "%+d", p)
        case .saturation:
            let p = Int(round(tuning.saturation * 100))
            return p == 0 ? "0" : String(format: "%+d", p)
        case .warmth:
            let p = Int(round(tuning.warmth * 100))
            return p == 0 ? "0" : String(format: "%+d", p)
        case .highlights:
            let p = Int(round(tuning.highlights * 100))
            return p == 0 ? "0" : String(format: "%+d", p)
        case .shadows:
            let p = Int(round(tuning.shadows * 100))
            return p == 0 ? "0" : String(format: "%+d", p)
        case .fade:
            return "\(Int(round(tuning.fade * 100)))%"
        case .halation:
            return "\(Int(round(tuning.halation * 100)))%"
        case .grain:
            return "\(Int(round(tuning.grain * 100)))%"
        case .vignette:
            return "\(Int(round(tuning.vignette * 100)))%"
        }
    }

    public func isModified(intensity: Double, tuning: FilmSimulationTuning, isFilmActive: Bool) -> Bool {
        switch self {
        case .intensity: return isFilmActive && abs(intensity - 1.0) >= 0.04
        case .contrast: return abs(tuning.contrast) >= 0.01
        case .saturation: return abs(tuning.saturation) >= 0.01
        case .warmth: return abs(tuning.warmth) >= 0.01
        case .highlights: return abs(tuning.highlights) >= 0.01
        case .shadows: return abs(tuning.shadows) >= 0.01
        case .fade: return tuning.fade >= 0.01
        case .halation: return tuning.halation >= 0.01
        case .grain: return tuning.grain >= 0.01
        case .vignette: return tuning.vignette >= 0.01
        }
    }
}

// MARK: - Collapsible Precision Adjustment Drawer
private struct ProPhotoAdjustmentDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var pro: ProPhotoManualControlsService
    @State private var filmSubMode: FilmSubMode = .preset
    @State private var selectedTuningAxis: FilmTuningAxis = .contrast

    private enum FilmSubMode: String, CaseIterable {
        case preset = "Preset"
        case tune = "Tinh chỉnh"
    }

    private struct FocusStopPreset: Identifiable {
        let label: String
        let val: Float
        var id: String { label }
    }

    private static let focusStops: [FocusStopPreset] = [
        FocusStopPreset(label: "Cận", val: 0.05),
        FocusStopPreset(label: "0.35", val: 0.35),
        FocusStopPreset(label: "0.65", val: 0.65),
        FocusStopPreset(label: "∞", val: 1.0)
    ]

    var body: some View {
        VStack(spacing: 8) {
            // Header gọn của bảng chỉnh
            HStack(spacing: 8) {
                Image(systemName: viewModel.selectedProPhotoTab.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(AlignTheme.studioAccent)

                Text(viewModel.selectedProPhotoTab.vietnameseTitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkPrimary)

                Text(activeHeaderValue)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(AlignTheme.studioAccent)

                Spacer()

                if let autoToggle = autoToggleConfig {
                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        autoToggle.toggle()
                    }) {
                        Text(autoToggle.label)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(autoToggle.isAuto ? .black : AlignTheme.studioInkPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(autoToggle.isAuto ? AlignTheme.studioAccent : Color.white.opacity(0.11))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    HapticFeedbackService.shared.triggerLight()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.84)) {
                        viewModel.isProPhotoPanelExpanded = false
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thu gọn bảng chỉnh Pro")
            }

            // Nội dung từng nhóm thông số
            switch viewModel.selectedProPhotoTab {
            case .ev:
                evPanel
            case .shutter:
                shutterPanel
            case .iso:
                isoPanel
            case .wb:
                wbPanel
            case .focus:
                focusPanel
            case .film:
                filmPanel
            case .hardware:
                hardwarePanel
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(StudioGlassRoundedSurface(cornerRadius: 16, tintOpacity: 0.78, borderOpacity: 0.14))
    }

    private var activeHeaderValue: String {
        switch viewModel.selectedProPhotoTab {
        case .ev:
            return "\(ProPhotoManualControlsService.formatEV(pro.currentEVBias)) EV"
        case .shutter:
            let sec = pro.isAutoShutter ? pro.measuredLiveShutterSeconds : pro.currentShutterSeconds
            return ProPhotoManualControlsService.formatShutter(sec, includeUnit: true)
        case .iso:
            let iso = pro.isAutoISO ? pro.measuredLiveISO : pro.currentISO
            return "ISO \(Int(round(iso)))"
        case .wb:
            if pro.isAutoWB && !pro.isHardwareCustomWBSupported {
                return pro.isWhiteBalanceLocked ? "AWB-L" : "AWB"
            }
            let k = pro.isAutoWB ? pro.measuredLiveKelvin : pro.currentKelvin
            let t = pro.isAutoWB ? pro.measuredLiveTint : pro.currentTint
            let tintStr = Int(round(t)) == 0 ? "0" : String(format: "%+d", Int(round(t)))
            return "\(Int((k / 50.0).rounded() * 50))K · T\(tintStr)"
        case .focus:
            if pro.isAutoFocus {
                return pro.isFocusLocked ? "AF-L" : "AF · \(pro.afRangeMode.shortLabel)"
            }
            return pro.currentLensPosition >= 0.96 ? "∞" : String(format: "%.2f", pro.currentLensPosition)
        case .film:
            if viewModel.isFilmSimulationActive {
                return "\(viewModel.selectedFilmPreset.displayName) · \(Int(round(viewModel.filmSimulationIntensity * 100)))%"
            }
            return viewModel.filmTuning.isIdentity ? "Tự nhiên" : "Tùy chỉnh"
        case .hardware:
            return "\(pro.activeLensDisplayName) · \(pro.maxPhotoMegapixels)MP"
        }
    }

    private var autoToggleConfig: (label: String, isAuto: Bool, toggle: () -> Void)? {
        switch viewModel.selectedProPhotoTab {
        case .ev:
            return ("0 EV", abs(pro.currentEVBias) < 0.05, { pro.setManualEVBias(0) })
        case .shutter:
            return ("AUTO", pro.isAutoShutter, { pro.setAutoShutter(!pro.isAutoShutter) })
        case .iso:
            return ("AUTO", pro.isAutoISO, { pro.setAutoISO(!pro.isAutoISO) })
        case .wb:
            return ("AWB", pro.isAutoWB && !pro.isWhiteBalanceLocked, { pro.setAutoWB(!pro.isAutoWB) })
        case .focus:
            return ("AF", pro.isAutoFocus, { pro.setAutoFocus(!pro.isAutoFocus) })
        case .film:
            let hasAnyColor = viewModel.isFilmSimulationActive || !viewModel.filmTuning.isIdentity
            return ("GỐC", !hasAnyColor, { viewModel.resetToNaturalColor() })
        case .hardware:
            return nil
        }
    }

    // MARK: - 1. EV Compensation Panel
    private var evPanel: some View {
        VStack(spacing: 7) {
            let span = max(0.2, Double(pro.maxEVBias - pro.minEVBias))
            let norm = max(0, min(1, Double(pro.currentEVBias - pro.minEVBias) / span))

            ProPrecisionRulerDial(
                normalizedValue: norm,
                tickCount: 31,
                majorEvery: 5,
                centerHighlight: true,
                onChanged: { newNorm in
                    let raw = Double(pro.minEVBias) + newNorm * span
                    let stepped = (raw * 10.0).rounded() / 10.0
                    pro.setManualEVBias(Float(stepped))
                }
            )

            HStack(spacing: 5) {
                ForEach([-2.0, -1.0, 0.0, 1.0, 2.0], id: \.self) { stop in
                    let fStop = Float(stop)
                    if fStop >= pro.minEVBias - 0.05 && fStop <= pro.maxEVBias + 0.05 {
                        let isActive = abs(pro.currentEVBias - fStop) < 0.08
                        presetChip(
                            label: stop == 0 ? "0" : String(format: "%+.0f", stop),
                            isActive: isActive,
                            action: { pro.setManualEVBias(fStop) }
                        )
                    }
                }
            }

            if !pro.isAutoISO || !pro.isAutoShutter {
                Text("Kéo EV sẽ chuyển phơi sáng sang Auto + Bù sáng theo chuẩn Apple AVFoundation.")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: - 2. Shutter Speed Panel
    private var shutterPanel: some View {
        VStack(spacing: 7) {
            if !pro.isCustomExposureSupported {
                unsupportedNotice("Ống kính hiện tại không hỗ trợ chỉnh tốc độ thủ công.")
            } else {
                let minD = max(1.0 / 16000.0, pro.minShutterSeconds)
                let maxD = max(minD * 1.1, pro.maxShutterSeconds)
                let activeSec = pro.isAutoShutter ? pro.measuredLiveShutterSeconds : pro.currentShutterSeconds
                let logRatio = log2(maxD / minD)
                let norm = logRatio > 0
                    ? max(0, min(1, log2(maxD / max(minD, min(maxD, activeSec))) / logRatio))
                    : 0.5

                ProPrecisionRulerDial(
                    normalizedValue: norm,
                    tickCount: 37,
                    majorEvery: 6,
                    centerHighlight: false,
                    onChanged: { newNorm in
                        let sec = maxD / pow(2.0, newNorm * logRatio)
                        pro.setManualShutterSeconds(sec)
                    }
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(pro.supportedShutterStops, id: \.self) { stopSec in
                            let isActive = !pro.isAutoShutter && abs(log2(max(1e-6, pro.currentShutterSeconds / stopSec))) < 0.25
                            presetChip(
                                label: ProPhotoManualControlsService.formatShutter(stopSec, includeUnit: false),
                                isActive: isActive,
                                action: { pro.setManualShutterSeconds(stopSec) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3. ISO Panel
    private var isoPanel: some View {
        VStack(spacing: 7) {
            if !pro.isCustomExposureSupported {
                unsupportedNotice("Ống kính hiện tại không hỗ trợ chỉnh ISO thủ công.")
            } else {
                let lo = max(20.0, Double(pro.minISO))
                let hi = max(lo * 1.1, Double(pro.maxISO))
                let activeISO = Double(pro.isAutoISO ? pro.measuredLiveISO : pro.currentISO)
                let logSpan = log2(hi / lo)
                let norm = logSpan > 0
                    ? max(0, min(1, log2(max(lo, min(hi, activeISO)) / lo) / logSpan))
                    : 0.0

                ProPrecisionRulerDial(
                    normalizedValue: norm,
                    tickCount: 33,
                    majorEvery: 4,
                    centerHighlight: false,
                    onChanged: { newNorm in
                        let targetISO = lo * pow(2.0, newNorm * logSpan)
                        pro.setManualISO(Float(targetISO.rounded()))
                    }
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(pro.supportedISOStops, id: \.self) { stopISO in
                            let isActive = !pro.isAutoISO && abs(pro.currentISO - stopISO) <= max(8, stopISO * 0.12)
                            presetChip(
                                label: "\(Int(stopISO))",
                                isActive: isActive,
                                action: { pro.setManualISO(stopISO) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. White Balance (Kelvin + Tint + Khóa AWB / Gray World — an toàn 100% mọi dòng iPhone)
    private var wbPanel: some View {
        VStack(spacing: 7) {
            let kSpan = Double(pro.maxKelvin - pro.minKelvin)
            let activeK = Double(pro.isAutoWB ? (pro.isHardwareCustomWBSupported ? pro.measuredLiveKelvin : 5500) : pro.currentKelvin)
            let kNorm = max(0, min(1, (activeK - Double(pro.minKelvin)) / max(1, kSpan)))

            // Thước Kelvin chuẩn máy ảnh: Trái 2500K (Lạnh xanh) → Giữa 5500K → Phải 9500K (Ấm vàng)
            ProPrecisionRulerDial(
                normalizedValue: kNorm,
                tickCount: 35,
                majorEvery: 7,
                centerHighlight: false,
                accentHairline: LinearGradient(
                    colors: [
                        Color(red: 0.52, green: 0.74, blue: 0.98).opacity(0.72),
                        Color.white.opacity(0.36),
                        Color(red: 0.96, green: 0.68, blue: 0.34).opacity(0.72)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                onChanged: { newNorm in
                    let rawK = Double(pro.minKelvin) + newNorm * kSpan
                    let stepped = (rawK / 50.0).rounded() * 50.0
                    pro.setManualWhiteBalance(kelvin: Float(stepped))
                }
            )

            // Thước Sắc độ Tint (-50 Xanh lá ↔ 0 ↔ +50 Hồng tím) thuần Canvas 60 FPS (tránh lỗi Slider)
            HStack(spacing: 8) {
                Text("Sắc độ")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .frame(width: 38, alignment: .leading)

                let activeTint = Double(pro.isAutoWB ? (pro.isHardwareCustomWBSupported ? pro.measuredLiveTint : 0) : pro.currentTint)
                let tintSpan = max(1.0, Double(pro.maxTint - pro.minTint))
                let tintNorm = max(0, min(1, (activeTint - Double(pro.minTint)) / tintSpan))

                ProPrecisionRulerDial(
                    normalizedValue: tintNorm,
                    tickCount: 21,
                    majorEvery: 5,
                    centerHighlight: true,
                    accentHairline: LinearGradient(
                        colors: [
                            Color(red: 0.38, green: 0.84, blue: 0.56).opacity(0.60),
                            Color.white.opacity(0.28),
                            Color(red: 0.90, green: 0.44, blue: 0.76).opacity(0.60)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    onChanged: { newNorm in
                        let rawT = Double(pro.minTint) + newNorm * tintSpan
                        let rounded = rawT.rounded()
                        pro.setManualTint(abs(rounded) <= 1 ? 0 : Float(rounded))
                    }
                )
                .frame(height: 24)

                Button(action: {
                    HapticFeedbackService.shared.triggerLight()
                    if pro.isHardwareCustomWBSupported {
                        pro.applyGrayWorldNeutralWB()
                    } else {
                        pro.toggleWhiteBalanceLock()
                    }
                }) {
                    let isLockActive = !pro.isHardwareCustomWBSupported && pro.isWhiteBalanceLocked
                    Text(pro.isHardwareCustomWBSupported ? "Xám" : (isLockActive ? "AWB-L" : "Khóa AWB"))
                        .font(.system(size: 9.0, weight: .bold, design: .rounded))
                        .foregroundColor(isLockActive ? .black : AlignTheme.studioInkPrimary)
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 3.8)
                        .background(
                            Capsule()
                                .fill(isLockActive ? AlignTheme.studioAccent : Color.white.opacity(0.11))
                                .overlay(Capsule().stroke(isLockActive ? AlignTheme.studioAccent : Color.white.opacity(0.16), lineWidth: 0.6))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pro.isHardwareCustomWBSupported ? "Cân bằng trắng chuẩn xám Gray World" : "Khóa cân bằng trắng AWB phần cứng")
            }

            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(ProPhotoManualControlsService.standardWBPresets) { preset in
                            let isActive = !pro.isAutoWB && abs(pro.currentKelvin - preset.kelvin) < 150
                            presetChip(
                                label: preset.label,
                                isActive: isActive,
                                action: { pro.setManualWhiteBalance(kelvin: preset.kelvin, tint: 0) }
                            )
                        }
                    }
                }
            }

            if !pro.isHardwareCustomWBSupported {
                Text(viewModel.selectedPhotoFormat == .dng
                     ? "Ống kính đa tiêu cự: Khóa AWB phần cứng; Kelvin/Tint GPU áp dụng cho JPG/HEIF (RAW giữ cảm biến gốc)."
                     : "Ống kính đa tiêu cự: Khóa AWB phần cứng · Chỉnh Kelvin/Tint GPU theo thời gian thực.")
                    .font(.system(size: 8.8, weight: .regular))
                    .foregroundColor(AlignTheme.studioInkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    // MARK: - 5B. Film Simulation & Recipe Fine-Tuning Panel (62 Presets + 8 Trục Tinh Chỉnh GPU)
    private var filmPanel: some View {
        VStack(spacing: 7) {
            if viewModel.selectedPhotoFormat == .dng {
                HStack(spacing: 8) {
                    Text("File RAW DNG giữ màu cảm biến nguyên bản.")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .lineLimit(2)
                    Spacer()
                    presetChip(label: "Đổi HEIF", isActive: true) {
                        viewModel.selectedPhotoFormat = .heif
                    }
                }
                .padding(.vertical, 4)
            } else {
                // Chuyển nhanh giữa Chọn Preset và Tinh chỉnh công thức
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(FilmSubMode.allCases, id: \.self) { mode in
                            let active = filmSubMode == mode
                            Button(action: {
                                HapticFeedbackService.shared.triggerSelectionChange()
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    filmSubMode = mode
                                    if mode == .tune && selectedTuningAxis == .intensity && !viewModel.isFilmSimulationActive {
                                        selectedTuningAxis = .contrast
                                    }
                                }
                            }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 9.5, weight: active ? .bold : .medium, design: .rounded))
                                    .foregroundColor(active ? .black : AlignTheme.studioInkSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(active ? AlignTheme.studioAccent : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )

                    Spacer()

                    if filmSubMode == .tune && !viewModel.filmTuning.isIdentity {
                        Button(action: {
                            viewModel.resetFilmTuning()
                        }) {
                            Text("Đặt lại")
                                .font(.system(size: 9.2, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    } else if filmSubMode == .preset && viewModel.isFilmSimulationActive {
                        Text("\(Int(round(viewModel.filmSimulationIntensity * 100)))%")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                }

                if filmSubMode == .preset {
                    // Dải chọn nhóm máy phim
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(FilmPresetCategory.allCases) { category in
                                let isSelected = viewModel.selectedFilmCategory == category
                                presetChip(
                                    label: category.displayName,
                                    isActive: isSelected,
                                    action: { viewModel.selectFilmCategory(category) }
                                )
                            }
                        }
                    }

                    // Dải chọn từng Preset màu phim
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            presetChip(
                                label: "Tắt màu",
                                isActive: !viewModel.isFilmSimulationActive,
                                action: { viewModel.disableFilmSimulation() }
                            )

                            ForEach(viewModel.selectedFilmCategory.presets) { preset in
                                let isSelected = viewModel.isFilmSimulationActive && viewModel.selectedFilmPreset == preset
                                presetChip(
                                    label: preset.shortTitle,
                                    isActive: isSelected,
                                    action: { viewModel.selectPreset(preset) }
                                )
                            }
                        }
                    }
                } else {
                    // Tinh chỉnh 8 trục giả lập thời gian thực bằng thước xúc giác 60 FPS
                    let availableAxes: [FilmTuningAxis] = viewModel.isFilmSimulationActive
                        ? FilmTuningAxis.allCases
                        : FilmTuningAxis.allCases.filter { $0 != .intensity }
                    let currentAxis = availableAxes.contains(selectedTuningAxis) ? selectedTuningAxis : .contrast

                    HStack(spacing: 6) {
                        Text(currentAxis.rawValue)
                            .font(.system(size: 10.0, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkSecondary)
                        Spacer()
                        Text(currentAxis.displayValue(intensity: viewModel.filmSimulationIntensity, tuning: viewModel.filmTuning))
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(AlignTheme.studioAccent)
                    }

                    ProPrecisionRulerDial(
                        normalizedValue: currentAxis.normalizedValue(intensity: viewModel.filmSimulationIntensity, tuning: viewModel.filmTuning),
                        tickCount: 31,
                        majorEvery: 5,
                        centerHighlight: currentAxis.isBipolar,
                        onChanged: { newNorm in
                            currentAxis.applyNormalized(newNorm, to: viewModel)
                        }
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(availableAxes) { axis in
                                let isSelected = (axis == currentAxis)
                                let isEdited = axis.isModified(
                                    intensity: viewModel.filmSimulationIntensity,
                                    tuning: viewModel.filmTuning,
                                    isFilmActive: viewModel.isFilmSimulationActive
                                )
                                Button(action: {
                                    HapticFeedbackService.shared.triggerSelectionChange()
                                    selectedTuningAxis = axis
                                }) {
                                    HStack(spacing: 3.5) {
                                        if isEdited {
                                            Circle()
                                                .fill(isSelected ? .black : AlignTheme.studioAccent)
                                                .frame(width: 4, height: 4)
                                        }
                                        Text(axis.rawValue)
                                            .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                    }
                                    .foregroundColor(isSelected ? .black : AlignTheme.studioInkPrimary.opacity(0.84))
                                    .padding(.horizontal, 8.5)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? AlignTheme.studioAccent : Color.white.opacity(0.08))
                                            .overlay(
                                                Capsule()
                                                    .stroke(isSelected ? AlignTheme.studioAccent : Color.white.opacity(0.11), lineWidth: 0.6)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. Manual Focus + AF Range + Focus Peaking Panel
    private var focusPanel: some View {
        VStack(spacing: 7) {
            if pro.isManualFocusSupported {
                let activePos = Double(pro.isAutoFocus ? pro.measuredLiveLensPosition : pro.currentLensPosition)
                ProPrecisionRulerDial(
                    normalizedValue: max(0, min(1, activePos)),
                    tickCount: 31,
                    majorEvery: 5,
                    centerHighlight: false,
                    onChanged: { newNorm in
                        pro.setManualFocus(Float(newNorm))
                    }
                )
            } else {
                unsupportedNotice("Camera hiện tại không hỗ trợ kéo nét thủ công (ống kính lấy nét cố định).")
            }

            HStack(spacing: 5) {
                if pro.isManualFocusSupported {
                    ForEach(Self.focusStops) { stop in
                        let isActive = !pro.isAutoFocus && abs(pro.currentLensPosition - stop.val) < 0.06
                        presetChip(
                            label: stop.label,
                            isActive: isActive,
                            action: { pro.setManualFocus(stop.val) }
                        )
                    }
                }

                Spacer(minLength: 2)

                // Bật nhanh Focus Peaking ngay trong tab Lấy nét
                let peakingAvail = viewModel.featureAvailability(.focusPeaking)
                Button(action: {
                    viewModel.attemptFeature(.focusPeaking) {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        viewModel.isFocusPeakingEnabled.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isFocusPeakingEnabled ? viewModel.focusPeakingColor.swiftUIColor : Color.white.opacity(0.32))
                            .frame(width: 6, height: 6)
                        Text("Báo nét")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(viewModel.isFocusPeakingEnabled ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        Capsule()
                            .fill(viewModel.isFocusPeakingEnabled ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .stroke(viewModel.isFocusPeakingEnabled ? AlignTheme.studioAccentBorder : Color.white.opacity(0.10), lineWidth: 0.6)
                            )
                    )
                    .opacity(peakingAvail.isAvailable ? 1.0 : 0.35)
                }
                .buttonStyle(.plain)
            }

            // Vùng lấy nét tự động (Apple AutoFocusRangeRestriction: Toàn dải / Gần / Xa)
            if pro.isAFRangeSupported {
                HStack(spacing: 6) {
                    Text("Vùng AF")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(AlignTheme.studioInkSecondary)

                    Spacer()

                    ForEach(ProPhotoAFRangeMode.allCases) { mode in
                        let isActive = pro.isAutoFocus && pro.afRangeMode == mode
                        presetChip(
                            label: mode.shortLabel,
                            isActive: isActive,
                            action: { pro.setAFRangeMode(mode) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 6. Apple Pro Hardware Assists Panel
    private var hardwarePanel: some View {
        let formatLabel: String = {
            switch viewModel.selectedPhotoFormat {
            case .dng: return "RAW DNG"
            case .heif, .heic: return "HEIF"
            case .jpeg: return "JPEG"
            }
        }()

        let torchText: String = pro.torchLevel < 0.05
            ? "Tắt"
            : "\(Int((pro.torchLevel * 100).rounded()))%"

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            hardwareTile(
                icon: "doc.plaintext",
                title: "Định dạng",
                value: formatLabel,
                isActive: viewModel.selectedPhotoFormat == .dng,
                isSupported: true,
                action: {
                    viewModel.attemptFeature(.photoFormat) {
                        viewModel.togglePhotoFormat()
                    }
                }
            )

            hardwareTile(
                icon: "camera.metering.matrix",
                title: "Phân giải cao",
                value: viewModel.isSuperResolutionRAWEnabled ? "\(pro.maxPhotoMegapixels)MP" : "12MP",
                isActive: viewModel.isSuperResolutionRAWEnabled,
                isSupported: pro.maxPhotoMegapixels > 12,
                action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    viewModel.isSuperResolutionRAWEnabled.toggle()
                }
            )

            hardwareTile(
                icon: "scope",
                title: "Báo nét",
                value: viewModel.isFocusPeakingEnabled ? "Bật" : "Tắt",
                isActive: viewModel.isFocusPeakingEnabled,
                isSupported: viewModel.featureAvailability(.focusPeaking).isAvailable,
                action: {
                    viewModel.attemptFeature(.focusPeaking) {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        viewModel.isFocusPeakingEnabled.toggle()
                    }
                }
            )

            hardwareTile(
                icon: "moon.stars",
                title: "Sáng đêm",
                value: pro.isLowLightBoostSupported ? (pro.isLowLightBoostPreferred ? "Tự động" : "Tắt") : "Không có",
                isActive: pro.isLowLightBoostSupported && pro.isLowLightBoostPreferred,
                isSupported: pro.isLowLightBoostSupported,
                action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    pro.setLowLightBoostEnabled(!pro.isLowLightBoostPreferred)
                }
            )

            hardwareTile(
                icon: "perspective",
                title: "Chống méo",
                value: pro.isGeometricDistortionCorrectionSupported ? (pro.isGeometricDistortionCorrectionEnabled ? "Bật" : "Tắt") : "Không có",
                isActive: pro.isGeometricDistortionCorrectionSupported && pro.isGeometricDistortionCorrectionEnabled,
                isSupported: pro.isGeometricDistortionCorrectionSupported,
                action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    pro.setGeometricDistortionCorrectionEnabled(!pro.isGeometricDistortionCorrectionEnabled)
                }
            )

            hardwareTile(
                icon: pro.torchLevel >= 0.05 ? "flashlight.on.fill" : "flashlight.off.fill",
                title: "Trợ sáng",
                value: pro.isTorchSupported ? torchText : "Không có",
                isActive: pro.torchLevel >= 0.05,
                isSupported: pro.isTorchSupported,
                action: {
                    HapticFeedbackService.shared.triggerSelectionChange()
                    pro.cycleTorchPreset()
                }
            )
        }
    }

    // MARK: - Subcomponents

    private func presetChip(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            HapticFeedbackService.shared.triggerSelectionChange()
            action()
        }) {
            Text(label)
                .font(.system(size: 10.0, weight: isActive ? .bold : .medium, design: .monospaced))
                .foregroundColor(isActive ? .black : AlignTheme.studioInkPrimary.opacity(0.84))
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4.5)
                .background(
                    Capsule()
                        .fill(isActive ? AlignTheme.studioAccent : Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(isActive ? AlignTheme.studioAccent : Color.white.opacity(0.11), lineWidth: 0.6)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func hardwareTile(
        icon: String,
        title: String,
        value: String,
        isActive: Bool,
        isSupported: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            if isSupported {
                action()
            } else {
                HapticFeedbackService.shared.triggerError()
            }
        }) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(isActive && isSupported ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                    Spacer(minLength: 0)
                    Text(value)
                        .font(.system(size: 9.0, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive && isSupported ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.76))
                        .lineLimit(1)
                }

                Text(title)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive && isSupported ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isActive && isSupported ? AlignTheme.studioAccentBorder : Color.white.opacity(0.10), lineWidth: 0.65)
                    )
            )
            .opacity(isSupported ? 1.0 : 0.42)
        }
        .buttonStyle(.plain)
    }

    private func unsupportedNotice(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .regular))
            .foregroundColor(AlignTheme.studioInkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// MARK: - Precision Tactile Tick-Mark Ruler Dial (Leica / Halide Style)
struct ProPrecisionRulerDial: View {
    let normalizedValue: Double
    let tickCount: Int
    let majorEvery: Int
    var centerHighlight: Bool = false
    var accentHairline: LinearGradient? = nil
    let onChanged: (Double) -> Void

    @State private var lastHapticBucket: Int = -1

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let inset: CGFloat = 10
            let usableWidth = max(1, width - inset * 2)
            let clamped = max(0, min(1, normalizedValue))
            let pointerX = inset + CGFloat(clamped) * usableWidth

            ZStack {
                // Vạch chia tỉ lệ bằng Canvas siêu nhẹ (60 FPS)
                Canvas { context, size in
                    let count = max(3, tickCount)
                    let bottomY = size.height - 5
                    for i in 0..<count {
                        let t = CGFloat(i) / CGFloat(count - 1)
                        let x = inset + t * usableWidth
                        let isCenter = centerHighlight && (i == count / 2)
                        let isMajor = (i % max(1, majorEvery) == 0) || i == count - 1
                        let tickH: CGFloat = isCenter ? 15 : (isMajor ? 11.5 : 6.5)
                        let tickW: CGFloat = isCenter ? 1.5 : (isMajor ? 1.1 : 0.8)
                        let color: Color = isCenter
                            ? Color.white.opacity(0.75)
                            : (isMajor ? Color.white.opacity(0.45) : Color.white.opacity(0.20))
                        let rect = CGRect(x: x - tickW * 0.5, y: bottomY - tickH, width: tickW, height: tickH)
                        context.fill(Path(rect), with: .color(color))
                    }
                }

                // Đường màu chỉ dẫn nhiệt độ màu (nếu có)
                if let hairline = accentHairline {
                    Capsule()
                        .fill(hairline)
                        .frame(width: usableWidth, height: 1.8)
                        .position(x: width * 0.5, y: geo.size.height - 2.2)
                }

                // Kim chỉ định Titanium trượt mượt trên thước
                VStack(spacing: 1) {
                    Circle()
                        .fill(AlignTheme.studioAccent)
                        .frame(width: 5, height: 5)
                    Capsule()
                        .fill(AlignTheme.studioAccent)
                        .frame(width: 2.2, height: 18)
                }
                .position(x: pointerX, y: geo.size.height * 0.48)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let localX = gesture.location.x - inset
                        let nextNorm = max(0.0, min(1.0, Double(localX / usableWidth)))
                        let bucket = Int((nextNorm * Double(max(1, tickCount - 1))).rounded())
                        if bucket != lastHapticBucket {
                            lastHapticBucket = bucket
                            HapticFeedbackService.shared.triggerSelectionChange()
                        }
                        onChanged(nextNorm)
                    }
                    .onEnded { _ in
                        lastHapticBucket = -1
                    }
            )
        }
        .frame(height: 30)
    }
}
