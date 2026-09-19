import SwiftUI

/// Read-only drawing of engine output; all normalized coordinate conversions are preserved.
public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                decoration(in: size).allowsHitTesting(false)
                if viewModel.isShowingSunSlider, let point = viewModel.activeFocusSquarePoint {
                    Slider(value: Binding(get: { Double(viewModel.activeSunExposureBias) }, set: {
                        viewModel.adjustSunExposureBias(delta: Float($0) - viewModel.activeSunExposureBias)
                    }), in: -2...2)
                    .tint(CameraUI.accent).frame(width: min(150, size.width - 32), height: 44)
                    .padding(.horizontal, 8).background(.black.opacity(0.55), in: Capsule())
                    .position(x: min(max(90, point.x * size.width), size.width - 90),
                              y: min(max(110, point.y * size.height + 64), size.height - 30))
                    .accessibilityLabel("Điều chỉnh độ sáng")
                }
                if viewModel.isAIVideoDirectorActive {
                    AIVideoDirectorOverlayView(viewModel: viewModel, screenSize: size)
                }
            }.clipped()
        }
    }

    @ViewBuilder private func decoration(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        if viewModel.isFocusPeakingEnabled, let image = viewModel.focusPeakingCGImage {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
        }
        if viewModel.isAISessionActive {
            CompositionGridLines(rule: viewModel.activeCompositionRule, size: size).opacity(0.22)
        }
        if viewModel.showDetectionBoxes {
            ForEach(Array(viewModel.detectedFaceRects.enumerated()), id: \.offset) { _, rect in
                detectionBox(rect, size: size, color: .white.opacity(0.7))
            }
            if viewModel.isAISessionActive {
                ForEach(Array(viewModel.detectedSubjectRects.enumerated()), id: \.offset) { _, rect in
                    detectionBox(rect, size: size, color: CameraUI.accent)
                }
            }
        }
        if viewModel.showTargetCircle, let point = viewModel.currentTargetPoint {
            let target = convertBufferPointToScreen(point, in: size)
            if viewModel.showGuidanceRay {
                Path { path in path.move(to: center); path.addLine(to: target) }
                    .stroke(CameraUI.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
            }
            Image(systemName: "plus").font(.system(size: 24, weight: .ultraLight))
                .foregroundColor(viewModel.isPerfectAlignment ? .green : .white).position(center)
            ZStack {
                Circle().strokeBorder(viewModel.isPerfectAlignment ? .green : CameraUI.accent, lineWidth: 2)
                if viewModel.autoCaptureCountdown > 0 {
                    Text("\(viewModel.autoCaptureCountdown)").font(.title2.weight(.semibold))
                } else if viewModel.isPerfectAlignment { Image(systemName: "checkmark").foregroundColor(.green) }
            }.frame(width: 54, height: 54).position(target)
        }
        if viewModel.isHorizonLevelerEnabled && !viewModel.isAISessionActive && viewModel.captureMode == .photo {
            ZStack {
                Capsule().fill(.white.opacity(0.45)).frame(width: 76, height: 1)
                Capsule().fill(viewModel.isDeviceLevel ? CameraUI.accent : .white).frame(width: 48, height: 2)
                    .rotationEffect(.degrees(-viewModel.currentRollDegrees))
            }.position(center)
        }
        if let point = viewModel.activeFocusSquarePoint {
            RoundedRectangle(cornerRadius: 8).strokeBorder(CameraUI.accent, lineWidth: 1.5)
                .frame(width: 66, height: 66).position(x: point.x * size.width, y: point.y * size.height)
        }
        if viewModel.isRevealingZoomTarget {
            let rect = viewModel.zoomRevealRect
            RoundedRectangle(cornerRadius: 10).strokeBorder(CameraUI.accent.opacity(0.8), lineWidth: 1.5)
                .frame(width: rect.width * size.width, height: rect.height * size.height)
                .position(x: rect.midX * size.width, y: rect.midY * size.height)
        }
        if viewModel.showAlignmentSuccessFlash {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.green, lineWidth: 3)
        }
        if viewModel.activeFlashMode2 { Color.white.opacity(0.55) }
    }
    private func detectionBox(_ rect: CGRect, size: CGSize, color: Color) -> some View {
        let mapped = convertBufferRectToScreen(rect, in: size)
        return RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 1)
            .frame(width: mapped.width, height: mapped.height).position(x: mapped.midX, y: mapped.midY)
    }
    public static func convertBufferPointToScreen(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        // Tỉ lệ cảm biến camera iOS ở chế độ portrait: 3:4 (width / height = 0.75)
        let bufferAspect: CGFloat = 3.0 / 4.0
        let screenAspect = screenSize.width / max(1.0, screenSize.height)

        if abs(screenAspect - bufferAspect) < 0.03 {
            // Khung ngắm chuẩn 4:3 (WYSIWYG 100% khớp cảm biến camera Apple): Ánh xạ 1:1 chính xác tuyệt đối
            return CGPoint(x: point.x * screenSize.width, y: point.y * screenSize.height)
        }

        if screenAspect < bufferAspect {
            // Màn hình hẹp hơn khung camera -> Bị crop 2 bên trái/phải
            let displayedWidth = screenSize.height * bufferAspect
            let horizontalCropOffset = (displayedWidth - screenSize.width) / 2.0
            let screenX = point.x * displayedWidth - horizontalCropOffset
            let screenY = point.y * screenSize.height
            return CGPoint(x: screenX, y: screenY)
        } else {
            // Màn hình rộng hơn khung camera -> Bị crop trên/dưới
            let displayedHeight = screenSize.width / bufferAspect
            let verticalCropOffset = (displayedHeight - screenSize.height) / 2.0
            let screenX = point.x * screenSize.width
            let screenY = point.y * displayedHeight - verticalCropOffset
            return CGPoint(x: screenX, y: screenY)
        }
    }

    public static func convertBufferRectToScreen(_ rect: CGRect, in screenSize: CGSize) -> CGRect {
        let topLeft = convertBufferPointToScreen(rect.origin, in: screenSize)
        let bottomRight = convertBufferPointToScreen(CGPoint(x: rect.maxX, y: rect.maxY), in: screenSize)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: max(0, bottomRight.x - topLeft.x),
            height: max(0, bottomRight.y - topLeft.y)
        )
    }

    private func convertBufferPointToScreen(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        return Self.convertBufferPointToScreen(point, in: screenSize)
    }

    private func convertBufferRectToScreen(_ rect: CGRect, in screenSize: CGSize) -> CGRect {
        return Self.convertBufferRectToScreen(rect, in: screenSize)
    }

    private func convertScreenPointToBuffer(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        let bufferAspect: CGFloat = 3.0 / 4.0
        let screenAspect = screenSize.width / max(1.0, screenSize.height)

        if abs(screenAspect - bufferAspect) < 0.03 {
            return CGPoint(
                x: max(0.02, min(0.98, point.x / screenSize.width)),
                y: max(0.02, min(0.98, point.y / screenSize.height))
            )
        }

        if screenAspect < bufferAspect {
            let displayedWidth = screenSize.height * bufferAspect
            let horizontalCropOffset = (displayedWidth - screenSize.width) / 2.0
            let bufferX = (point.x + horizontalCropOffset) / displayedWidth
            let bufferY = point.y / screenSize.height
            return CGPoint(x: max(0.02, min(0.98, bufferX)), y: max(0.02, min(0.98, bufferY)))
        } else {
            let displayedHeight = screenSize.width / bufferAspect
            let verticalCropOffset = (displayedHeight - screenSize.height) / 2.0
            let bufferX = point.x / screenSize.width
            let bufferY = (point.y + verticalCropOffset) / displayedHeight
            return CGPoint(x: max(0.02, min(0.98, bufferX)), y: max(0.02, min(0.98, bufferY)))
        }
    }

}

struct CompositionGridLines: View {
    let rule: CompositionRule
    let size: CGSize

    var body: some View {
        Path { path in
            switch rule {
            case .ruleOfThirds, .dynamicAI:
                for frac in [CGFloat(1)/3, CGFloat(2)/3] {
                    path.move(to: CGPoint(x: size.width * frac, y: 0))
                    path.addLine(to: CGPoint(x: size.width * frac, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * frac))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                }
            case .goldenRatio:
                for frac in [CGFloat(0.381966), CGFloat(0.618034)] {
                    path.move(to: CGPoint(x: size.width * frac, y: 0))
                    path.addLine(to: CGPoint(x: size.width * frac, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * frac))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                }
            case .goldenSpiral:
                let phi2: CGFloat = 0.618034
                let phi1: CGFloat = 0.381966
                path.move(to: CGPoint(x: size.width * phi2, y: 0))
                path.addLine(to: CGPoint(x: size.width * phi2, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * phi1))
                path.addLine(to: CGPoint(x: size.width, y: size.height * phi1))
            case .centerSymmetry:
                path.move(to: CGPoint(x: size.width * 0.5, y: 0))
                path.addLine(to: CGPoint(x: size.width * 0.5, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * 0.5))
                path.addLine(to: CGPoint(x: size.width, y: size.height * 0.5))
            }
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 0.7, dash: [5, 4]))
    }
}

// MARK: - Center Dot (Chấm Trắng Cố Định Ở Chính Giữa Màn Hình - Chuẩn Ảnh 1)


public struct AIVideoDirectorOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let screenSize: CGSize
    public var body: some View {
        if let guidance = viewModel.activeVideoGuidance {
            let points = guidance.waypoints.map { ARFramingOverlayView.convertBufferPointToScreen($0.point, in: screenSize) }
            ZStack {
                Path { path in
                    if let first = points.first {
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                }.stroke(CameraUI.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 6]))
                    .allowsHitTesting(false)
                ForEach(Array(guidance.waypoints.enumerated()), id: \.offset) { index, waypoint in
                    Button { viewModel.selectWaypoint(index: index) } label: {
                        Text("\(index + 1)").font(.subheadline.bold()).frame(width: 44, height: 44)
                            .background(index == viewModel.currentActiveWaypointIndex ? CameraUI.accent : .black.opacity(0.55), in: Circle())
                            .foregroundColor(index == viewModel.currentActiveWaypointIndex ? .black : .white)
                    }.position(points[index]).accessibilityLabel(waypoint.label + ". " + waypoint.actionTip)
                }
                VStack {
                    Spacer()
                    if guidance.waypoints.indices.contains(viewModel.currentActiveWaypointIndex) {
                        Text(guidance.waypoints[viewModel.currentActiveWaypointIndex].actionTip)
                            .font(.caption).multilineTextAlignment(.center).padding(10)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(16).allowsHitTesting(false)
            }
        }
    }
}
