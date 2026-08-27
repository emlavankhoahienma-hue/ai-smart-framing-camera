import SwiftUI

public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    @State private var radarPulse: CGFloat = 1.0
    @State private var radarOpacity: Double = 0.8
    @State private var dashOffset: CGFloat = 0
    
    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let centerPoint = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            
            ZStack {
                // 1. Composition Grid Lines
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
                
                // 4. YELLOW PIN TARGET (FIXED position — where AI pinned the target)
                if viewModel.showTargetCircle, let pinned = viewModel.pinnedTargetPoint {
                    let pinnedScreen = CGPoint(x: pinned.x * size.width, y: pinned.y * size.height)
                    
                    // Guidance ray from WHITE crosshair → YELLOW pin
                    if viewModel.showGuidanceRay {
                        let crosshairScreen = CGPoint(
                            x: viewModel.trackedSubjectPoint.x * size.width,
                            y: viewModel.trackedSubjectPoint.y * size.height
                        )
                        GuidanceRayLine(
                            from: crosshairScreen,
                            to: pinnedScreen,
                            dashOffset: dashOffset,
                            distance: viewModel.alignmentDistance
                        )
                    }
                    
                    // Yellow PIN (fixed)
                    TargetCircleView(
                        isAligned: viewModel.isPerfectAlignment,
                        alignmentDistance: viewModel.alignmentDistance,
                        radarPulse: radarPulse,
                        radarOpacity: radarOpacity,
                        countdown: viewModel.autoCaptureCountdown
                    )
                    .position(pinnedScreen)
                }
                
                // 5. WHITE CROSSHAIR — tracks the subject (moves with camera)
                // SNIPER MODEL: This is your "gun sight" — aim it at the yellow pin
                if viewModel.isAISessionActive {
                    let crosshairScreen = CGPoint(
                        x: viewModel.trackedSubjectPoint.x * size.width,
                        y: viewModel.trackedSubjectPoint.y * size.height
                    )
                    CurrentCenterCrosshair(
                        isAligned: viewModel.isPerfectAlignment,
                        sessionState: viewModel.aiSessionState,
                        distance: viewModel.alignmentDistance
                    )
                    .position(crosshairScreen)
                    .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: viewModel.trackedSubjectPoint)
                } else {
                    // Idle: show static center crosshair
                    CurrentCenterCrosshair(
                        isAligned: false,
                        sessionState: .idle,
                        distance: 1.0
                    )
                    .position(centerPoint)
                }
                
                // 6. Countdown overlay
                if case .alignmentPerfect = viewModel.aiSessionState {
                    CountdownOverlayView(countdown: viewModel.autoCaptureCountdown)
                }
                
                // 7. Alignment Success Flash border
                if viewModel.showAlignmentSuccessFlash {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green, lineWidth: 5)
                        .padding(4)
                        .transition(.opacity)
                }
                
                // 8. Gemini status toast (when analyzing)
                if viewModel.isGeminiAnalyzing {
                    GeminiAnalyzingBadge()
                }
                
                // 9. Capture flash
                if viewModel.activeFlashMode2 {
                    Color.white.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .clipped()
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

// MARK: - White Crosshair (Moving subject tracker — "gun sight")

struct CurrentCenterCrosshair: View {
    let isAligned: Bool
    let sessionState: AISessionState
    let distance: CGFloat
    
    var body: some View {
        let color: Color = isAligned ? .green : ringColor
        // Size pulses when close to target
        let proximityScale: CGFloat = distance < 0.15 ? (1.0 + (0.15 - distance) * 1.2) : 1.0
        
        ZStack {
            // Outer ring
            Circle()
                .stroke(color, lineWidth: isAligned ? 2.5 : 1.8)
                .frame(width: 38, height: 38)
            
            // 4 tick marks (crosshair arms)
            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Rectangle()
                    .fill(color.opacity(0.9))
                    .frame(width: 10, height: 1.6)
                    .offset(x: 25)
                    .rotationEffect(.degrees(Double(deg)))
            }
            
            // Center dot
            Circle()
                .fill(color)
                .frame(width: isAligned ? 6 : 4.5, height: isAligned ? 6 : 4.5)
            
            // Check when aligned
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

// MARK: - Yellow Target Circle (FIXED pin)

struct TargetCircleView: View {
    let isAligned: Bool
    let alignmentDistance: CGFloat
    let radarPulse: CGFloat
    let radarOpacity: Double
    let countdown: Int
    
    var body: some View {
        ZStack {
            // Radar pulse (not aligned)
            if !isAligned {
                Circle()
                    .stroke(Color.yellow.opacity(radarOpacity), lineWidth: 1.2)
                    .frame(width: 64 * radarPulse, height: 64 * radarPulse)
            }
            
            // Proximity progress ring
            let progress = max(0, 1.0 - (alignmentDistance / 0.30))
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    isAligned ? Color.green : Color.yellow.opacity(0.5),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: 60, height: 60)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.12), value: alignmentDistance)
            
            // Main ring
            Circle()
                .stroke(
                    isAligned ? Color.green : Color.yellow,
                    style: StrokeStyle(lineWidth: isAligned ? 3.5 : 2.2)
                )
                .frame(width: 52, height: 52)
                .shadow(color: isAligned ? Color.green.opacity(0.9) : Color.yellow.opacity(0.65), radius: isAligned ? 10 : 5)
            
            // Center: countdown or dot
            if isAligned {
                if countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                }
            } else {
                // Crosshair center in yellow target
                ZStack {
                    Circle().fill(Color.yellow.opacity(0.75)).frame(width: 8, height: 8)
                    // mini crosshair
                    Rectangle().fill(Color.yellow.opacity(0.6)).frame(width: 14, height: 1)
                    Rectangle().fill(Color.yellow.opacity(0.6)).frame(width: 1, height: 14)
                }
            }
        }
        .scaleEffect(isAligned ? 1.18 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: isAligned)
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
    
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
                Text("Gemini đang phân tích...")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.cyan)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
            Spacer()
        }
        .padding(.top, 80)
    }
}

// MARK: - Other Subviews

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
