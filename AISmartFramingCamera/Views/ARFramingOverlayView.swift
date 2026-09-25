import SwiftUI

public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel

    @State private var radarPulse: CGFloat = 1.0
    @State private var radarOpacity: Double = 0.8
    @State private var dashOffset: CGFloat = 0
    @State private var pinchBaseZoom: CGFloat = 1.0
    @State private var isPinching: Bool = false

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let screenCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

            ZStack {
                // 0. Focus Peaking Neon Edges (Báo nét điện ảnh)
                if viewModel.isFocusPeakingEnabled, let peakingImage = viewModel.focusPeakingCGImage {
                    Image(decorative: peakingImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .allowsHitTesting(false)
                        .opacity(1.0)
                }

                // 1. Composition Grid Lines (hiện khi AI session active)
                if viewModel.isAISessionActive {
                    CompositionGridLines(rule: viewModel.activeCompositionRule, size: size)
                        .opacity(0.28)
                        .animation(.easeInOut(duration: 0.4), value: viewModel.isAISessionActive)
                }

                // 2. Detected Faces & Subject preview (Chỉ hiện khi bật trong Cài đặt > Khung ngắm)
                if viewModel.showDetectionBoxes {
                    ForEach(0..<viewModel.detectedFaceRects.count, id: \.self) { i in
                        let rect = viewModel.detectedFaceRects[i]
                        FaceDetectionBox(rect: convertBufferRectToScreen(rect, in: size))
                    }

                    if viewModel.isAISessionActive {
                        ForEach(0..<viewModel.detectedSubjectRects.count, id: \.self) { i in
                            let rect = viewModel.detectedSubjectRects[i]
                            SubjectHighlightBox(rect: convertBufferRectToScreen(rect, in: size))
                        }
                    }
                }

                if case .analyzing = viewModel.aiSessionState {
                    ForEach(0..<viewModel.localSuggestionRects.count, id: \.self) { index in
                        let sourceRect = viewModel.localSuggestionRects[index]
                        if !sourceRect.isEmpty, sourceRect.maxX > 0, sourceRect.maxY > 0,
                           sourceRect.minX < 1, sourceRect.minY < 1 {
                            let rect = convertBufferRectToScreen(sourceRect, in: size)
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                if let message = viewModel.localSelectionMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78)))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 145)
                    }
                    .allowsHitTesting(false)
                }

                // 4. VÒNG TRÒN TARGET VÀNG (Bám vật thể quang học + 60Hz Gyroscope)
                // Chuyển đổi toạ độ chính xác 100% từ Camera Buffer 4:3 sang màn hình tràn viền AspectFill
                if viewModel.showTargetCircle, let targetPoint = viewModel.currentTargetPoint {
                    let projectedScreen = convertBufferPointToScreen(targetPoint, in: size)
                    let targetScreen = TrackingGeometry.dock(projectedScreen, size: size)
                    let isDocked = hypot(projectedScreen.x - targetScreen.x,
                                         projectedScreen.y - targetScreen.y) > 0.5

                    // Đường chỉ dẫn nối từ Tâm Giữa (0.5, 0.5) -> Target Vàng
                    if viewModel.showGuidanceRay {
                        GuidanceRayLine(
                            from: screenCenter,
                            to: targetScreen,
                            dashOffset: dashOffset,
                            distance: viewModel.alignmentDistance
                        )
                    }

                    // Target Vàng
                    TargetCircleView(
                        isAligned: viewModel.isPerfectAlignment,
                        alignmentDistance: viewModel.alignmentDistance,
                        radarPulse: radarPulse,
                        radarOpacity: radarOpacity,
                        countdown: viewModel.autoCaptureCountdown,
                        trackingQuality: viewModel.trackingQuality
                    )
                    .position(targetScreen)
                    .transaction { $0.animation = nil }

                    if isDocked {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.yellow)
                            .rotationEffect(Angle(radians: Double(atan2(projectedScreen.y - screenCenter.y,
                                                                         projectedScreen.x - screenCenter.x)) + Double.pi / 2.0))
                            .position(targetScreen)
                            .accessibilityLabel("Quay camera theo hướng mũi tên để tìm lại mục tiêu")
                            .allowsHitTesting(false)
                    }
                }

                // Optical centre is always fixed in the photo viewfinder.
                if !viewModel.captureMode.isVideo {
                    CurrentCenterCrosshair(
                        isAligned: viewModel.isPerfectAlignment,
                        sessionState: viewModel.aiSessionState,
                        distance: viewModel.alignmentDistance
                    )
                    .position(screenCenter)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }

                // 6. Countdown Overlay khi 2 tâm đã trùng khớp
                if case .alignmentPerfect = viewModel.aiSessionState {
                    CountdownOverlayView(countdown: viewModel.autoCaptureCountdown)
                }

                // 7. Success Flash
                if viewModel.showAlignmentSuccessFlash {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green, lineWidth: 5)
                        .padding(4)
                        .transition(.opacity)
                }

                // 7b. AI Video Cinematography Director Overlay (Quỹ đạo, Các tâm đánh dấu & Chỉ dẫn cú máy)
                if viewModel.isAIVideoDirectorActive {
                    AIVideoDirectorOverlayView(viewModel: viewModel, screenSize: size)
                }

                // 8. Gemini analyzing toast
                if viewModel.isGeminiAnalyzing {
                    GeminiAnalyzingBadge()
                }

                // 8c. Save error toast — hiện khi lưu ảnh thất bại hoặc thiếu quyền Photos
                if let errorMsg = viewModel.saveErrorMessage {
                    VStack {
                        Spacer()
                        Text(errorMsg)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.85)))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 140)
                    }
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation { viewModel.saveErrorMessage = nil }
                        }
                    }
                }

                // 8b. Khóa AE/AF Banner (Chuẩn Camera iPhone)
                if viewModel.isAEAFLocked {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Đã khóa sáng và nét")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(Capsule().fill(Color.yellow))
                        .padding(.top, 46)
                        .transition(.move(edge: .top).combined(with: .opacity))

                        Spacer()
                    }
                }

                // 8c. Thước Đo Cân Bằng Chân Trời (Virtual Horizon Leveler)
                if viewModel.isHorizonLevelerEnabled && !viewModel.isAISessionActive && viewModel.captureMode == .photo {
                    HorizonLevelerView(rollDegrees: viewModel.currentRollDegrees, isLevel: viewModel.isDeviceLevel)
                        .position(screenCenter)
                }

                // 9. Smart Autofocus Yellow Square Indicator with Sun Exposure Slider (Apple Camera Style)
                if let focusPoint = viewModel.activeFocusSquarePoint {
                    FocusSquareWithSunSlider(
                        isLocked: viewModel.isAEAFLocked,
                        showSun: viewModel.isShowingSunSlider,
                        exposureBias: viewModel.activeSunExposureBias,
                        onAdjustBias: { delta in
                            viewModel.adjustSunExposureBias(delta: delta)
                        }
                    )
                    .position(x: focusPoint.x * size.width, y: focusPoint.y * size.height)
                    .transition(.scale.combined(with: .opacity))
                }

                // 10. Capture Flash
                if viewModel.activeFlashMode2 {
                    Color.white.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // 11. AI Zoom Reveal Overlay (Khung bố cục điện ảnh mượt mà, không làm tối màn hình)
                ZoomRevealOverlay(
                    rect: viewModel.zoomRevealRect,
                    isVisible: viewModel.isRevealingZoomTarget,
                    displayZoom: viewModel.displayZoom
                )
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let norm = convertScreenPointToBuffer(location, in: size)
                if viewModel.isAEAFLocked {
                    viewModel.unlockAEAF()
                } else if case .targetPlaced = viewModel.aiSessionState {
                    viewModel.pinTargetAndStartMotion(at: norm)
                } else if case .analyzing = viewModel.aiSessionState,
                          viewModel.localSelectionMessage != nil {
                    viewModel.chooseLocalSuggestion(at: norm)
                } else {
                    viewModel.userDidTapToFocus(at: norm)
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        switch value {
                        case .second(true, let drag):
                            if let loc = drag?.location {
                                let norm = convertScreenPointToBuffer(loc, in: size)
                                viewModel.userDidLongPressToLockAEAF(at: norm)
                            }
                        default:
                            break
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if !isPinching {
                            isPinching = true
                            pinchBaseZoom = viewModel.displayZoom
                            viewModel.cancelAIZoomForGesture()
                            viewModel.isPinchingZoom = true
                        }
                        let minZ = viewModel.cameraService.convertDeviceZoomToDisplayZoom(viewModel.cameraService.minZoom)
                        let maxZ = viewModel.cameraService.convertDeviceZoomToDisplayZoom(viewModel.cameraService.maxZoom)
                        let targetZoom = max(minZ, min(pinchBaseZoom * scale, maxZ))
                        viewModel.setZoomContinuous(targetZoom)
                    }
                    .onEnded { scale in
                        let minZ = viewModel.cameraService.convertDeviceZoomToDisplayZoom(viewModel.cameraService.minZoom)
                        let maxZ = viewModel.cameraService.convertDeviceZoomToDisplayZoom(viewModel.cameraService.maxZoom)
                        let targetZoom = max(minZ, min(pinchBaseZoom * scale, maxZ))
                        viewModel.finishZoomGesture(targetZoom)
                        isPinching = false
                        viewModel.isPinchingZoom = false
                        pinchBaseZoom = targetZoom
                    }
            )
            .clipped()
            .animation(.easeOut(duration: 0.25), value: viewModel.showTargetCircle)
            .onChange(of: size) { _, newSize in viewModel.viewfinderSize = newSize }
            .onAppear {
                viewModel.viewfinderSize = size
                SpatialTrackingEngine.shared.prepare()
                startAnimations()
            }
            // The overlay can be temporarily removed by SwiftUI or a sheet.
            // It does not own the tracking session's lifetime.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                viewModel.suspendSpatialTracking()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                SpatialTrackingEngine.shared.prepare()
            }
        }
    }

    // MARK: - AspectFill Coordinate Conversion Helpers
    // Chuyển đổi toạ độ chuẩn hóa từ Camera Buffer (4:3) sang màn hình Preview
    public static func convertBufferPointToScreen(_ point: CGPoint, in screenSize: CGSize) -> CGPoint {
        TrackingGeometry.screenPoint(point, size: screenSize,
            aspect: SpatialTrackingEngine.shared.currentBufferAspect)
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
        let p = TrackingGeometry.bufferPoint(point, size: screenSize,
            aspect: SpatialTrackingEngine.shared.currentBufferAspect)
        // Only user input is clipped to the image domain, never estimator state.
        return CGPoint(x: max(0, min(1, p.x)), y: max(0, min(1, p.y)))
    }

    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            radarPulse = 1.40; radarOpacity = 0.15
        }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            dashOffset = -20
        }
    }
}

// MARK: - Composition Grid

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

struct CurrentCenterCrosshair: View {
    let isAligned: Bool
    let sessionState: AISessionState
    let distance: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .shadow(color: .black.opacity(0.7), radius: 1)
            .allowsHitTesting(false)
    }
}

// MARK: - Target Vòng Tròn Bé Với Tâm Dấu Cộng (+) - Chuẩn Ảnh 2

struct PlusCrosshairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Thanh ngang dấu cộng
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        // Thanh dọc dấu cộng
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct TargetCircleView: View {
    let isAligned: Bool
    let alignmentDistance: CGFloat
    let radarPulse: CGFloat
    let radarOpacity: Double
    let countdown: Int
    let trackingQuality: TrackingQuality

    private var ringColor: Color {
        if isAligned { return .green }
        switch trackingQuality {
        case .locked, .predicting, .reacquiring: return Color.yellow
        case .lost: return Color.red
        }
    }

    var body: some View {
        ZStack {
            if !isAligned {
                Circle()
                    .stroke(ringColor.opacity(radarOpacity * 0.6), lineWidth: 1.2)
                    .frame(width: 28 * radarPulse, height: 28 * radarPulse)
            }
            Circle()
                .stroke(ringColor, lineWidth: isAligned ? 2.2 : 1.6)
                .frame(width: 28, height: 28)
                .shadow(color: Color.black.opacity(0.5), radius: 2)
                .shadow(color: ringColor.opacity(isAligned ? 0.8 : 0.35), radius: isAligned ? 7 : 3)
            PlusCrosshairShape()
                .stroke(ringColor, lineWidth: isAligned ? 2.0 : 1.5)
                .frame(width: 9, height: 9)
                .shadow(color: Color.black.opacity(0.5), radius: 1)
            if isAligned {
                Circle()
                    .stroke(Color.green.opacity(0.4), lineWidth: 3.5)
                    .frame(width: 36, height: 36)
            }
        }
        .frame(width: 36, height: 36)
        .allowsHitTesting(false)
        // Status is outside layout. A label appearing must never shift the ring
        // above its projected point by changing the centre of a VStack.
        .overlay(alignment: .top) {
            if trackingQuality == .reacquiring || trackingQuality == .lost {
                Text("Đang khôi phục tín hiệu…")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .fixedSize()
                    .offset(y: 42)
            }
        }
    }
}

// MARK: - Guidance Ray

struct GuidanceRayLine: View {
    let from: CGPoint
    let to: CGPoint
    let dashOffset: CGFloat
    let distance: CGFloat

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            Color.yellow.opacity(0.65 * Double(min(1.0, distance / 0.1 + 0.4))),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [5, 5], dashPhase: dashOffset)
        )
    }
}

// MARK: - Countdown Overlay

struct CountdownOverlayView: View {
    let countdown: Int
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "camera.fill").font(.system(size: 15, weight: .bold))
                Text(countdown > 0 ? "Chụp trong \(countdown)..." : "Đang chụp...")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(Color.green))
            .shadow(color: Color.green.opacity(0.4), radius: 10)
            Spacer().frame(height: 200)
        }
    }
}

// MARK: - Gemini Analyzing Badge

struct GeminiAnalyzingBadge: View {
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                    .scaleEffect(0.8)
                Text("Đang phân tích…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.65))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            )
            Spacer()
        }
        .padding(.top, 50)
        .transition(.opacity)
    }
}

// MARK: - Boxes

struct FaceDetectionBox: View {
    let rect: CGRect
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.cyan.opacity(0.7), lineWidth: 1.2)
            .frame(width: max(20, rect.width), height: max(20, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}

struct SubjectHighlightBox: View {
    let rect: CGRect
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.yellow.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: max(20, rect.width), height: max(20, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Smart Focus Square Indicator with Sun EV Slider (Apple Camera Style)

struct FocusSquareWithSunSlider: View {
    let isLocked: Bool
    let showSun: Bool
    let exposureBias: Float
    let onAdjustBias: (Float) -> Void

    @State private var scale: CGFloat = 1.3

    var body: some View {
        HStack(spacing: 8) {
            // Focus Box
            ZStack {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: isLocked ? 2.0 : 1.5)
                    .frame(width: 65, height: 65)

                // 4 Corner tick marks
                VStack {
                    HStack {
                        Rectangle().fill(Color.yellow).frame(width: 6, height: 1.5)
                        Spacer()
                        Rectangle().fill(Color.yellow).frame(width: 6, height: 1.5)
                    }
                    Spacer()
                    HStack {
                        Rectangle().fill(Color.yellow).frame(width: 6, height: 1.5)
                        Spacer()
                        Rectangle().fill(Color.yellow).frame(width: 6, height: 1.5)
                    }
                }
                .frame(width: 65, height: 65)
            }
            .scaleEffect(scale)

            // Vertical Sun Exposure Slider (Apple Camera Standard)
            if showSun || isLocked {
                VStack(spacing: 4) {
                    ZStack(alignment: .center) {
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 1.5, height: 65)

                        let sunOffset = CGFloat(-exposureBias / 2.0) * 26.0
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)
                            .offset(y: sunOffset)
                    }
                    .frame(width: 32, height: 75)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { val in
                                let delta = Float(-val.translation.height / 75.0) * 0.25
                                onAdjustBias(delta)
                            }
                    )
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = 1.0
            }
        }
    }
}

// MARK: - Virtual Horizon Leveler (Thước Cân Bằng Chân Trời)
struct HorizonLevelerView: View {
    let rollDegrees: Double
    let isLevel: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(isLevel ? Color.yellow : Color.white.opacity(0.65))
                .frame(width: 38, height: isLevel ? 2.0 : 1.2)

            Circle()
                .stroke(isLevel ? Color.yellow : Color.white.opacity(0.65), lineWidth: isLevel ? 2.0 : 1.2)
                .frame(width: 8, height: 8)

            Rectangle()
                .fill(isLevel ? Color.yellow : Color.white.opacity(0.65))
                .frame(width: 38, height: isLevel ? 2.0 : 1.2)
        }
        .rotationEffect(.degrees(-rollDegrees))
        .opacity(abs(rollDegrees) > 25.0 ? 0.0 : (isLevel ? 1.0 : max(0.25, 1.0 - abs(rollDegrees) / 20.0)))
        .animation(.easeInOut(duration: 0.15), value: isLevel)
    }
}

// MARK: - AI Zoom Reveal Overlay (Bố Cục Điện Ảnh Mượt Mà, Không Làm Tối Màn Hình)
struct ZoomRevealOverlay: View {
    let rect: CGRect
    let isVisible: Bool
    let displayZoom: CGFloat

    var body: some View {
        GeometryReader { geo in
            let pixelRect = CGRect(
                x: rect.origin.x * geo.size.width,
                y: rect.origin.y * geo.size.height,
                width: rect.width * geo.size.width,
                height: rect.height * geo.size.height
            )

            if isVisible {
                ZStack {
                    // 1. Lớp làm mờ nhẹ điện ảnh vùng ngoài khung ngắm (Subtle Cinematic Focus Blur)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.42)
                        .mask(
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: geo.size))
                                path.addRoundedRect(in: pixelRect, cornerSize: CGSize(width: 16, height: 16))
                            }
                            .fill(style: FillStyle(eoFill: true))
                        )
                        .ignoresSafeArea()

                    // 2. Viền bóng mờ nhẹ chuyển tiếp mềm mại xung quanh viền cắt (Soft feathered edge)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.black.opacity(0.18), lineWidth: 4)
                        .blur(radius: 3)
                        .frame(width: max(20, pixelRect.width), height: max(20, pixelRect.height))
                        .position(x: pixelRect.midX, y: pixelRect.midY)

                    // 3. Viền khung ngắm vàng mỏng nhẹ 1.8px (giữ màn hình sáng tự nhiên)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [Color.yellow, Color.yellow.opacity(0.7), Color.yellow],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.8
                        )
                        .frame(width: max(20, pixelRect.width), height: max(20, pixelRect.height))
                        .position(x: pixelRect.midX, y: pixelRect.midY)
                        .shadow(color: Color.yellow.opacity(0.35), radius: 8, x: 0, y: 0)

                    // 4. Bốn góc ngắm bố cục điện ảnh (Cinematic Corner Ticks)
                    CinematicCornerTicks(rect: pixelRect)

                    // Huy hiệu AI ZOOM ở mép trên khung
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("AI ZOOM \(String(format: "%.1f", displayZoom))x")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.yellow))
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
                    .position(x: pixelRect.midX, y: max(24, pixelRect.minY - 12))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .animation(.easeInOut(duration: 0.45), value: isVisible)
            }
        }
        .allowsHitTesting(false)
    }
}

// 4 Góc ngắm bố cục điện ảnh (Corner Ticks)
struct CinematicCornerTicks: View {
    let rect: CGRect
    private let tickLength: CGFloat = 16
    private let tickWidth: CGFloat = 2.5

    var body: some View {
        Path { path in
            let r: CGFloat = 8
            // Góc trên trái
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + tickLength))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + tickLength, y: rect.minY))

            // Góc trên phải
            path.move(to: CGPoint(x: rect.maxX - tickLength, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tickLength))

            // Góc dưới trái
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY - tickLength))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: rect.minX + tickLength, y: rect.maxY))

            // Góc dưới phải
            path.move(to: CGPoint(x: rect.maxX - tickLength, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tickLength))
        }
        .stroke(Color.yellow, lineWidth: tickWidth)
        .shadow(color: Color.yellow.opacity(0.6), radius: 4)
    }
}

// MARK: - AI Video Cinematography Director Overlay View

public struct AIVideoDirectorOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    let screenSize: CGSize

    @State private var dashPhase: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.85

    public var body: some View {
        ZStack {
            if viewModel.isAIVideoDirectorAnalyzing {
                // 1. Loading Badge khi AI Cloud đang phân tích
                VStack {
                    HStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                            .scaleEffect(0.9)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles.tv")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.yellow)
                                Text("ĐẠO DIỄN AI CLOUD")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundColor(.yellow)
                            }
                            Text("Đang phân tích bối cảnh & lập hướng quay...")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.black.opacity(0.82))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.4), lineWidth: 1.2))
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 8)
                    .padding(.top, 56)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let guidance = viewModel.activeVideoGuidance {
                // 2. Trajectory motion path nối các tâm đánh dấu
                let screenPoints = guidance.waypoints.map { wp in
                    ARFramingOverlayView.convertBufferPointToScreen(wp.point, in: screenSize)
                }

                TrajectoryPathView(
                    points: screenPoints,
                    currentIndex: viewModel.currentActiveWaypointIndex,
                    isCompleted: viewModel.hasCompletedAllWaypoints,
                    dashPhase: dashPhase
                )

                // 3. Các tâm đánh dấu (Waypoints Reticles)
                ForEach(0..<guidance.waypoints.count, id: \.self) { idx in
                    let wp = guidance.waypoints[idx]
                    let screenPt = screenPoints[idx]
                    let isCurrent = idx == viewModel.currentActiveWaypointIndex && !viewModel.hasCompletedAllWaypoints
                    let isPast = idx < viewModel.currentActiveWaypointIndex || viewModel.hasCompletedAllWaypoints

                    CinematicWaypointMarker(
                        waypoint: wp,
                        isCurrent: isCurrent,
                        isPast: isPast,
                        pulseScale: pulseScale,
                        pulseOpacity: pulseOpacity,
                        recordingDuration: wp.recommendedDuration,
                        elapsedDuration: viewModel.waypointElapsedSeconds,
                        isRecording: viewModel.isRecordingVideo,
                        onTap: {
                            viewModel.selectWaypoint(index: idx)
                        }
                    )
                    .position(screenPt)
                }

                // 4. Director Guidance HUD Card ở trên cùng
                VStack {
                    DirectorHUDCard(
                        guidance: guidance,
                        currentIndex: viewModel.currentActiveWaypointIndex,
                        totalCount: guidance.waypoints.count,
                        isCompleted: viewModel.hasCompletedAllWaypoints,
                        onDismiss: {
                            viewModel.dismissAIVideoDirector()
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 52)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                dashPhase = -32
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.35
                pulseOpacity = 0.2
            }
        }
    }
}

// MARK: - Director HUD Card

struct DirectorHUDCard: View {
    let guidance: AIVideoDirectorGuidance
    let currentIndex: Int
    let totalCount: Int
    let isCompleted: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Title & Model badge & Close Button
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.yellow)

                    Text("ĐẠO DIỄN QUAY PHIM AI")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundColor(.yellow)

                    let modelName = guidance.modelUsed.contains("google/") ? guidance.modelUsed.replacingOccurrences(of: "google/", with: "") : guidance.modelUsed
                    Text(modelName)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                }
            }

            // Shot Style & Pacing / Waypoint Counter Pills
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(guidance.shotStyleTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Waypoint Pill
                HStack(spacing: 4) {
                    Circle()
                        .fill(isCompleted ? Color.green : Color.yellow)
                        .frame(width: 6, height: 6)
                    Text(isCompleted ? "HOÀN TẤT \u{2713}" : "Tâm \(currentIndex + 1)/\(totalCount)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(isCompleted ? .green : .yellow)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }

            // Movement Direction Instruction
            Text(guidance.movementDirectionDescription)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Director Tip
            if !guidance.directorTip.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Text("\u{1f4a1}")
                        .font(.system(size: 10))
                    Text(guidance.directorTip)
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundColor(.yellow.opacity(0.95))
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(
                            LinearGradient(
                                colors: [Color.yellow.opacity(0.7), Color.yellow.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.6), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Trajectory Path View

struct TrajectoryPathView: View {
    let points: [CGPoint]
    let currentIndex: Int
    let isCompleted: Bool
    let dashPhase: CGFloat

    var body: some View {
        guard points.count >= 2 else { return AnyView(EmptyView()) }

        return AnyView(
            ZStack {
                // Đường viền phát sáng nền
                Path { path in
                    path.move(to: points[0])
                    for i in 1..<points.count {
                        path.addLine(to: points[i])
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.4), Color.yellow.opacity(0.6), Color.cyan.opacity(0.4)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                )
                .blur(radius: 2)

                // Đường nét đứt chuyển động theo chiều di chuyển
                Path { path in
                    path.move(to: points[0])
                    for i in 1..<points.count {
                        path.addLine(to: points[i])
                    }
                }
                .stroke(
                    Color.yellow,
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round, dash: [8, 6], dashPhase: dashPhase)
                )

                // Các mũi tên chỉ hướng ở giữa các đoạn thẳng
                ForEach(0..<(points.count - 1), id: \.self) { i in
                    let p1 = points[i]
                    let p2 = points[i + 1]
                    let mid = CGPoint(x: (p1.x + p2.x) * 0.5, y: (p1.y + p2.y) * 0.5)
                    let angle = atan2(p2.y - p1.y, p2.x - p1.x)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(.yellow)
                        .shadow(color: Color.black.opacity(0.8), radius: 3)
                        .rotationEffect(.radians(Double(angle)))
                        .position(mid)
                }
            }
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Cinematic Waypoint Marker

struct CinematicWaypointMarker: View {
    let waypoint: CinematicWaypoint
    let isCurrent: Bool
    let isPast: Bool
    let pulseScale: CGFloat
    let pulseOpacity: Double
    let recordingDuration: Double
    let elapsedDuration: Double
    let isRecording: Bool
    let onTap: () -> Void

    private var markerColor: Color {
        if isPast { return .green }
        if isCurrent { return .yellow }
        return .white.opacity(0.7)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    // Sóng radar cho tâm đang được chọn
                    if isCurrent {
                        Circle()
                            .stroke(Color.yellow, lineWidth: 1.8)
                            .frame(width: 44, height: 44)
                            .scaleEffect(pulseScale)
                            .opacity(pulseOpacity)
                    }

                    // Vòng tròn ngoài
                    Circle()
                        .stroke(markerColor, lineWidth: isCurrent ? 2.5 : 1.6)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .shadow(color: markerColor.opacity(isCurrent ? 0.6 : 0.3), radius: isCurrent ? 6 : 2)

                    // Vòng đếm tiến độ quay nếu đang ghi hình tại tâm này
                    if isCurrent && isRecording && recordingDuration > 0 {
                        let prog = min(1.0, max(0.0, elapsedDuration / recordingDuration))
                        Circle()
                            .trim(from: 0, to: CGFloat(prog))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .frame(width: 36, height: 36)
                            .rotationEffect(.degrees(-90))
                    }

                    // Biểu tượng tâm
                    if isPast {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.green)
                    } else {
                        Text("\(waypoint.id)")
                            .font(.system(size: 14, weight: isCurrent ? .heavy : .bold, design: .rounded))
                            .foregroundColor(markerColor)
                    }
                }

                // Nhãn và hướng dẫn
                VStack(spacing: 2) {
                    Text(waypoint.label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(isCurrent ? .yellow : (isPast ? .green : .white))

                    if isCurrent && !waypoint.actionTip.isEmpty {
                        Text(waypoint.actionTip)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.75))
                        .overlay(Capsule().stroke(markerColor.opacity(0.4), lineWidth: 0.8))
                )
                .shadow(color: Color.black.opacity(0.6), radius: 4)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isCurrent ? 1.08 : 0.95)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isCurrent)
    }
}
