import SwiftUI
import Foundation

// MARK: - Compact Top-Bar Real Rec.709 RGB + Luma Histogram Meter
public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    let width: CGFloat

    private let haptic = UISelectionFeedbackGenerator()

    // Muted pro-monitor RGB palette (tinh tế, đồng nhất với hệ màu carbon trầm — không chói neon)
    static let studioRedChannel = Color(red: 0.82, green: 0.36, blue: 0.34)
    static let studioGreenChannel = Color(red: 0.38, green: 0.68, blue: 0.50)
    static let studioBlueChannel = Color(red: 0.36, green: 0.56, blue: 0.78)

    public init(viewModel: CameraViewModel, width: CGFloat = 62) {
        self.viewModel = viewModel
        self.width = width
    }

    public var body: some View {
        let telemetry = viewModel.histogramTelemetry
        Button(action: {
            haptic.prepare()
            haptic.selectionChanged()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
        }) {
            ZStack {
                ProHistogramWaveformCanvas(telemetry: telemetry, showZoneTicks: true, showRGBChannels: true)
                    .frame(width: width, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                // Điểm báo bết tối (mép trái) và báo cháy sáng (mép phải) chỉ bật khi thật sự clipping
                HStack {
                    Circle()
                        .fill(Self.studioBlueChannel)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(telemetry.isShadowClipping ? 0.95 : 0.0)
                    Spacer()
                    Circle()
                        .fill(AlignTheme.studioRecordRed)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(telemetry.isHighlightClipping ? 0.95 : 0.0)
                }
                .padding(.horizontal, 1.5)
                .padding(.top, 1.5)
                .frame(width: width, height: 22, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Biểu đồ ánh sáng RGB, trung bình \(Int(round(telemetry.averageLuminance * 100))) phần trăm, cháy sáng \(Int(round(telemetry.highlightClipRatio * 100))) phần trăm. Chạm để mở rộng hoặc thu gọn")
    }
}

// MARK: - Expanded Pro RGB + Luma Scope HUD (Chạm vào thanh Histogram hoặc bật trong Cài đặt)
public struct ProHistogramExpandedHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let t = viewModel.histogramTelemetry
        let avgPct = Int(round(t.averageLuminance * 100))
        let hiPct = t.highlightClipRatio * 100
        let shPct = t.shadowClipRatio * 100

        VStack(spacing: 6) {
            // Header: Nhãn quang phổ + EV stop thực tế + nút đóng
            HStack(spacing: 5) {
                HStack(spacing: 2.5) {
                    Circle().fill(LiveColorHistogramHUDView.studioRedChannel).frame(width: 4, height: 4)
                    Circle().fill(LiveColorHistogramHUDView.studioGreenChannel).frame(width: 4, height: 4)
                    Circle().fill(LiveColorHistogramHUDView.studioBlueChannel).frame(width: 4, height: 4)
                }

                Text("RGB·Y")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(AlignTheme.studioInkSecondary)

                Spacer(minLength: 4)

                Text(String(format: "%+.1f EV", t.evOffset))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(abs(t.evOffset) > 0.9 ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)

                Button(action: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        viewModel.isHistogramBarExpanded = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            // Vùng vẽ sóng RGB + Luma 48 bins độ nét cao
            ProHistogramWaveformCanvas(telemetry: t, showZoneTicks: true, showRGBChannels: true, isExpanded: true)
                .frame(height: 46)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )

            // Dòng thông số thực: Bết tối (SH) | Trung bình (AVG) | Cháy sáng (HI)
            HStack(spacing: 0) {
                metricCell(
                    label: "SH",
                    value: String(format: "%.1f%%", shPct),
                    accent: t.isShadowClipping ? LiveColorHistogramHUDView.studioBlueChannel : AlignTheme.studioInkSecondary
                )
                Spacer(minLength: 4)
                metricCell(
                    label: "AVG",
                    value: "\(avgPct)%",
                    accent: AlignTheme.studioInkPrimary
                )
                Spacer(minLength: 4)
                metricCell(
                    label: "HI",
                    value: String(format: "%.1f%%", hiPct),
                    accent: t.isHighlightClipping ? AlignTheme.studioRecordRed : AlignTheme.studioInkSecondary
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 164)
        .background(StudioGlassRoundedSurface(cornerRadius: 14, tintOpacity: 0.64, borderOpacity: 0.16))
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 4)
    }

    private func metricCell(label: String, value: String, accent: Color) -> some View {
        HStack(spacing: 2.5) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkTertiary)
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundColor(accent)
        }
    }
}

// MARK: - High-Precision 48-Bin Rec.709 RGB + Luma Canvas
struct ProHistogramWaveformCanvas: View {
    let telemetry: HistogramTelemetry
    var showZoneTicks: Bool = true
    var showRGBChannels: Bool = true
    var isExpanded: Bool = false

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            guard telemetry.luma.count >= 2 else { return }

            // 1. Vạch chia vùng phơi sáng (3 vùng ở chế độ gọn, 5 vùng ở chế độ mở rộng)
            if showZoneTicks {
                let divisions = isExpanded ? 5 : 3
                for idx in 1..<divisions {
                    let x = rect.minX + rect.width * CGFloat(idx) / CGFloat(divisions)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: rect.minY + 1))
                    tick.addLine(to: CGPoint(x: x, y: rect.maxY))
                    context.stroke(
                        tick,
                        with: .color(Color.white.opacity(isExpanded ? 0.10 : 0.08)),
                        lineWidth: 0.5
                    )
                }
            }

            // 2. Các kênh R / G / B thực từ cảm biến với sắc độ trầm kiểu màn hình kiểm màu Pro
            if showRGBChannels {
                drawCurve(
                    in: &context,
                    rect: rect,
                    values: telemetry.blue,
                    fillTop: LiveColorHistogramHUDView.studioBlueChannel.opacity(isExpanded ? 0.30 : 0.24),
                    fillBottom: LiveColorHistogramHUDView.studioBlueChannel.opacity(0.02),
                    stroke: LiveColorHistogramHUDView.studioBlueChannel.opacity(isExpanded ? 0.78 : 0.62),
                    lineWidth: isExpanded ? 0.85 : 0.65
                )
                drawCurve(
                    in: &context,
                    rect: rect,
                    values: telemetry.green,
                    fillTop: LiveColorHistogramHUDView.studioGreenChannel.opacity(isExpanded ? 0.28 : 0.22),
                    fillBottom: LiveColorHistogramHUDView.studioGreenChannel.opacity(0.02),
                    stroke: LiveColorHistogramHUDView.studioGreenChannel.opacity(isExpanded ? 0.76 : 0.60),
                    lineWidth: isExpanded ? 0.85 : 0.65
                )
                drawCurve(
                    in: &context,
                    rect: rect,
                    values: telemetry.red,
                    fillTop: LiveColorHistogramHUDView.studioRedChannel.opacity(isExpanded ? 0.30 : 0.24),
                    fillBottom: LiveColorHistogramHUDView.studioRedChannel.opacity(0.02),
                    stroke: LiveColorHistogramHUDView.studioRedChannel.opacity(isExpanded ? 0.78 : 0.64),
                    lineWidth: isExpanded ? 0.85 : 0.65
                )
            }

            // 3. Đường Luma chủ đạo (Alabaster sắc nét nằm trên cùng)
            drawCurve(
                in: &context,
                rect: rect,
                values: telemetry.luma,
                fillTop: Color.white.opacity(isExpanded ? 0.22 : 0.24),
                fillBottom: Color.white.opacity(0.02),
                stroke: AlignTheme.studioInkPrimary.opacity(0.90),
                lineWidth: isExpanded ? 1.1 : 0.95
            )

            // 4. Vạch cảnh báo clipping sát mép phải/trái khi mở rộng
            if isExpanded {
                if telemetry.isHighlightClipping {
                    let clipRect = CGRect(x: rect.maxX - 2.0, y: rect.minY, width: 2.0, height: rect.height)
                    context.fill(Path(clipRect), with: .color(AlignTheme.studioRecordRed.opacity(0.85)))
                }
                if telemetry.isShadowClipping {
                    let clipRect = CGRect(x: rect.minX, y: rect.minY, width: 2.0, height: rect.height)
                    context.fill(Path(clipRect), with: .color(LiveColorHistogramHUDView.studioBlueChannel.opacity(0.85)))
                }
            }
        }
    }

    private func drawCurve(
        in context: inout GraphicsContext,
        rect: CGRect,
        values: [Float],
        fillTop: Color,
        fillBottom: Color,
        stroke: Color,
        lineWidth: CGFloat
    ) {
        let (fillPath, linePath) = smoothPaths(for: values, in: rect)
        context.fill(
            fillPath,
            with: .linearGradient(
                Gradient(colors: [fillTop, fillBottom]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        context.stroke(
            linePath,
            with: .color(stroke),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func smoothPaths(for values: [Float], in rect: CGRect) -> (fill: Path, line: Path) {
        let n = values.count
        guard n >= 2 else { return (Path(), Path()) }
        let stepX = rect.width / CGFloat(n - 1)
        let usableHeight = max(2, rect.height - 2)

        var points: [CGPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * stepX
            let v = CGFloat(max(0.02, min(1.0, values[i])))
            let y = rect.maxY - v * usableHeight
            points.append(CGPoint(x: x, y: y))
        }

        var line = Path()
        var fill = Path()
        line.move(to: points[0])
        fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        fill.addLine(to: points[0])

        // Quadratic midpoint spline (không tạo overshoot âm như Catmull-Rom, siêu mượt và nhẹ GPU)
        for i in 1..<n {
            let prev = points[i - 1]
            let curr = points[i]
            let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
            line.addQuadCurve(to: mid, control: prev)
            fill.addQuadCurve(to: mid, control: prev)
        }
        line.addLine(to: points[n - 1])
        fill.addLine(to: points[n - 1])
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.closeSubpath()

        return (fill, line)
    }
}
