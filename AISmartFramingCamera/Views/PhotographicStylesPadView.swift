import SwiftUI
import UIKit

// MARK: - 1. Quick Trigger Button (3x3 Dot Grid with Live Active Coordinate Dot)
public struct PhotographicStyleQuickTriggerButton: View {
    @ObservedObject var viewModel: CameraViewModel
    let isCompactTopBarVariant: Bool

    public init(viewModel: CameraViewModel, isCompactTopBarVariant: Bool = false) {
        self.viewModel = viewModel
        self.isCompactTopBarVariant = isCompactTopBarVariant
    }

    private var isStyleActive: Bool {
        !viewModel.photographicStyle.isIdentity
    }

    private var activeDotColumn: Int {
        let c = viewModel.photographicStyle.color
        if c < -0.22 { return 0 }
        if c > 0.22 { return 2 }
        return 1
    }

    private var activeDotRow: Int {
        let t = viewModel.photographicStyle.tone
        if t > 0.22 { return 0 }
        if t < -0.22 { return 2 }
        return 1
    }

    public var body: some View {
        let availability = viewModel.featureAvailability(.photographicStyles)
        let isHighlighted = availability.isAvailable && (isStyleActive || viewModel.isShowingPhotographicStylePad)

        Button(action: {
            viewModel.attemptFeature(.photographicStyles) {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                    viewModel.isShowingPhotographicStylePad.toggle()
                }
            }
        }) {
            ZStack {
                if isCompactTopBarVariant {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.60))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    isHighlighted ? AlignTheme.studioAccent : Color.white.opacity(0.24),
                                    lineWidth: isHighlighted ? 1.0 : 0.7
                                )
                        )
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isHighlighted ? AlignTheme.studioAccentSoft : AlignTheme.studioGlassTint.opacity(0.52))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    isHighlighted ? AlignTheme.studioAccentBorder : Color.white.opacity(0.16),
                                    lineWidth: isHighlighted ? 0.85 : 0.65
                                )
                        )
                }

                VStack(spacing: 3.0) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 3.0) {
                            ForEach(0..<3, id: \.self) { col in
                                let isActiveCell = (isStyleActive || viewModel.isShowingPhotographicStylePad)
                                    && row == activeDotRow
                                    && col == activeDotColumn
                                Circle()
                                    .fill(
                                        isActiveCell
                                            ? AlignTheme.studioAccent
                                            : Color.white.opacity(isHighlighted ? 0.88 : 0.76)
                                    )
                                    .frame(width: isActiveCell ? 3.8 : 2.1, height: isActiveCell ? 3.8 : 2.1)
                            }
                        }
                    }
                }
            }
            .frame(width: 30, height: 30)
            .opacity(availability.isAvailable ? 1.0 : 0.34)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(
            viewModel.isShowingPhotographicStylePad
                ? "Ẩn Photographic Styles"
                : (isStyleActive
                    ? "Photographic Styles: \(viewModel.photographicStyle.preset.displayName)"
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
        let style = viewModel.photographicStyle
        let axis = viewModel.activePhotographicStyleAxis
        let isPadDragging = axis == .pad2D
        let isPaletteDragging = axis == .palette

        HStack(spacing: 6) {
            if !compact {
                Color.clear.frame(width: 30, height: 30)
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

            // Right-edge active 3x3 grid toggle button (tap to dismiss)
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

// MARK: - 3. Unobstructed Viewfinder Overlay (Story-Style Horizontal Swipe + Minimal Style Badge & Dots)
public struct PhotographicStylesViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    @State private var swipeOffsetX: CGFloat = 0
    @State private var isSwipingHorizontally: Bool = false

    public init(viewModel: CameraViewModel, topInset: CGFloat, bottomInset: CGFloat) {
        self.viewModel = viewModel
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    private var allPresets: [PhotographicStylePreset] { PhotographicStylePreset.allCases }

    private var currentIndex: Int {
        allPresets.firstIndex(of: viewModel.photographicStyle.preset) ?? 0
    }

    private var previewedPreset: PhotographicStylePreset {
        guard isSwipingHorizontally else { return viewModel.photographicStyle.preset }
        if swipeOffsetX < -44, currentIndex + 1 < allPresets.count {
            return allPresets[currentIndex + 1]
        }
        if swipeOffsetX > 44, currentIndex - 1 >= 0 {
            return allPresets[currentIndex - 1]
        }
        return viewModel.photographicStyle.preset
    }

    public var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)

            ZStack {
                // Full-viewfinder swipe layer: vuốt trái/phải đổi phong cách mượt như lướt trang, chạm nhẹ để ẩn
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                if !isSwipingHorizontally && abs(dx) > 10 && abs(dx) > abs(dy) * 1.15 {
                                    isSwipingHorizontally = true
                                }
                                if isSwipingHorizontally {
                                    // Tạo lực cản nhẹ ở 2 đầu danh sách preset
                                    let atStart = currentIndex == 0 && dx > 0
                                    let atEnd = currentIndex == allPresets.count - 1 && dx < 0
                                    let resistance: CGFloat = (atStart || atEnd) ? 0.25 : 0.85
                                    swipeOffsetX = dx * resistance
                                }
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                let predictedX = value.predictedEndTranslation.width
                                let wasSwipe = isSwipingHorizontally

                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    swipeOffsetX = 0
                                    isSwipingHorizontally = false
                                }

                                if wasSwipe {
                                    if dx < -38 || predictedX < -95 {
                                        viewModel.stepPhotographicStylePreset(by: 1)
                                    } else if dx > 38 || predictedX > 95 {
                                        viewModel.stepPhotographicStylePreset(by: -1)
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

                // Đường ranh chia dọc mảnh lướt ngang khung ngắm khi vuốt chuyển phong cách (như Camera iOS 18)
                if isSwipingHorizontally && abs(swipeOffsetX) > 6 {
                    let curtainX: CGFloat = swipeOffsetX < 0
                        ? max(0, min(w, w + swipeOffsetX * 1.35))
                        : max(0, min(w, swipeOffsetX * 1.35))

                    Rectangle()
                        .fill(Color.black.opacity(0.68))
                        .frame(width: 2.0, height: h)
                        .overlay(
                            Rectangle()
                                .fill(Color.white.opacity(0.26))
                                .frame(width: 0.6, height: h)
                        )
                        .position(x: curtainX, y: h * 0.5)
                        .allowsHitTesting(false)
                }

                // Nhóm phong cách tinh gọn trên đỉnh khung ngắm (STANDARD / UNDERTONE / MOOD)
                VStack {
                    Text(previewedPreset.group.badgeTitle)
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
                        .animation(.easeOut(duration: 0.16), value: previewedPreset.group)

                    Spacer()

                    // Tên phong cách + dãy chấm trang ở sát đáy khung ngắm (gọn nhẹ, không che ảnh)
                    VStack(spacing: 6) {
                        Text(previewedPreset.displayName)
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
                            .offset(x: swipeOffsetX * 0.18)
                            .id(previewedPreset.id)
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.16), value: previewedPreset.id)

                        // Dãy chấm trang iOS Camera (mốc Standard hình vuông rỗng, các phong cách khác hình tròn)
                        HStack(spacing: 6.5) {
                            ForEach(allPresets) { preset in
                                let isSelected = preset == viewModel.photographicStyle.preset
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
        let style = viewModel.photographicStyle

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
