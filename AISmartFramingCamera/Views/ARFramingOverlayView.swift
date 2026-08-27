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
                // 1. Composition Grid Guidelines
                CompositionGridLines(rule: viewModel.activeCompositionRule, size: size)
                    .opacity(viewModel.isAIAnalysisActive ? 0.35 : 0.2)
                
                // 2. Detected Subject / Face Bounding Boxes
                if viewModel.isAIAnalysisActive {
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
                
                // 3. Optical Camera Center Crosshair
                CurrentCenterCrosshair(isAligned: isAligned)
                    .position(centerPoint)
                
                // 4. AI Target Circle & Guidance Ray
                if viewModel.isAIAnalysisActive, let targetResult = viewModel.framingResult {
                    let targetScreenPoint = CGPoint(
                        x: targetResult.targetPoint.x * size.width,
                        y: targetResult.targetPoint.y * size.height
                    )
                    
                    // Guidance Ray (Line from current center to target)
                    if !targetResult.isAligned {
                        GuidanceRayLine(
                            from: centerPoint,
                            to: targetScreenPoint,
                            dashOffset: dashOffset
                        )
                    }
                    
                    // Animated Target Circle
                    TargetCircleView(
                        isAligned: targetResult.isAligned,
                        alignmentScore: targetResult.alignmentScore,
                        radarPulse: radarPulse,
                        radarOpacity: radarOpacity
                    )
                    .position(targetScreenPoint)
                }
                
                // 5. Magnetic Snap Flash Effect
                if viewModel.showAlignmentSuccessFlash {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.green, lineWidth: 6)
                        .padding(4)
                        .transition(.opacity)
                }
            }
            .clipped()
            .onAppear {
                startAnimations()
            }
        }
    }
    
    private var isAligned: Bool {
        if case .aligned = viewModel.alignmentState { return true }
        return false
    }
    
    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            radarPulse = 1.35
            radarOpacity = 0.2
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
                // 1/3 and 2/3 vertical
                path.move(to: CGPoint(x: size.width / 3.0, y: 0))
                path.addLine(to: CGPoint(x: size.width / 3.0, y: size.height))
                path.move(to: CGPoint(x: size.width * 2.0 / 3.0, y: 0))
                path.addLine(to: CGPoint(x: size.width * 2.0 / 3.0, y: size.height))
                
                // 1/3 and 2/3 horizontal
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
        .stroke(Color.white, style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
    }
}

struct CurrentCenterCrosshair: View {
    let isAligned: Bool
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(isAligned ? Color.green : Color.white.opacity(0.85), lineWidth: 1.8)
                .frame(width: 32, height: 32)
            
            Circle()
                .fill(isAligned ? Color.green : Color.white)
                .frame(width: 4, height: 4)
            
            // Subtle 4-axis ticks
            ForEach([0, 90, 180, 270], id: \.self) { deg in
                Rectangle()
                    .fill(isAligned ? Color.green : Color.white.opacity(0.7))
                    .frame(width: 6, height: 1.5)
                    .offset(x: 20)
                    .rotationEffect(.degrees(Double(deg)))
            }
        }
    }
}

struct TargetCircleView: View {
    let isAligned: Bool
    let alignmentScore: Double
    let radarPulse: CGFloat
    let radarOpacity: Double
    
    var body: some View {
        ZStack {
            if !isAligned {
                // Outer Pulsing Radar Ring
                Circle()
                    .stroke(Color.yellow.opacity(radarOpacity), lineWidth: 1.5)
                    .frame(width: 58 * radarPulse, height: 58 * radarPulse)
            }
            
            // Main Target Ring
            Circle()
                .stroke(
                    isAligned ? Color.green : Color.yellow,
                    style: StrokeStyle(lineWidth: isAligned ? 3.0 : 2.0)
                )
                .frame(width: 50, height: 50)
                .shadow(color: isAligned ? Color.green.opacity(0.8) : Color.yellow.opacity(0.5), radius: isAligned ? 8 : 4)
            
            // Inner Target Marker
            Circle()
                .fill(isAligned ? Color.green : Color.yellow.opacity(0.8))
                .frame(width: 10, height: 10)
            
            if isAligned {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .scaleEffect(isAligned ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isAligned)
    }
}

struct GuidanceRayLine: View {
    let from: CGPoint
    let to: CGPoint
    let dashOffset: CGFloat
    
    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.8), Color.yellow]),
                startPoint: .init(x: 0.5, y: 0.5),
                endPoint: .init(x: to.x / 400.0, y: to.y / 800.0)
            ),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [6, 4], dashPhase: dashOffset)
        )
    }
}

struct FaceDetectionBox: View {
    let rect: CGRect
    
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.cyan.opacity(0.75), lineWidth: 1.2)
            .frame(width: max(20, rect.width), height: max(20, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}

struct SubjectHighlightBox: View {
    let rect: CGRect
    
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: max(20, rect.width), height: max(20, rect.height))
            .position(x: rect.midX, y: rect.midY)
    }
}
