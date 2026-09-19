import SwiftUI

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    public init(viewModel: CameraViewModel) { self.viewModel = viewModel }
    public var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.liveISO).font(.caption.weight(.semibold).monospacedDigit())
                Text(viewModel.liveShutterSpeed).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if viewModel.isHistogramBarExpanded {
                HistogramPlot(bars: viewModel.histogramBars).frame(width: 64, height: 28)
                    .accessibilityLabel("Histogram độ sáng trực tiếp")
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(viewModel.captureMode.isVideo ? viewModel.selectedVideoCodec.rawValue : viewModel.selectedPhotoFormat.rawValue)
                    .font(.caption.weight(.semibold))
                if viewModel.captureMode.isVideo {
                    Text(viewModel.activeVideoResolutionString).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                } else { Text("ẢNH").font(.caption2).foregroundColor(.secondary) }
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, 12).frame(height: 48)
        .modifier(CameraGlass()).foregroundColor(.white)
        .allowsHitTesting(false)
    }
}

private struct HistogramPlot: View {
    let bars: [HistogramBarData]
    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let width = size.width / CGFloat(bars.count)
            for (index, bar) in bars.enumerated() {
                let height = max(1, min(1, max(0, bar.height)) * size.height)
                let rect = CGRect(x: CGFloat(index) * width, y: size.height - height, width: max(1, width - 0.5), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.7), with: .color(bar.color.opacity(0.85)))
            }
        }
    }
}
