import SwiftUI
import Foundation

// MARK: - Animatable 48-Bin Vector for Native Metal/CoreAnimation Curve Interpolation (0 timers, 0 fake motion)
private struct HistogramAnimatableVector: VectorArithmetic, Equatable {
    var values: [Double]

    static var zero: HistogramAnimatableVector {
        HistogramAnimatableVector(values: Array(repeating: 0.0, count: HistogramTelemetry.binCount))
    }

    init(values: [Double]) {
        self.values = values
    }

    init(floats: [Float]) {
        self.values = floats.map(Double.init)
    }

    mutating func scale(by rhs: Double) {
        for i in values.indices { values[i] *= rhs }
    }

    var magnitudeSquared: Double {
        var sum = 0.0
        for v in values { sum += v * v }
        return sum
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        let n = max(lhs.values.count, rhs.values.count)
        var out = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let a = i < lhs.values.count ? lhs.values[i] : 0.0
            let b = i < rhs.values.count ? rhs.values[i] : 0.0
            out[i] = a + b
        }
        return HistogramAnimatableVector(values: out)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        let n = max(lhs.values.count, rhs.values.count)
        var out = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let a = i < lhs.values.count ? lhs.values[i] : 0.0
            let b = i < rhs.values.count ? rhs.values[i] : 0.0
            out[i] = a - b
        }
        return HistogramAnimatableVector(values: out)
    }
}

private struct SmoothHistogramCurveShape: Shape {
    var data: HistogramAnimatableVector
    var closedFill: Bool

    var animatableData: HistogramAnimatableVector {
        get { data }
        set { data = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let vals = data.values
        let n = vals.count
        guard n >= 2, rect.width > 1, rect.height > 1 else { return Path() }

        let stepX = rect.width / CGFloat(n - 1)
        let usableH = max(2.0, rect.height - 2.0)

        var points: [CGPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let x = rect.minX + CGFloat(i) * stepX
            let v = CGFloat(max(0.02, min(1.0, vals[i])))
            let y = rect.maxY - v * usableH
            points.append(CGPoint(x: x, y: y))
        }

        var path = Path()
        if closedFill {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: points[0])
        } else {
            path.move(to: points[0])
        }

        // Quadratic midpoint spline (không overshoot âm, siêu mượt trên GPU)
        for i in 1..<n {
            let prev = points[i - 1]
            let curr = points[i]
            let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: points[n - 1])
        if closedFill {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Compact Top-Bar Real Rec.709 RGB + Luma Histogram Meter (Kèm báo Cháy sáng & Noise không che khung hình)
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
        let borderAlertColor: Color = telemetry.isHighlightClipping
            ? AlignTheme.studioRecordRed.opacity(telemetry.isSevereHighlightClipping ? 0.85 : 0.55)
            : (telemetry.isHighNoise ? AlignTheme.studioAccent.opacity(0.65) : Color.clear)

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

                // Dải đỏ mép phải báo cháy sáng trực tiếp trên thanh histogram (không che viewfinder)
                if telemetry.isHighlightClipping {
                    HStack {
                        Spacer()
                        Rectangle()
                            .fill(AlignTheme.studioRecordRed.opacity(telemetry.isSevereHighlightClipping ? 0.95 : 0.72))
                            .frame(width: telemetry.isSevereHighlightClipping ? 2.5 : 1.8, height: 22)
                    }
                    .frame(width: width, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // Nhãn siêu gọn ở 2 góc trên bên trong thanh histogram: NS (Nhiễu cao) | HI (Cháy sáng)
                HStack(spacing: 2) {
                    if telemetry.isHighNoise {
                        Text("NS")
                            .font(.system(size: 6.5, weight: .black, design: .monospaced))
                            .foregroundColor(Color.black)
                            .padding(.horizontal, 2.5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(AlignTheme.studioAccent.opacity(0.92)))
                    } else if telemetry.isShadowClipping {
                        Circle()
                            .fill(Self.studioBlueChannel)
                            .frame(width: 3.5, height: 3.5)
                    }
                    Spacer(minLength: 0)
                    if telemetry.isHighlightClipping {
                        Text("HI")
                            .font(.system(size: 6.5, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 2.5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(AlignTheme.studioRecordRed.opacity(0.94)))
                    }
                }
                .padding(.horizontal, 1.5)
                .padding(.top, 1.5)
                .frame(width: width, height: 22, alignment: .top)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderAlertColor, lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(for: telemetry))
    }

    private func accessibilitySummary(for t: HistogramTelemetry) -> String {
        var parts = [
            "Biểu đồ ánh sáng RGB, trung bình \(Int(round(t.averageLuminance * 100))) phần trăm"
        ]
        if t.isHighlightClipping {
            parts.append("cảnh báo cháy sáng \(Int(round(t.highlightClipRatio * 100))) phần trăm")
        }
        if t.isHighNoise {
            parts.append("cảnh báo nhiễu cao")
        }
        parts.append("Chạm để mở rộng hoặc thu gọn")
        return parts.joined(separator: ", ")
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
        let noisePct = Int(round(t.noiseLevel * 100))

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

            // Vùng vẽ sóng RGB + Luma 48 bins độ nét cao nội suy mượt
            ProHistogramWaveformCanvas(telemetry: t, showZoneTicks: true, showRGBChannels: true, isExpanded: true)
                .frame(height: 46)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )

            // Dòng thông số thực: Bết tối (SH) | Trung bình (AVG) | Cháy sáng (HI) | Nhiễu (NS)
            HStack(spacing: 0) {
                metricCell(
                    label: "SH",
                    value: String(format: "%.0f%%", shPct),
                    accent: t.isShadowClipping ? LiveColorHistogramHUDView.studioBlueChannel : AlignTheme.studioInkSecondary
                )
                Spacer(minLength: 3)
                metricCell(
                    label: "AVG",
                    value: "\(avgPct)%",
                    accent: AlignTheme.studioInkPrimary
                )
                Spacer(minLength: 3)
                metricCell(
                    label: "HI",
                    value: String(format: "%.1f%%", hiPct),
                    accent: t.isHighlightClipping ? AlignTheme.studioRecordRed : AlignTheme.studioInkSecondary
                )
                Spacer(minLength: 3)
                metricCell(
                    label: "NS",
                    value: "\(noisePct)%",
                    accent: t.isHighNoise ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary
                )
            }

            // Cảnh báo gọn nằm trọn trong thẻ scope (chỉ hiện khi thật sự cháy sáng hoặc nhiễu cao)
            if t.isHighlightClipping || t.isHighNoise {
                HStack(spacing: 4) {
                    if t.isHighlightClipping {
                        HStack(spacing: 2.5) {
                            Circle().fill(AlignTheme.studioRecordRed).frame(width: 4.5, height: 4.5)
                            Text(t.isSevereHighlightClipping ? "Cháy sáng mạnh" : "Cháy sáng")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioRecordRed)
                        }
                    }
                    if t.isHighlightClipping && t.isHighNoise {
                        Text("·")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(AlignTheme.studioInkTertiary)
                    }
                    if t.isHighNoise {
                        HStack(spacing: 2.5) {
                            Circle().fill(AlignTheme.studioAccent).frame(width: 4.5, height: 4.5)
                            Text(t.sensorISO >= 1000 ? "Nhiễu · ISO \(Int(round(t.sensorISO)))" : "Nhiễu cao")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioAccent)
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 178)
        .background(StudioGlassRoundedSurface(cornerRadius: 14, tintOpacity: 0.64, borderOpacity: 0.16))
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 4)
    }

    private func metricCell(label: String, value: String, accent: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkTertiary)
            Text(value)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(accent)
        }
    }
}

// MARK: - High-Precision 48-Bin Rec.709 RGB + Luma Animatable Scope
struct ProHistogramWaveformCanvas: View {
    let telemetry: HistogramTelemetry
    var showZoneTicks: Bool = true
    var showRGBChannels: Bool = true
    var isExpanded: Bool = false

    var body: some View {
        ZStack {
            // 1. Vạch chia vùng phơi sáng tĩnh (không vẽ lại mỗi frame)
            if showZoneTicks {
                GeometryReader { geo in
                    let divisions = isExpanded ? 5 : 3
                    Path { path in
                        for idx in 1..<divisions {
                            let x = geo.size.width * CGFloat(idx) / CGFloat(divisions)
                            path.move(to: CGPoint(x: x, y: 1))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        }
                    }
                    .stroke(Color.white.opacity(isExpanded ? 0.10 : 0.08), lineWidth: 0.5)
                }
            }

            // 2. Các kênh R / G / B & Luma nội suy mượt trên GPU (Animatable Shape, không dùng Timer)
            ZStack {
                if showRGBChannels {
                    curveLayer(
                        values: telemetry.blue,
                        fillTop: LiveColorHistogramHUDView.studioBlueChannel.opacity(isExpanded ? 0.30 : 0.24),
                        fillBottom: LiveColorHistogramHUDView.studioBlueChannel.opacity(0.02),
                        stroke: LiveColorHistogramHUDView.studioBlueChannel.opacity(isExpanded ? 0.78 : 0.62),
                        lineWidth: isExpanded ? 0.85 : 0.65
                    )
                    curveLayer(
                        values: telemetry.green,
                        fillTop: LiveColorHistogramHUDView.studioGreenChannel.opacity(isExpanded ? 0.28 : 0.22),
                        fillBottom: LiveColorHistogramHUDView.studioGreenChannel.opacity(0.02),
                        stroke: LiveColorHistogramHUDView.studioGreenChannel.opacity(isExpanded ? 0.76 : 0.60),
                        lineWidth: isExpanded ? 0.85 : 0.65
                    )
                    curveLayer(
                        values: telemetry.red,
                        fillTop: LiveColorHistogramHUDView.studioRedChannel.opacity(isExpanded ? 0.30 : 0.24),
                        fillBottom: LiveColorHistogramHUDView.studioRedChannel.opacity(0.02),
                        stroke: LiveColorHistogramHUDView.studioRedChannel.opacity(isExpanded ? 0.78 : 0.64),
                        lineWidth: isExpanded ? 0.85 : 0.65
                    )
                }

                curveLayer(
                    values: telemetry.luma,
                    fillTop: Color.white.opacity(isExpanded ? 0.22 : 0.24),
                    fillBottom: Color.white.opacity(0.02),
                    stroke: AlignTheme.studioInkPrimary.opacity(0.90),
                    lineWidth: isExpanded ? 1.1 : 0.95
                )
            }
            .animation(.linear(duration: 0.10), value: telemetry)

            // 3. Vạch cảnh báo clipping sát mép phải/trái khi mở rộng
            if isExpanded {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(LiveColorHistogramHUDView.studioBlueChannel.opacity(telemetry.isShadowClipping ? 0.85 : 0.0))
                        .frame(width: 2.0)
                    Spacer()
                    Rectangle()
                        .fill(AlignTheme.studioRecordRed.opacity(telemetry.isHighlightClipping ? 0.92 : 0.0))
                        .frame(width: 2.0)
                }
            }
        }
    }

    @ViewBuilder
    private func curveLayer(
        values: [Float],
        fillTop: Color,
        fillBottom: Color,
        stroke: Color,
        lineWidth: CGFloat
    ) -> some View {
        let vec = HistogramAnimatableVector(floats: values)
        ZStack {
            SmoothHistogramCurveShape(data: vec, closedFill: true)
                .fill(
                    LinearGradient(
                        colors: [fillTop, fillBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            SmoothHistogramCurveShape(data: vec, closedFill: false)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Cảnh báo Cháy sáng / Bết tối / Nhiễu dạng viên thuốc (chỉ hiện khi có cảnh báo thật)
public struct HistogramAlertPillView: View {
    @ObservedObject var viewModel: CameraViewModel
    let expandsOnTap: Bool

    public init(viewModel: CameraViewModel, expandsOnTap: Bool) {
        self.viewModel = viewModel
        self.expandsOnTap = expandsOnTap
    }

    public var body: some View {
        let t = viewModel.histogramTelemetry
        let hasAlert = t.isHighlightClipping || t.isShadowClipping || t.isHighNoise
        Group {
            if hasAlert {
                Button(action: {
                    guard expandsOnTap else { return }
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        viewModel.isHistogramBarExpanded = true
                    }
                }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(t.isHighlightClipping ? AlignTheme.studioRecordRed
                                  : (t.isShadowClipping ? LiveColorHistogramHUDView.studioBlueChannel : AlignTheme.studioAccent))
                            .frame(width: 5, height: 5)
                        Text(Self.label(for: t))
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(StudioGlassRoundedSurface(cornerRadius: 11, tintOpacity: 0.64, borderOpacity: 0.16))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hasAlert)
    }

    private static func label(for t: HistogramTelemetry) -> String {
        var parts: [String] = []
        if t.isHighlightClipping { parts.append(t.isSevereHighlightClipping ? "Cháy sáng mạnh" : "Cháy sáng") }
        if t.isShadowClipping { parts.append("Bết tối") }
        if t.isHighNoise { parts.append(t.sensorISO >= 1000 ? "Nhiễu · ISO \(Int(round(t.sensorISO)))" : "Nhiễu cao") }
        return parts.joined(separator: " · ")
    }
}
