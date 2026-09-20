import SwiftUI
import Foundation
import QuartzCore

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    @State private var smoothedHeights: [CGFloat] = Array(repeating: 0.08, count: 32)
    @State private var lastUpdateTime: Double = 0
    private let haptic = UISelectionFeedbackGenerator()

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 3) {
            rgbWaveformCanvas
                .frame(width: 140, height: 26)

            infoRow
                .frame(width: 140, height: 14)
        }
        .frame(width: 140, height: 44)
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear {
            initializeHeights()
        }
        .onChange(of: viewModel.histogramBars) { newBars in
            handleHistogramUpdate(newBars)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Histogram, \(viewModel.liveISO), độ phơi sáng \(formattedExposure), định dạng \(activeFormatTitle)")
    }

    // MARK: - 1. RGB Continuous Curved Waveform (SwiftUI Canvas)
    private var rgbWaveformCanvas: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            guard smoothedHeights.count >= 2 else { return }

            // 1. Derive 3 Spectral Curves (Red, Green, Blue) from Luminance + Frequency
            let redValues = channelValues(weights: (midBoost: 0.28, highBoost: 0.35, offset: 0.08))
            let greenValues = channelValues(weights: (midBoost: 0.40, highBoost: 0.12, offset: 0.0))
            let blueValues = channelValues(weights: (midBoost: 0.18, highBoost: 0.08, offset: 0.22))

            // 2. Draw Subtle Spectral Needles (Vertical Filaments matching Pro Cinema UI)
            let stepX = rect.width / CGFloat(smoothedHeights.count - 1)
            for i in 0..<smoothedHeights.count {
                let x = rect.minX + CGFloat(i) * stepX
                let maxH = max(redValues[i], max(greenValues[i], blueValues[i])) * rect.height
                let needlePath = Path { p in
                    p.move(to: CGPoint(x: x, y: rect.maxY))
                    p.addLine(to: CGPoint(x: x, y: rect.maxY - maxH))
                }
                context.stroke(
                    needlePath,
                    with: .color(needleColor(for: i).opacity(0.22)),
                    lineWidth: 0.75
                )
            }

            // 3. Layer: Blue / Cyan (Cool & Shadows)
            drawChannelLayer(
                in: &context,
                rect: rect,
                values: blueValues,
                fillGradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.65, blue: 1.0).opacity(0.30),
                    Color(red: 0.10, green: 0.40, blue: 0.90).opacity(0.02)
                ]),
                strokeColor: Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.85)
            )

            // 4. Layer: Green (Luminance & Midtones)
            drawChannelLayer(
                in: &context,
                rect: rect,
                values: greenValues,
                fillGradient: Gradient(colors: [
                    Color(red: 0.25, green: 0.90, blue: 0.45).opacity(0.32),
                    Color(red: 0.15, green: 0.70, blue: 0.35).opacity(0.02)
                ]),
                strokeColor: Color(red: 0.35, green: 0.95, blue: 0.50).opacity(0.85)
            )

            // 5. Layer: Red (Warmth & Highlights)
            drawChannelLayer(
                in: &context,
                rect: rect,
                values: redValues,
                fillGradient: Gradient(colors: [
                    Color(red: 1.0, green: 0.30, blue: 0.35).opacity(0.32),
                    Color(red: 0.85, green: 0.15, blue: 0.20).opacity(0.02)
                ]),
                strokeColor: Color(red: 1.0, green: 0.35, blue: 0.40).opacity(0.85)
            )
        }
    }

    // MARK: - Spline Path Drawing for Channel
    private func drawChannelLayer(
        in context: inout GraphicsContext,
        rect: CGRect,
        values: [CGFloat],
        fillGradient: Gradient,
        strokeColor: Color
    ) {
        let (fillPath, linePath) = splinePaths(for: values, in: rect)

        // Filled area with delicate vertical gradient
        context.fill(
            fillPath,
            with: .linearGradient(
                fillGradient,
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )

        // Top contour stroke line (antialiased, thin & crisp)
        context.stroke(
            linePath,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func splinePaths(for values: [CGFloat], in rect: CGRect) -> (fill: Path, line: Path) {
        guard values.count >= 2 else { return (Path(), Path()) }
        let stepX = rect.width / CGFloat(values.count - 1)

        var points: [CGPoint] = []
        for (i, val) in values.enumerated() {
            let x = rect.minX + CGFloat(i) * stepX
            let clamped = max(0.04, min(1.0, val))
            let y = rect.maxY - (clamped * rect.height)
            points.append(CGPoint(x: x, y: y))
        }

        var line = Path()
        var fill = Path()

        line.move(to: points[0])
        fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        fill.addLine(to: points[0])

        for i in 0..<points.count - 1 {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : p2

            let cp1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: p1.y + (p2.y - p0.y) / 6.0
            )
            let cp2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: p2.y - (p3.y - p1.y) / 6.0
            )

            line.addCurve(to: p2, control1: cp1, control2: cp2)
            fill.addCurve(to: p2, control1: cp1, control2: cp2)
        }

        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.closeSubpath()

        return (fill, line)
    }

    // MARK: - Spectral Channel Weighting
    private func channelValues(weights: (midBoost: CGFloat, highBoost: CGFloat, offset: CGFloat)) -> [CGFloat] {
        let count = smoothedHeights.count
        guard count > 0 else { return [] }

        return (0..<count).map { i in
            let base = smoothedHeights[i]
            let t = CGFloat(i) / CGFloat(max(1, count - 1))

            let midFactor = sin(t * .pi) * weights.midBoost
            let highFactor = pow(t, 1.3) * weights.highBoost
            let shadowFactor = pow(1.0 - t, 1.3) * weights.offset

            let multiplier = 0.82 + midFactor + highFactor + shadowFactor
            return max(0.04, min(1.0, base * multiplier))
        }
    }

    private func needleColor(for index: Int) -> Color {
        let t = Double(index) / 31.0
        if t < 0.33 {
            return Color(red: 0.25, green: 0.60, blue: 0.95)
        } else if t < 0.66 {
            return Color(red: 0.30, green: 0.85, blue: 0.45)
        } else {
            return Color(red: 0.95, green: 0.40, blue: 0.35)
        }
    }

    // MARK: - 2. Bottom Info Row (ISO · EV · Format)
    private var infoRow: some View {
        HStack(spacing: 0) {
            Text(viewModel.liveISO)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.22), value: viewModel.liveISO)

            Text(formattedExposure)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.22), value: viewModel.exposureBias)

            Button(action: toggleActiveFormat) {
                Text(activeFormatTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đổi định dạng \(activeFormatTitle)")
        }
        .font(.system(size: 9.0, weight: .medium, design: .monospaced))
        .foregroundColor(.white.opacity(0.70))
    }

    // MARK: - Data Formatting & Handlers
    private var activeFormatTitle: String {
        if viewModel.captureMode.isVideo {
            return viewModel.selectedVideoCodec == .hevc ? "HEVC" : "H.264"
        }

        switch viewModel.selectedPhotoFormat {
        case .jpeg: return "JPEG"
        case .heic, .heif: return "HEIF"
        case .dng: return "DNG"
        }
    }

    private var formattedExposure: String {
        String(format: "EV %+.1f", viewModel.exposureBias)
    }

    private func toggleActiveFormat() {
        if viewModel.captureMode.isVideo {
            viewModel.toggleVideoCodec()
        } else {
            viewModel.togglePhotoFormat()
        }
        haptic.selectionChanged()
    }

    private func initializeHeights() {
        if !viewModel.histogramBars.isEmpty {
            smoothedHeights = viewModel.histogramBars.map { max(0.05, min(1.0, $0.height)) }
        }
    }

    private func handleHistogramUpdate(_ newBars: [HistogramBarData]) {
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime >= 0.05 else { return } // Rate-limit updates to protect 60fps Live View
        lastUpdateTime = now

        guard !newBars.isEmpty else { return }
        let target = newBars.map { max(0.04, min(1.0, $0.height)) }
        let count = min(target.count, 32)

        var nextSmoothed: [CGFloat] = []
        for i in 0..<count {
            let prev = smoothedHeights.indices.contains(i) ? smoothedHeights[i] : 0.08
            let targetVal = target[i]
            // Exponential Moving Average (EMA) bất đối xứng: tăng bắt sáng (0.35), giảm giữ hình (0.22)
            let alpha: CGFloat = targetVal > prev ? 0.35 : 0.22
            let val = prev * (1.0 - alpha) + targetVal * alpha
            nextSmoothed.append(val)
        }

        withAnimation(.easeOut(duration: 0.20)) {
            smoothedHeights = nextSmoothed
        }
    }
}
