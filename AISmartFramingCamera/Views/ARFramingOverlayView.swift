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
            let topChromeInset = viewModel.isRecordingVideo ?
                max(82, min(104, size.height * 0.22)) :
                max(52, min(74, size.height * 0.14))
            let bottomChromeInset = max(70, min(96, size.height * 0.18))

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

                // 2. Detected Faces & Multi-Object Preview (Chỉ hiện khi bật trong Cài đặt > Khung ngắm và ở chế độ Ảnh)
                if viewModel.showDetectionBoxes && !viewModel.captureMode.isVideo && viewModel.currentTargetPoint == nil {
                    ForEach(viewModel.heroDetectedEntities) { entity in
                        let layerRect = viewModel.convertMetadataRectToLayerRect(entity.rect, in: size)
                        if layerRect.width >= 12, layerRect.height >= 12 {
                            LiveEntityBoxView(entity: entity, layerRect: layerRect) {
                                let member = viewModel.liveDetectedEntities.first { $0.id == entity.id } ?? entity
                                viewModel.pinTargetAndStartMotion(
                                    at: CGPoint(x: member.rect.midX, y: member.rect.midY),
                                    subjectRect: entity.rect
                                )
                            }
                        }
                    }
                }

                if case .analyzing = viewModel.aiSessionState {
                    ForEach(0..<viewModel.localSuggestionRects.count, id: \.self) { index in
                        let sourceRect = viewModel.localSuggestionRects[index]
                        if !viewModel.localSuggestionRects.prefix(index).contains(sourceRect),
                           !sourceRect.isEmpty, sourceRect.maxX > 0, sourceRect.maxY > 0,
                           sourceRect.minX < 1, sourceRect.minY < 1 {
                            let rect = viewModel.convertMetadataRectToLayerRect(sourceRect, in: size)
                            CornerBracketsShape(bracketLength: 16)
                                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                                .animation(.interpolatingSpring(stiffness: 160, damping: 27), value: rect)
                        }
                    }
                }
                if case .analyzing = viewModel.aiSessionState,
                   let message = viewModel.localSelectionMessage,
                   viewModel.localSuggestionRects.isEmpty {
                    VStack {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.60)))
                            .padding(.top, topChromeInset)
                        Spacer()
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
                        .transaction { $0.animation = nil }
                    }

                    // Target Vàng
                    TargetCircleView(
                        isAligned: viewModel.isPerfectAlignment,
                        radarPulse: radarPulse,
                        radarOpacity: radarOpacity,
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
                if viewModel.showTargetCircle && !viewModel.captureMode.isVideo {
                    CurrentCenterCrosshair()
                    .position(screenCenter)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
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
                    GeminiAnalyzingBadge(topInset: topChromeInset)
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
                            .padding(.bottom, bottomChromeInset)
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
                        .padding(.top, topChromeInset)
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

                // 11. AI Zoom Reveal Overlay (Optical Window Pull-In Effect: 4 Giai đoạn Chuẩn TikTok/Douyin)
                ZoomRevealOverlay(
                    viewModel: viewModel,
                    containerSize: size
                )

                // 12. Realtime Diagnostic & Experiment Overlay
                if CompositionTuning.isDebugOverlayEnabled {
                    CompositionDebugOverlayView(viewModel: viewModel, containerSize: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                let location = event.location
                let norm = convertScreenPointToBuffer(location, in: size)
                if viewModel.isAEAFLocked {
                    viewModel.unlockAEAF()
                } else if case .analyzing = viewModel.aiSessionState,
                          !viewModel.localSuggestionRects.isEmpty {
                    viewModel.chooseLocalSuggestion(at: norm)
                } else {
                    viewModel.userDidTapToFocus(at: norm)
                }
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { val in
                        guard viewModel.showTargetCircle, let targetPoint = viewModel.currentTargetPoint else { return }
                        let currentScreen = convertBufferPointToScreen(targetPoint, in: size)
                        let dist = hypot(val.startLocation.x - currentScreen.x, val.startLocation.y - currentScreen.y)
                        if dist <= 44 {
                            let newNorm = convertScreenPointToBuffer(val.location, in: size)
                            viewModel.adjustTargetPoint(to: newNorm)
                        }
                    }
            )
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
                            viewModel.beginManualZoomGesture()
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
                        pinchBaseZoom = targetZoom
                    }
            )
            .clipped()
            .animation(.easeOut(duration: 0.25), value: viewModel.showTargetCircle)
            .onChangeCompatible(of: size) { newSize in viewModel.viewfinderSize = newSize }
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
    let radarPulse: CGFloat
    let radarOpacity: Double
    let trackingQuality: TrackingQuality

    private var ringGradient: LinearGradient {
        if isAligned {
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.95, blue: 0.55), Color(red: 0.05, green: 0.80, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        switch trackingQuality {
        case .locked, .predicting, .reacquiring:
            // Logo app gradient: Electric Cyan (#28B6F2) -> Iris Violet (#7863F2)
            return AlignTheme.signatureGradient
        case .lost:
            return LinearGradient(
                colors: [Color.red, Color.orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shadowGlowColor: Color {
        if isAligned { return Color.green }
        switch trackingQuality {
        case .locked, .predicting, .reacquiring: return AlignTheme.electricCyan
        case .lost: return Color.red
        }
    }

    var body: some View {
        ZStack {
            if !isAligned {
                Circle()
                    .stroke(ringGradient.opacity(radarOpacity * 0.6), lineWidth: 1.2)
                    .frame(width: 28 * radarPulse, height: 28 * radarPulse)
            }
            Circle()
                .stroke(ringGradient, lineWidth: isAligned ? 2.4 : 1.8)
                .frame(width: 28, height: 28)
                .shadow(color: Color.black.opacity(0.5), radius: 2)
                .shadow(color: shadowGlowColor.opacity(isAligned ? 0.85 : 0.50), radius: isAligned ? 8 : 4)

            PlusCrosshairShape()
                .stroke(isAligned ? Color.green : Color.white, lineWidth: isAligned ? 2.0 : 1.5)
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
                    .foregroundColor(.white)
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

// MARK: - Gemini Analyzing Badge

struct GeminiAnalyzingBadge: View {
    let topInset: CGFloat
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
        .padding(.top, topInset)
        .transition(.opacity)
    }
}

// MARK: - Live Entity Detection Box & Pro Corner Brackets

struct CornerBracketsShape: Shape {
    var bracketLength: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let len = min(bracketLength, min(rect.width, rect.height) * 0.35)

        // Top-Left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))

        // Top-Right
        path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))

        // Bottom-Right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))

        // Bottom-Left
        path.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))

        return path
    }
}

struct LiveEntityBoxView: View {
    let entity: LiveDetectedEntity
    let layerRect: CGRect
    let onTap: () -> Void

    var body: some View {
        let color = Color(red: 0.94, green: 0.88, blue: 0.69)

        CornerBracketsShape(bracketLength: min(16, min(layerRect.width, layerRect.height) * 0.35))
            .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            .frame(width: max(24, layerRect.width), height: max(24, layerRect.height))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.015))
            )
            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            .overlay(alignment: .topLeading) {
                Text(entity.label.uppercased())
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                    .offset(y: -22)
            }
            .position(x: layerRect.midX, y: layerRect.midY)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            .animation(.interpolatingSpring(stiffness: 160, damping: 27), value: layerRect)
            .accessibilityLabel("Chủ thể chính: \(entity.label)")
    }
}

// MARK: - Smart Focus Square Indicator with Sun EV Slider (Apple Camera Style)

struct FocusSquareWithSunSlider: View {
    let isLocked: Bool
    let showSun: Bool
    let exposureBias: Float
    let onAdjustBias: (Float) -> Void

    @State private var scale: CGFloat = 1.3
    @State private var lastDragTranslationY: CGFloat = 0.0

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
                                let incrementalY = val.translation.height - lastDragTranslationY
                                lastDragTranslationY = val.translation.height
                                let stepDelta = Float(-incrementalY / 65.0) * 2.5
                                onAdjustBias(stepDelta)
                            }
                            .onEnded { _ in
                                lastDragTranslationY = 0.0
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
        HStack(spacing: 16) {
            Rectangle()
                .fill(isLevel ? Color.yellow : Color.white.opacity(0.60))
                .frame(width: 34, height: isLevel ? 1.8 : 1.0)

            Color.clear
                .frame(width: 8, height: 8)

            Rectangle()
                .fill(isLevel ? Color.yellow : Color.white.opacity(0.60))
                .frame(width: 34, height: isLevel ? 1.8 : 1.0)
        }
        .rotationEffect(.degrees(-rollDegrees))
        .opacity(abs(rollDegrees) > 15.0 ? 0.0 : (isLevel ? 1.0 : max(0.20, 1.0 - abs(rollDegrees) / 12.0)))
        .animation(.easeInOut(duration: 0.15), value: isLevel)
    }
}

// MARK: - AI Zoom Reveal Cutout Mask Shape (Even-Odd Fill: Tối bên ngoài, trong suốt hoàn toàn bên trong)
public struct ZoomRevealCutoutShape: Shape {
    public var windowRect: CGRect

    public var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(windowRect.origin.x, windowRect.origin.y),
                AnimatablePair(windowRect.size.width, windowRect.size.height)
            )
        }
        set {
            windowRect = CGRect(
                x: newValue.first.first,
                y: newValue.first.second,
                width: newValue.second.first,
                height: newValue.second.second
            )
        }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        // Toàn bộ màn hình preview
        path.addRect(rect)
        // Khoét rỗng khung chữ nhật ở giữa với bo góc 16pt (Even-Odd Fill sẽ bỏ qua vùng này)
        let r = max(0.0, min(16.0, min(windowRect.width, windowRect.height) / 2.0))
        path.addRoundedRect(in: windowRect, cornerSize: CGSize(width: r, height: r))
        return path
    }
}

// MARK: - 4 Ngoặc Vuông Góc Khung (Corner Brackets)
public struct ZoomCornerBracketsShape: Shape {
    public var cornerLength: CGFloat = 18.0
    public var cornerRadius: CGFloat = 16.0

    public init(cornerLength: CGFloat = 18.0, cornerRadius: CGFloat = 16.0) {
        self.cornerLength = cornerLength
        self.cornerRadius = cornerRadius
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = max(0.0, min(cornerRadius, min(rect.width, rect.height) / 2.0))
        let l = max(r, min(cornerLength, min(rect.width, rect.height) / 2.0))

        // Top-Left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))

        // Top-Right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))

        // Bottom-Right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))

        // Bottom-Left
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))

        return path
    }
}

// MARK: - AI Zoom Reveal Overlay (Optical Window Pull-In Effect: 4 Giai đoạn Chuẩn TikTok/Douyin)
public struct ZoomRevealOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let containerSize: CGSize

    public init(viewModel: CameraViewModel, containerSize: CGSize) {
        self.viewModel = viewModel
        self.containerSize = containerSize
    }

    // Giai đoạn 1: Khung ngắm mục tiêu nhỏ (Pre-Zoom Crop Box) khi AI đề xuất mức zoom mà chưa khóa
    private var isPreZoomSuggested: Bool {
        guard !viewModel.hasExecutedAutoZoomForSession,
              viewModel.isAutoZoomEnabled,
              (viewModel.pendingSuggestedZoom - viewModel.displayZoom) > 0.15,
              viewModel.currentTargetPoint != nil else { return false }
        switch viewModel.aiSessionState {
        case .analyzing, .targetPlaced:
            return true
        default:
            return false
        }
    }

    private var isEffectActive: Bool {
        viewModel.isRevealingZoomTarget || isPreZoomSuggested
    }

    private var startDisplayZoom: CGFloat {
        max(0.5, viewModel.isRevealingZoomTarget ? viewModel.zoomRevealStartDisplayZoom : viewModel.displayZoom)
    }

    private var targetDisplayZoom: CGFloat {
        max(startDisplayZoom, viewModel.isRevealingZoomTarget ? viewModel.pendingTargetZoomForReveal : viewModel.pendingSuggestedZoom)
    }

    private var windowRect: CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }

        let s = min(1.0, max(0.18, startDisplayZoom / targetDisplayZoom))
        let cropW = containerSize.width * s
        let cropH = containerSize.height * s

        let centerNorm = viewModel.currentTargetPoint ?? CGPoint(x: 0.5, y: 0.5)
        let centerX = centerNorm.x * containerSize.width
        let centerY = centerNorm.y * containerSize.height

        let minX = max(0.0, min(containerSize.width - cropW, centerX - cropW / 2.0))
        let minY = max(0.0, min(containerSize.height - cropH, centerY - cropH / 2.0))
        let initialRect = CGRect(x: minX, y: minY, width: cropW, height: cropH)

        let fullRect = CGRect(origin: .zero, size: containerSize)

        let t = viewModel.isRevealingZoomTarget ? viewModel.zoomExpansionProgress : 0.0
        return interpolateRect(from: initialRect, to: fullRect, progress: t)
    }

    private func interpolateRect(from startRect: CGRect, to endRect: CGRect, progress t: CGFloat) -> CGRect {
        let clampedT = max(0.0, min(1.0, t))
        return CGRect(
            x: startRect.origin.x + (endRect.origin.x - startRect.origin.x) * clampedT,
            y: startRect.origin.y + (endRect.origin.y - startRect.origin.y) * clampedT,
            width: startRect.width + (endRect.width - startRect.width) * clampedT,
            height: startRect.height + (endRect.height - startRect.height) * clampedT
        )
    }

    public var body: some View {
        if isEffectActive {
            let rect = windowRect
            let isRevealing = viewModel.isRevealingZoomTarget
            let lockProgress = isRevealing ? viewModel.lockOnProgress : 0.0
            let expansionProgress = isRevealing ? viewModel.zoomExpansionProgress : 0.0

            // Giai đoạn 4: Settle & Fade Out (Khi expansionProgress từ 0.82 -> 1.0, tan biến mượt mà)
            let fadeMultiplier: CGFloat = expansionProgress >= 0.82 ? max(0.0, (1.0 - expansionProgress) / 0.18) : 1.0
            let strokeOpacity = (isRevealing ? lockProgress : 0.75) * fadeMultiplier
            let dimmingOpacity = (isRevealing ? 0.32 * lockProgress : 0.0) * fadeMultiplier

            ZStack {
                // 1. Giai đoạn 2: Mặt nạ khoét lỗ Even-Odd Cutout Mask (Tối nhẹ 32% bên ngoài, trong suốt hoàn toàn bên trong khung)
                if dimmingOpacity > 0.01 {
                    ZoomRevealCutoutShape(windowRect: rect)
                        .fill(Color.black.opacity(dimmingOpacity), style: FillStyle(eoFill: true))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // 2. Viền bóng mờ nhẹ chuyển tiếp (Soft feathered shadow)
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.18 * strokeOpacity), lineWidth: 3)
                    .blur(radius: 2)
                    .frame(width: max(20, rect.width), height: max(20, rect.height))
                    .position(x: rect.midX, y: rect.midY)

                // 3. Khung viền chính:
                // - Giai đoạn 1: Viền mảnh trắng mờ
                // - Giai đoạn 2 -> 4: Viền Cầu Vồng Iridescent Rainbow phát sáng neon
                if isRevealing {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(AlignTheme.iridescentRainbow, lineWidth: 2.0)
                        .frame(width: max(20, rect.width), height: max(20, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: Color(red: 0.70, green: 0.35, blue: 0.95).opacity(0.65 * strokeOpacity), radius: 8, x: 0, y: 0)
                        .shadow(color: Color(red: 0.15, green: 0.85, blue: 0.95).opacity(0.45 * strokeOpacity), radius: 14, x: 0, y: 0)
                        .opacity(strokeOpacity)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.65), lineWidth: 1.5)
                        .frame(width: max(20, rect.width), height: max(20, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(strokeOpacity)
                }

                // 4. 4 Ngoặc Vuông Góc Khung (Corner Brackets)
                if isRevealing {
                    ZoomCornerBracketsShape(cornerLength: 18.0, cornerRadius: 16.0)
                        .stroke(AlignTheme.iridescentRainbow, lineWidth: 2.8)
                        .frame(width: max(20, rect.width), height: max(20, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(strokeOpacity)
                } else {
                    ZoomCornerBracketsShape(cornerLength: 18.0, cornerRadius: 16.0)
                        .stroke(Color.white.opacity(0.85), lineWidth: 2.0)
                        .frame(width: max(20, rect.width), height: max(20, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(strokeOpacity)
                }

                // 5. Huy hiệu AI ZOOM ở mép trên khung
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9, weight: .bold))
                    Text("AI ZOOM \(String(format: "%.1f", targetDisplayZoom))x")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(isRevealing ? AlignTheme.iridescentRainbow : AlignTheme.signatureGradient)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
                .position(x: rect.midX, y: max(28, rect.minY - 14))
                .opacity(strokeOpacity)
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.20), value: isEffectActive)
        }
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
                    .padding(.top, max(52, min(74, screenSize.height * 0.14)))

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
                    .padding(.top, max(52, min(74, screenSize.height * 0.14)))

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
