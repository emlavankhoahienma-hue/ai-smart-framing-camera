import SwiftUI

@main
struct WindowedZoomSnapshotApp: App {
    var body: some Scene { WindowGroup { WindowedZoomSnapshot() } }
}

private struct WindowedZoomSnapshot: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var stage = "photo"

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 32, (proxy.size.height - 130) * (stage == "video" ? 9.0 / 16 : 0.75))
            let height = width / (stage == "video" ? 9.0 / 16 : 0.75)
            VStack(spacing: 12) {
                Text("Windowed Zoom · \(stage)").foregroundStyle(.white)
                ZStack {
                    LinearGradient(colors: [.blue, .gray, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Canvas { context, size in
                        for index in 1..<10 {
                            var path = Path()
                            path.move(to: CGPoint(x: size.width * CGFloat(index) / 10, y: 0))
                            path.addLine(to: CGPoint(x: size.width * CGFloat(index) / 10, y: size.height))
                            path.move(to: CGPoint(x: 0, y: size.height * CGFloat(index) / 10))
                            path.addLine(to: CGPoint(x: size.width, y: size.height * CGFloat(index) / 10))
                            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
                        }
                    }
                    WindowedZoomOverlayView(viewModel: viewModel, containerSize: CGSize(width: width, height: height))
                }
                .frame(width: width, height: height)
                .clipped()
                Text("Khung thử · Tâm (0.40, 0.65) · 50mm")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .onAppear { configureWindow(for: stage) }
        .onOpenURL(perform: openSnapshotStage)
    }

    private func openSnapshotStage(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "alignai-snapshot", components.host == "window",
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "stage", let value = items[0].value,
              ["photo", "square", "video"].contains(value) else { return }
        stage = value
        configureWindow(for: value)
    }

    private func configureWindow(for stage: String) {
        viewModel.windowedZoomFocalLength = 50
        viewModel.windowedZoomAspectRatio = stage == "video" ? .ratio16_9 : (stage == "square" ? .ratio1_1 : .ratio3_4)
        viewModel.windowedZoomNormalizedCenter = CGPoint(x: 0.4, y: 0.65)
    }
}
