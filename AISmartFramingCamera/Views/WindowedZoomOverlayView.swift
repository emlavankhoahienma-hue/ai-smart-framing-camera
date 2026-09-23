//
//  WindowedZoomOverlayView.swift
//  AISmartFramingCamera
//
//  Khung ngắm thu nhỏ quang học Rangefinder (Windowed Zoom)
//  Tự động phân tích bối cảnh AI, co giãn tiêu cự mm và cắt ảnh cảm biến 48MP siêu nét.
//

import SwiftUI

public struct WindowedZoomOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    @State private var gestureInitialFocalLength: Double = 35.0
    @State private var isPinching: Bool = false

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    // MARK: - Window Dimensions Calculation
    private var windowRect: CGRect {
        let fractions = viewModel.windowedZoomAspectRatio.windowFractions(focalLength: viewModel.windowedZoomFocalLength)
        let w = containerSize.width * fractions.widthFraction
        let h = containerSize.height * fractions.heightFraction
        let x = (containerSize.width - w) / 2.0
        let y = (containerSize.height - h) / 2.0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    public var body: some View {
        ZStack {
            // 1. Lớp làm tối ngoài viền (Cutout Dimming Mask 38%)
            WindowedMaskCutout(windowRect: windowRect)
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 2. Khung ngắm chính (Border + 4 Góc Reticle + Badge)
            ZStack(alignment: .top) {
                // Viền chữ nhật bo tròn nhẹ
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.80), lineWidth: 1.2)
                    .frame(width: windowRect.width, height: windowRect.height)

                // 4 Góc ngắm Reticle chuyên nghiệp
                ReticleCornersView(size: CGSize(width: windowRect.width, height: windowRect.height))

                // Huy hiệu tiêu cự trên đỉnh khung (Top Focal Badge)
                topFocalBadge
                    .offset(y: -34)
            }
            .position(x: windowRect.midX, y: windowRect.midY)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        isPinching = true
                        gestureInitialFocalLength = viewModel.windowedZoomFocalLength
                    }
                    // Pinch out (value > 1.0) -> zoom in (tăng mm)
                    // Pinch in (value < 1.0) -> zoom out (giảm mm)
                    let newFocal = gestureInitialFocalLength * Double(value)
                    viewModel.windowedZoomFocalLength = max(24.0, min(135.0, newFocal))
                    viewModel.isAIWindowedFocalRecommended = false
                }
                .onEnded { _ in
                    isPinching = false
                    viewModel.haptics.triggerSelectionChange()
                }
        )
    }

    // MARK: - Top Focal Badge
    private var topFocalBadge: some View {
        HStack(spacing: 6) {
            if viewModel.isAIWindowedFocalRecommended {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(amberGold)
            }

            Text(String(format: "%.0f mm", viewModel.windowedZoomFocalLength))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 12)

            // Nút chuyển đổi tỉ lệ 3:4 <-> 1:1
            Button(action: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                    viewModel.windowedZoomAspectRatio = (viewModel.windowedZoomAspectRatio == .ratio3_4) ? .ratio1_1 : .ratio3_4
                }
                viewModel.haptics.triggerSelectionChange()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: viewModel.windowedZoomAspectRatio == .ratio3_4 ? "rectangle.portrait" : "square")
                        .font(.system(size: 10, weight: .semibold))
                    Text(viewModel.windowedZoomAspectRatio.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(amberGold)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.78))
                .overlay(
                    Capsule()
                        .stroke(viewModel.isAIWindowedFocalRecommended ? amberGold.opacity(0.8) : Color.white.opacity(0.18), lineWidth: 1.0)
                )
        )
        .shadow(color: Color.black.opacity(0.5), radius: 4, y: 2)
    }
}

// MARK: - Focal Length Quick Pills Selector
public struct WindowedFocalLengthSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(WindowedFocalLengthPreset.standardPresets) { preset in
                let isSelected = abs(viewModel.windowedZoomFocalLength - preset.focalLength) < 3.0
                Button(action: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                        viewModel.windowedZoomFocalLength = preset.focalLength
                        viewModel.isAIWindowedFocalRecommended = false
                    }
                    viewModel.haptics.triggerSelectionChange()
                }) {
                    Text(preset.label)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .monospaced))
                        .foregroundColor(isSelected ? .black : Color.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? amberGold : Color.black.opacity(0.65))
                                .overlay(
                                    Capsule()
                                        .stroke(isSelected ? amberGold : Color.white.opacity(0.15), lineWidth: 0.8)
                                )
                        )
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11).opacity(0.85))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - 4 Reticle Corners
private struct ReticleCornersView: View {
    let size: CGSize
    private let bracketLen: CGFloat = 16.0
    private let bracketWidth: CGFloat = 2.4

    var body: some View {
        ZStack {
            // Góc trên - trái
            CornerBracketShape(corner: .topLeft, length: bracketLen)
                .stroke(Color.white, lineWidth: bracketWidth)
                .frame(width: bracketLen, height: bracketLen)
                .position(x: bracketLen / 2, y: bracketLen / 2)

            // Góc trên - phải
            CornerBracketShape(corner: .topRight, length: bracketLen)
                .stroke(Color.white, lineWidth: bracketWidth)
                .frame(width: bracketLen, height: bracketLen)
                .position(x: size.width - bracketLen / 2, y: bracketLen / 2)

            // Góc dưới - trái
            CornerBracketShape(corner: .bottomLeft, length: bracketLen)
                .stroke(Color.white, lineWidth: bracketWidth)
                .frame(width: bracketLen, height: bracketLen)
                .position(x: bracketLen / 2, y: size.height - bracketLen / 2)

            // Góc dưới - phải
            CornerBracketShape(corner: .bottomRight, length: bracketLen)
                .stroke(Color.white, lineWidth: bracketWidth)
                .frame(width: bracketLen, height: bracketLen)
                .position(x: size.width - bracketLen / 2, y: size.height - bracketLen / 2)
        }
        .frame(width: size.width, height: size.height)
    }
}

private enum CornerType {
    case topLeft, topRight, bottomLeft, bottomRight
}

private struct CornerBracketShape: Shape {
    let corner: CornerType
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .topRight:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomLeft:
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomRight:
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return p
    }
}

// MARK: - Windowed Mask Cutout Shape (Even-Odd Fill)
private struct WindowedMaskCutout: Shape {
    let windowRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Toàn bộ màn hình
        path.addRect(rect)
        // Khoét rỗng vùng khung ngắm
        path.addRoundedRect(in: windowRect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}
