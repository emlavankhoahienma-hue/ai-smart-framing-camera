import SwiftUI

// MARK: - Pro Video Parameter Tick Ruler Shape
private struct ProTriangleIndicator: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Interactive Horizontal Tick Dial Ruler (Mockup 4)
private struct ProParameterTickRuler: View {
    let tab: ProVideoParameterTab
    @ObservedObject var proService: ProVideoManualControlsService
    @State private var dragAccumulator: CGFloat = 0

    var body: some View {
        ZStack(alignment: .center) {
            // Background ticks
            GeometryReader { geometry in
                Canvas { context, size in
                    let midX = size.width / 2.0
                    let step: CGFloat = 9.0
                    let tickCount = Int(size.width / step) / 2 + 6
                    let offset = dragAccumulator.truncatingRemainder(dividingBy: step)

                    for i in -tickCount...tickCount {
                        let x = midX + CGFloat(i) * step + offset
                        guard x >= 0 && x <= size.width else { continue }
                        let isMajor = abs(i) % 5 == 0
                        let tickHeight: CGFloat = isMajor ? 18 : 9
                        let tickColor = isMajor ? Color.white.opacity(0.85) : Color.white.opacity(0.25)

                        let tickPath = Path { p in
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                        }
                        context.stroke(tickPath, with: .color(tickColor), lineWidth: isMajor ? 1.5 : 1.0)
                    }
                }
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { val in
                        let delta = val.translation.width - dragAccumulator
                        dragAccumulator = val.translation.width
                        stepValue(delta: delta)
                    }
                    .onEnded { _ in
                        dragAccumulator = 0
                    }
            )

            // Center gold indicator needle (Mockup 4)
            VStack(spacing: 0) {
                ProTriangleIndicator()
                    .fill(CameraDesignSystem.Colors.accent)
                    .frame(width: 8, height: 6)
                Rectangle()
                    .fill(CameraDesignSystem.Colors.accent)
                    .frame(width: 2, height: 22)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 32)
    }

    private func stepValue(delta: CGFloat) {
        let haptic = UISelectionFeedbackGenerator()
        haptic.prepare()
        switch tab {
        case .shutter:
            let step = delta > 0 ? 10.0 : -10.0
            let newSpeed = max(proService.minShutterSpeed, min(2000.0, proService.currentShutterSpeed + step))
            proService.setManualShutterSpeed(newSpeed)
            haptic.selectionChanged()
        case .iso:
            let step: Float = delta > 0 ? 25.0 : -25.0
            let newISO = max(proService.minISO, min(proService.maxISO, proService.currentISO + step))
            proService.setManualISO(newISO)
            haptic.selectionChanged()
        case .wb:
            let step: Float = delta > 0 ? 100.0 : -100.0
            let newKelvin = max(2500.0, min(9000.0, proService.currentKelvin + step))
            proService.setManualWhiteBalance(kelvin: newKelvin, tint: proService.currentTint)
            haptic.selectionChanged()
        case .aperture:
            let step: Float = delta > 0 ? 0.1 : -0.1
            let newEV = max(-2.0, min(2.0, proService.currentEVBias + step))
            proService.setManualEVBias(newEV)
            haptic.selectionChanged()
        case .focus:
            let step: Float = delta > 0 ? 0.02 : -0.02
            let newPos = max(0.0, min(1.0, proService.currentLensPosition + step))
            proService.setManualFocus(newPos)
            haptic.selectionChanged()
        }
    }
}

// MARK: - Main Pro Video Manual Controls View (Mockup 4)
public struct ProVideoManualControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var proService = ProVideoManualControlsService.shared

    private let haptic = UISelectionFeedbackGenerator()

    private let tabs: [(tab: ProVideoParameterTab, title: String)] = [
        (.shutter, "S"),
        (.iso, "ISO"),
        (.wb, "WB"),
        (.aperture, "EV"),
        (.focus, "MF")
    ]

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 5) {
            // 0. Drag Grabber Handle (visual affordance to swipe up/down)
            dragHandleBar

            // 1. Parameter Cards Tab Bar (S | ISO | WB | EV | MF)
            parameterTabBar

            // 2. Expandable Adjustment Drawer (Mockup 4)
            if viewModel.isShowingProControlsDrawer {
                VStack(spacing: 10) {
                    // 2.1 Readout Header + Auto Toggle + Dismiss Chevron
                    parameterReadoutHeader

                    // 2.2 Interactive Horizontal Tick Ruler (Mockup 4)
                    ProParameterTickRuler(tab: viewModel.selectedProTab, proService: proService)
                        .padding(.horizontal, 4)

                    // 2.3 Quick Presets Row
                    quickPresetsRow

                    // 2.4 Quick Toggles: Khóa tự động & Focus Peaking
                    quickTogglesRow
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(CameraDesignSystem.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(CameraDesignSystem.Colors.hairline, lineWidth: 1)
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .padding(.horizontal, 10)
        .onAppear {
            proService.syncHardwareCapabilities()
        }
    }

    // MARK: - 0. Drag Grabber Handle
    private var dragHandleBar: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 38, height: 4)
                .padding(.vertical, 3)
            Spacer()
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.height > 15 {
                        collapseDrawer()
                    } else if value.translation.height < -15 {
                        expandDrawer()
                    }
                }
        )
    }

    // MARK: - 1. Parameter Cards Tab Bar
    private var parameterTabBar: some View {
        HStack(spacing: 5) {
            ForEach(tabs, id: \.tab) { item in
                let isSelected = viewModel.selectedProTab == item.tab
                Button(action: {
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        if viewModel.selectedProTab == item.tab {
                            viewModel.isShowingProControlsDrawer.toggle()
                        } else {
                            viewModel.selectedProTab = item.tab
                            viewModel.isShowingProControlsDrawer = true
                        }
                    }
                }) {
                    VStack(spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .lineLimit(1)

                        Text(tabValueLabel(for: item.tab))
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Thông số \(item.title): \(tabValueLabel(for: item.tab))")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { val in
                    if val.translation.height > 15 {
                        collapseDrawer()
                    } else if val.translation.height < -15 {
                        expandDrawer()
                    }
                }
        )
    }

    private func tabValueLabel(for tab: ProVideoParameterTab) -> String {
        switch tab {
        case .shutter:
            return proService.isAutoShutter ? "AUTO" : "1/\(Int(proService.currentShutterSpeed))s"
        case .iso:
            return proService.isAutoISO ? "AUTO" : "\(Int(proService.currentISO))"
        case .wb:
            return proService.isAutoWB ? "AWB" : "\(Int(proService.currentKelvin))K"
        case .aperture:
            return proService.isAutoEV ? "0.0 EV" : String(format: "%+.1f", proService.currentEVBias)
        case .focus:
            return proService.isAutoFocus ? "AF" : "\(Int(proService.currentLensPosition * 100))"
        }
    }

    // MARK: - 2.1 Readout Header
    private var parameterReadoutHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(readoutTitle)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(CameraDesignSystem.Colors.textSecondary)

                Text(currentPrimaryValueText)
                    .font(.system(size: 21, weight: .bold, design: .monospaced))
                    .foregroundColor(CameraDesignSystem.Colors.textPrimary)
            }

            Spacer()

            HStack(spacing: 8) {
                // AUTO Button Toggle
                autoToggleButton

                // 1-Tap Dismiss / Collapse Button
                Button(action: {
                    collapseDrawer()
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(CameraDesignSystem.Colors.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(CameraDesignSystem.Colors.surfaceElevated))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Thu gọn bảng điều khiển thủ công")
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { val in
                    if val.translation.height > 15 {
                        collapseDrawer()
                    }
                }
        )
    }

    private func collapseDrawer() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            viewModel.isShowingProControlsDrawer = false
        }
    }

    private func expandDrawer() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            viewModel.isShowingProControlsDrawer = true
        }
    }

    private var readoutTitle: String {
        switch viewModel.selectedProTab {
        case .shutter: return "TỐC ĐỘ MÀN TRẬP"
        case .iso: return "ĐỘ NHẠY SÁNG ISO"
        case .wb: return "CÂN BẰNG TRẮNG"
        case .aperture: return "BÙ PHƠI SÁNG EV"
        case .focus: return "LẤY NÉT ỐNG KÍNH"
        }
    }

    private var currentPrimaryValueText: String {
        switch viewModel.selectedProTab {
        case .shutter:
            return proService.isAutoShutter
                ? "AUTO (1/\(Int(proService.measuredLiveShutterSpeed))s)"
                : "1/\(Int(proService.currentShutterSpeed)) s"
        case .iso:
            return proService.isAutoISO
                ? "AUTO (\(Int(proService.measuredLiveISO)))"
                : "ISO \(Int(proService.currentISO))"
        case .wb:
            return proService.isAutoWB
                ? "AWB (\(Int(proService.measuredLiveKelvin))K)"
                : "\(Int(proService.currentKelvin)) K"
        case .aperture:
            return proService.isAutoEV
                ? "0.0 EV"
                : String(format: "%+.1f EV", proService.currentEVBias)
        case .focus:
            return proService.isAutoFocus
                ? "AF-C TỰ ĐỘNG"
                : "MF \(Int(proService.currentLensPosition * 100))%"
        }
    }

    // MARK: - Auto Mode Toggle Button
    @ViewBuilder
    private var autoToggleButton: some View {
        switch viewModel.selectedProTab {
        case .shutter:
            Button(action: {
                proService.setAutoShutter(!proService.isAutoShutter)
                haptic.selectionChanged()
            }) {
                autoButtonLabel(isAuto: proService.isAutoShutter)
            }
        case .iso:
            Button(action: {
                proService.setAutoISO(!proService.isAutoISO)
                haptic.selectionChanged()
            }) {
                autoButtonLabel(isAuto: proService.isAutoISO)
            }
        case .wb:
            Button(action: {
                proService.setAutoWB(!proService.isAutoWB)
                haptic.selectionChanged()
            }) {
                autoButtonLabel(isAuto: proService.isAutoWB)
            }
        case .aperture:
            Button(action: {
                proService.setAutoEV(true)
                haptic.selectionChanged()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                    Text("RESET")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(CameraDesignSystem.Colors.surfaceElevated)
                .cornerRadius(8)
                .foregroundColor(CameraDesignSystem.Colors.textPrimary)
            }
        case .focus:
            Button(action: {
                let enableAuto = !proService.isAutoFocus
                proService.setAutoFocus(enableAuto)
                if !enableAuto {
                    viewModel.isFocusPeakingEnabled = true
                }
                haptic.selectionChanged()
            }) {
                autoButtonLabel(isAuto: proService.isAutoFocus)
            }
            .disabled(!proService.isManualFocusSupported)
        }
    }

    private func autoButtonLabel(isAuto: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isAuto ? CameraDesignSystem.Colors.meterGood : CameraDesignSystem.Colors.textSecondary)
                .frame(width: 6, height: 6)
            Text(isAuto ? "AUTO: BẬT" : "AUTO: TẮT")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isAuto ? CameraDesignSystem.Colors.meterGood.opacity(0.18) : CameraDesignSystem.Colors.surfaceElevated)
        .cornerRadius(8)
        .foregroundColor(isAuto ? CameraDesignSystem.Colors.meterGood : CameraDesignSystem.Colors.textPrimary)
    }

    // MARK: - 2.3 Quick Presets Row
    @ViewBuilder
    private var quickPresetsRow: some View {
        switch viewModel.selectedProTab {
        case .shutter:
            let presets: [(label: String, val: Double)] = [
                ("1/24", 24), ("1/48", 48), ("1/60", 60), ("1/120", 120),
                ("1/240", 240), ("1/500", 500), ("1/1000", 1000)
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.val) { p in
                        let isCur = !proService.isAutoShutter && abs(proService.currentShutterSpeed - p.val) < 2
                        Button(action: {
                            proService.setManualShutterSpeed(p.val)
                            haptic.selectionChanged()
                        }) {
                            Text(p.label)
                                .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                                .foregroundColor(isCur ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isCur ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                                .cornerRadius(6)
                        }
                    }
                }
            }
        case .iso:
            let presets: [Float] = [50, 100, 200, 400, 800, 1600, 3200]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        let isCur = !proService.isAutoISO && abs(proService.currentISO - p) < 10
                        Button(action: {
                            proService.setManualISO(p)
                            haptic.selectionChanged()
                        }) {
                            Text("\(Int(p))")
                                .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                                .foregroundColor(isCur ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isCur ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                                .cornerRadius(6)
                        }
                    }
                }
            }
        case .wb:
            let presets: [(name: String, kelvin: Float)] = [
                ("3200K Vàng", 3200), ("4300K Huỳnh quang", 4300),
                ("5600K Ban ngày", 5600), ("6500K Mây", 6500), ("7500K Râm", 7500)
            ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.kelvin) { p in
                        let isCur = !proService.isAutoWB && abs(proService.currentKelvin - p.kelvin) < 100
                        Button(action: {
                            proService.setManualWhiteBalance(kelvin: p.kelvin, tint: proService.currentTint)
                            haptic.selectionChanged()
                        }) {
                            Text(p.name)
                                .font(.system(size: 10.5, weight: isCur ? .heavy : .medium))
                                .foregroundColor(isCur ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(isCur ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                                .cornerRadius(6)
                        }
                    }
                }
            }
        case .aperture:
            let evPresets: [Float] = [-1.5, -1.0, -0.5, 0.0, +0.5, +1.0, +1.5]
            HStack(spacing: 6) {
                ForEach(evPresets, id: \.self) { ev in
                    let isCur = abs(proService.currentEVBias - ev) < 0.08
                    Button(action: {
                        proService.setManualEVBias(ev)
                        haptic.selectionChanged()
                    }) {
                        Text(String(format: "%+.1f", ev))
                            .font(.system(size: 11, weight: isCur ? .heavy : .medium, design: .monospaced))
                            .foregroundColor(isCur ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(isCur ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                            .cornerRadius(6)
                    }
                }
            }
        case .focus:
            let focusPresets: [(name: String, position: Float)] = [
                ("MACRO", 0.02), ("GẦN", 0.20), ("TRUNG", 0.50), ("XA", 0.78), ("∞", 1.00)
            ]
            HStack(spacing: 6) {
                ForEach(focusPresets, id: \.position) { p in
                    let isCur = !proService.isAutoFocus && abs(proService.currentLensPosition - p.position) < 0.04
                    Button(action: {
                        proService.setManualFocus(p.position)
                        viewModel.isFocusPeakingEnabled = true
                        haptic.selectionChanged()
                    }) {
                        Text(p.name)
                            .font(.system(size: 10.5, weight: isCur ? .heavy : .medium, design: .monospaced))
                            .foregroundColor(isCur ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(isCur ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                            .cornerRadius(6)
                    }
                    .disabled(!proService.isManualFocusSupported)
                }
            }
        }
    }

    // MARK: - 2.4 Quick Toggles: Khóa tự động & Focus Peaking (Mockup 4)
    private var quickTogglesRow: some View {
        HStack(spacing: 10) {
            // Toggle 1: Khóa tự động (Auto AE/AF lock)
            Button(action: {
                viewModel.isAEAFLocked.toggle()
                haptic.selectionChanged()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isAEAFLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 12, weight: .bold))
                    Text("Khóa tự động")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(viewModel.isAEAFLocked ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(viewModel.isAEAFLocked ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(viewModel.isAEAFLocked ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.hairline, lineWidth: 1)
                )
            }

            // Toggle 2: Focus Peaking
            Button(action: {
                viewModel.isFocusPeakingEnabled.toggle()
                haptic.selectionChanged()
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isFocusPeakingEnabled ? viewModel.focusPeakingColor.swiftUIColor : CameraDesignSystem.Colors.textSecondary)
                        .frame(width: 8, height: 8)
                    Text("Focus Peaking")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundColor(viewModel.isFocusPeakingEnabled ? CameraDesignSystem.Colors.background : CameraDesignSystem.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(viewModel.isFocusPeakingEnabled ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.surfaceElevated)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(viewModel.isFocusPeakingEnabled ? CameraDesignSystem.Colors.accent : CameraDesignSystem.Colors.hairline, lineWidth: 1)
                )
            }
        }
    }
}
