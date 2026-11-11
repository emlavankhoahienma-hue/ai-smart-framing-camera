//
//  WindowedZoomOverlayView.swift
//  AISmartFramingCamera
//
//  Khung ngắm quang học Rangefinder (Windowed Zoom)
//  Tự động phân tích bối cảnh, co giãn tiêu cự mm quang học, hiển thị thông số tiêu cự chuẩn Leica/Kapi Cam.
//

import SwiftUI

public struct WindowedZoomOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    @State private var gestureInitialFocalLength: Double = 50.0
    @State private var isPinching: Bool = false
    @State private var liveNormalizedCenter: CGPoint? = nil
    @State private var liveFocalLength: Double? = nil
    @State private var lastVideoKeyframeSyncTime: CFTimeInterval = 0
    @State private var dragStartNormalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingWindow: Bool = false
    @State private var isWindowTemporarilyHidden: Bool = false
    @Namespace private var focalPillNamespace

    private let presets = WindowedFocalLengthPreset.standardPresets
    private let windowCornerRadius: CGFloat = 20.0

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

    /// Trạng thái hiển thị khung ngắm cửa sổ: hiển thị khi không ở Full và không bị ẩn tạm thời.
    private var shouldShowViewfinderWindow: Bool {
        !isUnmodifiedFullView && !isWindowTemporarilyHidden
    }

    private var isInteracting: Bool {
        isDraggingWindow || isPinching
    }

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

    public var body: some View {
        ZStack {
            // Nền trong suốt bắt sự kiện chạm bên ngoài khung cửa sổ để ẩn/hiện tạm khung ngắm
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isUnmodifiedFullView {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            isWindowTemporarilyHidden.toggle()
                        }
                    }
                }

            // 1. Lớp làm tối ngoài viền (Cutout Dimming Mask 44% bo tròn mềm mại)
            if shouldShowViewfinderWindow {
                WindowedMaskCutout(windowRect: windowRect, cornerRadius: windowCornerRadius)
                    .fill(Color.black.opacity(0.44), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 2. Khung ngắm Rangefinder bo tròn hiện đại, di chuyển siêu mượt 120Hz (không còn 4 chấm tròn)
            if shouldShowViewfinderWindow {
                ZStack(alignment: .center) {
                    // Viền ngoài bo tròn continuous 20pt dày dặn, sắc nét chuẩn Kapi Cam, KHÔNG viền kép thừa
                    RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous)
                        .stroke(
                            isInteracting ? AlignTheme.electricCyan.opacity(0.98) : Color.white.opacity(0.92),
                            lineWidth: isInteracting ? 2.6 : 2.0
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .background(Color.white.opacity(0.001))
                        .frame(width: windowRect.width, height: windowRect.height)

                    // Lưới bố cục 3x3 chỉ hiện khi bật grid, giữ khung ngắm trong suốt sạch sẽ
                    if viewModel.isManualGridVisible {
                        opticalGridView
                            .clipShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                    }

                    // Tâm ngắm siêu mảnh tại chính giữa cửa sổ
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(isInteracting ? 0.55 : 0.25), lineWidth: 0.8)
                            .frame(width: 8, height: 8)
                        Circle()
                            .fill(isInteracting ? AlignTheme.electricCyan : Color.white.opacity(0.55))
                            .frame(width: 2.5, height: 2.5)
                    }
                }
                .frame(width: windowRect.width, height: windowRect.height)
                .position(x: windowRect.midX, y: windowRect.midY)
                .transaction { $0.animation = isInteracting ? nil : $0.animation }
                .contentShape(RoundedRectangle(cornerRadius: windowCornerRadius, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("windowed_container"))
                        .onChanged { value in
                            guard containerSize.width > 0, containerSize.height > 0 else { return }
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

                // 3. Thông số tiêu cự mm hiển thị trên đỉnh mép trên cửa sổ (Font đậm, sắc nét, dễ nhìn như ảnh 3)
                Text("\(Int(round(effectiveFocalLength)))mm")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(isInteracting ? AlignTheme.electricCyan : .white)
                    .shadow(color: Color.black.opacity(0.85), radius: 2.5, x: 0, y: 1)
                    .position(x: windowRect.midX, y: max(16, windowRect.minY - 14))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 4. Thanh chọn tiêu cự Prime nhanh + nút đổi tỉ lệ khung (Full, 28mm, 35mm, 50mm, 85mm • 3:4/1:1/16:9)
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

    // MARK: - Optical Grid (Chỉ hiển thị khi người dùng bật Grid)
    @ViewBuilder
    private var opticalGridView: some View {
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
        .stroke(Color.white.opacity(isInteracting ? 0.28 : 0.15), lineWidth: 0.5)
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

        // Nếu bấm lại chính preset đang chọn (và không phải Full): toggle ẩn/hiện tạm khung vuông!
        if isPresetSelected(preset) && preset.focalLength > 24.5 {
            withAnimation(.easeInOut(duration: 0.22)) {
                isWindowTemporarilyHidden.toggle()
            }
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            isWindowTemporarilyHidden = false
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
                    isWindowTemporarilyHidden = false
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

// MARK: - Corner Bracket Geometry Reference (Duy trì chuẩn hình học & Contract tests)
public struct LeicaCornerBrackets: Shape {
    public let bracketLength: CGFloat
    public var cornerRadius: CGFloat = 20.0

    public init(bracketLength: CGFloat = 18, cornerRadius: CGFloat = 20.0) {
        self.bracketLength = bracketLength
        self.cornerRadius = cornerRadius
    }

    public func path(in rect: CGRect) -> Path {
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
