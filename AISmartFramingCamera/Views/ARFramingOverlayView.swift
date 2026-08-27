import SwiftUI

public struct ARFramingOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    @State private var radarPulse: CGFloat = 1.0
    @State private var radarOpacity: Double = 0.8
    @State private var dashOffset: CGFloat = 0
    @State private var countdownScale: CGFloat = 1.0
    
    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let centerPoint = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            
            ZStack {
                // 1. Composition Grid Lines (chỉ hiện khi có session active)
                if viewModel.isAISessionActive {
                    CompositionGridLines(rule: viewModel.activeCompositionRule, size: size)
                        .opacity(0.30)
                        .animation(.easeInOut(duration: 0.4), value: viewModel.isAISessionActive)
                }
                
                // 2. Detected Faces (luôn hiển thị preview khi idle)
                ForEach(0..<viewModel.detectedFaceRects.count, id: \.self) { index in
                    let rect = viewModel.detectedFaceRects[index]
                    FaceDetectionBox(
                        rect: CGRect(
                            x: rect.origin.x * size.width,
                            y: rect.origin.y * size.height,
                            width: rect.width * size.width,
                            height: rect.height * size.height
                        )
                    )
                }
                
                // 3. Subject Highlight (chỉ khi phân tích)
                if viewModel.isAISessionActive {
                    ForEach(0..<viewModel.detectedSubjectRects.count, id: \.self) { index in
                        let rect = viewModel.detectedSubjectRects[index]
                        SubjectHighlightBox(
                            rect: CGRect(
                                x: rect.origin.x * size.width,
                                y: rect.origin.y * size.height,
                                width: rect.width * size.width,
                                height: rect.height * size.height
                            )
                        )
                    }
                }
                
                // 4. Tâm Trắng (Current Crosshair) — LUÔN ở chính giữa, không di chuyển
                CurrentCenterCrosshair(
                    isAligned: viewModel.isPerfectAlignment,
                    sessionState: viewModel.aiSessionState
                )
                .position(centerPoint)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: viewModel.isPerfectAlignment)
                
                // 5. Vòng Tròn Vàng (Target) + Đường Chỉ Dẫn
                if viewModel.showTargetCircle, let targetResult = viewModel.framingResult {
                    let targetScreenPoint = CGPoint(
                        x: targetResult.targetPoint.x * size.width,
                        y: targetResult.targetPoint.y * size.height
                    )
                    
                    // Đường chỉ dẫn từ tâm trắng → tâm vàng
                    if viewModel.showGuidanceRay {
                        GuidanceRayLine(
                            from: centerPoint,
                            to: targetScreenPoint,
                            dashOffset: dashOffset,
                            distance: viewModel.alignmentDistance
                        )
                    }
                    
                    // Vòng tròn mục tiêu vàng (CỐ ĐỊNH — không di chuyển)
                    TargetCircleView(
                        isAligned: viewModel.isPerfectAlignment,
                        alignmentDistance: viewModel.alignmentDistance,
                        radarPulse: radarPulse,
                        radarOpacity: radarOpacity,
                        countdown: viewModel.autoCaptureCountdown
                    )
                    .position(targetScreenPoint)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.isPerfectAlignment)
                }
                
                // 6. Countdown & flash overlay
                if case .alignmentPerfect = viewModel.aiSessionState {
                    CountdownOverlayView(countdown: viewModel.autoCaptureCountdown)
                }
                
                // 7. Alignment Success Flash
                if viewModel.showAlignmentSuccessFlash {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green, lineWidth: 5)
                        .padding(4)
                        .transition(.opacity)
                }
                
                // 8. Flash overlay for capture
                if viewModel.activeFlashMode2 {
                    Color.white.opacity(0.55)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .clipped()
            .onAppear {
                startAnimations()
            }
        }
    }
    
    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            radarPulse = 1.40
            radarOpacity = 0.15
        }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            dashOffset = -20
        }
    }
}

// MARK: - Subviews

struct CompositionGridLines: View {
    let rule: CompositionRule
    let size: CGSize
    
    var body: some View {
        Path { path in
            switch rule {
            case .ruleOfThirds, .dynamicAI:
                path.move(to: CGPoint(x: size.width / 3.0, y: 0))
                path.addLine(to: CGPoint(x: size.width / 3.0, y: size.height))
                path.move(to: CGPoint(x: size.width * 2.0 / 3.0, y: 0))
                path.addLine(to: CGPoint(x: size.width * 2.0 / 3.0, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height / 3.0))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 3.0))
                path.move(to: CGPoint(x: 0, y: size.height * 2.0 / 3.0))
                path.addLine(to: CGPoint(x: size.width, y: size.height * 2.0 / 3.0))
                
            case .goldenRatio:
                let phi1: CGFloat = 0.381966
                let phi2: CGFloat = 0.618034
                path.move(to: CGPoint(x: size.width * phi1, y: 0))
                path.addLine(to: CGPoint(x: size.width * phi1, y: size.height))
                path.move(to: CGPoint(x: size.width * phi2, y: 0))
                path.addLine(to: CGPoint(x: size.width * phi2, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * phi1))
                path.addLine(to: CGPoint(x: size.width, y: size.height * phi1))
                path.move(to: CGPoint(x: 0, y: size.height * phi2))
                path.addLine(to: CGPoint(x: size.width, y: size.height * phi2))
                
            case .goldenSpiral:
                let phi1: CGFloat = 0.381966
                let phi2: CGFloat = 0.618034
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

/// Tâm trắng ở chính giữa màn hình — người dùng di chuyển máy để tâm này đến tâm vàng
struct CurrentCenterCrosshair: View {
    let isAligned: Bool
    let sessionState: AISessionState
    
    var body: some View {
        let color: Color = isAligned ? .green : ringColor
        
        ZStack {
            // Outer ring
            Circle()
                .stroke(color, lineWidth: isAligned ? 2.5 : 1.8)
                .frame(width: 36, height: 36)
            
            // Inner dot
            Circle()
                .fill(color)
                .frame(width: isAligned ? 6 : 4, height: isAligned ? 6 : 4)
            
            // 4 tick marks
            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Rectangle()
                    .fill(color.opacity(0.85))
                    .frame(width: 8, height: 1.5)
                    .offset(x: 22)
                    .rotationEffect(.degrees(Double(deg)))
            }
            
            // Check mark when aligned
            if isAligned {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.green)
            }
        }
        .shadow(color: color.opacity(0.5), radius: isAligned ? 6 : 0)
    }
    
    private var ringColor: Color {
        switch sessionState {
        case .idle: return Color.white.opacity(0.75)
        case .analyzing: return Color.yellow.opacity(0.8)
        case .targetPlaced: return Color.white
        default: return Color.white
        }
    }
}

struct TargetCircleView: View {
    let isAligned: Bool
    let alignmentDistance: CGFloat
    let radarPulse: CGFloat
    let radarOpacity: Double
    let countdown: Int
    
    var body: some View {
        ZStack {
            // Outer Radar Pulse (only when not aligned)
            if !isAligned {
                Circle()
                    .stroke(Color.yellow.opacity(radarOpacity), lineWidth: 1.2)
                    .frame(width: 62 * radarPulse, height: 62 * radarPulse)
            }
            
            // Proximity fill ring — fills up as you get closer
            let proximityProgress = max(0, 1.0 - (alignmentDistance / 0.3))
            Circle()
                .trim(from: 0, to: proximityProgress)
                .stroke(
                    isAligned ? Color.green : Color.yellow.opacity(0.4),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.15), value: alignmentDistance)
            
            // Main Target Ring
            Circle()
                .stroke(
                    isAligned ? Color.green : Color.yellow,
                    style: StrokeStyle(lineWidth: isAligned ? 3.5 : 2.2)
                )
                .frame(width: 50, height: 50)
                .shadow(color: isAligned ? Color.green.opacity(0.9) : Color.yellow.opacity(0.6), radius: isAligned ? 10 : 5)
            
            // Inner marker
            if isAligned {
                // Countdown indicator
                if countdown > 0 {
                    Text("\(countdown)")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                }
            } else {
                Circle()
                    .fill(Color.yellow.opacity(0.7))
                    .frame(width: 10, height: 10)
            }
        }
        .scaleEffect(isAligned ? 1.18 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: isAligned)
    }
}

struct GuidanceRayLine: View {
    let from: CGPoint
    let to: CGPoint
    let dashOffset: CGFloat
    let distance: CGFloat
    
    private var arrowOpacity: Double {
        Double(max(0.3, min(1.0, distance / 0.2)))
    }
    
    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            Color.yellow.opacity(0.7),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [5, 5], dashPhase: dashOffset)
        )
    }
}

struct CountdownOverlayView: View {
    let countdown: Int
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .bold))
                
                Text(countdown > 0 ? "Chụp trong \(countdown)..." : "Đang chụp...")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.green))
            .shadow(color: Color.green.opacity(0.4), radius: 10)
            
            Spacer().frame(height: 200)
        }
    }
}

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
