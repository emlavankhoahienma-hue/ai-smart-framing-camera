//
//  WindowedZoomOverlayView.swift
//  AISmartFramingCamera
//
//  Khung ngam thu nho quang hoc Rangefinder (Windowed Zoom)
//  Tu dong phan tich boi canh AI, co gian tieu cu mm va cat anh/video chuan quang hoc.
//

import SwiftUI

public struct WindowedZoomOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    @State private var gestureInitialFocalLength: Double = 35.0
    @State private var isPinching: Bool = false
    @Namespace private var focalPillNamespace

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)
    private let presets = WindowedFocalLengthPreset.standardPresets

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    private var isFull: Bool {
        viewModel.windowedZoomFocalLength <= 24.5
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
            // 1. Lop lam toi ngoai vien (Cutout Dimming Mask 38%) - An hoan toan khi chon Full (khong crop)
            if !isFull {
                WindowedMaskCutout(windowRect: windowRect)
                    .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 2. Khung ngam chinh voi vien bo tron nhe 14pt & so mm tren dinh
            if !isFull {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: windowRect.width, height: windowRect.height)

                    Text("\(Int(round(viewModel.windowedZoomFocalLength)))mm")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(viewModel.isAIWindowedFocalRecommended ? amberGold : .white)
                        .shadow(color: Color.black.opacity(0.9), radius: 3, x: 0, y: 1)
                        .offset(y: -22)
                }
                .position(x: windowRect.midX, y: windowRect.midY)
                .transition(.opacity)
            }

            // 3. Thanh chon tieu cu Prime nhanh (Full, 28mm, 35mm, 50mm, 85mm)
            VStack {
                Spacer()
                focalPresetBar
                    .padding(.bottom, 14)
            }
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
                    let safeScale = Double(max(0.05, value))
                    let newFocal = gestureInitialFocalLength / safeScale
                    let clamped = max(24.0, min(135.0, newFocal))
                    viewModel.windowedZoomFocalLength = clamped <= 24.5 ? 24.0 : clamped
                    viewModel.isAIWindowedFocalRecommended = false
                }
                .onEnded { _ in
                    isPinching = false
                    viewModel.haptics.triggerSelectionChange()
                }
        )
    }

    private func isPresetSelected(_ preset: WindowedFocalLengthPreset) -> Bool {
        if preset.focalLength <= 24.0 {
            return isFull
        }
        return abs(viewModel.windowedZoomFocalLength - preset.focalLength) < 2.0
    }

    private func selectPreset(_ preset: WindowedFocalLengthPreset) {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
            viewModel.windowedZoomFocalLength = preset.focalLength
            viewModel.isAIWindowedFocalRecommended = false
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

// MARK: - Focal Preset Button Subview (Fast Type-Checking)
private struct FocalPresetButton: View {
    let preset: WindowedFocalLengthPreset
    let isSelected: Bool
    let action: () -> Void
    var focalPillNamespace: Namespace.ID

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Capsule()
                        .stroke(amberGold, lineWidth: 1.5)
                        .background(Capsule().fill(Color.black.opacity(0.40)))
                        .matchedGeometryEffect(id: "active_windowed_focal_ring", in: focalPillNamespace)
                }

                Text(preset.label)
                    .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .frame(minWidth: 40, height: 32)
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
