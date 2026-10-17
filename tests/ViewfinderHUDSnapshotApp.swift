// Simulator-only host for the production reticle and subject-bracket views.
import SwiftUI

@main
struct ViewfinderHUDSnapshotApp: App {
    var body: some Scene {
        WindowGroup { ViewfinderHUDSnapshot().preferredColorScheme(.dark) }
    }
}

private struct ViewfinderHUDSnapshot: View {
    private let entity = LiveDetectedEntity(rect: CGRect(x: 0.22, y: 0.18, width: 0.56, height: 0.64),
        label: "Chủ thể chính", confidence: 0.92, category: .human)

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 32, 430)
            let height = min(proxy.size.height * 0.68, width * 4 / 3)
            VStack(spacing: 20) {
                Text("ALIGN AI")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(4)
                ZStack {
                    LinearGradient(colors: [Color(white: 0.26), Color(white: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: width * 0.43, y: height * 0.30))
                        path.addLine(to: CGPoint(x: width, y: height * 0.65))
                    }.stroke(.white.opacity(0.12), lineWidth: 1)
                    Ellipse().fill(Color(white: 0.38)).frame(width: width * 0.20, height: height * 0.18)
                        .position(x: width * 0.5, y: height * 0.31)
                    RoundedRectangle(cornerRadius: width * 0.12).fill(Color(white: 0.30))
                        .frame(width: width * 0.35, height: height * 0.39)
                        .position(x: width * 0.5, y: height * 0.57)
                    LiveEntityBoxView(entity: entity,
                        layerRect: CGRect(x: width * 0.22, y: height * 0.18, width: width * 0.56, height: height * 0.64), onTap: {})
                    CurrentCenterCrosshair().position(x: width * 0.5, y: height * 0.5)
                    TargetCircleView(isAligned: false, trackingQuality: .locked)
                        .position(x: width * 0.67, y: height * 0.4)
                }
                .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 42) {
                    TargetCircleView(isAligned: false, trackingQuality: .locked)
                    TargetCircleView(isAligned: true, trackingQuality: .locked)
                    TargetCircleView(isAligned: false, trackingQuality: .lost)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
    }
}
