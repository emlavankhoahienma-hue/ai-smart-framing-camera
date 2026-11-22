import SwiftUI
import UIKit

// MARK: - 1. Native iOS 18 Photographic Styles Glyph (5x5 Micro-Dot Grid + Live Continuous Cursor Mirror)
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
                    // Giấu chấm nhỏ trùng ngay dưới tâm chấm con trỏ để sắc nét tuyệt đối
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
    let isCompactTopBarVariant: Bool

    public init(viewModel: CameraViewModel, isCompactTopBarVariant: Bool = false) {
        self.viewModel = viewModel
        self.isCompactTopBarVariant = isCompactTopBarVariant
    }

    private var displayedStyle: PhotographicStyleState {
        viewModel.photographicStyleSplit.isActive
            ? viewModel.photographicStyleSplit.dominantStyle
            : viewModel.photographicStyle
    }

    public var body: some View {
        let availability = viewModel.featureAvailability(.photographicStyles)
        let style = displayedStyle
        let isOpen = viewModel.isShowingPhotographicStylePad
        let isDraggingPad = viewModel.activePhotographicStyleAxis == .pad2D

        Button(action: {
            viewModel.attemptFeature(.photographicStyles) {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    viewModel.isShowingPhotographicStylePad.toggle()
                }
            }
        }) {
            PhotographicStyleLiveIconCanvas(
                tone: style.tone,
                color: style.color,
                isOpen: isOpen,
                isDraggingPad: isDraggingPad
            )
            .frame(width: 23, height: 23)
            .animation(.interactiveSpring(response: 0.11, dampingFraction: 0.88), value: style.tone)
            .animation(.interactiveSpring(response: 0.11, dampingFraction: 0.88), value: style.color)
            .animation(.easeOut(duration: 0.14), value: isDraggingPad)
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
                : (!style.isIdentity
                    ? "Photographic Styles: \(style.preset.displayName)"
                    : "Mở Photographic Styles")
        )
    }
}

// MARK: - 2. Top Bar Telemetry HUD (Replaces TopCameraBar — Native iOS 18 English Capsule + Tap-to-Edit Precision Nudge)
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

public struct PhotographicStylesTopHUDBar: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    @State private var activeNudgeMetric: PhotographicStyleNudgeMetric? = nil

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    public var body: some View {
        let style = viewModel.photographicStyleSplit.isActive
            ? viewModel.photographicStyleSplit.dominantStyle
            : viewModel.photographicStyle
        let axis = viewModel.activePhotographicStyleAxis
        let isPadDragging = axis == .pad2D
        let isPaletteDragging = axis == .palette

        HStack(spacing: 6) {
            if !compact {
                Color.clear.frame(width: 34, height: 34)
            }

            Spacer(minLength: 0)

            // Centered Hairline Capsule: TONE 00   COLOR 00   PALETTE 100   ↺ (chạm từng chỉ số để chỉnh số chính xác)
            HStack(spacing: compact ? 8 : 12) {
                hudMetricButton(
                    metric: .tone,
                    label: "TONE",
                    value: style.toneHUDNumber,
                    highlighted: isPadDragging || activeNudgeMetric == .tone,
                    dimmed: isPaletteDragging
                )

                hudMetricButton(
                    metric: .color,
                    label: "COLOR",
                    value: style.colorHUDNumber,
                    highlighted: isPadDragging || activeNudgeMetric == .color,
                    dimmed: isPaletteDragging
                )

                hudMetricButton(
                    metric: .palette,
                    label: "PALETTE",
                    value: style.paletteHUDNumber,
                    highlighted: isPaletteDragging || activeNudgeMetric == .palette,
                    dimmed: isPadDragging
                )

                Button(action: {
                    activeNudgeMetric = nil
                    viewModel.resetActivePhotographicStylePreset()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundColor(
                            style.isModifiedFromPresetDefault
                                ? AlignTheme.studioInkPrimary
                                : AlignTheme.studioInkPrimary.opacity(0.28)
                        )
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!style.isModifiedFromPresetDefault)
                .accessibilityLabel("Reset active photographic style")
            }
            .padding(.leading, compact ? 11 : 14)
            .padding(.trailing, compact ? 7 : 9)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.70))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.75)
                    )
            )

            Spacer(minLength: 0)

            // Right-edge native 5x5 live-mirror icon button (tap to dismiss)
            PhotographicStyleQuickTriggerButton(viewModel: viewModel, isCompactTopBarVariant: true)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if let metric = activeNudgeMetric {
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
    }

    @ViewBuilder
    private func hudMetricButton(
        metric: PhotographicStyleNudgeMetric,
        label: String,
        value: String,
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
                    .contentTransition(.numericText())
                    .foregroundColor(isEditingThis ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)
                    .frame(minWidth: compact ? 20 : 22, alignment: .leading)
                    .animation(.easeOut(duration: 0.10), value: value)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(dimmed ? 0.38 : 1.0)
        .animation(.easeOut(duration: 0.14), value: dimmed)
        .animation(.easeOut(duration: 0.14), value: highlighted)
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

// MARK: - Rounded Split-Screen Seam Canvas (iOS 18 Camera Continuous Squircle Dual-Card Mask)
private struct PhotographicStyleRoundedSplitSeam: View {
    let splitPosition: CGFloat

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard splitPosition > 0.002 && splitPosition < 0.998 else { return }

            let gap: CGFloat = 5.5
            let splitX = splitPosition * w
            let leftEdge = max(0, splitX - gap * 0.5)
            let rightEdge = min(w, splitX + gap * 0.5)

            // Dùng evenOdd mask khoét 2 thẻ squircle `.continuous` khớp tuyệt đối bo góc 20pt của khung ngắm 4:3
            var maskPath = Path()
            maskPath.addRect(CGRect(origin: .zero, size: size))

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

            context.fill(
                maskPath,
                with: .color(AlignTheme.studioCanvas),
                style: FillStyle(eoFill: true)
            )
        }
    }
}

// MARK: - 3. Unobstructed Viewfinder Overlay (True 60 FPS GPU Live Split-Screen Wipe + Hold-to-Compare + 16-Style Strip)
public struct PhotographicStylesViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var isSwipingHorizontally: Bool = false
    @State private var swipeStartPresetIndex: Int = 0
    @State private var bounceOffsetX: CGFloat = 0
    @State private var touchDownActive: Bool = false
    @State private var holdCompareTask: Task<Void, Never>? = nil

    public init(viewModel: CameraViewModel, topInset: CGFloat, bottomInset: CGFloat) {
        self.viewModel = viewModel
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    private var allPresets: [PhotographicStylePreset] { PhotographicStylePreset.allCases }

    private var displayedStyle: PhotographicStyleState {
        viewModel.photographicStyleSplit.isActive
            ? viewModel.photographicStyleSplit.dominantStyle
            : viewModel.photographicStyle
    }

    private var activeStyleSubtitleTag: String? {
        let s = displayedStyle
        if s.textureMode != .standard && s.grainEnabled {
            return "\(s.textureMode.displayName) + Hạt"
        } else if s.textureMode != .standard {
            return s.textureMode.displayName
        } else if s.grainEnabled {
            return "Hạt phim"
        }
        return nil
    }

    public var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let activeSplit = viewModel.photographicStyleSplit
            let shownPreset = displayedStyle.preset
            let isComparingOriginal = viewModel.isHoldingCompareOriginalStyle

            ZStack {
                // Full-viewfinder gesture layer: vuốt ngang chia đôi 60 FPS, nhấn giữ 0.28s xem ảnh gốc, chạm nhẹ để ẩn
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height

                                if !touchDownActive {
                                    touchDownActive = true
                                    holdCompareTask?.cancel()
                                    if !viewModel.photographicStyle.isIdentity {
                                        holdCompareTask = Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: 270_000_000)
                                            guard !Task.isCancelled, touchDownActive, !isSwipingHorizontally else { return }
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

                                if !isSwipingHorizontally && abs(dx) > 8 && abs(dx) > abs(dy) * 1.1 {
                                    isSwipingHorizontally = true
                                    viewModel.cancelPhotographicStyleSwipe()
                                    swipeStartPresetIndex = allPresets.firstIndex(of: viewModel.photographicStyle.preset) ?? 0
                                }
                                guard isSwipingHorizontally else { return }

                                let idx = swipeStartPresetIndex
                                let currentState = viewModel.photographicStyleState(for: allPresets[idx])

                                if dx < 0 {
                                    // Vuốt sang trái -> kéo phong cách kế tiếp từ mép phải sang trái (1.0 -> 0.0)
                                    if idx + 1 < allPresets.count {
                                        bounceOffsetX = 0
                                        let nextPreset = allPresets[idx + 1]
                                        let nextState = viewModel.photographicStyleState(for: nextPreset)
                                        let progress = Float(max(0.0, min(1.0, -dx / w)))
                                        let splitPos = 1.0 - progress
                                        let dominant = progress >= 0.5 ? nextState : currentState
                                        viewModel.updatePhotographicStyleSplit(
                                            PhotographicStyleSplitTransition(
                                                isActive: true,
                                                leftStyle: currentState,
                                                rightStyle: nextState,
                                                splitPosition: splitPos,
                                                dominantStyle: dominant,
                                                incomingPreset: nextPreset,
                                                morphProgress: progress
                                            )
                                        )
                                    } else {
                                        viewModel.cancelPhotographicStyleSwipe()
                                        bounceOffsetX = dx * 0.16
                                    }
                                } else if dx > 0 {
                                    // Vuốt sang phải -> kéo phong cách trước đó từ mép trái sang phải (0.0 -> 1.0)
                                    if idx - 1 >= 0 {
                                        bounceOffsetX = 0
                                        let prevPreset = allPresets[idx - 1]
                                        let prevState = viewModel.photographicStyleState(for: prevPreset)
                                        let progress = Float(max(0.0, min(1.0, dx / w)))
                                        let splitPos = progress
                                        let dominant = progress >= 0.5 ? prevState : currentState
                                        viewModel.updatePhotographicStyleSplit(
                                            PhotographicStyleSplitTransition(
                                                isActive: true,
                                                leftStyle: prevState,
                                                rightStyle: currentState,
                                                splitPosition: splitPos,
                                                dominantStyle: dominant,
                                                incomingPreset: prevPreset,
                                                morphProgress: progress
                                            )
                                        )
                                    } else {
                                        viewModel.cancelPhotographicStyleSwipe()
                                        bounceOffsetX = dx * 0.16
                                    }
                                }
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let predictedX = value.predictedEndTranslation.width
                                let wasSwipe = isSwipingHorizontally
                                let wasCompare = viewModel.isHoldingCompareOriginalStyle
                                let idx = swipeStartPresetIndex

                                touchDownActive = false
                                holdCompareTask?.cancel()
                                holdCompareTask = nil
                                if wasCompare {
                                    viewModel.setPhotographicStyleHoldCompare(false)
                                }

                                isSwipingHorizontally = false
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                    bounceOffsetX = 0
                                }

                                if wasSwipe {
                                    let currentSplit = viewModel.photographicStyleSplit
                                    if currentSplit.isActive {
                                        if dx < 0, idx + 1 < allPresets.count {
                                            let progress = -dx / w
                                            let predictedProgress = -predictedX / w
                                            let shouldCommit = progress >= 0.30 || predictedProgress >= 0.44
                                            viewModel.finishPhotographicStyleSwipe(
                                                from: currentSplit,
                                                targetSplitPosition: shouldCommit ? 0.0 : 1.0,
                                                isSwipingToNext: true,
                                                commitPreset: shouldCommit ? allPresets[idx + 1] : nil
                                            )
                                        } else if dx > 0, idx - 1 >= 0 {
                                            let progress = dx / w
                                            let predictedProgress = predictedX / w
                                            let shouldCommit = progress >= 0.30 || predictedProgress >= 0.44
                                            viewModel.finishPhotographicStyleSwipe(
                                                from: currentSplit,
                                                targetSplitPosition: shouldCommit ? 1.0 : 0.0,
                                                isSwipingToNext: false,
                                                commitPreset: shouldCommit ? allPresets[idx - 1] : nil
                                            )
                                        } else {
                                            viewModel.cancelPhotographicStyleSwipe()
                                        }
                                    }
                                } else if !wasCompare && hypot(dx, dy) < 9 {
                                    // Chạm nhẹ vùng trống khung ngắm -> thu gọn Pad để chụp bình thường
                                    HapticFeedbackService.shared.triggerLight()
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        viewModel.isShowingPhotographicStylePad = false
                                    }
                                }
                            }
                    )

                // Đường ranh chia đôi đen bo 4 góc tròn theo đúng tọa độ GPU splitPosition (như iOS 18 Camera)
                if activeSplit.isActive {
                    PhotographicStyleRoundedSplitSeam(splitPosition: CGFloat(activeSplit.splitPosition))
                        .allowsHitTesting(false)
                }

                // Nhóm phong cách tinh gọn trên đỉnh khung ngắm (STANDARD / UNDERTONE / MOOD hoặc ORIGINAL khi nhấn giữ)
                VStack {
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
                        .padding(.top, topInset)
                        .animation(.easeOut(duration: 0.16), value: shownPreset.group)
                        .animation(.easeOut(duration: 0.14), value: isComparingOriginal)

                    Spacer()

                    // Tên phong cách + dãy 16 chấm trang gọn ở sát đáy khung ngắm (khít cả iPhone SE 329pt)
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Text(shownPreset.displayName)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)

                            if let tag = activeStyleSubtitleTag {
                                Text("·")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color.white.opacity(0.45))
                                Text(tag.uppercased())
                                    .font(.system(size: 9.0, weight: .bold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioAccent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.black.opacity(0.54))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                                )
                        )
                        .offset(x: bounceOffsetX * 0.5)
                        .id("\(shownPreset.id)_\(activeStyleSubtitleTag ?? "")")
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.14), value: shownPreset.id)

                        // Dãy 16 chấm trang chuẩn Camera iOS (6 Undertones trái · Standard ô vuông giữa · 9 Moods phải)
                        HStack(spacing: 4.5) {
                            ForEach(allPresets) { preset in
                                let isSelected = preset == shownPreset
                                let hasEdits = viewModel.hasSessionEditsForPhotographicStyle(preset)

                                Button(action: {
                                    HapticFeedbackService.shared.triggerSelectionChange()
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        viewModel.selectPhotographicStylePreset(preset)
                                    }
                                }) {
                                    Group {
                                        if preset == .standard {
                                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                                .stroke(
                                                    isSelected ? Color.white : Color.white.opacity(0.50),
                                                    lineWidth: isSelected ? 1.5 : 1.0
                                                )
                                                .frame(width: isSelected ? 6.5 : 5.2, height: isSelected ? 6.5 : 5.2)
                                        } else {
                                            Circle()
                                                .fill(
                                                    isSelected
                                                        ? Color.white
                                                        : (hasEdits ? AlignTheme.studioAccent.opacity(0.88) : Color.white.opacity(0.38))
                                                )
                                                .frame(width: isSelected ? 5.8 : 4.0, height: isSelected ? 5.8 : 4.0)
                                        }
                                    }
                                    .frame(width: 9.5, height: 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.32)))
                    }
                    .padding(.bottom, max(8, bottomInset - 2))
                }
            }
            .onDisappear {
                holdCompareTask?.cancel()
                holdCompareTask = nil
                touchDownActive = false
            }
        }
    }
}

// MARK: - 4. Bottom Control Deck (Replaces Shutter Deck BELOW Viewfinder — 2D Palette Pad + Styles 3 Texture/Grain + Saved Recipes)
public struct PhotographicStylesBottomControlDeck: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    @State private var isPressingQuickShutter: Bool = false
    @State private var isShowingTextureTab: Bool = false
    @State private var isShowingRecipesSheet: Bool = false

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    private var padSide: CGFloat { compact ? 92 : 106 }

    public var body: some View {
        let split = viewModel.photographicStyleSplit
        let style = split.isActive ? split.dominantStyle : viewModel.photographicStyle
        let hasTextureOrGrain = viewModel.photographicStyle.hasTextureOrGrain

        HStack(alignment: .center, spacing: 0) {
            // Left: Back button (<) + compact Texture/Grain & Saved Recipes tool buttons
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                Button(action: {
                    HapticFeedbackService.shared.triggerLight()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        viewModel.isShowingPhotographicStylePad = false
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AlignTheme.studioInkPrimary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.13))
                                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Ẩn bảng chỉnh màu và quay về chụp bình thường")

                HStack(spacing: 6) {
                    // Toggle Styles 3 Texture & Grain deck
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
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(
                                        (isShowingTextureTab || hasTextureOrGrain)
                                            ? AlignTheme.studioAccent
                                            : Color.white.opacity(0.13)
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
                    .accessibilityLabel(isShowingTextureTab ? "Quay về bảng màu 2D" : "Mở Kết cấu & Hạt phim")

                    // Saved & Built-in Photographic Style Recipes
                    Button(action: {
                        HapticFeedbackService.shared.triggerLight()
                        isShowingRecipesSheet = true
                    }) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.86))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.13))
                                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Thư viện công thức bảng màu")
                }
            }
            .frame(width: 64, alignment: .leading)

            Spacer(minLength: 6)

            // Center: 2D Control Pad + Palette Slider OR Styles 3 Texture & Grain Deck
            if isShowingTextureTab {
                PhotographicStyleTextureDeckView(viewModel: viewModel, compact: compact)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                VStack(spacing: compact ? 1 : 3) {
                    PhotographicStyleDotGridPad(
                        preset: style.preset,
                        tone: style.tone,
                        color: style.color,
                        padSize: padSide,
                        onDragStateChanged: { dragging in
                            viewModel.activePhotographicStyleAxis = dragging ? .pad2D : .none
                        },
                        onUpdate: { newTone, newColor in
                            viewModel.updatePhotographicStyle(tone: newTone, color: newColor)
                        },
                        onDoubleTapReset: {
                            viewModel.resetPhotographicStyleAxesOnly()
                        }
                    )

                    PhotographicPalettePillSlider(
                        value: Binding(
                            get: { viewModel.photographicStyle.palette },
                            set: { viewModel.updatePhotographicStyle(palette: $0) }
                        ),
                        preset: style.preset,
                        width: padSide,
                        height: compact ? 16 : 18,
                        onDragStateChanged: { dragging in
                            viewModel.activePhotographicStyleAxis = dragging ? .palette : .none
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            Spacer(minLength: 6)

            // Right: Compact Quick Shutter button (giống sát bố cục Camera iOS 18, cân xứng 2 bên)
            Button(action: triggerQuickCapture) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.90), lineWidth: 2.2)
                        .frame(width: 44, height: 44)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 35, height: 35)
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
            .frame(width: 52, alignment: .trailing)
            .accessibilityLabel("Chụp ảnh ngay với phong cách màu hiện tại")
        }
        .padding(.horizontal, compact ? 14 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isShowingRecipesSheet) {
            PhotographicStyleRecipesSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func triggerQuickCapture() {
        guard viewModel.aiSessionState != .capturing else { return }
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

                // Independent Grain toggle (như nút tròn Hạt của Styles 3)
                Button(action: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        viewModel.togglePhotographicGrain()
                    }
                }) {
                    VStack(spacing: 0) {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 12, weight: .bold))
                        Text("Hạt")
                            .font(.system(size: 7.5, weight: .bold, design: .rounded))
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
                .accessibilityLabel(style.grainEnabled ? "Tắt hạt phim" : "Bật hạt phim")
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
                    .foregroundColor(AlignTheme.studioAccent)
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

                    // User Saved Recipes
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

                    // 5 Built-in Community Benchmark Recipes
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

// MARK: - Animatable 11x11 Micro-Dot Grid Canvas (Crisp Dot-Cluster Swell + Preset Default Origin Marker)
private struct PhotographicStyleDotGridCanvas: View, Animatable {
    var tone: Float
    var color: Float
    var dragGlow: Double
    let defaultTone: Float
    let defaultColor: Float

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(Double(tone), Double(color)), dragGlow) }
        set {
            tone = Float(newValue.first.first)
            color = Float(newValue.first.second)
            dragGlow = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            let inset = size.width * 0.115
            let span = max(1, size.width - inset * 2.0)
            let step = span / 10.0

            let thumbCol = CGFloat((color + 1.0) * 5.0)
            let thumbRow = CGFloat((1.0 - tone) * 5.0)
            let thumbX = inset + thumbCol * step
            let thumbY = inset + thumbRow * step
            let glow = CGFloat(max(0.0, min(1.0, dragGlow)))
            // Khớp chính xác vòng chấm phồng đậm đặc quanh con trỏ trắng (tập trung gọn trong bán kính ~2 ô lưới)
            let sigmaSq: CGFloat = 1.44 * 1.44 * 2.0

            for row in 0...10 {
                for col in 0...10 {
                    let baseX = inset + CGFloat(col) * step
                    let baseY = inset + CGFloat(row) * step

                    let dCol = CGFloat(col) - thumbCol
                    let dRow = CGFloat(row) - thumbRow
                    let distGrid = hypot(dCol, dRow)

                    // Giấu gọn các chấm nằm hẳn bên dưới tâm nút trắng để viền nhân trắng sắc gọn
                    let hideInner: CGFloat = 0.42 + 0.56 * glow
                    let underThumbFade = max(0.0, min(1.0, (distGrid - hideInner) / 0.36))
                    if underThumbFade <= 0.02 { continue }

                    // Local Crisp Dot-Cluster Swell: chấm bao quanh nhân trắng phồng rõ thành cụm chấm trắng sắc nét
                    let gaussian = exp(-(distGrid * distGrid) / sigmaSq)
                    var drawX = baseX
                    var drawY = baseY
                    if glow > 0.01 && distGrid > 0.2 {
                        let dxPx = baseX - thumbX
                        let dyPx = baseY - thumbY
                        let lenPx = max(1.0, hypot(dxPx, dyPx))
                        let push: CGFloat = 0.85 * glow * gaussian * max(0.0, min(1.0, distGrid / 1.1))
                        drawX += (dxPx / lenPx) * push
                        drawY += (dyPx / lenPx) * push
                    }

                    let onCrosshairRow = abs(dRow) <= 0.48
                    let onCrosshairCol = abs(dCol) <= 0.48
                    let isOrigin = (row == 5 && col == 5)

                    if isOrigin {
                        let ringR: CGFloat = 2.05 + 0.40 * gaussian * glow
                        let ringRect = CGRect(x: drawX - ringR, y: drawY - ringR, width: ringR * 2, height: ringR * 2)
                        let ringAlpha = (0.48 + 0.36 * gaussian) * underThumbFade
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(Color.white.opacity(ringAlpha)),
                            lineWidth: 0.90
                        )
                    } else {
                        let isAxisDot = onCrosshairRow || onCrosshairCol
                        let axisFade = isAxisDot ? max(0.30, 1.0 - distGrid * 0.075) : 1.0
                        let baseRadius: CGFloat = isAxisDot ? 1.08 : 0.76
                        let swellRadius: CGFloat = (0.42 + 1.92 * glow) * gaussian
                        let radius = min(2.95, baseRadius + swellRadius)

                        let baseAlpha: CGFloat = isAxisDot ? (0.72 * axisFade) : 0.28
                        let alpha = min(0.98, baseAlpha + (0.34 + 0.56 * glow) * gaussian) * underThumbFade

                        let dotRect = CGRect(x: drawX - radius, y: drawY - radius, width: radius * 2, height: radius * 2)
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(Color.white.opacity(alpha))
                        )
                    }
                }
            }

            // Chấm neo mốc mặc định của từng phong cách (tọa độ defaultColor / defaultTone — sáng ấm gọn giống ảnh mẫu)
            if abs(defaultTone) > 0.015 || abs(defaultColor) > 0.015 {
                let defX = inset + CGFloat((defaultColor + 1.0) * 0.5) * span
                let defY = inset + CGFloat((1.0 - defaultTone) * 0.5) * span
                let distToCursorPx = hypot(defX - thumbX, defY - thumbY)
                if distToCursorPx > 8.5 {
                    let defR: CGFloat = 2.15
                    let defRect = CGRect(x: defX - defR, y: defY - defR, width: defR * 2, height: defR * 2)
                    context.fill(
                        Path(ellipseIn: defRect),
                        with: .color(Color(red: 1.0, green: 0.95, blue: 0.84).opacity(0.88))
                    )
                }
            }
        }
    }
}

// MARK: - Tight Crisp White Cursor Orb (Zero Overflow Fog — Strictly Clipped Inside Squircle Pad)
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
        // Nhân trắng đặc gọn sắc nét (nghỉ 8.6pt -> kéo 18.2pt) + viền sáng ôm sát gọn, tuyệt đối không lan mù ra ngoài
        let coreDiameter: CGFloat = 8.6 + 9.6 * g
        let outerAuraDiameter: CGFloat = coreDiameter + 5.0 + 4.5 * g

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.42 + 0.16 * g), location: 0.0),
                            .init(color: Color.white.opacity(0.14 + 0.10 * g), location: 0.62),
                            .init(color: Color.clear, location: 1.0)
                        ]),
                        center: .center,
                        startRadius: coreDiameter * 0.42,
                        endRadius: outerAuraDiameter * 0.5
                    )
                )
                .frame(width: outerAuraDiameter, height: outerAuraDiameter)

            Circle()
                .fill(Color.white)
                .frame(width: coreDiameter, height: coreDiameter)
                .shadow(color: Color.black.opacity(0.18), radius: 1.4, y: 0.5)
        }
        .position(cursorPoint)
    }
}

// MARK: - Interactive Compact 2D Control Pad (Relative Drag + Tap-to-Glide + Double-Tap + Tight Clipped Orb)
private struct PhotographicStyleDotGridPad: View {
    let preset: PhotographicStylePreset
    let tone: Float
    let color: Float
    let padSize: CGFloat
    let onDragStateChanged: (Bool) -> Void
    let onUpdate: (Float, Float) -> Void
    let onDoubleTapReset: () -> Void

    @State private var isDragging: Bool = false
    @State private var dragSessionActive: Bool = false
    @State private var hasMovedPastTapThreshold: Bool = false
    @State private var dragStartTone: Float = 0.0
    @State private var dragStartColor: Float = 0.0
    @State private var snappedToZeroX: Bool = true
    @State private var snappedToZeroY: Bool = true
    @State private var lastTickStepX: Int = 0
    @State private var lastTickStepY: Int = 0
    @State private var lastTapTimestamp: CFTimeInterval = 0

    // Magnetic zero-snap hysteresis thresholds
    private let snapEnterDeadzone: Float = 0.04
    private let snapExitDeadzone: Float = 0.065

    private var gridInset: CGFloat { padSize * 0.115 }
    private var usableSpan: CGFloat { max(1, padSize - gridInset * 2.0) }
    private var cornerRadius: CGFloat { padSize < 100 ? 18 : 20 }

    private var cursorMotionAnimation: Animation {
        isDragging
            ? .interactiveSpring(response: 0.10, dampingFraction: 0.88)
            : .spring(response: 0.28, dampingFraction: 0.80)
    }

    var body: some View {
        let dragGlow: Double = isDragging ? 1.0 : 0.0

        ZStack {
            // 1. Nền mặt phẳng màu 2D quang học sạch theo đúng bản chất từng preset (không phủ quầng trắng mù toàn ô)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.78, green: 0.79, blue: 0.82),
                            Color(red: 0.42, green: 0.43, blue: 0.46),
                            Color(red: 0.10, green: 0.10, blue: 0.12)
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
                                    preset.padTopRightColor.opacity(0.72)
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
                                    preset.padBottomRightColor.opacity(0.78)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .animation(.easeInOut(duration: 0.24), value: preset)

            // 2. Lưới 11x11 chấm Animatable + cụm chấm phồng sắc nét quanh con trỏ + chấm neo mốc mặc định
            PhotographicStyleDotGridCanvas(
                tone: tone,
                color: color,
                dragGlow: dragGlow,
                defaultTone: preset.defaultTone,
                defaultColor: preset.defaultColor
            )
            .animation(cursorMotionAnimation, value: tone)
            .animation(cursorMotionAnimation, value: color)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: dragGlow)
            .allowsHitTesting(false)

            // 3. Con trỏ trắng sắc nét gọn gàng, bị cắt chuẩn trong bo góc squircle (tuyệt đối không tràn blur ra ngoài)
            PhotographicStyleLuminousCursor(
                tone: tone,
                color: color,
                dragGlow: dragGlow,
                padSize: padSize
            )
            .animation(cursorMotionAnimation, value: tone)
            .animation(cursorMotionAnimation, value: color)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: dragGlow)
            .allowsHitTesting(false)
        }
        .frame(width: padSize, height: padSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                .allowsHitTesting(false)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !dragSessionActive {
                        dragSessionActive = true
                        hasMovedPastTapThreshold = false
                        dragStartTone = tone
                        dragStartColor = color
                        snappedToZeroX = abs(color) < 0.005
                        snappedToZeroY = abs(tone) < 0.005
                        lastTickStepX = Int(round(color * 10.0))
                        lastTickStepY = Int(round(tone * 10.0))
                        isDragging = true
                        onDragStateChanged(true)
                    }

                    let travel = hypot(value.translation.width, value.translation.height)
                    if !hasMovedPastTapThreshold && travel >= 3.5 {
                        hasMovedPastTapThreshold = true
                    }
                    guard hasMovedPastTapThreshold else { return }

                    // Relative 1:1 Delta Drag: ngón tay không che mất con trỏ trắng
                    let halfSpan = max(1.0, usableSpan * 0.5)
                    let rawColor = max(-1.0, min(1.0, dragStartColor + Float(value.translation.width / halfSpan)))
                    let rawTone = max(-1.0, min(1.0, dragStartTone - Float(value.translation.height / halfSpan)))

                    var finalColor = applyHysteresisSnap(raw: rawColor, wasSnapped: &snappedToZeroX)
                    var finalTone = applyHysteresisSnap(raw: rawTone, wasSnapped: &snappedToZeroY)

                    // Hít nhẹ vào tọa độ mặc định của phong cách nếu đi sát qua (tạo cảm giác nút cơ học chính xác)
                    if (abs(preset.defaultColor) > 0.01 || abs(preset.defaultTone) > 0.01),
                       hypot(finalColor - preset.defaultColor, finalTone - preset.defaultTone) < 0.045 {
                        finalColor = preset.defaultColor
                        finalTone = preset.defaultTone
                    }

                    fireDetentHaptics(newColor: finalColor, newTone: finalTone)
                    onUpdate(finalTone, finalColor)
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
                        onUpdate(snappedT, snappedC)
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

// MARK: - Compact Pill Palette Slider (Matches Square Pad Width — Native iOS 18 Capsule Gradient)
private struct PhotographicPalettePillSlider: View {
    @Binding var value: Float
    let preset: PhotographicStylePreset
    let width: CGFloat
    let height: CGFloat
    let onDragStateChanged: (Bool) -> Void

    @State private var isDragging: Bool = false
    @State private var lastNotch: Int = 10

    var body: some View {
        let thumbDiameter = height - 3.0
        let travelSpan = max(1, width - thumbDiameter - 3.0)
        let clamped = CGFloat(max(0.0, min(1.0, value)))
        let thumbX = (thumbDiameter * 0.5) + 1.5 + clamped * travelSpan

        ZStack(alignment: .leading) {
            // Dải màu viên thuốc mượt đặc trưng từng phong cách
            Capsule()
                .fill(
                    LinearGradient(
                        colors: preset.paletteGradientColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.65)
                )
                .animation(.easeInOut(duration: 0.22), value: preset)

            // Núm tròn trắng với quầng sáng RadialGradient mượt 120Hz (0 offscreen blur pass)
            ZStack {
                if isDragging {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.48), Color.white.opacity(0.14), Color.clear],
                                center: .center,
                                startRadius: thumbDiameter * 0.35,
                                endRadius: (thumbDiameter + 14) * 0.5
                            )
                        )
                        .frame(width: thumbDiameter + 14, height: thumbDiameter + 14)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.28), radius: 2.0, y: 0.6)
            }
            .scaleEffect(isDragging ? 1.12 : 1.0)
            .position(x: thumbX, y: height * 0.5)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.86), value: value)
            .animation(.spring(response: 0.20, dampingFraction: 0.76), value: isDragging)
        }
        .frame(width: width, height: height)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        lastNotch = Int(round(value * 10.0))
                        onDragStateChanged(true)
                    }
                    let norm = (drag.location.x - (thumbDiameter * 0.5 + 1.5)) / travelSpan
                    let raw = Float(max(0.0, min(1.0, norm)))
                    let finalVal: Float = abs(raw - 0.5) < 0.02 ? 0.5 : raw
                    let notch = Int(round(finalVal * 10.0))
                    if notch != lastNotch {
                        if notch == 0 || notch == 5 || notch == 10 {
                            HapticFeedbackService.shared.triggerLight()
                        } else {
                            HapticFeedbackService.shared.triggerPadGridTick()
                        }
                        lastNotch = notch
                    }
                    value = finalVal
                }
                .onEnded { _ in
                    isDragging = false
                    onDragStateChanged(false)
                }
        )
        .accessibilityLabel("Photographic Style Palette Intensity")
    }
}
