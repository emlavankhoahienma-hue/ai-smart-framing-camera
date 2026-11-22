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

// MARK: - 2. Top Bar Telemetry HUD (Replaces TopCameraBar — Native iOS 18 English Capsule, Zero Dashes)
public struct PhotographicStylesTopHUDBar: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

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

            // Centered Hairline Capsule: TONE 00   COLOR 00   PALETTE 100   ↺ (không có dấu gạch ngăn)
            HStack(spacing: compact ? 8 : 12) {
                hudMetric(
                    label: "TONE",
                    value: style.toneHUDNumber,
                    highlighted: isPadDragging,
                    dimmed: isPaletteDragging
                )

                hudMetric(
                    label: "COLOR",
                    value: style.colorHUDNumber,
                    highlighted: isPadDragging,
                    dimmed: isPaletteDragging
                )

                hudMetric(
                    label: "PALETTE",
                    value: style.paletteHUDNumber,
                    highlighted: isPaletteDragging,
                    dimmed: isPadDragging
                )

                Button(action: {
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
                    .fill(Color.black.opacity(0.68))
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
    }

    @ViewBuilder
    private func hudMetric(
        label: String,
        value: String,
        highlighted: Bool,
        dimmed: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: compact ? 8.5 : 9.2, weight: .medium, design: .rounded))
                .foregroundColor(
                    highlighted
                        ? AlignTheme.studioInkPrimary.opacity(0.88)
                        : AlignTheme.studioInkPrimary.opacity(0.56)
                )

            Text(value)
                .font(.system(size: compact ? 10.5 : 11.2, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundColor(AlignTheme.studioInkPrimary)
                .frame(minWidth: compact ? 20 : 22, alignment: .leading)
                .animation(.easeOut(duration: 0.10), value: value)
        }
        .opacity(dimmed ? 0.38 : 1.0)
        .animation(.easeOut(duration: 0.14), value: dimmed)
        .animation(.easeOut(duration: 0.14), value: highlighted)
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

// MARK: - 3. Unobstructed Viewfinder Overlay (True 60 FPS GPU Live Split-Screen Wipe + Style Badge & Dots)
public struct PhotographicStylesViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var isSwipingHorizontally: Bool = false
    @State private var swipeStartPresetIndex: Int = 0
    @State private var bounceOffsetX: CGFloat = 0

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

    public var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let activeSplit = viewModel.photographicStyleSplit
            let shownPreset = displayedStyle.preset

            ZStack {
                // Full-viewfinder live split-wipe layer: vuốt trái/phải chia đôi camera theo tay thời gian thực, chạm nhẹ để ẩn
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
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
                                let idx = swipeStartPresetIndex

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
                                } else if hypot(dx, dy) < 9 {
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

                // Nhóm phong cách tinh gọn trên đỉnh khung ngắm (STANDARD / UNDERTONE / MOOD)
                VStack {
                    Text(shownPreset.group.badgeTitle)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.90))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.46))
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        )
                        .padding(.top, topInset)
                        .animation(.easeOut(duration: 0.16), value: shownPreset.group)

                    Spacer()

                    // Tên phong cách + dãy chấm trang ở sát đáy khung ngắm (gọn nhẹ, không che ảnh)
                    VStack(spacing: 6) {
                        Text(shownPreset.displayName)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.black.opacity(0.50))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                                    )
                            )
                            .offset(x: bounceOffsetX * 0.5)
                            .id(shownPreset.id)
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.14), value: shownPreset.id)

                        // Dãy chấm trang iOS Camera (mốc Standard hình vuông rỗng, các phong cách khác hình tròn)
                        HStack(spacing: 6.5) {
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
                                                    isSelected ? Color.white : Color.white.opacity(0.46),
                                                    lineWidth: isSelected ? 1.5 : 1.0
                                                )
                                                .frame(width: isSelected ? 6.5 : 5.5, height: isSelected ? 6.5 : 5.5)
                                        } else {
                                            Circle()
                                                .fill(
                                                    isSelected
                                                        ? Color.white
                                                        : (hasEdits ? AlignTheme.studioAccent.opacity(0.85) : Color.white.opacity(0.38))
                                                )
                                                .frame(width: isSelected ? 6.0 : 4.2, height: isSelected ? 6.0 : 4.2)
                                        }
                                    }
                                    .frame(width: 11, height: 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.28)))
                    }
                    .padding(.bottom, max(8, bottomInset - 2))
                }
            }
        }
    }
}

// MARK: - 4. Bottom Control Deck (Replaces Shutter Deck BELOW Viewfinder — Zero Camera Obstruction!)
public struct PhotographicStylesBottomControlDeck: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    @State private var isPressingQuickShutter: Bool = false

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    private var padSide: CGFloat { compact ? 92 : 106 }

    public var body: some View {
        let split = viewModel.photographicStyleSplit
        let style = split.isActive ? split.dominantStyle : viewModel.photographicStyle

        HStack(alignment: .center, spacing: 0) {
            // Left: Back / Hide button (<) -> thu gọn về cụm nút chụp bình thường
            Button(action: {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    viewModel.isShowingPhotographicStylePad = false
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.13))
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.6))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .frame(width: 52, alignment: .leading)
            .accessibilityLabel("Ẩn bảng chỉnh màu và quay về chụp bình thường")

            Spacer(minLength: 8)

            // Center: Compact 2D Pad + Matching-Width Pill Palette Slider
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

            Spacer(minLength: 8)

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
        .padding(.horizontal, compact ? 18 : 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Animatable 11x11 Micro-Dot Grid Canvas (60-120Hz Silky Interpolation)
private struct PhotographicStyleDotGridCanvas: View, Animatable {
    var tone: Float
    var color: Float
    var dragGlow: Double

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
            let sigmaSq: CGFloat = 1.65 * 1.65 * 2.0

            for row in 0...10 {
                for col in 0...10 {
                    let baseX = inset + CGFloat(col) * step
                    let baseY = inset + CGFloat(row) * step

                    let dCol = CGFloat(col) - thumbCol
                    let dRow = CGFloat(row) - thumbRow
                    let distGrid = hypot(dCol, dRow)

                    // Chấm nằm sát tâm con trỏ mờ dần mềm mại để viền sáng trắng sạch mịn
                    let hideInner: CGFloat = 0.28 + 0.34 * glow
                    let underThumbFade = max(0.0, min(1.0, (distGrid - hideInner) / 0.48))
                    if underThumbFade <= 0.02 { continue }

                    // Gaussian Proximity Field: chấm quanh con trỏ phồng lớn & sáng rực tạo quầng chấm giống iOS 18
                    let gaussian = exp(-(distGrid * distGrid) / sigmaSq)
                    var drawX = baseX
                    var drawY = baseY
                    if glow > 0.01 && distGrid > 0.15 {
                        let dxPx = baseX - thumbX
                        let dyPx = baseY - thumbY
                        let lenPx = max(1.0, hypot(dxPx, dyPx))
                        let push: CGFloat = 1.35 * glow * gaussian * max(0.0, min(1.0, distGrid / 0.9))
                        drawX += (dxPx / lenPx) * push
                        drawY += (dyPx / lenPx) * push
                    }

                    let onCrosshairRow = abs(dRow) <= 0.48
                    let onCrosshairCol = abs(dCol) <= 0.48
                    let isOrigin = (row == 5 && col == 5)

                    if isOrigin {
                        let ringR: CGFloat = 2.15 + 0.55 * gaussian * glow
                        let ringRect = CGRect(x: drawX - ringR, y: drawY - ringR, width: ringR * 2, height: ringR * 2)
                        let ringAlpha = (0.50 + 0.36 * gaussian) * underThumbFade
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(Color.white.opacity(ringAlpha)),
                            lineWidth: 0.95
                        )
                    } else {
                        let isAxisDot = onCrosshairRow || onCrosshairCol
                        let axisFade = isAxisDot ? max(0.32, 1.0 - distGrid * 0.08) : 1.0
                        let baseRadius: CGFloat = isAxisDot ? 1.15 : 0.82
                        let swellRadius: CGFloat = (0.35 + 1.65 * glow) * gaussian
                        let radius = baseRadius + swellRadius

                        let baseAlpha: CGFloat = isAxisDot ? (0.72 * axisFade) : 0.28
                        let alpha = min(0.98, baseAlpha + (0.28 + 0.46 * glow) * gaussian) * underThumbFade

                        let dotRect = CGRect(x: drawX - radius, y: drawY - radius, width: radius * 2, height: radius * 2)
                        context.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(Color.white.opacity(alpha))
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Animatable Multi-Layered Luminous Blurred White Cursor Orb
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
        let coreDiameter: CGFloat = 8.2 + 12.8 * g          // Nghỉ: 8.2pt tinh gọn -> Kéo: 21pt rực sáng
        let innerHaloDiameter: CGFloat = 16.0 + 18.0 * g    // Quầng sáng mờ trong
        let outerAuraDiameter: CGFloat = 24.0 + 26.0 * g    // Quầng blur lan tỏa mềm xung quanh

        ZStack {
            // Lớp 1: Quầng sáng lan tỏa mờ ngoài cùng (outer diffused blur aura)
            Circle()
                .fill(Color.white.opacity(0.18 + 0.24 * g))
                .frame(width: outerAuraDiameter, height: outerAuraDiameter)
                .blur(radius: 7.0 + 6.5 * g)

            // Lớp 2: Quầng bloom sáng sát viền con trỏ
            Circle()
                .fill(Color.white.opacity(0.32 + 0.36 * g))
                .frame(width: innerHaloDiameter, height: innerHaloDiameter)
                .blur(radius: 3.5 + 3.8 * g)

            // Lớp 3: Nhân trắng tinh khiết với viền mềm mượt
            Circle()
                .fill(Color.white)
                .frame(width: coreDiameter, height: coreDiameter)
                .shadow(color: Color.white.opacity(0.55 + 0.35 * g), radius: 3.0 + 4.5 * g)
                .shadow(color: Color.black.opacity(0.24), radius: 2.5, y: 1)
        }
        .position(cursorPoint)
    }
}

// MARK: - Interactive Compact 2D Control Pad (Relative Drag + Tap-to-Glide + Double-Tap + Blurred Glow)
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

    private var thumbUnitPoint: UnitPoint {
        let nx = Double((color + 1.0) * 0.5)
        let ny = Double((1.0 - tone) * 0.5)
        let insetRatio = 0.115
        return UnitPoint(
            x: insetRatio + nx * (1.0 - insetRatio * 2.0),
            y: insetRatio + ny * (1.0 - insetRatio * 2.0)
        )
    }

    private var cursorMotionAnimation: Animation {
        isDragging
            ? .interactiveSpring(response: 0.10, dampingFraction: 0.88)
            : .spring(response: 0.28, dampingFraction: 0.80)
    }

    var body: some View {
        let dragGlow: Double = isDragging ? 1.0 : 0.0

        ZStack {
            // 1. Nền mặt phẳng màu 2D quang học theo đúng bản chất từng preset (Trục Y sáng/tối, Trục X sắc độ)
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
                                    preset.padTopRightColor.opacity(0.68)
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
                // Quầng sáng nền mềm mại chạy theo vị trí con trỏ
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isDragging ? 0.36 : 0.14),
                                    Color.white.opacity(isDragging ? 0.12 : 0.0),
                                    Color.clear
                                ],
                                center: thumbUnitPoint,
                                startRadius: 2,
                                endRadius: padSize * (isDragging ? 0.54 : 0.38)
                            )
                        )
                        .animation(cursorMotionAnimation, value: tone)
                        .animation(cursorMotionAnimation, value: color)
                        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isDragging)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                )
                .animation(.easeInOut(duration: 0.24), value: preset)

            // 2. Lưới 11x11 chấm Animatable đồng bộ 120Hz cùng con trỏ (bo gọn trong khung squircle)
            PhotographicStyleDotGridCanvas(
                tone: tone,
                color: color,
                dragGlow: dragGlow
            )
            .animation(cursorMotionAnimation, value: tone)
            .animation(cursorMotionAnimation, value: color)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: dragGlow)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)

            // 3. Con trỏ trắng đa tầng có quầng blur sáng lan tỏa tự nhiên (như iOS 18 khi kéo sát viền)
            PhotographicStyleLuminousCursor(
                tone: tone,
                color: color,
                dragGlow: dragGlow,
                padSize: padSize
            )
            .animation(cursorMotionAnimation, value: tone)
            .animation(cursorMotionAnimation, value: color)
            .animation(.spring(response: 0.22, dampingFraction: 0.74), value: dragGlow)
            .allowsHitTesting(false)
        }
        .frame(width: padSize, height: padSize)
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

                    let finalColor = applyHysteresisSnap(raw: rawColor, wasSnapped: &snappedToZeroX)
                    let finalTone = applyHysteresisSnap(raw: rawTone, wasSnapped: &snappedToZeroY)

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

            // Núm tròn trắng với quầng blur nhẹ khi kéo
            ZStack {
                if isDragging {
                    Circle()
                        .fill(Color.white.opacity(0.50))
                        .frame(width: thumbDiameter + 10, height: thumbDiameter + 10)
                        .blur(radius: 4.5)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.32), radius: 2.5, y: 0.8)
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
