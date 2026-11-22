import SwiftUI
import UIKit

// MARK: - Active Drag Axis Tracking for Real-Time HUD Highlighting
private enum PhotographicStyleActiveAxis: Equatable {
    case none
    case pad2D
    case palette
}

// MARK: - Top-Right Viewfinder 3x3 Dot Grid Quick Trigger (iOS 18 Camera Native Placement)
public struct PhotographicStyleQuickTriggerButton: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
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
        let highlight = availability.isAvailable && (isStyleActive || viewModel.isShowingPhotographicStylePad)

        Button(action: {
            viewModel.attemptFeature(.photographicStyles) {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    viewModel.isShowingPhotographicStylePad.toggle()
                }
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(highlight ? AlignTheme.studioAccentSoft : AlignTheme.studioGlassTint.opacity(0.52))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                highlight ? AlignTheme.studioAccentBorder : Color.white.opacity(0.16),
                                lineWidth: highlight ? 0.85 : 0.65
                            )
                    )

                // Biểu tượng lưới chấm 3x3 mô phỏng trực tiếp Photographic Styles Control Pad
                VStack(spacing: 3.2) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 3.2) {
                            ForEach(0..<3, id: \.self) { col in
                                let isActiveCell = isStyleActive && row == activeDotRow && col == activeDotColumn
                                Circle()
                                    .fill(
                                        isActiveCell
                                            ? AlignTheme.studioAccent
                                            : Color.white.opacity(highlight ? 0.88 : 0.76)
                                    )
                                    .frame(width: isActiveCell ? 3.8 : 2.3, height: isActiveCell ? 3.8 : 2.3)
                            }
                        }
                    }
                }
            }
            .frame(width: 32, height: 32)
            .opacity(availability.isAvailable ? 1.0 : 0.34)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(
            isStyleActive
                ? "Photographic Styles: \(viewModel.photographicStyle.preset.displayName)"
                : "Mở bảng Photographic Styles 2D"
        )
    }
}

// MARK: - Main Floating Control Pad Overlay (Monochrome Carbon & Smoked Glass)
public struct PhotographicStylesControlPadOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    @State private var activeAxis: PhotographicStyleActiveAxis = .none
    @Namespace private var presetPillNamespace

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    private var padSide: CGFloat { compact ? 132 : 158 }

    public var body: some View {
        let style = viewModel.photographicStyle

        VStack(spacing: compact ? 7 : 9) {
            // 1. Real-Time Numeric Telemetry HUD Strip (Luôn hiển thị số thực, không bao giờ N/A)
            realtimeHUDHeader(style: style)

            // 2. Interactive 2D Control Pad (11x11 Dot Grid + Gaussian Proximity + Relative Drag)
            PhotographicStyleDotGridPad(
                preset: style.preset,
                tone: style.tone,
                color: style.color,
                padSize: padSide,
                onDragStateChanged: { dragging in
                    withAnimation(.easeOut(duration: 0.14)) {
                        activeAxis = dragging ? .pad2D : .none
                    }
                },
                onUpdate: { newTone, newColor in
                    viewModel.updatePhotographicStyle(tone: newTone, color: newColor)
                },
                onDoubleTapReset: {
                    viewModel.resetPhotographicStyleAxesOnly()
                }
            )

            // 3. Numbered Circular Palette Slider (0 - 100%)
            PhotographicPaletteSlider(
                value: Binding(
                    get: { viewModel.photographicStyle.palette },
                    set: { viewModel.updatePhotographicStyle(palette: $0) }
                ),
                tintColor: style.preset.padTintColor,
                onDragStateChanged: { dragging in
                    withAnimation(.easeOut(duration: 0.14)) {
                        activeAxis = dragging ? .palette : .none
                    }
                }
            )
            .padding(.horizontal, 14)

            // 4. Horizontal 8-Preset Selector Strip (Undertones + Moods)
            presetSelectorStrip(activePreset: style.preset)
        }
        .padding(.vertical, compact ? 9 : 11)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AlignTheme.studioGlassTint.opacity(0.68))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 0.65)
                )
        )
        .padding(.horizontal, 10)
        // Chặn sự kiện chạm lọt xuống viewfinder phía sau khay điều khiển
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {}
    }

    // MARK: - 1. Real-Time Telemetry HUD
    @ViewBuilder
    private func realtimeHUDHeader(style: PhotographicStyleState) -> some View {
        let isPadActive = activeAxis == .pad2D
        let isPaletteActive = activeAxis == .palette
        let isIdle = activeAxis == .none

        HStack(spacing: 6) {
            // Reset nút chỉ đặt lại preset đang chọn về mặc định của chính nó
            Button(action: {
                viewModel.resetActivePhotographicStylePreset()
            }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(
                        style.isModifiedFromPresetDefault
                            ? AlignTheme.studioAccent
                            : AlignTheme.studioInkTertiary
                    )
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(
                                style.isModifiedFromPresetDefault
                                    ? AlignTheme.studioAccentSoft
                                    : Color.white.opacity(0.06)
                            )
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!style.isModifiedFromPresetDefault)
            .accessibilityLabel("Đặt lại thông số phong cách hiện tại")

            Spacer(minLength: 2)

            // 3 chỉ số thời gian thực: SẮC THÁI · MÀU · BẢNG MÀU
            HStack(spacing: compact ? 8 : 11) {
                hudMetricItem(
                    label: "SẮC THÁI",
                    value: style.toneDisplayText,
                    highlighted: isPadActive,
                    dimmed: isPaletteActive,
                    isEdited: style.tonePercent != 0
                )

                hudDivider

                hudMetricItem(
                    label: style.preset.isMonochrome ? "TÔNG BẠC" : "MÀU",
                    value: style.colorDisplayText,
                    highlighted: isPadActive,
                    dimmed: isPaletteActive,
                    isEdited: style.colorPercent != 0
                )

                hudDivider

                hudMetricItem(
                    label: "BẢNG MÀU",
                    value: style.paletteDisplayText,
                    highlighted: isPaletteActive,
                    dimmed: isPadActive && !isIdle,
                    isEdited: style.palettePercent != 100
                )
            }

            Spacer(minLength: 2)

            // Đóng khay điều khiển (vẫn giữ màu đang chọn)
            Button(action: {
                HapticFeedbackService.shared.triggerLight()
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    viewModel.isShowingPhotographicStylePad = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đóng bảng Photographic Styles")
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func hudMetricItem(
        label: String,
        value: String,
        highlighted: Bool,
        dimmed: Bool,
        isEdited: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: compact ? 8.2 : 8.8, weight: .semibold, design: .rounded))
                .foregroundColor(
                    highlighted
                        ? AlignTheme.studioInkPrimary
                        : AlignTheme.studioInkSecondary
                )

            Text(value)
                .font(.system(size: compact ? 10.2 : 10.8, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(
                    highlighted || isEdited
                        ? AlignTheme.studioAccent
                        : AlignTheme.studioInkPrimary.opacity(0.90)
                )
                .frame(minWidth: compact ? 24 : 28, alignment: .trailing)
        }
        .opacity(dimmed ? 0.45 : 1.0)
        .animation(.easeOut(duration: 0.14), value: highlighted)
        .animation(.easeOut(duration: 0.14), value: dimmed)
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 0.6, height: 10)
    }

    // MARK: - 4. Horizontal Preset Selector Strip
    @ViewBuilder
    private func presetSelectorStrip(activePreset: PhotographicStylePreset) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotographicStylePreset.allCases) { preset in
                        let isSelected = preset == activePreset
                        let hasCustomEdits = viewModel.hasSessionEditsForPhotographicStyle(preset)

                        Button(action: {
                            HapticFeedbackService.shared.triggerSelectionChange()
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                viewModel.selectPhotographicStylePreset(preset)
                                proxy.scrollTo(preset.id, anchor: .center)
                            }
                        }) {
                            HStack(spacing: 4) {
                                if hasCustomEdits {
                                    Circle()
                                        .fill(isSelected ? Color.black : AlignTheme.studioAccent)
                                        .frame(width: 4, height: 4)
                                }
                                Text(preset.displayName)
                                    .font(.system(size: compact ? 10.2 : 10.8, weight: isSelected ? .semibold : .medium, design: .rounded))
                            }
                            .foregroundColor(isSelected ? Color.black : AlignTheme.studioInkPrimary.opacity(0.84))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(
                                ZStack {
                                    if isSelected {
                                        Capsule()
                                            .fill(AlignTheme.studioAccent)
                                            .matchedGeometryEffect(id: "active_photo_style_pill", in: presetPillNamespace)
                                    } else {
                                        Capsule()
                                            .fill(Color.white.opacity(0.07))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.55)
                                            )
                                    }
                                }
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id(preset.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear {
                proxy.scrollTo(activePreset.id, anchor: .center)
            }
        }
    }
}

// MARK: - Interactive 11x11 2D Control Pad (Gaussian Proximity + Relative Drag + Tap-to-Glide + Hysteresis Snap)
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

    private var thumbPoint: CGPoint {
        let nx = CGFloat((color + 1.0) * 0.5)
        let ny = CGFloat((1.0 - tone) * 0.5)
        return CGPoint(
            x: gridInset + nx * usableSpan,
            y: gridInset + ny * usableSpan
        )
    }

    private var thumbUnitPoint: UnitPoint {
        UnitPoint(
            x: Double(thumbPoint.x / max(1, padSize)),
            y: Double(thumbPoint.y / max(1, padSize))
        )
    }

    var body: some View {
        ZStack {
            // 1. Nền gradient quang học tối (dưới) -> sáng dịu (trên) + ánh sắc preset nhẹ (phải)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.80, green: 0.81, blue: 0.83).opacity(0.62),
                            Color(red: 0.42, green: 0.43, blue: 0.46).opacity(0.68),
                            Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.84)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    preset.padTintColor.opacity(0.42)
                                ],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                )
                // Lớp RadialGradient sáng mờ bám theo vị trí con trỏ
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isDragging ? 0.24 : 0.14),
                                    Color.clear
                                ],
                                center: thumbUnitPoint,
                                startRadius: 4,
                                endRadius: padSize * 0.46
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                )

            // 2. Lưới 11x11 chấm trên 1 GPU Canvas (60-120Hz zero view-tree allocation)
            Canvas { context, size in
                let inset = size.width * 0.115
                let span = max(1, size.width - inset * 2.0)
                let step = span / 10.0

                let thumbCol = CGFloat((color + 1.0) * 5.0)
                let thumbRow = CGFloat((1.0 - tone) * 5.0)
                let thumbX = inset + thumbCol * step
                let thumbY = inset + thumbRow * step
                let sigmaSq: CGFloat = 1.45 * 1.45 * 2.0

                for row in 0...10 {
                    for col in 0...10 {
                        let baseX = inset + CGFloat(col) * step
                        let baseY = inset + CGFloat(row) * step

                        let dCol = CGFloat(col) - thumbCol
                        let dRow = CGFloat(row) - thumbRow
                        let distGrid = hypot(dCol, dRow)

                        // Chấm nằm ngay dưới thân nút tròn trắng mờ dần để viền sạch tuyệt đối
                        let underThumbFade = clampUnit((distGrid - 0.50) / 0.42)
                        if underThumbFade <= 0.02 { continue }

                        // Gaussian Proximity Field: chấm gần con trỏ sáng hơn, phồng nhẹ và giãn ra ngoài khi kéo
                        let gaussian = exp(-(distGrid * distGrid) / sigmaSq)
                        var drawX = baseX
                        var drawY = baseY
                        if isDragging && distGrid > 0.15 {
                            let dxPx = baseX - thumbX
                            let dyPx = baseY - thumbY
                            let lenPx = max(1.0, hypot(dxPx, dyPx))
                            let push: CGFloat = 1.55 * gaussian * clampUnit(distGrid / 0.9)
                            drawX += (dxPx / lenPx) * push
                            drawY += (dyPx / lenPx) * push
                        }

                        let onCrosshairRow = abs(dRow) <= 0.52
                        let onCrosshairCol = abs(dCol) <= 0.52
                        let isOrigin = (row == 5 && col == 5)

                        if isOrigin {
                            // Vòng tròn rỗng mốc gốc (0, 0) giống sát Camera iOS
                            let ringR: CGFloat = 3.0 + 0.5 * gaussian
                            let ringRect = CGRect(x: drawX - ringR, y: drawY - ringR, width: ringR * 2, height: ringR * 2)
                            let ringAlpha = (0.48 + 0.34 * gaussian) * underThumbFade
                            context.stroke(
                                Path(ellipseIn: ringRect),
                                with: .color(Color.white.opacity(ringAlpha)),
                                lineWidth: 1.05
                            )
                        } else {
                            let isAxisDot = onCrosshairRow || onCrosshairCol
                            let baseRadius: CGFloat = isAxisDot ? 1.85 : 1.25
                            let radius = baseRadius + (isDragging ? 0.85 : 0.45) * gaussian
                            let baseAlpha: CGFloat = isAxisDot ? 0.78 : 0.28
                            let alpha = min(0.96, baseAlpha + 0.24 * gaussian) * underThumbFade

                            let dotRect = CGRect(x: drawX - radius, y: drawY - radius, width: radius * 2, height: radius * 2)
                            context.fill(
                                Path(ellipseIn: dotRect),
                                with: .color(Color.white.opacity(alpha))
                            )
                        }
                    }
                }
            }
            .allowsHitTesting(false)

            // 3. Núm điều khiển tròn trắng đặc trưng iOS Camera
            Circle()
                .fill(Color.white)
                .frame(width: isDragging ? 25 : 21, height: isDragging ? 25 : 21)
                .shadow(color: Color.black.opacity(0.38), radius: isDragging ? 6 : 4, y: 1.5)
                .position(thumbPoint)
                .animation(.spring(response: 0.20, dampingFraction: 0.78), value: isDragging)
                .allowsHitTesting(false)
        }
        .frame(width: padSize, height: padSize)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                    if !hasMovedPastTapThreshold && travel >= 4.0 {
                        hasMovedPastTapThreshold = true
                    }
                    guard hasMovedPastTapThreshold else { return }

                    // Relative 1:1 Delta Drag: ngón tay đặt đâu kéo đó, không che mất con trỏ trắng
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
                        // Double-tap -> trả (Tone, Color) về mốc gốc (0, 0)
                        lastTapTimestamp = 0
                        HapticFeedbackService.shared.triggerMedium()
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.80)) {
                            onDoubleTapReset()
                        }
                    } else {
                        // Tap đơn -> trượt mượt tới vị trí chạm
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
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.80)) {
                            onUpdate(snappedT, snappedC)
                        }
                    }
                }
        )
    }

    private func clampUnit(_ value: CGFloat) -> CGFloat {
        max(0.0, min(1.0, value))
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

// MARK: - Numbered Circular Palette Slider (0 ... 100%)
private struct PhotographicPaletteSlider: View {
    @Binding var value: Float
    let tintColor: Color
    let onDragStateChanged: (Bool) -> Void

    @State private var isDragging: Bool = false
    @State private var lastNotch: Int = 10

    var body: some View {
        GeometryReader { geo in
            let thumbDiameter: CGFloat = 24
            let trackWidth = max(1, geo.size.width - thumbDiameter)
            let clamped = CGFloat(max(0.0, min(1.0, value)))
            let thumbX = thumbDiameter * 0.5 + clamped * trackWidth
            let percentInt = Int(round(Double(clamped) * 100.0))

            ZStack(alignment: .leading) {
                // Nền track
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 4)

                // Phần fill sáng nhẹ theo sắc độ preset
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.60),
                                tintColor.opacity(0.92)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, thumbX), height: 4)

                // Mốc giữa 50% tinh tế
                Circle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 3, height: 3)
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                    .allowsHitTesting(false)

                // Núm tròn trắng có hiển thị số 0-100 trực tiếp bên trong
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.34), radius: isDragging ? 5 : 3, y: 1)

                    Text("\(percentInt)")
                        .font(.system(size: 8.8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(AlignTheme.obsidianBlack)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                }
                .frame(width: thumbDiameter, height: thumbDiameter)
                .scaleEffect(isDragging ? 1.12 : 1.0)
                .position(x: thumbX, y: geo.size.height * 0.5)
                .animation(.spring(response: 0.18, dampingFraction: 0.78), value: isDragging)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            lastNotch = Int(round(value * 10.0))
                            onDragStateChanged(true)
                        }
                        let norm = (drag.location.x - thumbDiameter * 0.5) / trackWidth
                        let raw = Float(max(0.0, min(1.0, norm)))
                        // Hút nhẹ ở mốc 50% (0.5) để cân chỉnh dễ dàng
                        let finalVal: Float = abs(raw - 0.5) < 0.018 ? 0.5 : raw
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
        }
        .frame(height: 28)
        .accessibilityLabel("Cường độ bảng màu Photographic Style")
    }
}
