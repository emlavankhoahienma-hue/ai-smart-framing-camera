//
//  WindowedZoomOverlayView.swift
//  AISmartFramingCamera
//
//  Khung ngắm quang học Rangefinder (Windowed Zoom)
//  Tự động phân tích bối cảnh, co giãn tiêu cự mm quang học, hỗ trợ lưới 3x3 và magnetic haptics.
//

import SwiftUI

public struct WindowedZoomOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    @State private var gestureInitialFocalLength: Double = 35.0
    @State private var isPinching: Bool = false
    @State private var resizingCorner: CornerPosition? = nil
    @State private var resizeInitialFocalLength: Double = 35.0
    @State private var resizeInitialHalfDiag: CGFloat = 100.0
    @State private var resizeInitialHalfSize: CGSize = CGSize(width: 100, height: 100)
    @State private var liveNormalizedCenter: CGPoint? = nil
    @State private var liveFocalLength: Double? = nil
    @State private var lastVideoKeyframeSyncTime: CFTimeInterval = 0
    @Namespace private var focalPillNamespace

    private let presets = WindowedFocalLengthPreset.standardPresets
    private let windowCornerRadius: CGFloat = 20.0

    private enum CornerPosition {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    private var effectiveFocalLength: Double {
        liveFocalLength ?? viewModel.windowedZoomFocalLength
    }

    private var effectiveNormalizedCenter: CGPoint {
        liveNormalizedCenter ?? viewModel.windowedZoomNormalizedCenter
    }

    /// Chỉ ẩn hoàn toàn Mask khi tiêu cự <= 24.5mm VÀ tỷ lệ khớp khung gốc 3:4.
    /// Nếu ở 24mm mà chọn 1:1 hoặc 16:9, vẫn hiển thị Mask và viền khung để cắt đúng tỷ lệ.
    private var isUnmodifiedFullView: Bool {
        effectiveFocalLength <= 24.5 && viewModel.windowedZoomAspectRatio == .ratio3_4
    }

    @State private var dragStartNormalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingWindow: Bool = false

    // MARK: - Window Dimensions Calculation (Fixed 1.0x Base Optical Zoom -> Zero Lens Jump)
    private var windowRect: CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
            focalLength: effectiveFocalLength,
            baseOpticalZoom: 1.0,
            containerAspect: containerSize.width / containerSize.height
        )
        let w = containerSize.width * fractions.widthFraction
        let h = containerSize.height * fractions.heightFraction
        let halfW = w / 2.0
        let halfH = h / 2.0
        let minCenterX = halfW
        let maxCenterX = max(halfW, containerSize.width - halfW)
        let minCenterY = halfH
        let maxCenterY = max(halfH, containerSize.height - halfH)
        let activeCenter = effectiveNormalizedCenter
        let centerX = max(minCenterX, min(containerSize.width * activeCenter.x, maxCenterX))
        let centerY = max(minCenterY, min(containerSize.height * activeCenter.y, maxCenterY))
        let x = centerX - halfW
        let y = centerY - halfH
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func clampNormalizedCenter(for focal: Double? = nil) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        let targetFocal = focal ?? effectiveFocalLength
        let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
            focalLength: targetFocal,
            baseOpticalZoom: 1.0,
            containerAspect: containerSize.width / containerSize.height
        )
        let halfWFrac = fractions.widthFraction / 2.0
        let halfHFrac = fractions.heightFraction / 2.0
        let current = effectiveNormalizedCenter
        let clampedX = max(halfWFrac, min(current.x, 1.0 - halfWFrac))
        let clampedY = max(halfHFrac, min(current.y, 1.0 - halfHFrac))
        let clampedPoint = CGPoint(x: clampedX, y: clampedY)
        if liveNormalizedCenter != nil {
            liveNormalizedCenter = clampedPoint
        }
        if clampedX != viewModel.windowedZoomNormalizedCenter.x || clampedY != viewModel.windowedZoomNormalizedCenter.y {
            viewModel.windowedZoomNormalizedCenter = clampedPoint
        }
    }

    private func syncLiveGestureToViewModelIfRecording(center: CGPoint?, focal: Double?) {
        guard viewModel.isRecordingVideo else { return }
        let now = CACurrentMediaTime()
        guard now - lastVideoKeyframeSyncTime >= 0.032 else { return }
        lastVideoKeyframeSyncTime = now
        if let center {
            viewModel.windowedZoomNormalizedCenter = center
        }
        if let focal {
            viewModel.windowedZoomFocalLength = focal
        }
        viewModel.recordWindowedKeyframeFromLiveGesture()
    }

    private var isInteracting: Bool {
        isDraggingWindow || isPinching || resizingCorner != nil
    }

    public var body: some View {
        ZStack {
            // 1. Lớp làm tối ngoài viền (Cutout Dimming Mask 44% bo tròn mềm mại)
            if !isUnmodifiedFullView {
                WindowedMaskCutout(windowRect: windowRect, cornerRadius: windowCornerRadius)
                    .fill(Color.black.opacity(0.44), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 2. Khung ngắm Rangefinder bo tròn hiện đại, di chuyển siêu mượt 120Hz
            if !isUnmodifiedFullView {
                ZStack(alignment: .center) {
                    // Viền ngoài bo tròn continuous 20pt mượt mà chuẩn Leica Brightline
                    RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                        .stroke(
                            isInteracting ? AlignTheme.electricCyan.opacity(0.96) : Color.white.opacity(0.82),
                            lineWidth: isInteracting ? 1.9 : 1.35
                        )
                        .background(
                            RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                                .stroke(Color.black.opacity(0.28), lineWidth: 0.8)
                                .padding(1.2)
                        )
                        .background(Color.white.opacity(0.001))
                        .frame(width: windowRect.width, height: windowRect.height)

                    // Lưới bố cục 3x3 & 4 góc bo tròn đồng tâm với cửa sổ
                    opticalGridView
                        .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))

                    // Tâm ngắm siêu mảnh tại chính giữa cửa sổ
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(isInteracting ? 0.55 : 0.30), lineWidth: 0.8)
                            .frame(width: 10, height: 10)
                        Circle()
                            .fill(isInteracting ? AlignTheme.electricCyan : Color.white.opacity(0.65))
                            .frame(width: 3, height: 3)
                    }
                }
                .frame(width: windowRect.width, height: windowRect.height)
                .position(x: windowRect.midX, y: windowRect.midY)
                .transaction { $0.animation = isInteracting ? nil : $0.animation }
                .contentShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("windowed_container"))
                        .onChanged { value in
                            guard resizingCorner == nil, containerSize.width > 0, containerSize.height > 0 else { return }
                            if !isDraggingWindow {
                                isDraggingWindow = true
                                dragStartNormalizedCenter = effectiveNormalizedCenter
                                liveNormalizedCenter = dragStartNormalizedCenter
                            }
                            let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
                                focalLength: effectiveFocalLength,
                                baseOpticalZoom: 1.0,
                                containerAspect: containerSize.width / containerSize.height
                            )
                            let halfWFrac = fractions.widthFraction / 2.0
                            let halfHFrac = fractions.heightFraction / 2.0
                            let deltaX = value.translation.width / containerSize.width
                            let deltaY = value.translation.height / containerSize.height
                            let rawX = dragStartNormalizedCenter.x + deltaX
                            let rawY = dragStartNormalizedCenter.y + deltaY
                            let clampedX = max(halfWFrac, min(rawX, 1.0 - halfWFrac))
                            let clampedY = max(halfHFrac, min(rawY, 1.0 - halfHFrac))
                            let nextCenter = CGPoint(x: clampedX, y: clampedY)
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                liveNormalizedCenter = nextCenter
                            }
                            syncLiveGestureToViewModelIfRecording(center: nextCenter, focal: nil)
                        }
                        .onEnded { _ in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                if let finalCenter = liveNormalizedCenter {
                                    viewModel.windowedZoomNormalizedCenter = finalCenter
                                }
                                liveNormalizedCenter = nil
                                isDraggingWindow = false
                            }
                            viewModel.recordWindowedKeyframeFromLiveGesture()
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        liveNormalizedCenter = nil
                        viewModel.windowedZoomNormalizedCenter = CGPoint(x: 0.5, y: 0.5)
                    }
                    viewModel.recordWindowedKeyframeFromLiveGesture()
                    viewModel.haptics.triggerSelectionChange()
                }

                // 4 Tay nắm kéo góc độc lập trong hệ tọa độ cố định của container (0% nhảy tọa độ)
                cornerResizeHandle(position: .topLeft)
                cornerResizeHandle(position: .topRight)
                cornerResizeHandle(position: .bottomLeft)
                cornerResizeHandle(position: .bottomRight)
            }

            // 3. Thanh chọn tiêu cự Prime nhanh + nút đổi tỉ lệ khung (Full, 28mm, 35mm, 50mm, 85mm • 3:4/1:1/16:9)
            VStack {
                Spacer()
                focalPresetBar
                    .padding(.bottom, 14)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .coordinateSpace(name: "windowed_container")
        .contentShape(Rectangle())
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        isPinching = true
                        gestureInitialFocalLength = effectiveFocalLength
                        liveFocalLength = gestureInitialFocalLength
                        liveNormalizedCenter = effectiveNormalizedCenter
                    }
                    let safeScale = max(0.12, Double(value))
                    let rawFocal = gestureInitialFocalLength / safeScale
                    let targetFocal = max(24.0, min(135.0, rawFocal))
                    let resolvedFocal = targetFocal <= 24.3 ? 24.0 : targetFocal

                    let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
                        focalLength: resolvedFocal,
                        baseOpticalZoom: 1.0,
                        containerAspect: max(0.1, containerSize.width / max(1.0, containerSize.height))
                    )
                    let halfWFrac = fractions.widthFraction / 2.0
                    let halfHFrac = fractions.heightFraction / 2.0
                    let current = effectiveNormalizedCenter
                    let clampedCenter = CGPoint(
                        x: max(halfWFrac, min(current.x, 1.0 - halfWFrac)),
                        y: max(halfHFrac, min(current.y, 1.0 - halfHFrac))
                    )

                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        liveFocalLength = resolvedFocal
                        liveNormalizedCenter = clampedCenter
                    }
                    syncLiveGestureToViewModelIfRecording(center: clampedCenter, focal: resolvedFocal)
                }
                .onEnded { _ in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let finalFocal = liveFocalLength {
                            viewModel.windowedZoomFocalLength = finalFocal
                        }
                        if let finalCenter = liveNormalizedCenter {
                            viewModel.windowedZoomNormalizedCenter = finalCenter
                        }
                        liveFocalLength = nil
                        liveNormalizedCenter = nil
                        isPinching = false
                    }
                    viewModel.recordWindowedKeyframeFromLiveGesture()
                }
        )
    }

    // MARK: - Interactive Corner Resize Handles (Kéo 4 góc mượt 120Hz không nhảy khung)
    @ViewBuilder
    private func cornerResizeHandle(position: CornerPosition) -> some View {
        let isCurrent = resizingCorner == position
        let handleTouchArea: CGFloat = 44
        let cornerInset: CGFloat = 3.0
        let cornerPoint: CGPoint = {
            switch position {
            case .topLeft:     return CGPoint(x: windowRect.minX + cornerInset, y: windowRect.minY + cornerInset)
            case .topRight:    return CGPoint(x: windowRect.maxX - cornerInset, y: windowRect.minY + cornerInset)
            case .bottomLeft:  return CGPoint(x: windowRect.minX + cornerInset, y: windowRect.maxY - cornerInset)
            case .bottomRight: return CGPoint(x: windowRect.maxX - cornerInset, y: windowRect.maxY - cornerInset)
            }
        }()

        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: handleTouchArea, height: handleTouchArea)
                .contentShape(Rectangle())

            Circle()
                .fill(isCurrent ? AlignTheme.electricCyan : Color.white.opacity(0.92))
                .frame(width: isCurrent ? 10 : 6, height: isCurrent ? 10 : 6)
                .shadow(color: Color.black.opacity(0.6), radius: 2)
        }
        .position(x: cornerPoint.x, y: cornerPoint.y)
        .transaction { $0.animation = isInteracting ? nil : $0.animation }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("windowed_container"))
                .onChanged { value in
                    if resizingCorner != position {
                        resizingCorner = position
                        resizeInitialFocalLength = effectiveFocalLength
                        liveFocalLength = resizeInitialFocalLength
                        liveNormalizedCenter = effectiveNormalizedCenter
                        let initHalfW = max(20.0, windowRect.width / 2.0)
                        let initHalfH = max(20.0, windowRect.height / 2.0)
                        resizeInitialHalfSize = CGSize(width: initHalfW, height: initHalfH)
                        resizeInitialHalfDiag = hypot(initHalfW, initHalfH)
                    }

                    let tx = value.translation.width
                    let ty = value.translation.height
                    let initHalfW = resizeInitialHalfSize.width
                    let initHalfH = resizeInitialHalfSize.height

                    let currentHalfDiag: CGFloat
                    switch position {
                    case .topLeft:
                        currentHalfDiag = hypot(max(16, initHalfW - tx), max(16, initHalfH - ty))
                    case .topRight:
                        currentHalfDiag = hypot(max(16, initHalfW + tx), max(16, initHalfH - ty))
                    case .bottomLeft:
                        currentHalfDiag = hypot(max(16, initHalfW - tx), max(16, initHalfH + ty))
                    case .bottomRight:
                        currentHalfDiag = hypot(max(16, initHalfW + tx), max(16, initHalfH + ty))
                    }

                    let ratio = currentHalfDiag / max(16.0, resizeInitialHalfDiag)
                    let rawFocal = resizeInitialFocalLength / max(0.12, Double(ratio))
                    let targetFocal = max(24.0, min(135.0, rawFocal))
                    let resolvedFocal = targetFocal <= 24.3 ? 24.0 : targetFocal

                    let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
                        focalLength: resolvedFocal,
                        baseOpticalZoom: 1.0,
                        containerAspect: max(0.1, containerSize.width / max(1.0, containerSize.height))
                    )
                    let halfWFrac = fractions.widthFraction / 2.0
                    let halfHFrac = fractions.heightFraction / 2.0
                    let current = effectiveNormalizedCenter
                    let clampedCenter = CGPoint(
                        x: max(halfWFrac, min(current.x, 1.0 - halfWFrac)),
                        y: max(halfHFrac, min(current.y, 1.0 - halfHFrac))
                    )

                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        liveFocalLength = resolvedFocal
                        liveNormalizedCenter = clampedCenter
                    }
                    syncLiveGestureToViewModelIfRecording(center: clampedCenter, focal: resolvedFocal)
                }
                .onEnded { _ in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if let finalFocal = liveFocalLength {
                            viewModel.windowedZoomFocalLength = finalFocal
                        }
                        if let finalCenter = liveNormalizedCenter {
                            viewModel.windowedZoomNormalizedCenter = finalCenter
                        }
                        liveFocalLength = nil
                        liveNormalizedCenter = nil
                        resizingCorner = nil
                    }
                    viewModel.recordWindowedKeyframeFromLiveGesture()
                }
        )
    }

    // MARK: - Optical Grid & Rounded Leica Corner Brackets
    @ViewBuilder
    private var opticalGridView: some View {
        ZStack {
            // Lưới Rule of Thirds siêu mảnh 0.5pt
            Path { path in
                let w = windowRect.width
                let h = windowRect.height
                path.move(to: CGPoint(x: w / 3.0, y: 0))
                path.addLine(to: CGPoint(x: w / 3.0, y: h))
                path.move(to: CGPoint(x: (2.0 * w) / 3.0, y: 0))
                path.addLine(to: CGPoint(x: (2.0 * w) / 3.0, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3.0))
                path.addLine(to: CGPoint(x: w, y: h / 3.0))
                path.move(to: CGPoint(x: 0, y: (2.0 * h) / 3.0))
                path.addLine(to: CGPoint(x: w, y: (2.0 * h) / 3.0))
            }
            .stroke(Color.white.opacity(isInteracting ? 0.32 : 0.16), lineWidth: 0.5)

            // 4 góc bo tròn ôm sát viền cửa sổ
            LeicaCornerBrackets(bracketLength: 18, cornerRadius: windowCornerRadius)
                .stroke(
                    isInteracting ? AlignTheme.electricCyan : Color.white.opacity(0.95),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: windowRect.width, height: windowRect.height)
        .allowsHitTesting(false)
    }

    private func isPresetSelected(_ preset: WindowedFocalLengthPreset) -> Bool {
        if preset.focalLength <= 24.0 {
            return effectiveFocalLength <= 24.5
        }
        return abs(effectiveFocalLength - preset.focalLength) < 2.0
    }

    private func selectPreset(_ preset: WindowedFocalLengthPreset) {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            liveFocalLength = nil
            liveNormalizedCenter = nil
            viewModel.windowedZoomFocalLength = preset.focalLength
            clampNormalizedCenter(for: preset.focalLength)
        }
        viewModel.recordWindowedKeyframeFromLiveGesture()
    }

    private var focalPresetBar: some View {
        HStack(spacing: 5) {
            ForEach(presets) { preset in
                FocalPresetButton(
                    preset: preset,
                    isSelected: isPresetSelected(preset),
                    action: { selectPreset(preset) },
                    focalPillNamespace: focalPillNamespace
                )
            }

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.25))

            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    liveFocalLength = nil
                    liveNormalizedCenter = nil
                    viewModel.cycleAspectRatio()
                    if viewModel.windowedZoomFocalLength <= 24.5 && viewModel.windowedZoomAspectRatio != .ratio3_4 {
                        viewModel.windowedZoomFocalLength = 28.0
                    }
                    clampNormalizedCenter()
                }
                viewModel.recordWindowedKeyframeFromLiveGesture()
                viewModel.haptics.triggerSelectionChange()
            }) {
                Text(viewModel.windowedZoomAspectRatio.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(viewModel.windowedZoomAspectRatio != .ratio3_4 ? AlignTheme.electricCyan : Color.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(height: 32)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
        )
    }
}

// MARK: - 4 Góc Bo Tròn Chuẩn Rangefinder Leica
private struct LeicaCornerBrackets: Shape {
    let bracketLength: CGFloat
    var cornerRadius: CGFloat = 20.0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let r = min(cornerRadius, min(w, h) / 3.0)
        let arm = max(r + 4.0, min(bracketLength + r * 0.45, min(w, h) / 2.6))

        // Top-Left Rounded Corner
        path.move(to: CGPoint(x: 0, y: arm))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: arm, y: 0))

        // Top-Right Rounded Corner
        path.move(to: CGPoint(x: w - arm, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(center: CGPoint(x: w - r, y: r), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: w, y: arm))

        // Bottom-Left Rounded Corner
        path.move(to: CGPoint(x: 0, y: h - arm))
        path.addLine(to: CGPoint(x: 0, y: h - r))
        path.addArc(center: CGPoint(x: r, y: h - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: arm, y: h))

        // Bottom-Right Rounded Corner
        path.move(to: CGPoint(x: w - arm, y: h))
        path.addLine(to: CGPoint(x: w - r, y: h))
        path.addArc(center: CGPoint(x: w - r, y: h - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: w, y: h - arm))

        return path
    }
}

// MARK: - Focal Preset Button Subview (Fast Type-Checking)
private struct FocalPresetButton: View {
    let preset: WindowedFocalLengthPreset
    let isSelected: Bool
    let action: () -> Void
    var focalPillNamespace: Namespace.ID

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Capsule()
                        .stroke(AlignTheme.signatureGradient, lineWidth: 1.5)
                        .background(Capsule().fill(Color.black.opacity(0.40)))
                        .matchedGeometryEffect(id: "active_windowed_focal_ring", in: focalPillNamespace)
                }

                Text(preset.label)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? AlignTheme.electricCyan : Color.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .frame(minWidth: 40)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Tieu cu \(preset.label)")
    }
}

// MARK: - Windowed Mask Cutout Shape (Even-Odd Fill)
private struct WindowedMaskCutout: Shape {
    let windowRect: CGRect
    var cornerRadius: CGFloat = 20.0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addPath(Path(roundedRect: windowRect, cornerRadius: cornerRadius, style: .continuous))
        return path
    }
}
