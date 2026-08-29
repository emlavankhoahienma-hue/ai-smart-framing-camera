import SwiftUI

public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    @State private var radarPulse: CGFloat = 1.0
    @State private var radarOpacity: Double = 0.8
    @State private var dashOffset: CGFloat = 0
    
    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let screenCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            
            ZStack {
                // 1. Composition Grid Lines (hiện khi AI session active)
                if viewModel.isAISessionActive {
                    CompositionGridLines(rule: viewModel.activeCompositionRule, size: size)
                        .opacity(0.28)
                        .animation(.easeInOut(duration: 0.4), value: viewModel.isAISessionActive)
                }
                
                // 2. Detected Faces preview
                ForEach(0..<viewModel.detectedFaceRects.count, id: \.self) { i in
                    let rect = viewModel.detectedFaceRects[i]
                    FaceDetectionBox(rect: CGRect(
                        x: rect.origin.x * size.width,
                        y: rect.origin.y * size.height,
                        width: rect.width * size.width,
                        height: rect.height * size.height
                    ))
                }
                
                // 3. Subject highlight rects
                if viewModel.isAISessionActive {
                    ForEach(0..<viewModel.detectedSubjectRects.count, id: \.self) { i in
                        let rect = viewModel.detectedSubjectRects[i]
                        SubjectHighlightBox(rect: CGRect(
                            x: rect.origin.x * size.width,
                            y: rect.origin.y * size.height,
                            width: rect.width * size.width,
                            height: rect.height * size.height
                        ))
                    }
                }
                
                // 4. VÒNG TRÒN TARGET VÀNG (Bám vật thể quang học + 60Hz Gyroscope)
                if viewModel.showTargetCircle, let targetPoint = viewModel.currentTargetPoint {
                    let targetScreen = CGPoint(
                        x: targetPoint.x * size.width,
                        y: targetPoint.y * size.height
                    )
                    
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
                }
                
                // 5. TÂM TRẮNG GIỮA MÀN HÌNH — CHỈ HIỆN KHI AI ĐÃ XÁC ĐỊNH ĐƯỢC TARGET
                // Trước đó (idle/đang phân tích) tâm này ẨN, không hiện gì cả.
                if viewModel.showTargetCircle {
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
                
                // 8b. AE/AF LOCK badge — hiện liên tục, không tự ẩn, cho tới khi chạm ra ngoài
                if viewModel.isAEAFLocked, let lockPoint = viewModel.aeafLockPoint {
                    ZStack {
                        Rectangle()
                            .stroke(Color.yellow, lineWidth: 1.5)
                            .frame(width: 70, height: 70)
                    }
                    .position(x: lockPoint.x * size.width, y: lockPoint.y * size.height)
                    
                    VStack {
                        Text("AE/AF LOCK")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(.top, 50)
                        Spacer()
                    }
                }
                
                // 9. Smart Autofocus Yellow Square Indicator (Apple Camera App style)
                if let focusPoint = viewModel.activeFocusSquarePoint {
                    FocusSquareView()
                        .position(x: focusPoint.x * size.width, y: focusPoint.y * size.height)
                        .transition(.scale.combined(with: .opacity))
                }
                
                // 10. Capture Flash
                if viewModel.activeFlashMode2 {
                    Color.white.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if case .targetPlaced = viewModel.aiSessionState {
                    let normalizedPoint = CGPoint(
                        x: max(0.05, min(0.95, location.x / size.width)),
                        y: max(0.05, min(0.95, location.y / size.height))
                    )
                    viewModel.pinTargetAndStartMotion(at: normalizedPoint)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.25), value: viewModel.showTargetCircle)
            .onAppear { startAnimations() }
        }
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

// MARK: - Center Crosshair (100% CỐ ĐỊNH Ở CHÍNH GIỮA)

struct CurrentCenterCrosshair: View {
    let isAligned: Bool
    let sessionState: AISessionState
    let distance: CGFloat
    
    var body: some View {
        let color: Color = isAligned ? .green : ringColor
        let proximityScale: CGFloat = distance < 0.15 ? (1.0 + (0.15 - distance) * 1.2) : 1.0
        
        ZStack {
            Circle()
                .stroke(color, lineWidth: isAligned ? 2.5 : 1.8)
                .frame(width: 38, height: 38)
            
            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Rectangle()
                    .fill(color.opacity(0.9))
                    .frame(width: 10, height: 1.6)
                    .offset(x: 25)
                    .rotationEffect(.degrees(Double(deg)))
            }
            
            Circle()
                .fill(color)
                .frame(width: isAligned ? 6 : 4.5, height: isAligned ? 6 : 4.5)
            
            if isAligned {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.green)
            }
        }
        .scaleEffect(proximityScale)
        .shadow(color: color.opacity(isAligned ? 0.65 : 0.3), radius: isAligned ? 8 : 3)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isAligned)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: proximityScale)
    }
    
    private var ringColor: Color {
        switch sessionState {
        case .idle: return Color.white.opacity(0.7)
        case .analyzing: return Color.yellow.opacity(0.8)
        case .targetPlaced: return Color.white
        default: return Color.white
        }
    }
}

// MARK: - Target Vàng (Di chuyển theo Gyro + Optical Tracking để về tâm giữa)

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
        case .locked, .predicting: return .yellow
        case .reacquiring: return .orange
        case .lost: return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(ringColor, lineWidth: isAligned ? 2.5 : 1.8)
                    .frame(width: 30, height: 30)
                    .shadow(color: ringColor.opacity(0.5), radius: isAligned ? 6 : 3)
                
                if isAligned {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.green)
                }
            }
            .scaleEffect(isAligned ? 1.15 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAligned)
            
            if trackingQuality == .reacquiring {
                Text("Đang tìm lại mục tiêu…")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
            } else if trackingQuality == .lost {
                HStack(spacing: 4) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 9))
                    Text("Chạm để đặt lại mục tiêu")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.red.opacity(0.85)))
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
    @State private var rotation: Double = 0
    @State private var pulse: CGFloat = 1.0
    
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.cyan)
                    .rotationEffect(.degrees(rotation))
                    .scaleEffect(pulse)
                    .onAppear {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulse = 1.25
                        }
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google Gemini AI Live")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(.cyan)
                    Text("Đang phân tích quang học & màu tự nhiên...")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                    .scaleEffect(0.8)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .overlay(Capsule().stroke(Color.cyan.opacity(0.6), lineWidth: 1.2))
                    .shadow(color: Color.cyan.opacity(0.3), radius: 10)
            )
            Spacer()
        }
        .padding(.top, 85)
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

// MARK: - Smart Focus Square Indicator (Apple Camera App Style)

struct FocusSquareView: View {
    @State private var scale: CGFloat = 1.3
    @State private var opacity: Double = 1.0
    
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 1.5)
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
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = 1.0
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.6)) {
                opacity = 0.0
            }
        }
    }
}
