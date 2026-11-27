import SwiftUI
import UIKit

// MARK: - 1. Native iOS 18 Photographic Styles Glyph (5x5 Micro-Dot Grid + Live Continuous Cursor Mirror + Landscape Rotation)
private struct PhotographicStyleLiveIconCanvas: View, Animatable {
    var tone: Float
    var color: Float
    let isOpen: Bool
    let isDraggingPad: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(Double(tone), Double(color)) }
        set {
            tone = Float(newValue.first)
            color = Float(newValue.second)
        }
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let strokeWidth: CGFloat = 1.45
            let cornerR: CGFloat = 5.6

            // Màu chuẩn Camera iOS 18: trắng tinh khi đóng, vàng hổ phách khi mở
            let accentGold = Color(red: 1.0, green: 0.84, blue: 0.25)
            let frameColor = isOpen ? accentGold : Color.white.opacity(0.94)
            let gridDotColor = isOpen ? accentGold.opacity(0.46) : Color.white.opacity(0.46)
            let cursorColor = isOpen ? accentGold : Color.white

            // 1. Viền khung vuông bo góc tối giản (không hộp kính nặng kiểu AI)
            let borderRect = CGRect(
                x: strokeWidth * 0.5,
                y: strokeWidth * 0.5,
                width: w - strokeWidth,
                height: h - strokeWidth
            )
            context.stroke(
                Path(roundedRect: borderRect, cornerRadius: cornerR, style: .continuous),
                with: .color(frameColor),
                lineWidth: strokeWidth
            )

            // 2. Lưới 5x5 chấm siêu mảnh đều nhau bên trong khung (25 chấm giống hệt icon gốc)
            let gridInset: CGFloat = 4.6
            let innerW = max(1, w - gridInset * 2.0)
            let innerH = max(1, h - gridInset * 2.0)
            let stepX = innerW / 4.0
            let stepY = innerH / 4.0

            let normX = CGFloat((max(-1.0, min(1.0, color)) + 1.0) * 0.5)
            let normY = CGFloat((1.0 - max(-1.0, min(1.0, tone))) * 0.5)
            let cursorX = gridInset + normX * innerW
            let cursorY = gridInset + normY * innerH

            let microR: CGFloat = 0.68
            for row in 0..<5 {
                for col in 0..<5 {
                    let dx = gridInset + CGFloat(col) * stepX
                    let dy = gridInset + CGFloat(row) * stepY
                    if hypot(dx - cursorX, dy - cursorY) < 1.65 { continue }
                    let dotRect = CGRect(x: dx - microR, y: dy - microR, width: microR * 2, height: microR * 2)
                    context.fill(Path(ellipseIn: dotRect), with: .color(gridDotColor))
                }
            }

            // 3. Chấm con trỏ thu nhỏ di chuyển liên tục theo tọa độ (color, tone) thực tế của ô Pad bên dưới
            if isDraggingPad {
                let haloR: CGFloat = 3.2
                let haloRect = CGRect(x: cursorX - haloR, y: cursorY - haloR, width: haloR * 2, height: haloR * 2)
                context.fill(Path(ellipseIn: haloRect), with: .color(cursorColor.opacity(0.32)))
            }
            let cursorR: CGFloat = isDraggingPad ? 2.15 : 1.9
            let cursorRect = CGRect(x: cursorX - cursorR, y: cursorY - cursorR, width: cursorR * 2, height: cursorR * 2)
            context.fill(Path(ellipseIn: cursorRect), with: .color(cursorColor))
        }
    }
}

public struct PhotographicStyleQuickTriggerButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var liveHUD: PhotographicStyleLiveHUDState
    @ObservedObject private var orientationMonitor: PhotographicStyleOrientationMonitor
    let isCompactTopBarVariant: Bool

    public init(viewModel: CameraViewModel, isCompactTopBarVariant: Bool = false) {
        self.viewModel = viewModel
        self._liveHUD = ObservedObject(wrappedValue: viewModel.liveStyleHUD)
        self._orientationMonitor = ObservedObject(wrappedValue: viewModel.styleOrientationMonitor)
        self.isCompactTopBarVariant = isCompactTopBarVariant
    }

    public var body: some View {
        let availability = viewModel.featureAvailability(.photographicStyles)
        let isOpen = viewModel.isShowingPhotographicStylePad
        let isDraggingPad = liveHUD.isInteracting && viewModel.activePhotographicStyleAxis == .pad2D
        let shownTone = isOpen ? liveHUD.tone : viewModel.photographicStyle.tone
        let shownColor = isOpen ? liveHUD.color : viewModel.photographicStyle.color
        let iconAngle: Double = isOpen ? orientationMonitor.orientation.rotationDegrees : 0.0

        Button(action: {
            viewModel.attemptFeature(.photographicStyles) {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    viewModel.isShowingPhotographicStylePad.toggle()
                }
            }
        }) {
            PhotographicStyleLiveIconCanvas(
                tone: shownTone,
                color: shownColor,
                isOpen: isOpen,
                isDraggingPad: isDraggingPad
            )
            .frame(width: 23, height: 23)
            .animation(liveHUD.isInteracting ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.88), value: shownTone)
            .animation(liveHUD.isInteracting ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.88), value: shownColor)
            .animation(.easeOut(duration: 0.14), value: isDraggingPad)
            .rotationEffect(.degrees(iconAngle))
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: iconAngle)
            .shadow(
                color: isCompactTopBarVariant ? Color.clear : Color.black.opacity(0.55),
                radius: isCompactTopBarVariant ? 0 : 2.5,
                y: isCompactTopBarVariant ? 0 : 1
            )
            .frame(width: 34, height: 34)
            .opacity(availability.isAvailable ? 1.0 : 0.34)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(
            isOpen
                ? "Ẩn Photographic Styles"
                : (!viewModel.photographicStyle.isIdentity
                    ? "Photographic Styles: \(viewModel.photographicStyle.preset.displayName)"
                    : "Mở Photographic Styles")
        )
    }
}

// MARK: - 2. Top Bar Telemetry HUD (Replaces TopCameraBar — Portrait Horizontal Capsule; Yields to Rotated Viewfinder HUD in Landscape)
private enum PhotographicStyleNudgeMetric: Equatable {
    case tone
    case color
    case palette

    var title: String {
        switch self {
        case .tone: return "TONE"
        case .color: return "COLOR"
        case .palette: return "PALETTE"
        }
    }
}

/// Viên thuốc hiển thị thông số TONE · COLOR · PALETTE chuẩn Camera gốc iOS (khớp video mẫu: không nhồi nút Reset thừa vào thanh đỉnh).
private struct PhotographicStyleMetricsCapsuleView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var liveHUD: PhotographicStyleLiveHUDState
    let compact: Bool
    @Binding var activeNudgeMetric: PhotographicStyleNudgeMetric?

    var body: some View {
        let axis = viewModel.activePhotographicStyleAxis
        let isPadDragging = axis == .pad2D
        let isPaletteDragging = axis == .palette

        HStack(spacing: compact ? 10 : 14) {
            hudMetricButton(
                metric: .tone,
                label: "TONE",
                value: liveHUD.toneHUDNumber,
                numericValue: liveHUD.displayedToneInt,
                highlighted: isPadDragging || activeNudgeMetric == .tone,
                dimmed: isPaletteDragging
            )

            hudMetricButton(
                metric: .color,
                label: "COLOR",
                value: liveHUD.colorHUDNumber,
                numericValue: liveHUD.displayedColorInt,
                highlighted: isPadDragging || activeNudgeMetric == .color,
                dimmed: isPaletteDragging
            )

            hudMetricButton(
                metric: .palette,
                label: "PALETTE",
                value: liveHUD.paletteHUDNumber,
                numericValue: liveHUD.displayedPaletteInt,
                highlighted: isPaletteDragging || activeNudgeMetric == .palette,
                dimmed: isPadDragging
            )
        }
        .padding(.horizontal, compact ? 12 : 15)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(white: 0.10).opacity(0.84))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.65)
                )
        )
    }

    @ViewBuilder
    private func hudMetricButton(
        metric: PhotographicStyleNudgeMetric,
        label: String,
        value: String,
        numericValue: Int,
        highlighted: Bool,
        dimmed: Bool
    ) -> some View {
        let isEditingThis = activeNudgeMetric == metric
        Button(action: {
            HapticFeedbackService.shared.triggerLight()
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                activeNudgeMetric = (activeNudgeMetric == metric) ? nil : metric
            }
        }) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: compact ? 8.5 : 9.2, weight: .medium, design: .rounded))
                    .foregroundColor(
                        isEditingThis
                            ? AlignTheme.studioAccent
                            : (highlighted
                                ? AlignTheme.studioInkPrimary.opacity(0.90)
                                : AlignTheme.studioInkPrimary.opacity(0.56))
                    )

                Text(value)
                    .font(.system(size: compact ? 10.5 : 11.2, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(numericValue)))
                    .foregroundColor(isEditingThis ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)
                    .frame(minWidth: compact ? 25 : 28, alignment: .leading)
                    .animation(.snappy(duration: 0.14), value: numericValue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(dimmed ? 0.38 : 1.0)
        .animation(.easeOut(duration: 0.14), value: dimmed)
        .animation(.easeOut(duration: 0.14), value: highlighted)
    }
}

public struct PhotographicStylesTopHUDBar: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var liveHUD: PhotographicStyleLiveHUDState
    @ObservedObject private var orientationMonitor: PhotographicStyleOrientationMonitor
    let compact: Bool

    @State private var activeNudgeMetric: PhotographicStyleNudgeMetric? = nil

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self._liveHUD = ObservedObject(wrappedValue: viewModel.liveStyleHUD)
        self._orientationMonitor = ObservedObject(wrappedValue: viewModel.styleOrientationMonitor)
        self.compact = compact
    }

    public var body: some View {
        let style = liveHUD.currentStyleSnapshot
        let isLandscape = orientationMonitor.orientation.isLandscape

        HStack(spacing: 6) {
            if !compact {
                Color.clear.frame(width: 34, height: 34)
            }

            Spacer(minLength: 0)

            // Khi cầm dọc: hiển thị thanh chỉ số ngang ở đỉnh; khi xoay ngang: nhường sang cạnh trên của khung ngắm ngang
            if !isLandscape {
                PhotographicStyleMetricsCapsuleView(
                    viewModel: viewModel,
                    liveHUD: liveHUD,
                    compact: compact,
                    activeNudgeMetric: $activeNudgeMetric
                )
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            // Right-edge native 5x5 live-mirror icon button (tap to dismiss)
            PhotographicStyleQuickTriggerButton(viewModel: viewModel, isCompactTopBarVariant: true)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.24), value: isLandscape)
        .overlay(alignment: .top) {
            if !isLandscape, let metric = activeNudgeMetric {
                precisionNudgeBar(for: metric, style: style)
                    .offset(y: 42)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.activePhotographicStyleAxis) { _, newAxis in
            if newAxis != .none && activeNudgeMetric != nil {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeNudgeMetric = nil
                }
            }
        }
        .onChange(of: orientationMonitor.orientation) { _, newOrient in
            if newOrient.isLandscape && activeNudgeMetric != nil {
                activeNudgeMetric = nil
            }
        }
    }

    @ViewBuilder
    private func precisionNudgeBar(for metric: PhotographicStyleNudgeMetric, style: PhotographicStyleState) -> some View {
        HStack(spacing: 6) {
            nudgeStepButton(title: "-10") { applyNudge(metric: metric, delta: -0.10) }
            nudgeStepButton(title: "-1") { applyNudge(metric: metric, delta: -0.01) }

            Button(action: { resetSingleMetric(metric, style: style) }) {
                Text(metric.title)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(AlignTheme.studioAccent)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(Capsule().fill(AlignTheme.studioAccent.opacity(0.16)))
            }
            .buttonStyle(PlainButtonStyle())

            nudgeStepButton(title: "+1") { applyNudge(metric: metric, delta: 0.01) }
            nudgeStepButton(title: "+10") { applyNudge(metric: metric, delta: 0.10) }

            Button(action: {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeNudgeMetric = nil
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.70))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.84))
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
        )
        .shadow(color: Color.black.opacity(0.45), radius: 8, y: 3)
    }

    private func nudgeStepButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(Color.white)
                .frame(minWidth: 28, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func applyNudge(metric: PhotographicStyleNudgeMetric, delta: Float) {
        switch metric {
        case .tone:
            viewModel.nudgePhotographicStyle(toneDelta: delta)
        case .color:
            viewModel.nudgePhotographicStyle(colorDelta: delta)
        case .palette:
            viewModel.nudgePhotographicStyle(paletteDelta: delta)
        }
    }

    private func resetSingleMetric(_ metric: PhotographicStyleNudgeMetric, style: PhotographicStyleState) {
        HapticFeedbackService.shared.triggerLight()
        switch metric {
        case .tone:
            viewModel.updatePhotographicStyle(tone: style.preset.defaultTone, color: style.color)
        case .color:
            viewModel.updatePhotographicStyle(tone: style.tone, color: style.preset.defaultColor)
        case .palette:
            viewModel.updatePhotographicStyle(palette: style.preset.defaultPalette)
        }
    }
}

// MARK: - Rounded Split-Screen Seam Canvas (Hỗ trợ cả cắt dọc Portrait và cắt ngang Landscape khớp bo góc 20pt)
private struct PhotographicStyleRoundedSplitSeam: View {
    let splitPosition: CGFloat
    let isLandscapeAxis: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard splitPosition > 0.002 && splitPosition < 0.998 else { return }

            let gap: CGFloat = 5.5
            var maskPath = Path()
            maskPath.addRect(CGRect(origin: .zero, size: size))

            if isLandscapeAxis {
                let splitY = splitPosition * h
                let topEdge = max(0, splitY - gap * 0.5)
                let bottomEdge = min(h, splitY + gap * 0.5)

                if topEdge > 1.0 {
                    let rT = min(20.0, topEdge * 0.5)
                    maskPath.addRoundedRect(
                        in: CGRect(x: 0, y: 0, width: w, height: topEdge),
                        cornerSize: CGSize(width: min(20.0, w * 0.5), height: rT),
                        style: .continuous
                    )
                }

                let bottomH = h - bottomEdge
                if bottomH > 1.0 {
                    let rB = min(20.0, bottomH * 0.5)
                    maskPath.addRoundedRect(
                        in: CGRect(x: 0, y: bottomEdge, width: w, height: bottomH),
                        cornerSize: CGSize(width: min(20.0, w * 0.5), height: rB),
                        style: .continuous
                    )
                }
            } else {
                let splitX = splitPosition * w
                let leftEdge = max(0, splitX - gap * 0.5)
                let rightEdge = min(w, splitX + gap * 0.5)

                if leftEdge > 1.0 {
                    let rL = min(20.0, leftEdge * 0.5)
                    maskPath.addRoundedRect(
                        in: CGRect(x: 0, y: 0, width: leftEdge, height: h),
                        cornerSize: CGSize(width: rL, height: min(20.0, h * 0.5)),
                        style: .continuous
                    )
                }

                let rightW = w - rightEdge
                if rightW > 1.0 {
                    let rR = min(20.0, rightW * 0.5)
                    maskPath.addRoundedRect(
                        in: CGRect(x: rightEdge, y: 0, width: rightW, height: h),
                        cornerSize: CGSize(width: rR, height: min(20.0, h * 0.5)),
                        style: .continuous
                    )
                }
            }

            context.fill(
                maskPath,
                with: .color(AlignTheme.studioCanvas),
                style: FillStyle(eoFill: true)
            )
        }
    }
}

// MARK: - 3. Unobstructed Viewfinder Overlay (60 FPS GPU Split-Screen Wipe + Landscape-Left/Right HUD & Swipe + 16-Style Strip)
public struct PhotographicStylesViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var liveHUD: PhotographicStyleLiveHUDState
    @ObservedObject private var orientationMonitor: PhotographicStyleOrientationMonitor
    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var isSwipingPresets: Bool = false
    @State private var swipeStartPresetIndex: Int = 0
    @State private var swipeStartOrientation: PhotographicStyleInterfaceOrientation = .portrait
    @State private var bounceOffset: CGFloat = 0
    @State private var touchDownActive: Bool = false
    @State private var holdCompareTask: Task<Void, Never>? = nil
    @State private var landscapeNudgeMetric: PhotographicStyleNudgeMetric? = nil

    public init(viewModel: CameraViewModel, topInset: CGFloat, bottomInset: CGFloat) {
        self.viewModel = viewModel
        self._liveHUD = ObservedObject(wrappedValue: viewModel.liveStyleHUD)
        self._orientationMonitor = ObservedObject(wrappedValue: viewModel.styleOrientationMonitor)
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    private var allPresets: [PhotographicStylePreset] { PhotographicStylePreset.allCases }

    private var displayedStyle: PhotographicStyleState {
        viewModel.photographicStyleSplit.isActive
            ? viewModel.photographicStyleSplit.dominantStyle
            : viewModel.activeInteractivePhotographicStyle
    }

    private var activeStyleSubtitleTag: String? {
        let s = displayedStyle
        if s.textureMode != .standard && s.grainEnabled {
            return "\(s.textureMode.displayName) + Grain"
        } else if s.textureMode != .standard {
            return s.textureMode.displayName
        } else if s.grainEnabled {
            return "Grain"
        }
        return nil
    }

    public var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            let activeSplit = viewModel.photographicStyleSplit
            let shownPreset = displayedStyle.preset
            let isComparingOriginal = viewModel.isHoldingCompareOriginalStyle
            let orientation = orientationMonitor.orientation
            let isLandscape = orientation.isLandscape

            ZStack {
                // Full-viewfinder gesture layer: tự đổi trục vuốt ngang theo hướng cầm máy (Portrait / Landscape-Left / Landscape-Right)
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height

                                if !touchDownActive {
                                    touchDownActive = true
                                    swipeStartOrientation = orientation
                                    holdCompareTask?.cancel()
                                    if !viewModel.photographicStyle.isIdentity {
                                        holdCompareTask = Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: 270_000_000)
                                            guard !Task.isCancelled, touchDownActive, !isSwipingPresets else { return }
                                            viewModel.setPhotographicStyleHoldCompare(true)
                                        }
                                    }
                                }

                                if hypot(dx, dy) >= 8 {
                                    holdCompareTask?.cancel()
                                    holdCompareTask = nil
                                    if viewModel.isHoldingCompareOriginalStyle {
                                        viewModel.setPhotographicStyleHoldCompare(false)
                                    }
                                }

                                // Quy đổi vector vuốt sang trục ngang theo mắt người cầm máy (visualDelta < 0 = vuốt sang trái = phong cách tiếp theo)
                                let visualDelta: CGFloat
                                let orthoDelta: CGFloat
                                let axisSpan: CGFloat
                                switch swipeStartOrientation {
                                case .portrait:
                                    visualDelta = dx
                                    orthoDelta = dy
                                    axisSpan = w
                                case .landscapeLeft:
                                    visualDelta = dy
                                    orthoDelta = dx
                                    axisSpan = h
                                case .landscapeRight:
                                    visualDelta = -dy
                                    orthoDelta = dx
                                    axisSpan = h
                                }

                                if !isSwipingPresets && abs(visualDelta) > 8 && abs(visualDelta) > abs(orthoDelta) * 1.1 {
                                    isSwipingPresets = true
                                    viewModel.cancelPhotographicStyleSwipe()
                                    swipeStartPresetIndex = allPresets.firstIndex(of: viewModel.photographicStyle.preset) ?? 0
                                }
                                guard isSwipingPresets else { return }

                                let idx = swipeStartPresetIndex
                                let currentState = viewModel.photographicStyleState(for: allPresets[idx])
                                let isLandAxis = swipeStartOrientation.isLandscape
                                let isInvertedCoord = (swipeStartOrientation == .landscapeRight)

                                if visualDelta < 0 {
                                    if idx + 1 < allPresets.count {
                                        bounceOffset = 0
                                        let nextPreset = allPresets[idx + 1]
                                        let nextState = viewModel.photographicStyleState(for: nextPreset)
                                        let progress = Float(max(0.0, min(1.0, -visualDelta / axisSpan)))
                                        let dominant = progress >= 0.5 ? nextState : currentState
                                        if isInvertedCoord {
                                            // Landscape-Right: phía PHẢI theo mắt người nằm tại dstUV.y = 0 -> cắt từ 0.0 -> 1.0
                                            viewModel.updatePhotographicStyleSplit(
                                                PhotographicStyleSplitTransition(
                                                    isActive: true,
                                                    leftStyle: nextState,
                                                    rightStyle: currentState,
                                                    splitPosition: progress,
                                                    dominantStyle: dominant,
                                                    incomingPreset: nextPreset,
                                                    morphProgress: progress,
                                                    isLandscapeAxis: true
                                                )
                                            )
                                        } else {
                                            let splitPos = 1.0 - progress
                                            viewModel.updatePhotographicStyleSplit(
                                                PhotographicStyleSplitTransition(
                                                    isActive: true,
                                                    leftStyle: currentState,
                                                    rightStyle: nextState,
                                                    splitPosition: splitPos,
                                                    dominantStyle: dominant,
                                                    incomingPreset: nextPreset,
                                                    morphProgress: progress,
                                                    isLandscapeAxis: isLandAxis
                                                )
                                            )
                                        }
                                    } else {
                                        viewModel.cancelPhotographicStyleSwipe()
                                        bounceOffset = visualDelta * 0.16
                                    }
                                } else if visualDelta > 0 {
                                    if idx - 1 >= 0 {
                                        bounceOffset = 0
                                        let prevPreset = allPresets[idx - 1]
                                        let prevState = viewModel.photographicStyleState(for: prevPreset)
                                        let progress = Float(max(0.0, min(1.0, visualDelta / axisSpan)))
                                        let dominant = progress >= 0.5 ? prevState : currentState
                                        if isInvertedCoord {
                                            let splitPos = 1.0 - progress
                                            viewModel.updatePhotographicStyleSplit(
                                                PhotographicStyleSplitTransition(
                                                    isActive: true,
                                                    leftStyle: currentState,
                                                    rightStyle: prevState,
                                                    splitPosition: splitPos,
                                                    dominantStyle: dominant,
                                                    incomingPreset: prevPreset,
                                                    morphProgress: progress,
                                                    isLandscapeAxis: true
                                                )
                                            )
                                        } else {
                                            viewModel.updatePhotographicStyleSplit(
                                                PhotographicStyleSplitTransition(
                                                    isActive: true,
                                                    leftStyle: prevState,
                                                    rightStyle: currentState,
                                                    splitPosition: progress,
                                                    dominantStyle: dominant,
                                                    incomingPreset: prevPreset,
                                                    morphProgress: progress,
                                                    isLandscapeAxis: isLandAxis
                                                )
                                            )
                                        }
                                    } else {
                                        viewModel.cancelPhotographicStyleSwipe()
                                        bounceOffset = visualDelta * 0.16
                                    }
                                }
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let predX = value.predictedEndTranslation.width
                                let predY = value.predictedEndTranslation.height
                                let wasSwipe = isSwipingPresets
                                let wasCompare = viewModel.isHoldingCompareOriginalStyle
                                let idx = swipeStartPresetIndex
                                let startOrient = swipeStartOrientation

                                let visualDelta: CGFloat
                                let predictedVisual: CGFloat
                                let axisSpan: CGFloat
                                switch startOrient {
                                case .portrait:
                                    visualDelta = dx; predictedVisual = predX; axisSpan = w
                                case .landscapeLeft:
                                    visualDelta = dy; predictedVisual = predY; axisSpan = h
                                case .landscapeRight:
                                    visualDelta = -dy; predictedVisual = -predY; axisSpan = h
                                }

                                touchDownActive = false
                                holdCompareTask?.cancel()
                                holdCompareTask = nil
                                if wasCompare {
                                    viewModel.setPhotographicStyleHoldCompare(false)
                                }

                                isSwipingPresets = false
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                    bounceOffset = 0
                                }

                                if wasSwipe {
                                    let currentSplit = viewModel.photographicStyleSplit
                                    let isInvertedCoord = (startOrient == .landscapeRight)
                                    if currentSplit.isActive {
                                        if visualDelta < 0, idx + 1 < allPresets.count {
                                            let progress = -visualDelta / axisSpan
                                            let predictedProgress = -predictedVisual / axisSpan
                                            let shouldCommit = progress >= 0.30 || predictedProgress >= 0.44
                                            let targetPos: Float = isInvertedCoord
                                                ? (shouldCommit ? 1.0 : 0.0)
                                                : (shouldCommit ? 0.0 : 1.0)
                                            viewModel.finishPhotographicStyleSwipe(
                                                from: currentSplit,
                                                targetSplitPosition: targetPos,
                                                isSwipingToNext: !isInvertedCoord,
                                                commitPreset: shouldCommit ? allPresets[idx + 1] : nil
                                            )
                                        } else if visualDelta > 0, idx - 1 >= 0 {
                                            let progress = visualDelta / axisSpan
                                            let predictedProgress = predictedVisual / axisSpan
                                            let shouldCommit = progress >= 0.30 || predictedProgress >= 0.44
                                            let targetPos: Float = isInvertedCoord
                                                ? (shouldCommit ? 0.0 : 1.0)
                                                : (shouldCommit ? 1.0 : 0.0)
                                            viewModel.finishPhotographicStyleSwipe(
                                                from: currentSplit,
                                                targetSplitPosition: targetPos,
                                                isSwipingToNext: isInvertedCoord,
                                                commitPreset: shouldCommit ? allPresets[idx - 1] : nil
                                            )
                                        } else {
                                            viewModel.cancelPhotographicStyleSwipe()
                                        }
                                    }
                                } else if !wasCompare && hypot(dx, dy) < 9 {
                                    HapticFeedbackService.shared.triggerLight()
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        viewModel.isShowingPhotographicStylePad = false
                                    }
                                }
                            }
                    )

                // Đường ranh chia đôi đen bo 4 góc tròn theo đúng tọa độ GPU splitPosition (cả dọc lẫn ngang)
                if activeSplit.isActive {
                    PhotographicStyleRoundedSplitSeam(
                        splitPosition: CGFloat(activeSplit.splitPosition),
                        isLandscapeAxis: activeSplit.isLandscapeAxis
                    )
                    .allowsHitTesting(false)
                }

                // Giao diện nhãn trên/dưới tự xoay khớp hướng cầm máy (Portrait vs Landscape-Left / Landscape-Right)
                if !isLandscape {
                    VStack {
                        groupBadgePill(shownPreset: shownPreset, isComparingOriginal: isComparingOriginal)
                            .padding(.top, topInset)

                        Spacer()

                        styleNameAndDotsStack(shownPreset: shownPreset)
                            .offset(x: bounceOffset * 0.5)
                            .padding(.bottom, max(8, bottomInset - 2))
                    }
                    .transition(.opacity)
                } else {
                    // Landscape-Left (+90°): cạnh PHẢI vật lý = Đỉnh theo mắt người; cạnh TRÁI vật lý = Đáy theo mắt người
                    // Landscape-Right (-90°): cạnh TRÁI vật lý = Đỉnh theo mắt người; cạnh PHẢI vật lý = Đáy theo mắt người
                    let angle = orientation.rotationDegrees
                    let hudCenterX: CGFloat = (orientation == .landscapeLeft) ? (w - 30) : 30
                    let stripCenterX: CGFloat = (orientation == .landscapeLeft) ? 32 : (w - 32)

                    // Đỉnh khung ngắm ngang: HUD thông số TONE · COLOR · PALETTE · Reset + thanh chỉnh số chính xác + nhãn nhóm
                    VStack(spacing: 6) {
                        PhotographicStyleMetricsCapsuleView(
                            viewModel: viewModel,
                            liveHUD: liveHUD,
                            compact: true,
                            activeNudgeMetric: $landscapeNudgeMetric
                        )
                        if let metric = landscapeNudgeMetric {
                            HStack(spacing: 5) {
                                ForEach([("-10", Float(-0.10)), ("-1", Float(-0.01)), ("+1", Float(0.01)), ("+10", Float(0.10))], id: \.0) { label, delta in
                                    Button(action: {
                                        switch metric {
                                        case .tone: viewModel.nudgePhotographicStyle(toneDelta: delta)
                                        case .color: viewModel.nudgePhotographicStyle(colorDelta: delta)
                                        case .palette: viewModel.nudgePhotographicStyle(paletteDelta: delta)
                                        }
                                    }) {
                                        Text(label)
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .frame(minWidth: 26, minHeight: 22)
                                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.16)))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                Button(action: { landscapeNudgeMetric = nil }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white.opacity(0.72))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.84)).overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.6)))
                            .transition(.opacity)
                        } else {
                            groupBadgePill(shownPreset: shownPreset, isComparingOriginal: isComparingOriginal)
                        }
                    }
                    .fixedSize()
                    .rotationEffect(.degrees(angle))
                    .position(x: hudCenterX, y: h * 0.5)
                    .transition(.opacity)

                    // Đáy khung ngắm ngang: Tên phong cách + 16 chấm chọn trực tiếp xoay thuận mắt
                    styleNameAndDotsStack(shownPreset: shownPreset)
                        .fixedSize()
                        .rotationEffect(.degrees(angle))
                        .position(
                            x: stripCenterX,
                            y: h * 0.5 + (orientation == .landscapeLeft ? bounceOffset * 0.35 : -bounceOffset * 0.35)
                        )
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: orientation)
            .onDisappear {
                holdCompareTask?.cancel()
                holdCompareTask = nil
                touchDownActive = false
            }
        }
    }

    private func groupBadgePill(shownPreset: PhotographicStylePreset, isComparingOriginal: Bool) -> some View {
        Text(isComparingOriginal ? "ORIGINAL" : shownPreset.group.badgeTitle)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .tracking(0.8)
            .foregroundColor(
                isComparingOriginal
                    ? Color.black
                    : AlignTheme.studioInkPrimary.opacity(0.90)
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isComparingOriginal ? AlignTheme.studioAccent : Color.black.opacity(0.46))
                    .overlay(Capsule().stroke(Color.white.opacity(isComparingOriginal ? 0.0 : 0.12), lineWidth: 0.5))
            )
            .animation(.easeOut(duration: 0.16), value: shownPreset.group)
            .animation(.easeOut(duration: 0.14), value: isComparingOriginal)
    }

    /// Tính cửa sổ 5 chỉ báo trang chuẩn Camera gốc iOS (khớp video mẫu: `[• ● • • ▢]` khi ở Undertones, `[• • ▢ • •]` ở Standard, `[▢ • ● • •]` ở Moods).
    private func visibleCarouselPresets(for activePreset: PhotographicStylePreset) -> [(preset: PhotographicStylePreset, isEdgeContinuation: Bool)] {
        let all = allPresets
        guard let activeIdx = all.firstIndex(of: activePreset),
              let stdIdx = all.firstIndex(of: .standard) else {
            return all.prefix(5).map { ($0, false) }
        }

        if activeIdx == stdIdx {
            let start = max(0, stdIdx - 2)
            let end = min(all.count - 1, stdIdx + 2)
            return (start...end).map { idx in
                let isEdge = (idx == start && start > 0) || (idx == end && end < all.count - 1)
                return (all[idx], isEdge)
            }
        } else if activeIdx < stdIdx {
            // Đang ở nhóm Undertones (bên trái Standard): luôn giữ ô vuông ▢ Standard ở rìa phải + 4 chấm Undertone quanh vị trí hiện tại
            let maxUndertoneIdx = stdIdx - 1
            let start = max(0, min(activeIdx - 1, maxUndertoneIdx - 3))
            let end = min(maxUndertoneIdx, start + 3)
            var result: [(PhotographicStylePreset, Bool)] = []
            for idx in start...end {
                let isLeftEdge = (idx == start && start > 0)
                result.append((all[idx], isLeftEdge))
            }
            result.append((.standard, false))
            return result
        } else {
            // Đang ở nhóm Moods (bên phải Standard): luôn giữ ô vuông ▢ Standard ở rìa trái + 4 chấm Mood quanh vị trí hiện tại
            let minMoodIdx = stdIdx + 1
            let maxMoodIdx = all.count - 1
            let start = max(minMoodIdx, min(activeIdx - 1, maxMoodIdx - 3))
            let end = min(maxMoodIdx, start + 3)
            var result: [(PhotographicStylePreset, Bool)] = [(.standard, false)]
            for idx in start...end {
                let isRightEdge = (idx == end && end < maxMoodIdx)
                result.append((all[idx], isRightEdge))
            }
            return result
        }
    }

    private func styleNameAndDotsStack(shownPreset: PhotographicStylePreset) -> some View {
        let carouselItems = visibleCarouselPresets(for: shownPreset)

        return VStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(shownPreset.englishCode)
                    .font(.system(size: 12.0, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundColor(.white)

                if let tag = activeStyleSubtitleTag {
                    Text("·")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.48))
                    Text(tag.uppercased())
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(AlignTheme.studioAccent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.56))
            )
            .id("\(shownPreset.id)_\(activeStyleSubtitleTag ?? "")")
            .transition(.opacity)
            .animation(.easeOut(duration: 0.14), value: shownPreset.id)

            // Dãy 5 chỉ báo trang dạng cửa sổ trượt chuẩn Camera iOS (khớp video mẫu ROSE GOLD: `• ● • • ▢`)
            HStack(spacing: 8) {
                ForEach(carouselItems, id: \.preset.id) { item in
                    let preset = item.preset
                    let isSelected = preset == shownPreset
                    let isEdge = item.isEdgeContinuation

                    Button(action: {
                        HapticFeedbackService.shared.triggerSelectionChange()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            viewModel.selectPhotographicStylePreset(preset)
                        }
                    }) {
                        Group {
                            if preset == .standard {
                                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.white : Color.white.opacity(0.58),
                                        lineWidth: isSelected ? 1.7 : 1.35
                                    )
                                    .frame(width: isSelected ? 6.8 : 5.8, height: isSelected ? 6.8 : 5.8)
                            } else {
                                let dotSize: CGFloat = isSelected ? 7.2 : (isEdge ? 4.0 : 5.6)
                                Circle()
                                    .fill(
                                        isSelected
                                            ? Color.white
                                            : Color.white.opacity(isEdge ? 0.42 : 0.56)
                                    )
                                    .frame(width: dotSize, height: dotSize)
                            }
                        }
                        .frame(width: 11, height: 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: shownPreset)
        }
    }
}

// MARK: - 4. Bottom Control Deck (Tự động xoay ngang Trái/Phải mượt như Camera gốc iPhone 16/17 + 120Hz Zero-Lag Drag)
/// Nút Reset tách riêng để chỉ tự cập nhật khi `liveHUD.isModifiedFromDefault` đổi, tuyệt đối không làm re-diff Pad 2D khi đang kéo.
private struct PhotographicStyleCornerResetButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var liveHUD: PhotographicStyleLiveHUDState
    let angle: Double

    var body: some View {
        Button(action: {
            viewModel.resetActivePhotographicStylePreset()
        }) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(
                    liveHUD.isModifiedFromDefault
                        ? AlignTheme.studioInkPrimary
                        : AlignTheme.studioInkPrimary.opacity(0.28)
                )
                .rotationEffect(.degrees(angle))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.white.opacity(liveHUD.isModifiedFromDefault ? 0.13 : 0.06))
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!liveHUD.isModifiedFromDefault)
        .accessibilityLabel("Đặt lại bảng màu về mặc định")
    }
}

public struct PhotographicStylesBottomControlDeck: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var orientationMonitor: PhotographicStyleOrientationMonitor
    let compact: Bool

    @State private var isPressingQuickShutter: Bool = false
    @State private var isShowingTextureTab: Bool = false
    @State private var isShowingRecipesSheet: Bool = false

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self._orientationMonitor = ObservedObject(wrappedValue: viewModel.styleOrientationMonitor)
        self.compact = compact
    }

    public var body: some View {
        let split = viewModel.photographicStyleSplit
        let style = split.isActive ? split.dominantStyle : viewModel.activeInteractivePhotographicStyle
        let hasTextureOrGrain = style.hasTextureOrGrain
        let orientation = orientationMonitor.orientation
        let isLandscape = orientation.isLandscape
        let angle = orientation.rotationDegrees

        // Cỡ Pad tối ưu để khi xoay ngang ±90° vẫn còn trọn chỗ cho nút chụp dưới Pad, không bao giờ cắt cạnh trên iPhone SE
        let activePadSide: CGFloat = isLandscape ? (compact ? 82 : 92) : (compact ? 92 : 104)
        let sliderHeight: CGFloat = compact ? 15 : 17
        let shutterOuterSize: CGFloat = isLandscape ? (compact ? 34 : 38) : (compact ? 42 : 44)
        let shutterInnerSize: CGFloat = isLandscape ? (compact ? 26 : 30) : (compact ? 33 : 35)

        ZStack {
            // 1. Các nút góc cố định đặt ở lớp nền (không bao giờ chắn cảm ứng của Pad/Slider) và xoay biểu tượng thuận mắt
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                    Button(action: {
                        HapticFeedbackService.shared.triggerLight()
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                            isShowingTextureTab.toggle()
                        }
                    }) {
                        Image(systemName: isShowingTextureTab ? "square.grid.3x3.fill" : "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(
                                (isShowingTextureTab || hasTextureOrGrain)
                                    ? Color.black
                                    : AlignTheme.studioInkPrimary.opacity(0.86)
                            )
                            .rotationEffect(.degrees(angle))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(
                                        (isShowingTextureTab || hasTextureOrGrain)
                                            ? AlignTheme.studioAccent
                                            : Color.white.opacity(0.11)
                                    )
                                    .overlay(
                                        Circle().stroke(
                                            Color.white.opacity((isShowingTextureTab || hasTextureOrGrain) ? 0.0 : 0.14),
                                            lineWidth: 0.6
                                        )
                                    )
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(isShowingTextureTab ? "Back to 2D Palette Pad" : "Open Texture & Grain")

                    Spacer(minLength: 0)

                    Button(action: {
                        HapticFeedbackService.shared.triggerLight()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            viewModel.isShowingPhotographicStylePad = false
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13.0, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .rotationEffect(.degrees(angle))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Close Photographic Styles Pad")
                }
                .padding(.vertical, compact ? 10 : 12)

                Spacer()

                // Góc dưới-phải: nút Reset nhanh (khớp video mẫu, xoay thuận chiều ngang/dọc)
                VStack {
                    Spacer()
                    PhotographicStyleCornerResetButton(
                        viewModel: viewModel,
                        liveHUD: viewModel.liveStyleHUD,
                        angle: angle
                    )
                }
                .padding(.vertical, compact ? 10 : 12)
            }
            .padding(.horizontal, compact ? 14 : 20)

            // 2. Cụm trung tâm xoay mượt như video mẫu (đặt trên lớp góc để luôn ưu tiên cảm ứng 100%):
            //    - Portrait (0°): Pad vuông ở giữa + thanh Palette nằm ngang ngay bên dưới
            //    - Landscape-Left (+90°): xoay +90° -> thanh Palette đứng dọc bên TRÁI Pad (ấm ở trên, đậm ở dưới)
            //    - Landscape-Right (-90°): xoay -90° -> thanh Palette đứng dọc bên PHẢI Pad (ấm ở dưới, đậm ở trên)
            if isShowingTextureTab {
                PhotographicStyleTextureDeckView(viewModel: viewModel, compact: compact)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                VStack(spacing: compact ? 1 : 3) {
                    PhotographicStyleDotGridPad(
                        preset: style.preset,
                        tone: style.tone,
                        color: style.color,
                        padSize: activePadSide,
                        onDragStateChanged: { dragging in
                            viewModel.activePhotographicStyleAxis = dragging ? .pad2D : .none
                            if !dragging {
                                viewModel.commitInteractivePhotographicStyle()
                            }
                        },
                        onInteractiveUpdate: { newTone, newColor in
                            viewModel.updatePhotographicStyleInteractive(tone: newTone, color: newColor)
                        },
                        onDiscreteUpdate: { newTone, newColor in
                            viewModel.updatePhotographicStyle(tone: newTone, color: newColor)
                        },
                        onDoubleTapReset: {
                            viewModel.resetPhotographicStyleAxesOnly()
                        }
                    )

                    PhotographicPalettePillSlider(
                        value: style.palette,
                        preset: style.preset,
                        width: activePadSide,
                        height: sliderHeight,
                        onDragStateChanged: { dragging in
                            viewModel.activePhotographicStyleAxis = dragging ? .palette : .none
                            if !dragging {
                                viewModel.commitInteractivePhotographicStyle()
                            }
                        },
                        onInteractiveUpdate: { newPal in
                            viewModel.updatePhotographicStyleInteractive(palette: newPal)
                        }
                    )
                }
                .rotationEffect(.degrees(angle))
                .offset(
                    x: isLandscape ? (orientation == .landscapeLeft ? -7 : 7) : 0,
                    y: isLandscape ? (compact ? -18 : -20) : 0
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // 3. Nút chụp nhanh lướt mượt theo vòng cung từ bên PHẢI Pad (Portrait) xuống chính giữa DƯỚI Pad (Landscape Trái & Phải)
            Button(action: triggerQuickCapture) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.90), lineWidth: isLandscape ? 2.0 : 2.2)
                        .frame(width: shutterOuterSize, height: shutterOuterSize)

                    Circle()
                        .fill(Color.white)
                        .frame(width: shutterInnerSize, height: shutterInnerSize)
                        .scaleEffect(isPressingQuickShutter ? 0.88 : 1.0)
                }
                .contentShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressingQuickShutter {
                            withAnimation(.easeOut(duration: 0.08)) { isPressingQuickShutter = true }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) { isPressingQuickShutter = false }
                    }
            )
            .rotationEffect(.degrees(angle))
            .offset(
                x: isShowingTextureTab
                    ? (compact ? 132 : 148)
                    : (isLandscape ? 0 : (activePadSide * 0.5 + (compact ? 56 : 64))),
                y: isShowingTextureTab
                    ? -22
                    : (isLandscape ? (compact ? 47 : 51) : -6)
            )
            .accessibilityLabel("Chụp ảnh ngay với phong cách màu hiện tại")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.80), value: orientation)
        .sheet(isPresented: $isShowingRecipesSheet) {
            PhotographicStyleRecipesSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func triggerQuickCapture() {
        guard viewModel.aiSessionState != .capturing else { return }
        viewModel.commitInteractivePhotographicStyle()
        HapticFeedbackService.shared.triggerLight()
        if viewModel.isUltraSharpEnabled && viewModel.captureMode == .photo && viewModel.featureAvailability(.ultraSharp).isAvailable {
            viewModel.performUltraSharpPhotoCapture()
        } else {
            viewModel.takePhotoManual()
        }
    }
}

// MARK: - 4b. Photographic Styles 3 — Live 60 FPS Texture & Grain Deck (Standard / Soft Skin / Glow / Film + Independent Grain)
private struct PhotographicStyleTextureDeckView: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    var body: some View {
        let style = viewModel.photographicStyle
        let activeMode = style.textureMode
        let showTextureSlider = activeMode != .standard
        let showGrainSlider = !showTextureSlider && style.grainEnabled

        VStack(spacing: compact ? 10 : 12) {
            // Row 1: 4 Texture pills | thin divider | independent circular Grain button
            HStack(spacing: compact ? 4 : 5) {
                HStack(spacing: 2) {
                    ForEach(PhotographicTextureMode.allCases) { mode in
                        let isSelected = activeMode == mode
                        Button(action: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                viewModel.selectPhotographicTextureMode(mode)
                            }
                        }) {
                            Text(mode.displayName)
                                .font(.system(size: compact ? 9.5 : 10.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundColor(isSelected ? Color.black : Color.white.opacity(0.84))
                                .lineLimit(1)
                                .padding(.horizontal, compact ? 6.5 : 8.5)
                                .frame(height: 28)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Color.white : Color.clear)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(2)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.11))
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                )

                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 1, height: 18)

                // Independent Grain toggle (nút tròn Grain độc lập chuẩn Styles 3)
                Button(action: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        viewModel.togglePhotographicGrain()
                    }
                }) {
                    VStack(spacing: 0) {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 12, weight: .bold))
                        Text("Grain")
                            .font(.system(size: 7.0, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(style.grainEnabled ? Color.black : Color.white.opacity(0.76))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(style.grainEnabled ? Color.white : Color.white.opacity(0.11))
                            .overlay(Circle().stroke(Color.white.opacity(style.grainEnabled ? 0.0 : 0.16), lineWidth: 0.6))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(style.grainEnabled ? "Disable Film Grain" : "Enable Film Grain")
            }

            // Row 2: Precision 0-100 tick slider for active Texture OR Grain
            if showTextureSlider {
                PhotographicTextureTickSlider(
                    title: activeMode.sliderTitle,
                    value: Binding(
                        get: { viewModel.photographicStyle.textureIntensity },
                        set: { viewModel.updatePhotographicTextureIntensity($0) }
                    ),
                    width: compact ? 186 : 216,
                    onDragStateChanged: { dragging in
                        viewModel.activePhotographicStyleAxis = dragging ? .texture : .none
                    }
                )
            } else if showGrainSlider {
                PhotographicTextureTickSlider(
                    title: "GRAIN",
                    value: Binding(
                        get: { viewModel.photographicStyle.grainAmount },
                        set: { viewModel.updatePhotographicGrain(amount: $0) }
                    ),
                    width: compact ? 186 : 216,
                    onDragStateChanged: { dragging in
                        viewModel.activePhotographicStyleAxis = dragging ? .texture : .none
                    }
                )
            } else {
                Text("Xem trước Kết cấu & Hạt 60 FPS trực tiếp")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.46))
                    .frame(height: 36)
            }
        }
    }
}

private struct PhotographicTextureTickSlider: View {
    let title: String
    @Binding var value: Float
    let width: CGFloat
    let onDragStateChanged: (Bool) -> Void

    @State private var isDragging: Bool = false
    @State private var lastStep: Int = 0

    var body: some View {
        let clamped = CGFloat(max(0.0, min(1.0, value)))
        let percent = Int(round(clamped * 100.0))

        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(Color.white.opacity(0.66))
                Spacer()
                Text("\(percent)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(percent)))
                    .foregroundColor(AlignTheme.studioAccent)
                    .animation(.snappy(duration: 0.14), value: percent)
            }
            .frame(width: width)

            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let tickCount = 25
                    let inset: CGFloat = 4
                    let usable = max(1, size.width - inset * 2)
                    let activeX = inset + clamped * usable
                    for i in 0..<tickCount {
                        let frac = CGFloat(i) / CGFloat(tickCount - 1)
                        let x = inset + frac * usable
                        let isMajor = (i % 6 == 0)
                        let h: CGFloat = isMajor ? 12 : 7
                        let isFilled = x <= activeX + 0.5
                        let rect = CGRect(x: x - 0.75, y: (size.height - h) * 0.5, width: 1.5, height: h)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 0.75),
                            with: .color(isFilled ? Color.white.opacity(0.94) : Color.white.opacity(0.28))
                        )
                    }
                    let knobRect = CGRect(x: activeX - 2.0, y: (size.height - 17) * 0.5, width: 4.0, height: 17)
                    context.fill(
                        Path(roundedRect: knobRect, cornerRadius: 2.0),
                        with: .color(AlignTheme.studioAccent)
                    )
                }
            }
            .frame(width: width, height: 22)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            lastStep = Int(round(value * 20.0))
                            onDragStateChanged(true)
                        }
                        let norm = Float(max(0.0, min(1.0, (drag.location.x - 4) / max(1, width - 8))))
                        let step = Int(round(norm * 20.0))
                        if step != lastStep {
                            HapticFeedbackService.shared.triggerPadGridTick()
                            lastStep = step
                        }
                        value = norm
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragStateChanged(false)
                    }
            )
        }
    }
}

// MARK: - 4c. Saved & Benchmark Photographic Style Recipes Sheet
private struct PhotographicStyleRecipesSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newRecipeName: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Save Current Style Card
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LƯU CÔNG THỨC HIỆN TẠI")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundColor(Color.white.opacity(0.55))

                        let s = viewModel.photographicStyle
                        Text("\(s.preset.displayName) · Tone \(s.toneDisplayText) · Color \(s.colorDisplayText) · Pal \(s.palettePercent)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(AlignTheme.studioAccent)

                        HStack(spacing: 8) {
                            TextField("Tên công thức (vd: Nắng chiều)...", text: $newRecipeName)
                                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                )

                            Button(action: {
                                let name = newRecipeName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                viewModel.saveCurrentPhotographicRecipe(name: name)
                                newRecipeName = ""
                            }) {
                                Text("Lưu")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 16)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(AlignTheme.studioAccent)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(newRecipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                            )
                    )

                    if !viewModel.savedPhotographicRecipes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("CÔNG THỨC CỦA BẠN")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .tracking(0.6)
                                .foregroundColor(Color.white.opacity(0.55))

                            ForEach(viewModel.savedPhotographicRecipes) { recipe in
                                recipeRow(recipe, canDelete: true)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("CÔNG THỨC CHUẨN NHIẾP ẢNH")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundColor(Color.white.opacity(0.55))

                        ForEach(PhotographicStyleCustomRecipe.builtInBenchmarks) { recipe in
                            recipeRow(recipe, canDelete: false)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.07, green: 0.07, blue: 0.08).ignoresSafeArea())
            .navigationTitle("Công thức bảng màu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                        .foregroundColor(AlignTheme.studioAccent)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func recipeRow(_ recipe: PhotographicStyleCustomRecipe, canDelete: Bool) -> some View {
        let isActive = viewModel.photographicStyle == recipe.state
        return HStack(spacing: 10) {
            Button(action: {
                viewModel.applyPhotographicRecipe(recipe)
                dismiss()
            }) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [recipe.state.preset.padTopRightColor, recipe.state.preset.padBottomRightColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.name)
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                        Text(recipe.subtitle)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.58))
                            .lineLimit(1)
                    }

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if canDelete {
                Button(action: {
                    viewModel.deletePhotographicRecipe(id: recipe.id)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.red.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? AlignTheme.studioAccent.opacity(0.14) : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? AlignTheme.studioAccent.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - Animatable 11x11 Liquid-Matrix Dot Grid Canvas (Apple iOS 18/26/27 Rectilinear Swell Crown + Velocity Wake Trail)
private struct PhotographicStyleDotGridCanvas: View, Animatable {
    var tone: Float
    var color: Float
    var wakeTone: Float
    var wakeColor: Float
    var dragGlow: Double
    let defaultTone: Float
    let defaultColor: Float

    var animatableData: AnimatablePair<
        AnimatablePair<Double, Double>,
        AnimatablePair<AnimatablePair<Double, Double>, Double>
    > {
        get {
            AnimatablePair(
                AnimatablePair(Double(tone), Double(color)),
                AnimatablePair(AnimatablePair(Double(wakeTone), Double(wakeColor)), dragGlow)
            )
        }
        set {
            tone = Float(newValue.first.first)
            color = Float(newValue.first.second)
            wakeTone = Float(newValue.second.first.first)
            wakeColor = Float(newValue.second.first.second)
            dragGlow = newValue.second.second
        }
    }

    /// Khoảng cách bình phương từ điểm lưới `(px, py)` tới đoạn thẳng vệt chuyển động `[(ax, ay) -> (bx, by)]`.
    @inline(__always)
    private static func segmentDistanceSquared(
        px: CGFloat, py: CGFloat,
        ax: CGFloat, ay: CGFloat,
        bx: CGFloat, by: CGFloat
    ) -> CGFloat {
        let abx = bx - ax
        let aby = by - ay
        let lenSq = abx * abx + aby * aby
        if lenSq < 1e-5 {
            let dx = px - bx
            let dy = py - by
            return dx * dx + dy * dy
        }
        let t = max(0.0, min(1.0, ((px - ax) * abx + (py - ay) * aby) / lenSq))
        let cx = ax + t * abx
        let cy = ay + t * aby
        let dx = px - cx
        let dy = py - cy
        return dx * dx + dy * dy
    }

    var body: some View {
        Canvas { context, size in
            let inset = size.width * 0.115
            let span = max(1, size.width - inset * 2.0)
            let step = span / 10.0

            let thumbCol = CGFloat((color + 1.0) * 5.0)
            let thumbRow = CGFloat((1.0 - tone) * 5.0)
            let wakeCol = CGFloat((wakeColor + 1.0) * 5.0)
            let wakeRow = CGFloat((1.0 - wakeTone) * 5.0)
            let thumbX = inset + thumbCol * step
            let thumbY = inset + thumbRow * step
            let glow = CGFloat(max(0.0, min(1.0, dragGlow)))

            // Chuẩn quang học từ video mẫu iPhone 16/17 Pro:
            // - Mỗi chấm lưới nằm cố định tuyệt đối trên giao điểm (col, row) (không đẩy lệch hàng/cột!)
            // - Khi kéo con trỏ, cụm chấm trong bán kính ~2.4 ô xung quanh quả cầu trắng phồng to thành các đĩa tròn bán trong suốt
            //   (đường kính lên tới ~0.92 * step ≈ 8.5pt) kết hợp vệt đuôi mượt dọc quỹ đạo lướt tay.
            let invLeadSigmaSq: CGFloat = 1.0 / (1.38 * 1.38 * 2.0)
            let invWakeSigmaSq: CGFloat = 1.0 / (1.15 * 1.15 * 2.0)
            let ambientDotR: CGFloat = max(0.75, step * 0.102)

            for row in 0...10 {
                let rowF = CGFloat(row)
                let baseY = inset + rowF * step
                let dRow = rowF - thumbRow
                let dRowAbs = abs(dRow)
                let dRowSq = dRow * dRow

                // Nội suy mượt (smoothstep) giữa 2 hàng kế cận để đường chữ thập lướt êm từ hàng này sang hàng khác không nhảy bậc
                let rawRowW = max(0.0, 1.0 - dRowAbs / 0.72)
                let rowCrossW = rawRowW * rawRowW * (3.0 - 2.0 * rawRowW)

                for col in 0...10 {
                    let colF = CGFloat(col)
                    let baseX = inset + colF * step
                    let dCol = colF - thumbCol
                    let dColAbs = abs(dCol)
                    let distSq = dCol * dCol + dRowSq
                    let isOrigin = (row == 5 && col == 5)

                    let rawColW = max(0.0, 1.0 - dColAbs / 0.72)
                    let colCrossW = rawColW * rawColW * (3.0 - 2.0 * rawColW)
                    let crossW = max(rowCrossW, colCrossW)

                    let trailSq = glow > 0.01
                        ? Self.segmentDistanceSquared(px: colF, py: rowF, ax: wakeCol, ay: wakeRow, bx: thumbCol, by: thumbRow)
                        : distSq

                    // Bỏ qua sqrt() & exp() cho các chấm ở xa cả con trỏ lẫn vệt đuôi và không nằm trên trục chữ thập
                    if distSq > 14.0 && trailSq > 11.0 && !isOrigin && crossW <= 0.001 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: baseX - ambientDotR, y: baseY - ambientDotR, width: ambientDotR * 2, height: ambientDotR * 2)),
                            with: .color(Color.white.opacity(0.25))
                        )
                        continue
                    }

                    let distGrid = sqrt(distSq)
                    let leadField: CGFloat = distSq < 14.0 ? exp(-distSq * invLeadSigmaSq) : 0.0
                    let wakeField: CGFloat = (glow > 0.01 && trailSq < 11.0) ? (exp(-trailSq * invWakeSigmaSq) * 0.78) : 0.0
                    let swell = max(leadField, wakeField) * glow

                    if isOrigin {
                        let ringR: CGFloat = step * (0.22 + 0.07 * swell)
                        let ringRect = CGRect(x: baseX - ringR, y: baseY - ringR, width: ringR * 2, height: ringR * 2)
                        let ringAlpha = min(0.82, 0.38 + 0.30 * swell + 0.18 * crossW)
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(Color.white.opacity(ringAlpha)),
                            lineWidth: 0.90
                        )
                    } else {
                        let baseRadius: CGFloat = ambientDotR + (step * 0.045) * crossW
                        let swellCurve: CGFloat = swell > 0.0001 ? pow(swell, 0.88) : 0.0
                        let swellRadius: CGFloat = (step * 0.45) * swellCurve
                        let radius = baseRadius + swellRadius

                        let axisFade = max(0.36, 1.0 - distGrid * 0.052)
                        let baseAlpha: CGFloat = 0.25 + (0.63 * axisFade * (1.0 - 0.20 * glow)) * crossW
                        let swellAlpha: CGFloat = (0.52 + 0.22 * crossW) * swellCurve
                        let alpha = min(0.84, max(baseAlpha, swellAlpha))

                        let dotRect = CGRect(x: baseX - radius, y: baseY - radius, width: radius * 2, height: radius * 2)
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(Color.white.opacity(alpha))
                        )
                    }
                }
            }

            // Chấm đặc đánh dấu tọa độ mặc định của từng phong cách (vd: Rose Gold tại (-20, -20), luôn hiện rõ như video mẫu)
            if abs(defaultTone) > 0.015 || abs(defaultColor) > 0.015 {
                let defX = inset + CGFloat((defaultColor + 1.0) * 0.5) * span
                let defY = inset + CGFloat((1.0 - defaultTone) * 0.5) * span
                let distToCursorPx = hypot(defX - thumbX, defY - thumbY)
                let hideRadiusPx = step * (0.45 + 0.70 * glow)
                if distToCursorPx > hideRadiusPx {
                    let defR: CGFloat = max(2.15, step * 0.28)
                    let defRect = CGRect(x: defX - defR, y: defY - defR, width: defR * 2, height: defR * 2)
                    context.fill(
                        Path(ellipseIn: defRect),
                        with: .color(Color.white.opacity(0.78))
                    )
                }
            }
        }
    }
}

// MARK: - Apple-Calibrated White Cursor Orb (Idle ~1.12x Step Dot -> Dragging ~2.68x Step Thumb Orb + Crisp Rim Halo)
private struct PhotographicStyleLuminousCursor: View, Animatable {
    var tone: Float
    var color: Float
    var dragGlow: Double
    let padSize: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(Double(tone), Double(color)), dragGlow) }
        set {
            tone = Float(newValue.first.first)
            color = Float(newValue.first.second)
            dragGlow = newValue.second
        }
    }

    private var gridInset: CGFloat { padSize * 0.115 }
    private var usableSpan: CGFloat { max(1, padSize - gridInset * 2.0) }
    private var gridStep: CGFloat { usableSpan / 10.0 }

    private var cursorPoint: CGPoint {
        let nx = CGFloat((color + 1.0) * 0.5)
        let ny = CGFloat((1.0 - tone) * 0.5)
        return CGPoint(
            x: gridInset + nx * usableSpan,
            y: gridInset + ny * usableSpan
        )
    }

    var body: some View {
        let g = CGFloat(max(0.0, min(1.0, dragGlow)))
        let idleDiameter = max(8.6, gridStep * 1.12)
        let expandedAdd = max(12.2, gridStep * 1.58)
        let coreDiameter: CGFloat = idleDiameter + expandedAdd * g
        let outerAuraDiameter: CGFloat = coreDiameter + 5.0 + 4.5 * g

        ZStack {
            if g > 0.01 {
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.white.opacity(0.46 * g), location: 0.0),
                                .init(color: Color.white.opacity(0.18 * g), location: 0.65),
                                .init(color: Color.clear, location: 1.0)
                            ]),
                            center: .center,
                            startRadius: coreDiameter * 0.44,
                            endRadius: outerAuraDiameter * 0.5
                        )
                    )
                    .frame(width: outerAuraDiameter, height: outerAuraDiameter)
            }

            Circle()
                .fill(Color.white)
                .frame(width: coreDiameter, height: coreDiameter)
                .shadow(color: Color.black.opacity(0.22), radius: 1.6, y: 0.5)
        }
        .position(cursorPoint)
    }
}

// MARK: - Interactive Compact 2D Control Pad (Zero-Latency 120Hz Direct Drag + 1€ De-Jitter Filter + Velocity Liquid Wake + Double-Tap Reset)
private struct PhotographicStyleDotGridPad: View {
    let preset: PhotographicStylePreset
    let tone: Float
    let color: Float
    let padSize: CGFloat
    let onDragStateChanged: (Bool) -> Void
    let onInteractiveUpdate: (Float, Float) -> Void
    let onDiscreteUpdate: (Float, Float) -> Void
    let onDoubleTapReset: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragSessionActive: Bool = false
    @State private var hasMovedPastTapThreshold: Bool = false
    @State private var dragTone: Float = 0.0
    @State private var dragColor: Float = 0.0
    @State private var wakeTone: Float = 0.0
    @State private var wakeColor: Float = 0.0
    @State private var dragStartTone: Float = 0.0
    @State private var dragStartColor: Float = 0.0
    @State private var snappedToZeroX: Bool = true
    @State private var snappedToZeroY: Bool = true
    @State private var snappedToPresetDefault: Bool = false
    @State private var oneEuroFilter = PhotographicStyleOneEuroFilter2D(
        minCutoff: 1.45,
        beta: 0.36,
        dCutoff: 1.0,
        radialDeadband: 0.0045
    )
    @State private var lastEmittedTone: Float = 0.0
    @State private var lastEmittedColor: Float = 0.0
    @State private var lastTickStepX: Int = 0
    @State private var lastTickStepY: Int = 0
    @State private var lastTapTimestamp: CFTimeInterval = 0

    // Magnetic zero-snap & preset-default snap hysteresis thresholds
    private let snapEnterDeadzone: Float = 0.04
    private let snapExitDeadzone: Float = 0.065
    private let defaultSnapEnterRadius: Float = 0.035
    private let defaultSnapExitRadius: Float = 0.058

    private var gridInset: CGFloat { padSize * 0.115 }
    private var usableSpan: CGFloat { max(1, padSize - gridInset * 2.0) }
    private var cornerRadius: CGFloat { padSize < 100 ? 18 : 20 }

    var body: some View {
        let dragGlow: Double = isDragging ? 1.0 : 0.0
        let shownTone: Float = isDragging ? dragTone : tone
        let shownColor: Float = isDragging ? dragColor : color
        let shownWakeTone: Float = isDragging ? wakeTone : tone
        let shownWakeColor: Float = isDragging ? wakeColor : color
        let glideAnimation: Animation? = isDragging ? nil : .spring(response: 0.26, dampingFraction: 0.80)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.56, green: 0.55, blue: 0.57),
                            Color(red: 0.30, green: 0.29, blue: 0.31),
                            Color(red: 0.08, green: 0.08, blue: 0.09)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    preset.padTopRightColor.opacity(0.66)
                                ],
                                startPoint: .leading,
                                endPoint: .topTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    preset.padBottomRightColor.opacity(0.76)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .animation(.easeInOut(duration: 0.24), value: preset)

            // Lưới 11x11 chấm: tâm chính bám tay 0ms, vệt đuôi (wakeTone/wakeColor) lướt đàn hồi tạo hiệu ứng sóng chấm Apple
            PhotographicStyleDotGridCanvas(
                tone: shownTone,
                color: shownColor,
                wakeTone: shownWakeTone,
                wakeColor: shownWakeColor,
                dragGlow: dragGlow,
                defaultTone: preset.defaultTone,
                defaultColor: preset.defaultColor
            )
            .animation(glideAnimation, value: shownTone)
            .animation(glideAnimation, value: shownColor)
            .animation(.interactiveSpring(response: 0.17, dampingFraction: 0.82), value: shownWakeTone)
            .animation(.interactiveSpring(response: 0.17, dampingFraction: 0.82), value: shownWakeColor)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: dragGlow)
            .allowsHitTesting(false)

            // Quả cầu con trỏ trắng mịn phóng to 2.68x ô lưới khi chạm giữ và thu gọn sắc nét khi nhả tay
            PhotographicStyleLuminousCursor(
                tone: shownTone,
                color: shownColor,
                dragGlow: dragGlow,
                padSize: padSize
            )
            .animation(glideAnimation, value: shownTone)
            .animation(glideAnimation, value: shownColor)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: dragGlow)
            .allowsHitTesting(false)
        }
        .frame(width: padSize, height: padSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.65)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let now = CACurrentMediaTime()
                    if !dragSessionActive {
                        dragSessionActive = true
                        hasMovedPastTapThreshold = false
                        dragStartTone = tone
                        dragStartColor = color
                        dragTone = tone
                        dragColor = color
                        wakeTone = tone
                        wakeColor = color
                        lastEmittedTone = tone
                        lastEmittedColor = color
                        snappedToZeroX = abs(color) < 0.005
                        snappedToZeroY = abs(tone) < 0.005
                        snappedToPresetDefault = hypot(color - preset.defaultColor, tone - preset.defaultTone) < 0.008
                        oneEuroFilter.reset(x: color, y: tone, timestamp: now)
                        lastTickStepX = Int(round(color * 10.0))
                        lastTickStepY = Int(round(tone * 10.0))
                        isDragging = true
                        onDragStateChanged(true)
                    }

                    let travel = hypot(value.translation.width, value.translation.height)
                    if !hasMovedPastTapThreshold && travel >= 3.0 {
                        hasMovedPastTapThreshold = true
                    }
                    guard hasMovedPastTapThreshold else { return }

                    // Relative 1:1 Delta Drag trong hệ tọa độ cục bộ (tự đúng hướng ở cả 0°, +90°, -90°)
                    let halfSpan = max(1.0, usableSpan * 0.5)
                    let unsmoothedColor = max(-1.0, min(1.0, dragStartColor + Float(value.translation.width / halfSpan)))
                    let unsmoothedTone = max(-1.0, min(1.0, dragStartTone - Float(value.translation.height / halfSpan)))

                    // Lọc khử rung 1€ thích ứng theo tốc độ + khóa Deadband khi giữ yên ngón tay
                    let filtered = oneEuroFilter.filter(x: unsmoothedColor, y: unsmoothedTone, timestamp: now)
                    var finalColor = applyHysteresisSnap(raw: filtered.x, wasSnapped: &snappedToZeroX)
                    var finalTone = applyHysteresisSnap(raw: filtered.y, wasSnapped: &snappedToZeroY)

                    // Hysteresis 2 ngưỡng cho mốc mặc định của Preset (ngăn nhảy ±4.5% qua lại khi giữ tay sát chấm mặc định)
                    if abs(preset.defaultColor) > 0.01 || abs(preset.defaultTone) > 0.01 {
                        let distToDefault = hypot(finalColor - preset.defaultColor, finalTone - preset.defaultTone)
                        if snappedToPresetDefault {
                            if distToDefault < defaultSnapExitRadius {
                                finalColor = preset.defaultColor
                                finalTone = preset.defaultTone
                            } else {
                                snappedToPresetDefault = false
                            }
                        } else if distToDefault <= defaultSnapEnterRadius {
                            snappedToPresetDefault = true
                            finalColor = preset.defaultColor
                            finalTone = preset.defaultTone
                        }
                    }

                    // Cổng chặn vi sai (Emission Deadband Gate): khi ngón tay giữ yên, không phát lại lệnh GPU/HUD thừa
                    guard abs(finalTone - lastEmittedTone) >= 0.0008 || abs(finalColor - lastEmittedColor) >= 0.0008 else {
                        return
                    }
                    lastEmittedTone = finalTone
                    lastEmittedColor = finalColor
                    dragTone = finalTone
                    dragColor = finalColor
                    wakeTone = finalTone
                    wakeColor = finalColor
                    fireDetentHaptics(newColor: finalColor, newTone: finalTone)
                    onInteractiveUpdate(finalTone, finalColor)
                }
                .onEnded { value in
                    let wasTap = !hasMovedPastTapThreshold
                    dragSessionActive = false
                    hasMovedPastTapThreshold = false
                    isDragging = false
                    onDragStateChanged(false)

                    guard wasTap else { return }

                    let now = CACurrentMediaTime()
                    if now - lastTapTimestamp < 0.28 {
                        lastTapTimestamp = 0
                        HapticFeedbackService.shared.triggerMedium()
                        onDoubleTapReset()
                    } else {
                        lastTapTimestamp = now
                        let normX = (value.location.x - gridInset) / usableSpan
                        let normY = (value.location.y - gridInset) / usableSpan
                        let tappedColor = max(-1.0, min(1.0, Float(normX * 2.0 - 1.0)))
                        let tappedTone = max(-1.0, min(1.0, Float(1.0 - normY * 2.0)))
                        let snappedC = abs(tappedColor) <= snapEnterDeadzone ? 0.0 : tappedColor
                        let snappedT = abs(tappedTone) <= snapEnterDeadzone ? 0.0 : tappedTone

                        if snappedC == 0.0 && snappedT == 0.0 {
                            HapticFeedbackService.shared.triggerMedium()
                        } else {
                            HapticFeedbackService.shared.triggerLight()
                        }
                        onDiscreteUpdate(snappedT, snappedC)
                    }
                }
        )
    }

    private func applyHysteresisSnap(raw: Float, wasSnapped: inout Bool) -> Float {
        if wasSnapped {
            if abs(raw) < snapExitDeadzone {
                return 0.0
            } else {
                wasSnapped = false
                return raw
            }
        } else {
            if abs(raw) <= snapEnterDeadzone {
                wasSnapped = true
                return 0.0
            } else {
                return raw
            }
        }
    }

    private func fireDetentHaptics(newColor: Float, newTone: Float) {
        let stepX = Int(round(newColor * 10.0))
        let stepY = Int(round(newTone * 10.0))
        let crossedZeroX = (stepX == 0 && lastTickStepX != 0)
        let crossedZeroY = (stepY == 0 && lastTickStepY != 0)

        if stepX == 0 && stepY == 0 && (lastTickStepX != 0 || lastTickStepY != 0) {
            HapticFeedbackService.shared.triggerMedium()
        } else if crossedZeroX || crossedZeroY {
            HapticFeedbackService.shared.triggerLight()
        } else if stepX != lastTickStepX || stepY != lastTickStepY {
            HapticFeedbackService.shared.triggerPadGridTick()
        }

        lastTickStepX = stepX
        lastTickStepY = stepY
    }
}

// MARK: - Compact Pill Palette Slider (Khớp video mẫu Apple: Rãnh tối + Dải màu lấp đầy từ trái tới núm kéo trắng)
private struct PhotographicPalettePillSlider: View {
    let value: Float
    let preset: PhotographicStylePreset
    let width: CGFloat
    let height: CGFloat
    let onDragStateChanged: (Bool) -> Void
    let onInteractiveUpdate: (Float) -> Void

    @State private var isDragging: Bool = false
    @State private var dragValue: Float = 1.0
    @State private var lastEmittedValue: Float = 1.0
    @State private var snappedToMidpoint: Bool = false
    @State private var oneEuroFilter = PhotographicStyleOneEuroFilter1D(
        minCutoff: 1.50,
        beta: 0.36,
        dCutoff: 1.0,
        stationaryDeadband: 0.0035
    )
    @State private var lastNotch: Int = 10

    private let midSnapEnter: Float = 0.016
    private let midSnapExit: Float = 0.028

    var body: some View {
        let shownValue = isDragging ? dragValue : value
        let thumbDiameter = height - 3.0
        let travelSpan = max(1, width - thumbDiameter - 3.0)
        let clamped = CGFloat(max(0.0, min(1.0, shownValue)))
        let thumbX = (thumbDiameter * 0.5) + 1.5 + clamped * travelSpan
        let activeFillWidth = min(width, max(height, thumbX + thumbDiameter * 0.5 + 1.5))

        ZStack(alignment: .leading) {
            // Rãnh nền tối bên phải núm kéo (giống hệt thanh Palette 75% trong video mẫu)
            Capsule()
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.94))

            // Dải màu đặc trưng của Style lấp đầy từ mép trái tới đúng vị trí núm trắng
            Capsule()
                .fill(
                    LinearGradient(
                        colors: preset.paletteGradientColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: activeFillWidth, height: height)
                .animation(.easeInOut(duration: 0.22), value: preset)

            Capsule()
                .stroke(Color.white.opacity(0.20), lineWidth: 0.65)

            ZStack {
                if isDragging {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.46), Color.white.opacity(0.14), Color.clear],
                                center: .center,
                                startRadius: thumbDiameter * 0.35,
                                endRadius: (thumbDiameter + 12) * 0.5
                            )
                        )
                        .frame(width: thumbDiameter + 12, height: thumbDiameter + 12)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.32), radius: 2.0, y: 0.6)
            }
            .scaleEffect(isDragging ? 1.12 : 1.0)
            .position(x: thumbX, y: height * 0.5)
            .animation(isDragging ? nil : .spring(response: 0.22, dampingFraction: 0.84), value: shownValue)
            .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isDragging)
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    let now = CACurrentMediaTime()
                    if !isDragging {
                        isDragging = true
                        dragValue = value
                        lastEmittedValue = value
                        snappedToMidpoint = abs(value - 0.5) < 0.008
                        oneEuroFilter.reset(to: value, timestamp: now)
                        lastNotch = Int(round(value * 10.0))
                        onDragStateChanged(true)
                    }
                    let norm = (drag.location.x - (thumbDiameter * 0.5 + 1.5)) / travelSpan
                    let raw = Float(max(0.0, min(1.0, norm)))
                    let filtered = oneEuroFilter.filter(raw, timestamp: now)

                    let finalVal: Float
                    let distMid = abs(filtered - 0.5)
                    if snappedToMidpoint {
                        if distMid < midSnapExit {
                            finalVal = 0.5
                        } else {
                            snappedToMidpoint = false
                            finalVal = filtered
                        }
                    } else if distMid <= midSnapEnter {
                        snappedToMidpoint = true
                        finalVal = 0.5
                    } else {
                        finalVal = filtered
                    }

                    guard abs(finalVal - lastEmittedValue) >= 0.0008 else { return }
                    lastEmittedValue = finalVal

                    let notch = Int(round(finalVal * 10.0))
                    if notch != lastNotch {
                        if notch == 0 || notch == 5 || notch == 10 {
                            HapticFeedbackService.shared.triggerLight()
                        } else {
                            HapticFeedbackService.shared.triggerPadGridTick()
                        }
                        lastNotch = notch
                    }
                    dragValue = finalVal
                    onInteractiveUpdate(finalVal)
                }
                .onEnded { _ in
                    isDragging = false
                    onDragStateChanged(false)
                }
        )
        .accessibilityLabel("Photographic Style Palette Intensity")
    }
}
