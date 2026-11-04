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
    @State private var lastSnappedPreset: Double? = nil
    @Namespace private var focalPillNamespace

    private let presets = WindowedFocalLengthPreset.standardPresets
    private let magneticPresets: [Double] = [24.0, 28.0, 35.0, 50.0, 85.0]

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    /// Chỉ ẩn hoàn toàn Mask khi tiêu cự <= 24.5mm VÀ tỷ lệ khớp khung gốc 3:4.
    /// Nếu ở 24mm mà chọn 1:1 hoặc 16:9, vẫn hiển thị Mask và viền khung để cắt đúng tỷ lệ.
    private var isUnmodifiedFullView: Bool {
        viewModel.windowedZoomFocalLength <= 24.5 && viewModel.windowedZoomAspectRatio == .ratio3_4
    }

    @State private var dragStartNormalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var isDraggingWindow: Bool = false

    // MARK: - Window Dimensions Calculation
    private var windowRect: CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
            focalLength: viewModel.windowedZoomFocalLength,
            baseOpticalZoom: viewModel.displayZoom,
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
        let centerX = max(minCenterX, min(containerSize.width * viewModel.windowedZoomNormalizedCenter.x, maxCenterX))
        let centerY = max(minCenterY, min(containerSize.height * viewModel.windowedZoomNormalizedCenter.y, maxCenterY))
        let x = centerX - halfW
        let y = centerY - halfH
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private var dynamicBadgeText: String {
        let mm = Int(round(viewModel.windowedZoomFocalLength))
        let aspect = viewModel.windowedZoomAspectRatio.rawValue
        let opticalTag = viewModel.displayZoom >= 1.95 ? "TELE 2X" : "OPTICAL"
        return "\(mm)mm • \(aspect) • \(opticalTag)"
    }

    public var body: some View {
        ZStack {
            // 1. Lớp làm tối ngoài viền (Cutout Dimming Mask 38%)
            if !isUnmodifiedFullView {
                WindowedMaskCutout(windowRect: windowRect)
                    .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 2. Khung ngắm chính với viền bo tròn nhẹ 14pt, tâm kéo, lưới 3x3 và nhãn tiêu cự
            if !isUnmodifiedFullView {
                ZStack(alignment: .center) {
                    // Viền chính của khung ngắm
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isDraggingWindow ? AlignTheme.electricCyan : Color.white.opacity(0.85), lineWidth: isDraggingWindow ? 2.0 : 1.5)
                        .background(Color.white.opacity(0.001))
                        .frame(width: windowRect.width, height: windowRect.height)

                    // Lưới bố cục quang học 3x3 & 4 góc L-Bracket khi đang tương tác
                    opticalGridView

                    // Drag Indicator & Optical Crosshair tại tâm
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.45), lineWidth: 1)
                            .frame(width: 14, height: 14)
                        Circle()
                            .fill(isDraggingWindow ? AlignTheme.electricCyan : Color.white.opacity(0.65))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(width: windowRect.width, height: windowRect.height)
                .overlay(alignment: .top) {
                    Text(dynamicBadgeText)
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(isDraggingWindow ? AlignTheme.electricCyan : .white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.9), radius: 3, x: 0, y: 1)
                        .offset(y: -26)
                }
                .position(x: windowRect.midX, y: windowRect.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("windowed_container"))
                        .onChanged { value in
                            guard containerSize.width > 0, containerSize.height > 0 else { return }
                            if !isDraggingWindow {
                                isDraggingWindow = true
                                dragStartNormalizedCenter = viewModel.windowedZoomNormalizedCenter
                            }
                            let fractions = viewModel.windowedZoomAspectRatio.windowFractions(
                                focalLength: viewModel.windowedZoomFocalLength,
                                baseOpticalZoom: viewModel.displayZoom,
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
                            viewModel.windowedZoomNormalizedCenter = CGPoint(x: clampedX, y: clampedY)
                        }
                        .onEnded { _ in
                            isDraggingWindow = false
                            viewModel.haptics.triggerSelectionChange()
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        viewModel.windowedZoomNormalizedCenter = CGPoint(x: 0.5, y: 0.5)
                    }
                    viewModel.haptics.triggerSelectionChange()
                }
                .transition(.opacity)
            }

            // 3. Thanh chọn tiêu cự Prime nhanh (Full, 28mm, 35mm, 50mm, 85mm)
            VStack {
                Spacer()
                focalPresetBar
                    .padding(.bottom, 14)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .coordinateSpace(name: "windowed_container")
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        isPinching = true
                        gestureInitialFocalLength = viewModel.windowedZoomFocalLength
                        lastSnappedPreset = nil
                    }
                    // Bung 2 ngón tay ra (value > 1.0) -> zoom cận vào chủ thể (tiêu cự mm tăng lên)
                    let rawFocal = gestureInitialFocalLength * Double(value)
                    var targetFocal = max(24.0, min(135.0, rawFocal))

                    // Tự động bắt dính nhẹ (magnetic snap) kèm rung phản hồi khi đi qua các mốc chuẩn
                    var didSnap = false
                    for preset in magneticPresets {
                        if abs(targetFocal - preset) <= 0.8 {
                            targetFocal = preset
                            if lastSnappedPreset != preset {
                                lastSnappedPreset = preset
                                viewModel.haptics.triggerSelectionChange()
                            }
                            didSnap = true
                            break
                        }
                    }
                    if !didSnap {
                        lastSnappedPreset = nil
                    }

                    viewModel.windowedZoomFocalLength = targetFocal <= 24.5 ? 24.0 : targetFocal
                }
                .onEnded { _ in
                    isPinching = false
                    lastSnappedPreset = nil
                    viewModel.haptics.triggerSelectionChange()
                }
        )
    }

    // MARK: - Optical Grid & Leica L-Brackets
    @ViewBuilder
    private var opticalGridView: some View {
        if isDraggingWindow || isPinching {
            ZStack {
                // Lưới Rule of Thirds siêu mảnh 0.5pt
                Path { path in
                    let w = windowRect.width
                    let h = windowRect.height
                    // 2 đường dọc
                    path.move(to: CGPoint(x: w / 3.0, y: 0))
                    path.addLine(to: CGPoint(x: w / 3.0, y: h))
                    path.move(to: CGPoint(x: (2.0 * w) / 3.0, y: 0))
                    path.addLine(to: CGPoint(x: (2.0 * w) / 3.0, y: h))
                    // 2 đường ngang
                    path.move(to: CGPoint(x: 0, y: h / 3.0))
                    path.addLine(to: CGPoint(x: w, y: h / 3.0))
                    path.move(to: CGPoint(x: 0, y: (2.0 * h) / 3.0))
                    path.addLine(to: CGPoint(x: w, y: (2.0 * h) / 3.0))
                }
                .stroke(Color.white.opacity(0.28), lineWidth: 0.5)

                // 4 góc L-Bracket đậm chuẩn Rangefinder Leica
                LeicaCornerBrackets(bracketLength: 14)
                    .stroke(isDraggingWindow ? AlignTheme.electricCyan : Color.white.opacity(0.85), lineWidth: 2.0)
            }
            .frame(width: windowRect.width, height: windowRect.height)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }
    }

    private func isPresetSelected(_ preset: WindowedFocalLengthPreset) -> Bool {
        if preset.focalLength <= 24.0 {
            return isUnmodifiedFullView
        }
        return abs(viewModel.windowedZoomFocalLength - preset.focalLength) < 2.0
    }

    private func selectPreset(_ preset: WindowedFocalLengthPreset) {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
            viewModel.windowedZoomFocalLength = preset.focalLength
        }
    }

    private var focalPresetBar: some View {
        HStack(spacing: 6) {
            ForEach(presets) { preset in
                FocalPresetButton(
                    preset: preset,
                    isSelected: isPresetSelected(preset),
                    action: { selectPreset(preset) },
                    focalPillNamespace: focalPillNamespace
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.35))
        )
    }
}

// MARK: - 4 Góc L-Bracket Chuẩn Rangefinder Leica
private struct LeicaCornerBrackets: Shape {
    let bracketLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let len = min(bracketLength, min(w, h) / 3.0)

        // Top-Left
        path.move(to: CGPoint(x: 0, y: len))
        path.addLine(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: len, y: 0))

        // Top-Right
        path.move(to: CGPoint(x: w - len, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: len))

        // Bottom-Left
        path.move(to: CGPoint(x: 0, y: h - len))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: len, y: h))

        // Bottom-Right
        path.move(to: CGPoint(x: w - len, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: h - len))

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

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(in: windowRect, cornerSize: CGSize(width: 14, height: 14))
        return path
    }
}
