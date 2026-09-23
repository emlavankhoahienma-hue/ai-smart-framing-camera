//
//  WindowedZoomOverlayView.swift
//  AISmartFramingCamera
//
//  Khung ngắm thu nhỏ quang học Rangefinder (Windowed Zoom)
//  Gợi ý tiêu cự và điều khiển zoom của camera; crop ảnh chỉ theo tỷ lệ khung.
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
            // 1. Lớp làm tối ngoài viền (Cutout Dimming Mask 38%) với góc bo nhẹ 14pt
            WindowedMaskCutout(windowRect: windowRect)
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 2. Khung ngắm chính với viền bo tròn nhẹ 14pt & số mm trên đỉnh
            ZStack(alignment: .top) {
                // Viền chữ nhật bo tròn nhẹ phù hợp (14pt)
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: windowRect.width, height: windowRect.height)

                // Chỉ để lại đúng số mm trên khung, không có viền tròn bao quanh
                Text("\(Int(round(viewModel.windowedZoomFocalLength)))mm · \(viewModel.isOpticalTelephotoActive ? "TELE" : "WIDE")")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.isAIWindowedFocalRecommended ? amberGold : .white)
                    .shadow(color: Color.black.opacity(0.9), radius: 3, x: 0, y: 1)
                    .offset(y: -22)
            }
            .position(x: windowRect.midX, y: windowRect.midY)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let normX = max(0.05, min(0.95, location.x / containerSize.width))
            let normY = max(0.05, min(0.95, location.y / containerSize.height))
            let normPoint = CGPoint(x: normX, y: normY)
            if viewModel.isAEAFLocked {
                viewModel.unlockAEAF()
            } else {
                viewModel.userDidTapToFocus(at: normPoint)
            }
        }
        .gesture(
            MagnificationGesture()
                .onChanged { value in
                    if !isPinching {
                        isPinching = true
                        gestureInitialFocalLength = viewModel.windowedZoomFocalLength
                    }
                    // Cử chỉ tự nhiên:
                    // Chụm 2 tay thu nhỏ lại (value < 1.0) -> Khung ngắm thu bé lại (zoom in / mm tăng lên)
                    // Mở 2 tay to ra (value > 1.0) -> Khung ngắm nở to ra (zoom out / mm giảm xuống)
                    let safeScale = Double(max(0.05, value))
                    let newFocal = gestureInitialFocalLength / safeScale
                    viewModel.windowedZoomFocalLength = max(24.0, min(135.0, newFocal))
                    viewModel.isAIWindowedFocalRecommended = false
                }
                .onEnded { _ in
                    isPinching = false
                    viewModel.finishWindowedFocalGesture()
                    viewModel.haptics.triggerSelectionChange()
                }
        )
    }
}

// MARK: - Windowed Mask Cutout Shape (Even-Odd Fill)
private struct WindowedMaskCutout: Shape {
    let windowRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Toàn bộ màn hình
        path.addRect(rect)
        // Khoét rỗng vùng khung ngắm với góc bo tròn 14pt khớp viền
        path.addRoundedRect(in: windowRect, cornerSize: CGSize(width: 14, height: 14))
        return path
    }
}
