import SwiftUI
import UIKit

// MARK: - Live Mini Luminance Histogram (Compact Top Header Indicator)
public struct PhotoDarkroomMiniHistogramView: View {
    public let histogram: PhotoDarkroomHistogram

    public init(histogram: PhotoDarkroomHistogram) {
        self.histogram = histogram
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bins = histogram.lumaBins
            ZStack {
                Path { path in
                    guard bins.count >= 2 else { return }
                    let stepX = w / CGFloat(bins.count - 1)
                    path.move(to: CGPoint(x: 0, y: h))
                    for (idx, val) in bins.enumerated() {
                        let clamped = CGFloat(min(1.0, max(0.02, val)))
                        path.addLine(to: CGPoint(x: CGFloat(idx) * stepX, y: h * (1.0 - clamped)))
                    }
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(0.32))

                Path { path in
                    guard bins.count >= 2 else { return }
                    let stepX = w / CGFloat(bins.count - 1)
                    for (idx, val) in bins.enumerated() {
                        let clamped = CGFloat(min(1.0, max(0.02, val)))
                        let pt = CGPoint(x: CGFloat(idx) * stepX, y: h * (1.0 - clamped))
                        if idx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                }
                .stroke(Color.white.opacity(0.82), lineWidth: 0.9)
            }
        }
        .frame(width: 54, height: 18)
    }
}

// MARK: - Floating Active Look Capsule Pill (Bottom-Left Over Photo)
public struct PhotoDarkroomLookBadgePill: View {
    public let title: String
    public let action: () -> Void

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundColor(AlignTheme.studioInkPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(StudioGlassCapsule(tintOpacity: 0.62, borderOpacity: 0.16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Precision Tick-Ruler Slider (Smooth 120Hz Scrubbing + Zero Haptic + Double-Tap Reset)
public struct StudioPrecisionTickSlider: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let step: Double
    public let accentColor: Color
    public let onDragChanged: (Double) -> Void
    public let onDragEnded: () -> Void

    @State private var isDragging: Bool = false
    @State private var lastCrossedDefault: Bool = false

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        defaultValue: Double = 0.0,
        step: Double = 0.01,
        accentColor: Color = AlignTheme.studioAccent,
        onDragChanged: @escaping (Double) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.step = step
        self.accentColor = accentColor
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let span = max(1e-6, range.upperBound - range.lowerBound)
            let norm = CGFloat((value - range.lowerBound) / span)
            let defNorm = CGFloat((defaultValue - range.lowerBound) / span)
            let thumbX = min(width, max(0, norm * width))
            let defX = min(width, max(0, defNorm * width))
            let tickCount = 31

            ZStack(alignment: .leading) {
                // Subtle fine tick marks (Leica / Darkroom precision scale)
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { idx in
                        let isMajor = idx % 5 == 0
                        Rectangle()
                            .fill(Color.white.opacity(isMajor ? 0.30 : 0.13))
                            .frame(width: 1, height: isMajor ? 10 : 6)
                        if idx < tickCount - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(height: 16)

                // Track base
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 2.5)

                // Active span between defaultValue and current value
                let segMinX = min(defX, thumbX)
                let segWidth = max(2, abs(thumbX - defX))
                Capsule()
                    .fill(accentColor)
                    .frame(width: segWidth, height: 3.0)
                    .offset(x: segMinX)

                // Default / zero anchor dot
                if defaultValue > range.lowerBound && defaultValue < range.upperBound {
                    Circle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 4.5, height: 4.5)
                        .position(x: defX, y: geo.size.height * 0.5)
                }

                // Precision circular thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging ? 20 : 17, height: isDragging ? 20 : 17)
                    .shadow(color: Color.black.opacity(0.55), radius: 3, y: 1)
                    .overlay(
                        Circle()
                            .stroke(accentColor.opacity(isDragging ? 0.9 : 0.0), lineWidth: 2)
                    )
                    .position(x: thumbX, y: geo.size.height * 0.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            lastCrossedDefault = abs(value - defaultValue) < step * 1.5
                        }
                        let rawNorm = min(1.0, max(0.0, Double(gesture.location.x / width)))
                        var nextVal = range.lowerBound + rawNorm * span
                        // Gentle magnetic snap to default value when dragging past center
                        let snapBand = span * 0.018
                        if abs(nextVal - defaultValue) < snapBand {
                            nextVal = defaultValue
                            if !lastCrossedDefault {
                                lastCrossedDefault = true
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        } else {
                            lastCrossedDefault = false
                        }
                        if step > 0 {
                            nextVal = (nextVal / step).rounded() * step
                        }
                        nextVal = min(range.upperBound, max(range.lowerBound, nextVal))
                        if abs(nextVal - value) >= step * 0.45 {
                            value = nextVal
                            onDragChanged(nextVal)
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                    }
            )
            .onTapGesture(count: 2) {
                value = defaultValue
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onDragChanged(defaultValue)
                onDragEnded()
            }
        }
        .frame(height: 30)
    }
}

// MARK: - Interactive 5-Point Tone Curves Canvas (RGB / Red / Green / Blue)
public struct PhotoCurvesEditorView: View {
    @Binding public var curves: PhotoCurvesState
    @Binding public var selectedChannel: PhotoCurveChannel
    public let histogram: PhotoDarkroomHistogram
    public let onCurveChanged: () -> Void
    public let onCurveCommitted: () -> Void

    @State private var activePointIndex: Int? = nil

    public init(
        curves: Binding<PhotoCurvesState>,
        selectedChannel: Binding<PhotoCurveChannel>,
        histogram: PhotoDarkroomHistogram,
        onCurveChanged: @escaping () -> Void,
        onCurveCommitted: @escaping () -> Void
    ) {
        self._curves = curves
        self._selectedChannel = selectedChannel
        self.histogram = histogram
        self.onCurveChanged = onCurveChanged
        self.onCurveCommitted = onCurveCommitted
    }

    private var channelColor: Color {
        switch selectedChannel {
        case .rgb: return .white
        case .red: return Color(red: 0.96, green: 0.34, blue: 0.32)
        case .green: return Color(red: 0.30, green: 0.86, blue: 0.48)
        case .blue: return Color(red: 0.34, green: 0.64, blue: 1.00)
        }
    }

    private var activeHistogramBins: [Double] {
        switch selectedChannel {
        case .rgb: return histogram.lumaBins
        case .red: return histogram.redBins
        case .green: return histogram.greenBins
        case .blue: return histogram.blueBins
        }
    }

    public var body: some View {
        VStack(spacing: 10) {
            // Channel Switcher Pills + Reset Channel
            HStack(spacing: 6) {
                ForEach(PhotoCurveChannel.allCases) { channel in
                    let selected = selectedChannel == channel
                    let modified = !curves[channel].isIdentity
                    Button(action: { selectedChannel = channel }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(dotColor(for: channel))
                                .frame(width: 6.5, height: 6.5)
                            Text(channel.rawValue)
                                .font(.system(size: 11, weight: selected ? .bold : .medium, design: .rounded))
                            if modified {
                                Circle()
                                    .fill(AlignTheme.studioAccent)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .foregroundColor(selected ? .black : .white.opacity(0.80))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(selected ? Color.white : AlignTheme.studioElevated)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if !curves[selectedChannel].isIdentity {
                    Button("Đặt lại kênh") {
                        curves[selectedChannel] = .linear
                        onCurveChanged()
                        onCurveCommitted()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioAccent)
                    .buttonStyle(.plain)
                }
            }

            // Interactive Graph Box
            GeometryReader { geo in
                let size = geo.size
                let activeCurve = curves[selectedChannel]
                let lut = activeCurve.buildLUT(samples: 64)

                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.45))

                    // Subtle 4x4 grid + diagonal identity reference
                    Path { path in
                        for i in 1...3 {
                            let fx = size.width * CGFloat(i) / 4.0
                            let fy = size.height * CGFloat(i) / 4.0
                            path.move(to: CGPoint(x: fx, y: 0))
                            path.addLine(to: CGPoint(x: fx, y: size.height))
                            path.move(to: CGPoint(x: 0, y: fy))
                            path.addLine(to: CGPoint(x: size.width, y: fy))
                        }
                    }
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.7)

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        path.addLine(to: CGPoint(x: size.width, y: 0))
                    }
                    .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))

                    // Live histogram backdrop for active channel
                    Path { path in
                        let bins = activeHistogramBins
                        guard bins.count >= 2 else { return }
                        let stepX = size.width / CGFloat(bins.count - 1)
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (idx, val) in bins.enumerated() {
                            path.addLine(to: CGPoint(
                                x: CGFloat(idx) * stepX,
                                y: size.height * (1.0 - CGFloat(min(1.0, max(0.0, val))) * 0.72)
                            ))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(channelColor.opacity(0.16))

                    // Monotone Cubic Spline Curve
                    Path { path in
                        guard lut.count >= 2 else { return }
                        let stepX = size.width / CGFloat(lut.count - 1)
                        for (idx, yVal) in lut.enumerated() {
                            let pt = CGPoint(x: CGFloat(idx) * stepX, y: size.height * (1.0 - CGFloat(yVal)))
                            if idx == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                    }
                    .stroke(channelColor, style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

                    // 5 Draggable Control Points
                    ForEach(0..<activeCurve.points.count, id: \.self) { idx in
                        let pt = activeCurve.points[idx]
                        let isDraggingThis = activePointIndex == idx
                        Circle()
                            .fill(isDraggingThis ? channelColor : AlignTheme.studioCanvas)
                            .frame(width: isDraggingThis ? 16 : 12, height: isDraggingThis ? 16 : 12)
                            .overlay(
                                Circle()
                                    .stroke(channelColor, lineWidth: 2.0)
                            )
                            .position(
                                x: CGFloat(pt.x) * size.width,
                                y: (1.0 - CGFloat(pt.y)) * size.height
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let nx = min(1.0, max(0.0, Double(gesture.location.x / max(1, size.width))))
                            let ny = min(1.0, max(0.0, 1.0 - Double(gesture.location.y / max(1, size.height))))
                            var curve = curves[selectedChannel]
                            let chosenIndex: Int
                            if let existing = activePointIndex {
                                chosenIndex = existing
                            } else {
                                // Select nearest of the 5 control handles
                                var bestIdx = 0
                                var bestDist = Double.infinity
                                for (i, p) in curve.points.enumerated() {
                                    let d = hypot(p.x - nx, p.y - ny)
                                    if d < bestDist {
                                        bestDist = d
                                        bestIdx = i
                                    }
                                }
                                activePointIndex = bestIdx
                                chosenIndex = bestIdx
                            }
                            guard chosenIndex >= 0, chosenIndex < curve.points.count else { return }
                            // Keep endpoint X locked to 0 / 1; interior points constrained cleanly between neighbors
                            let newX: Double
                            if chosenIndex == 0 {
                                newX = 0.0
                            } else if chosenIndex == curve.points.count - 1 {
                                newX = 1.0
                            } else {
                                let minX = curve.points[chosenIndex - 1].x + 0.08
                                let maxX = curve.points[chosenIndex + 1].x - 0.08
                                newX = min(maxX, max(minX, nx))
                            }
                            curve.points[chosenIndex] = PhotoCurvePoint(x: newX, y: ny)
                            curves[selectedChannel] = curve
                            onCurveChanged()
                        }
                        .onEnded { _ in
                            activePointIndex = nil
                            onCurveCommitted()
                        }
                )
            }
            .frame(height: 122)
        }
    }

    private func dotColor(for channel: PhotoCurveChannel) -> Color {
        switch channel {
        case .rgb: return .white
        case .red: return Color(red: 0.96, green: 0.34, blue: 0.32)
        case .green: return Color(red: 0.30, green: 0.86, blue: 0.48)
        case .blue: return Color(red: 0.34, green: 0.64, blue: 1.00)
        }
    }
}

// MARK: - Interactive Crop Frame Overlay Directly On Hero Photo
public struct PhotoInteractiveCropOverlayView: View {
    @Binding public var cropState: PhotoCropState
    public let imageSize: CGSize
    public let viewportSize: CGSize
    public let onCommit: (PhotoCropState) -> Void

    @State private var dragStartRect: CGRect? = nil
    @State private var dragStartCropState: PhotoCropState? = nil

    public init(
        cropState: Binding<PhotoCropState>,
        imageSize: CGSize,
        viewportSize: CGSize,
        onCommit: @escaping (PhotoCropState) -> Void
    ) {
        self._cropState = cropState
        self.imageSize = imageSize
        self.viewportSize = viewportSize
        self.onCommit = onCommit
    }

    private var fittedImageFrame: CGRect {
        let imgW = max(1, imageSize.width)
        let imgH = max(1, imageSize.height)
        let imgAspect = imgW / imgH
        let vpW = max(1, viewportSize.width - 28)
        let vpH = max(1, viewportSize.height - 28)
        let vpAspect = vpW / vpH
        let fitW = (vpAspect > imgAspect) ? (vpH * imgAspect) : vpW
        let fitH = (vpAspect > imgAspect) ? vpH : (vpW / imgAspect)
        return CGRect(
            x: (viewportSize.width - fitW) * 0.5,
            y: (viewportSize.height - fitH) * 0.5,
            width: fitW,
            height: fitH
        )
    }

    private var lockedAspect: Double? {
        if let fixed = cropState.aspectRatio.numericRatio { return fixed }
        if cropState.aspectRatio == .original {
            return Double(max(1, imageSize.width) / max(1, imageSize.height))
        }
        return nil
    }

    public var body: some View {
        let imgFrame = fittedImageFrame
        let nr = cropState.normalizedRect
        let boxRect = CGRect(
            x: imgFrame.minX + nr.minX * imgFrame.width,
            y: imgFrame.minY + nr.minY * imgFrame.height,
            width: nr.width * imgFrame.width,
            height: nr.height * imgFrame.height
        )

        ZStack {
            // Dimmed outer scrim outside the crop box
            Path { path in
                path.addRect(CGRect(origin: .zero, size: viewportSize))
                path.addRect(boxRect)
            }
            .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Draggable interior area to pan crop window
            Rectangle()
                .fill(Color.clear)
                .frame(width: max(20, boxRect.width), height: max(20, boxRect.height))
                .position(x: boxRect.midX, y: boxRect.midY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { val in
                            if dragStartCropState == nil { dragStartCropState = cropState }
                            let start = dragStartRect ?? cropState.normalizedRect
                            if dragStartRect == nil { dragStartRect = start }
                            let dx = val.translation.width / max(1, imgFrame.width)
                            let dy = val.translation.height / max(1, imgFrame.height)
                            let nx = min(1.0 - start.width, max(0.0, start.origin.x + dx))
                            let ny = min(1.0 - start.height, max(0.0, start.origin.y + dy))
                            cropState.normalizedRect = CGRect(x: nx, y: ny, width: start.width, height: start.height)
                        }
                        .onEnded { _ in
                            let before = dragStartCropState ?? cropState
                            dragStartRect = nil
                            dragStartCropState = nil
                            onCommit(before)
                        }
                )

            // Rule of Thirds grid lines + border
            Path { path in
                path.addRect(boxRect)
                for i in 1...2 {
                    let gx = boxRect.minX + boxRect.width * CGFloat(i) / 3.0
                    let gy = boxRect.minY + boxRect.height * CGFloat(i) / 3.0
                    path.move(to: CGPoint(x: gx, y: boxRect.minY))
                    path.addLine(to: CGPoint(x: gx, y: boxRect.maxY))
                    path.move(to: CGPoint(x: boxRect.minX, y: gy))
                    path.addLine(to: CGPoint(x: boxRect.maxX, y: gy))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
            .allowsHitTesting(false)

            // 4 Interactive L-Shaped Corner Handles
            cornerHandle(corner: .topLeft, boxRect: boxRect, imgFrame: imgFrame)
            cornerHandle(corner: .topRight, boxRect: boxRect, imgFrame: imgFrame)
            cornerHandle(corner: .bottomLeft, boxRect: boxRect, imgFrame: imgFrame)
            cornerHandle(corner: .bottomRight, boxRect: boxRect, imgFrame: imgFrame)
        }
    }

    private enum CropCorner { case topLeft, topRight, bottomLeft, bottomRight }

    @ViewBuilder
    private func cornerHandle(corner: CropCorner, boxRect: CGRect, imgFrame: CGRect) -> some View {
        let pt: CGPoint = {
            switch corner {
            case .topLeft: return CGPoint(x: boxRect.minX, y: boxRect.minY)
            case .topRight: return CGPoint(x: boxRect.maxX, y: boxRect.minY)
            case .bottomLeft: return CGPoint(x: boxRect.minX, y: boxRect.maxY)
            case .bottomRight: return CGPoint(x: boxRect.maxX, y: boxRect.maxY)
            }
        }()

        ZStack {
            Color.clear.frame(width: 40, height: 40)
            Path { path in
                let len: CGFloat = 18
                switch corner {
                case .topLeft:
                    path.move(to: CGPoint(x: 20, y: 20 + len))
                    path.addLine(to: CGPoint(x: 20, y: 20))
                    path.addLine(to: CGPoint(x: 20 + len, y: 20))
                case .topRight:
                    path.move(to: CGPoint(x: 20 - len, y: 20))
                    path.addLine(to: CGPoint(x: 20, y: 20))
                    path.addLine(to: CGPoint(x: 20, y: 20 + len))
                case .bottomLeft:
                    path.move(to: CGPoint(x: 20, y: 20 - len))
                    path.addLine(to: CGPoint(x: 20, y: 20))
                    path.addLine(to: CGPoint(x: 20 + len, y: 20))
                case .bottomRight:
                    path.move(to: CGPoint(x: 20 - len, y: 20))
                    path.addLine(to: CGPoint(x: 20, y: 20))
                    path.addLine(to: CGPoint(x: 20, y: 20 - len))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.0, lineCap: .square))
        }
        .position(pt)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { val in
                    if dragStartCropState == nil { dragStartCropState = cropState }
                    let start = dragStartRect ?? cropState.normalizedRect
                    if dragStartRect == nil { dragStartRect = start }
                    let dx = val.translation.width / max(1, imgFrame.width)
                    let dy = val.translation.height / max(1, imgFrame.height)
                    cropState.normalizedRect = resizedRect(from: start, corner: corner, dx: dx, dy: dy, imgFrame: imgFrame)
                }
                .onEnded { _ in
                    let before = dragStartCropState ?? cropState
                    dragStartRect = nil
                    dragStartCropState = nil
                    onCommit(before)
                }
        )
    }

    private func resizedRect(from start: CGRect, corner: CropCorner, dx: CGFloat, dy: CGFloat, imgFrame: CGRect) -> CGRect {
        let minSide: CGFloat = 0.16
        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY

        switch corner {
        case .topLeft:
            minX = min(maxX - minSide, max(0, start.minX + dx))
            minY = min(maxY - minSide, max(0, start.minY + dy))
        case .topRight:
            maxX = max(minX + minSide, min(1, start.maxX + dx))
            minY = min(maxY - minSide, max(0, start.minY + dy))
        case .bottomLeft:
            minX = min(maxX - minSide, max(0, start.minX + dx))
            maxY = max(minY + minSide, min(1, start.maxY + dy))
        case .bottomRight:
            maxX = max(minX + minSide, min(1, start.maxX + dx))
            maxY = max(minY + minSide, min(1, start.maxY + dy))
        }

        if let targetRatio = lockedAspect {
            let imgAspect = Double(imgFrame.width / max(1, imgFrame.height))
            let desiredNormWOverH = CGFloat(targetRatio / max(0.05, imgAspect))
            var w = max(minSide, maxX - minX)
            var h = w / max(0.05, desiredNormWOverH)

            if h < minSide {
                h = minSide
                w = h * desiredNormWOverH
            }

            switch corner {
            case .topLeft:
                let maxAvailW = maxX
                let maxAvailH = maxY
                let scale = min(1.0, min(maxAvailW / max(1e-4, w), maxAvailH / max(1e-4, h)))
                w *= scale; h *= scale
                minX = maxX - w; minY = maxY - h
            case .topRight:
                let maxAvailW = 1.0 - minX
                let maxAvailH = maxY
                let scale = min(1.0, min(maxAvailW / max(1e-4, w), maxAvailH / max(1e-4, h)))
                w *= scale; h *= scale
                maxX = minX + w; minY = maxY - h
            case .bottomLeft:
                let maxAvailW = maxX
                let maxAvailH = 1.0 - minY
                let scale = min(1.0, min(maxAvailW / max(1e-4, w), maxAvailH / max(1e-4, h)))
                w *= scale; h *= scale
                minX = maxX - w; maxY = minY + h
            case .bottomRight:
                let maxAvailW = 1.0 - minX
                let maxAvailH = 1.0 - minY
                let scale = min(1.0, min(maxAvailW / max(1e-4, w), maxAvailH / max(1e-4, h)))
                w *= scale; h *= scale
                maxX = minX + w; maxY = minY + h
            }
        }
        return CGRect(x: minX, y: minY, width: max(minSide, maxX - minX), height: max(minSide, maxY - minY))
    }
}

// MARK: - Lazy Live-Rendered Look / Recipe Thumbnail Card
public struct PhotoDarkroomLiveThumbCard: View {
    public let title: String
    public let badge: String?
    public let cacheKey: String
    public let previewState: PhotoDarkroomEditState
    public let fallbackOriginal: CGImage
    public let coordinator: PhotoDarkroomSessionCoordinator
    public let isSelected: Bool
    public let isFavorited: Bool
    public let showSelectedSlidersOverlay: Bool
    public let onTap: () -> Void
    public let onToggleFavorite: () -> Void
    public let onDeleteCustom: (() -> Void)?

    @State private var renderedThumb: UIImage? = nil

    public init(
        title: String,
        badge: String? = nil,
        cacheKey: String,
        previewState: PhotoDarkroomEditState,
        fallbackOriginal: CGImage,
        coordinator: PhotoDarkroomSessionCoordinator,
        isSelected: Bool,
        isFavorited: Bool,
        showSelectedSlidersOverlay: Bool = true,
        onTap: @escaping () -> Void,
        onToggleFavorite: @escaping () -> Void,
        onDeleteCustom: (() -> Void)? = nil
    ) {
        self.title = title
        self.badge = badge
        self.cacheKey = cacheKey
        self.previewState = previewState
        self.fallbackOriginal = fallbackOriginal
        self.coordinator = coordinator
        self.isSelected = isSelected
        self.isFavorited = isFavorited
        self.showSelectedSlidersOverlay = showSelectedSlidersOverlay
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
        self.onDeleteCustom = onDeleteCustom
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    if let thumb = renderedThumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 62, height: 62)
                            .clipped()
                    } else {
                        AlignTheme.studioElevated
                            .frame(width: 62, height: 62)
                    }

                    if isSelected && showSelectedSlidersOverlay {
                        Color.black.opacity(0.42)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    // Favorite indicator heart top-right
                    if isFavorited {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(AlignTheme.studioAccent)
                                    .padding(4)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                                    .padding(3)
                            }
                            Spacer()
                        }
                    }

                    // Optional subtle film badge bottom-left when unselected
                    if !isSelected, let badge, !badge.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Text(badge)
                                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.92))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1.5)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.58)))
                                    .padding(3)
                                Spacer()
                            }
                        }
                    }
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.white : AlignTheme.studioHairline, lineWidth: isSelected ? 1.8 : 0.7)
                )

                Text(title.uppercased())
                    .font(.system(size: 9.2, weight: isSelected ? .bold : .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundColor(isSelected ? .white : AlignTheme.studioInkSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 66, height: 24, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onToggleFavorite) {
                Label(isFavorited ? "Bỏ khỏi Yêu thích" : "Thêm vào Yêu thích", systemImage: isFavorited ? "heart.slash" : "heart")
            }
            if let onDeleteCustom {
                Button(role: .destructive, action: onDeleteCustom) {
                    Label("Xóa công thức", systemImage: "trash")
                }
            }
        }
        .onAppear {
            if renderedThumb == nil {
                coordinator.requestThumbnail(
                    cacheKey: cacheKey,
                    fallbackOriginal: fallbackOriginal,
                    state: previewState
                ) { img in
                    self.renderedThumb = img
                }
            }
        }
    }
}

// MARK: - Complete Darkroom Studio Bottom Deck (Looks · Effects · Tools)
public struct PhotoDarkroomStudioDeckView: View {
    @Binding public var editState: PhotoDarkroomEditState
    @Binding public var activeMainTab: PhotoDarkroomMainTab
    @Binding public var activeLooksSubTab: PhotoLooksSubTab
    @Binding public var selectedEffect: PhotoEffectKind?
    @Binding public var selectedTool: PhotoToolKind?
    @Binding public var isTuningFilmIntensity: Bool
    @Binding public var selectedHSLChannel: PhotoHSLColorChannel
    @Binding public var selectedCurveChannel: PhotoCurveChannel

    public let originalImage: CGImage
    public let currentImageSize: CGSize
    public let coordinator: PhotoDarkroomSessionCoordinator
    public let histogram: PhotoDarkroomHistogram
    public let customRecipes: [PhotoDarkroomRecipe]
    public let favoriteFilmRawValues: Set<String>
    public let favoriteRecipeIDs: Set<String>

    public let onLiveChange: () -> Void
    public let onCommitChange: (PhotoDarkroomEditState) -> Void
    public let onOpenCatalogSheet: () -> Void
    public let onOpenNewRecipeSheet: () -> Void
    public let onToggleFavoriteFilm: (String) -> Void
    public let onToggleFavoriteRecipe: (String) -> Void
    public let onDeleteCustomRecipe: (String) -> Void
    public let onToggleAIEnhance: () -> Void

    @State private var dragStartState: PhotoDarkroomEditState? = nil

    public init(
        editState: Binding<PhotoDarkroomEditState>,
        activeMainTab: Binding<PhotoDarkroomMainTab>,
        activeLooksSubTab: Binding<PhotoLooksSubTab>,
        selectedEffect: Binding<PhotoEffectKind?>,
        selectedTool: Binding<PhotoToolKind?>,
        isTuningFilmIntensity: Binding<Bool>,
        selectedHSLChannel: Binding<PhotoHSLColorChannel>,
        selectedCurveChannel: Binding<PhotoCurveChannel>,
        originalImage: CGImage,
        currentImageSize: CGSize,
        coordinator: PhotoDarkroomSessionCoordinator,
        histogram: PhotoDarkroomHistogram,
        customRecipes: [PhotoDarkroomRecipe],
        favoriteFilmRawValues: Set<String>,
        favoriteRecipeIDs: Set<String>,
        onLiveChange: @escaping () -> Void,
        onCommitChange: @escaping (PhotoDarkroomEditState) -> Void,
        onOpenCatalogSheet: @escaping () -> Void,
        onOpenNewRecipeSheet: @escaping () -> Void,
        onToggleFavoriteFilm: @escaping (String) -> Void,
        onToggleFavoriteRecipe: @escaping (String) -> Void,
        onDeleteCustomRecipe: @escaping (String) -> Void,
        onToggleAIEnhance: @escaping () -> Void
    ) {
        self._editState = editState
        self._activeMainTab = activeMainTab
        self._activeLooksSubTab = activeLooksSubTab
        self._selectedEffect = selectedEffect
        self._selectedTool = selectedTool
        self._isTuningFilmIntensity = isTuningFilmIntensity
        self._selectedHSLChannel = selectedHSLChannel
        self._selectedCurveChannel = selectedCurveChannel
        self.originalImage = originalImage
        self.currentImageSize = currentImageSize
        self.coordinator = coordinator
        self.histogram = histogram
        self.customRecipes = customRecipes
        self.favoriteFilmRawValues = favoriteFilmRawValues
        self.favoriteRecipeIDs = favoriteRecipeIDs
        self.onLiveChange = onLiveChange
        self.onCommitChange = onCommitChange
        self.onOpenCatalogSheet = onOpenCatalogSheet
        self.onOpenNewRecipeSheet = onOpenNewRecipeSheet
        self.onToggleFavoriteFilm = onToggleFavoriteFilm
        self.onToggleFavoriteRecipe = onToggleFavoriteRecipe
        self.onDeleteCustomRecipe = onDeleteCustomRecipe
        self.onToggleAIEnhance = onToggleAIEnhance
    }

    private func beginInteractiveDragIfNeeded() {
        if dragStartState == nil {
            dragStartState = editState
        }
    }

    private func commitInteractiveDrag() {
        if let before = dragStartState {
            dragStartState = nil
            onCommitChange(before)
        }
    }

    private func applyImmediateChange(_ mutation: (inout PhotoDarkroomEditState) -> Void) {
        let before = editState
        mutation(&editState)
        onLiveChange()
        onCommitChange(before)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Contextual Precision Adjuster Panel (Opens cleanly above tray when a film/effect/tool is focused)
            if activeMainTab == .looks && isTuningFilmIntensity && editState.presetRawValue != FilmPreset.standard.rawValue {
                filmIntensityInlinePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if activeMainTab == .effects, let eff = selectedEffect {
                effectAdjusterPanel(for: eff)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if activeMainTab == .tools, let tool = selectedTool {
                toolAdjusterPanel(for: tool)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Main Tray Content (Looks / Effects / Tools)
            VStack(spacing: 0) {
                switch activeMainTab {
                case .looks:
                    looksTrayContent
                case .effects:
                    effectsIconStrip
                case .tools:
                    toolsIconStrip
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                AlignTheme.studioSurface
                    .overlay(alignment: .top) {
                        Rectangle().fill(AlignTheme.studioHairlineSubtle).frame(height: 0.7)
                    }
            )

            // Bottom 3-Tab Darkroom Bar (Màu phim · Hiệu ứng · Công cụ)
            HStack(spacing: 0) {
                ForEach(PhotoDarkroomMainTab.allCases) { tab in
                    let isSelected = activeMainTab == tab
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeMainTab = tab
                            if tab != .looks { isTuningFilmIntensity = false }
                            if tab != .effects { selectedEffect = nil }
                            if tab != .tools { selectedTool = nil }
                        }
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                            Text(tab.rawValue.uppercased())
                                .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .monospaced))
                                .tracking(0.6)
                            Circle()
                                .fill(isSelected ? Color.white : Color.clear)
                                .frame(width: 3.5, height: 3.5)
                        }
                        .foregroundColor(isSelected ? .white : AlignTheme.studioInkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 9)
                        .padding(.bottom, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                AlignTheme.studioCanvas
                    .overlay(alignment: .top) {
                        Rectangle().fill(AlignTheme.studioHairlineSubtle).frame(height: 0.6)
                    }
            )
        }
    }

    // MARK: - 1. LOOKS Tray (FILMS · RECIPES · MINE · FAVORITES + ALL Grid)
    private var looksTrayContent: some View {
        VStack(spacing: 11) {
            // 4 Sub-Tab Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PhotoLooksSubTab.allCases) { sub in
                        let selected = activeLooksSubTab == sub
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                activeLooksSubTab = sub
                                isTuningFilmIntensity = false
                            }
                        }) {
                            Text(sub.rawValue)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundColor(selected ? .black : AlignTheme.studioInkPrimary.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(selected ? Color.white : AlignTheme.studioElevated)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            // Active Sub-Tab Horizontal Strip
            switch activeLooksSubTab {
            case .films:
                filmsHorizontalStrip
            case .recipes:
                recipesHorizontalStrip
            case .mine:
                mineRecipesStrip
            case .favorites:
                favoritesStrip
            }
        }
    }

    private var allGridButton: some View {
        Button(action: onOpenCatalogSheet) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AlignTheme.studioElevated)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                    )

                Text("TẤT CẢ")
                    .font(.system(size: 9.2, weight: .medium, design: .monospaced))
                    .tracking(0.3)
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .frame(width: 66, height: 24, alignment: .top)
            }
        }
        .buttonStyle(.plain)
    }

    private var orderedFilmPresets: [FilmPreset] {
        var list: [FilmPreset] = [.standard]
        for p in FilmPreset.selectablePresets where p != .standard && !list.contains(p) {
            list.append(p)
        }
        return list
    }

    private var filmsHorizontalStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                allGridButton

                ForEach(orderedFilmPresets) { preset in
                    let isSelected = editState.activeRecipeID == nil && editState.presetRawValue == preset.rawValue
                    let previewState = PhotoDarkroomEditState(presetRawValue: preset.rawValue, filmIntensity: 1.0)
                    PhotoDarkroomLiveThumbCard(
                        title: preset == .standard ? "GỐC" : preset.cameraDisplayTag,
                        badge: preset == .standard ? nil : preset.deviceBadge,
                        cacheKey: "film_\(preset.rawValue)",
                        previewState: previewState,
                        fallbackOriginal: originalImage,
                        coordinator: coordinator,
                        isSelected: isSelected,
                        isFavorited: favoriteFilmRawValues.contains(preset.rawValue),
                        showSelectedSlidersOverlay: preset != .standard,
                        onTap: {
                            if isSelected && preset != .standard {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isTuningFilmIntensity.toggle()
                                }
                            } else {
                                applyImmediateChange { st in
                                    st.presetRawValue = preset.rawValue
                                    st.filmIntensity = 1.0
                                    st.activeRecipeID = nil
                                    st.activeRecipeName = nil
                                }
                                isTuningFilmIntensity = false
                            }
                        },
                        onToggleFavorite: { onToggleFavoriteFilm(preset.rawValue) }
                    )
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 92)
    }

    private var recipesHorizontalStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                allGridButton

                ForEach(PhotoDarkroomRecipe.builtInRecipes) { recipe in
                    let isSelected = editState.activeRecipeID == recipe.id
                    let previewState = PhotoDarkroomEditState(
                        presetRawValue: recipe.presetRawValue,
                        filmIntensity: recipe.filmIntensity,
                        effects: recipe.effects,
                        tools: recipe.tools
                    )
                    PhotoDarkroomLiveThumbCard(
                        title: recipe.name,
                        badge: nil,
                        cacheKey: "recipe_\(recipe.id)",
                        previewState: previewState,
                        fallbackOriginal: originalImage,
                        coordinator: coordinator,
                        isSelected: isSelected,
                        isFavorited: favoriteRecipeIDs.contains(recipe.id),
                        showSelectedSlidersOverlay: true,
                        onTap: {
                            if isSelected {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isTuningFilmIntensity.toggle()
                                }
                            } else {
                                applyImmediateChange { st in
                                    st = recipe.apply(preservingCropFrom: st)
                                }
                                isTuningFilmIntensity = false
                            }
                        },
                        onToggleFavorite: { onToggleFavoriteRecipe(recipe.id) }
                    )
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 92)
    }

    private var mineRecipesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                allGridButton

                // + NEW RECIPE Card
                Button(action: onOpenNewRecipeSheet) {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AlignTheme.studioElevated)
                            .frame(width: 62, height: 62)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(AlignTheme.studioAccent)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(AlignTheme.studioAccentBorder, lineWidth: 0.9)
                            )

                        Text("TẠO MỚI")
                            .font(.system(size: 9.2, weight: .semibold, design: .monospaced))
                            .tracking(0.3)
                            .foregroundColor(AlignTheme.studioAccent)
                            .frame(width: 66, height: 24, alignment: .top)
                    }
                }
                .buttonStyle(.plain)

                if customRecipes.isEmpty {
                    Text("Công thức là sự kết hợp giữa màu phim\nvà mọi hiệu ứng, công cụ bạn đã chỉnh.")
                        .font(.system(size: 11.5, weight: .regular, design: .rounded))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .lineSpacing(3)
                        .padding(.leading, 8)
                } else {
                    ForEach(customRecipes) { recipe in
                        let isSelected = editState.activeRecipeID == recipe.id
                        let previewState = PhotoDarkroomEditState(
                            presetRawValue: recipe.presetRawValue,
                            filmIntensity: recipe.filmIntensity,
                            effects: recipe.effects,
                            tools: recipe.tools
                        )
                        PhotoDarkroomLiveThumbCard(
                            title: recipe.name,
                            badge: nil,
                            cacheKey: "custom_\(recipe.id)",
                            previewState: previewState,
                            fallbackOriginal: originalImage,
                            coordinator: coordinator,
                            isSelected: isSelected,
                            isFavorited: favoriteRecipeIDs.contains(recipe.id),
                            showSelectedSlidersOverlay: true,
                            onTap: {
                                applyImmediateChange { st in
                                    st = recipe.apply(preservingCropFrom: st)
                                }
                            },
                            onToggleFavorite: { onToggleFavoriteRecipe(recipe.id) },
                            onDeleteCustom: { onDeleteCustomRecipe(recipe.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 92)
    }

    private var favoritesStrip: some View {
        let favFilms = orderedFilmPresets.filter { favoriteFilmRawValues.contains($0.rawValue) }
        let allRecipes = customRecipes + PhotoDarkroomRecipe.builtInRecipes
        let favRecipes = allRecipes.filter { favoriteRecipeIDs.contains($0.id) }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                allGridButton

                if favFilms.isEmpty && favRecipes.isEmpty {
                    Text("Nhấn giữ vào màu phim hoặc công thức\nđể thêm nhanh vào Yêu thích.")
                        .font(.system(size: 11.5, weight: .regular, design: .rounded))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                        .lineSpacing(3)
                        .padding(.leading, 8)
                } else {
                    ForEach(favRecipes) { recipe in
                        let isSelected = editState.activeRecipeID == recipe.id
                        let previewState = PhotoDarkroomEditState(
                            presetRawValue: recipe.presetRawValue,
                            filmIntensity: recipe.filmIntensity,
                            effects: recipe.effects,
                            tools: recipe.tools
                        )
                        PhotoDarkroomLiveThumbCard(
                            title: recipe.name,
                            badge: nil,
                            cacheKey: "fav_recipe_\(recipe.id)",
                            previewState: previewState,
                            fallbackOriginal: originalImage,
                            coordinator: coordinator,
                            isSelected: isSelected,
                            isFavorited: true,
                            onTap: {
                                applyImmediateChange { st in
                                    st = recipe.apply(preservingCropFrom: st)
                                }
                            },
                            onToggleFavorite: { onToggleFavoriteRecipe(recipe.id) }
                        )
                    }

                    ForEach(favFilms) { preset in
                        let isSelected = editState.activeRecipeID == nil && editState.presetRawValue == preset.rawValue
                        let previewState = PhotoDarkroomEditState(presetRawValue: preset.rawValue, filmIntensity: 1.0)
                        PhotoDarkroomLiveThumbCard(
                            title: preset.cameraDisplayTag,
                            badge: preset.deviceBadge,
                            cacheKey: "fav_film_\(preset.rawValue)",
                            previewState: previewState,
                            fallbackOriginal: originalImage,
                            coordinator: coordinator,
                            isSelected: isSelected,
                            isFavorited: true,
                            onTap: {
                                applyImmediateChange { st in
                                    st.presetRawValue = preset.rawValue
                                    st.filmIntensity = 1.0
                                    st.activeRecipeID = nil
                                    st.activeRecipeName = nil
                                }
                            },
                            onToggleFavorite: { onToggleFavoriteFilm(preset.rawValue) }
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 92)
    }

    // MARK: - 2. EFFECTS Icon Strip (All 14 Optical & Analog Effects)
    private var effectsIconStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(PhotoEffectKind.allCases) { kind in
                    let isSelected = selectedEffect == kind
                    let isActive = editState.effects.isActive(kind)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedEffect = (selectedEffect == kind) ? nil : kind
                        }
                    }) {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.white : AlignTheme.studioElevated)
                                    .frame(width: 50, height: 50)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? Color.white : (isActive ? AlignTheme.studioAccent : AlignTheme.studioHairline),
                                                lineWidth: (isSelected || isActive) ? 1.4 : 0.7
                                            )
                                    )

                                Image(systemName: kind.iconName)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(isSelected ? .black : (isActive ? AlignTheme.studioAccent : .white.opacity(0.90)))
                            }

                            VStack(spacing: 2.5) {
                                Text(kind.title)
                                    .font(.system(size: 9.0, weight: isSelected ? .bold : .medium, design: .monospaced))
                                    .tracking(0.4)
                                    .foregroundColor(isSelected ? .white : AlignTheme.studioInkSecondary)
                                    .lineLimit(1)

                                Circle()
                                    .fill(isActive ? AlignTheme.studioAccent : Color.clear)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .frame(width: 58)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 82)
    }

    // MARK: - 3. TOOLS Icon Strip (All 12 Pro Tools)
    private var toolsIconStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(PhotoToolKind.allCases) { kind in
                    let isSelected = selectedTool == kind
                    let isActive = editState.tools.isActive(kind)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTool = (selectedTool == kind) ? nil : kind
                        }
                    }) {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.white : AlignTheme.studioElevated)
                                    .frame(width: 50, height: 50)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? Color.white : (isActive ? AlignTheme.studioAccent : AlignTheme.studioHairline),
                                                lineWidth: (isSelected || isActive) ? 1.4 : 0.7
                                            )
                                    )

                                Image(systemName: kind.iconName)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(isSelected ? .black : (isActive ? AlignTheme.studioAccent : .white.opacity(0.90)))
                            }

                            VStack(spacing: 2.5) {
                                Text(kind.title)
                                    .font(.system(size: 9.0, weight: isSelected ? .bold : .medium, design: .monospaced))
                                    .tracking(0.3)
                                    .foregroundColor(isSelected ? .white : AlignTheme.studioInkSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)

                                Circle()
                                    .fill(isActive ? AlignTheme.studioAccent : Color.clear)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .frame(width: 62)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 82)
    }

    // MARK: - Inline Panel: Film Intensity
    private var filmIntensityInlinePanel: some View {
        adjusterContainer(
            title: editState.activeRecipeName ?? (FilmPreset(rawValue: editState.presetRawValue)?.cameraDisplayTag ?? "Màu phim"),
            subtitle: "Cường độ",
            readout: "\(Int(round(editState.filmIntensity * 100)))%",
            canReset: abs(editState.filmIntensity - 1.0) > 0.02,
            onReset: {
                applyImmediateChange { $0.filmIntensity = 1.0 }
            },
            onClose: {
                withAnimation(.easeInOut(duration: 0.16)) { isTuningFilmIntensity = false }
            }
        ) {
            StudioPrecisionTickSlider(
                value: $editState.filmIntensity,
                in: 0.0...1.0,
                defaultValue: 1.0,
                step: 0.01,
                onDragChanged: { _ in
                    beginInteractiveDragIfNeeded()
                    onLiveChange()
                },
                onDragEnded: { commitInteractiveDrag() }
            )
        }
    }

    // MARK: - Inline Panels: All 14 Effects
    @ViewBuilder
    private func effectAdjusterPanel(for kind: PhotoEffectKind) -> some View {
        let isActive = editState.effects.isActive(kind)
        adjusterContainer(
            title: kind.title,
            subtitle: kind.localizedSubtitle,
            readout: effectReadout(for: kind),
            canReset: isActive,
            onReset: {
                applyImmediateChange { $0.effects.reset(kind) }
            },
            onClose: {
                withAnimation(.easeInOut(duration: 0.16)) { selectedEffect = nil }
            }
        ) {
            switch kind {
            case .grain:
                VStack(spacing: 8) {
                    labeledSliderRow(label: "Cường độ", readout: pct(editState.effects.grain)) {
                        StudioPrecisionTickSlider(value: $editState.effects.grain, in: 0...1, defaultValue: 0, step: 0.01,
                                                  onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                  onDragEnded: { commitInteractiveDrag() })
                    }
                    if editState.effects.grain >= 0.01 {
                        labeledSliderRow(label: "Cỡ hạt", readout: String(format: "%.1fx", editState.effects.grainSize)) {
                            StudioPrecisionTickSlider(value: $editState.effects.grainSize, in: 0.6...2.2, defaultValue: 1.25, step: 0.05,
                                                      onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                      onDragEnded: { commitInteractiveDrag() })
                        }
                    }
                }

            case .vignette:
                VStack(spacing: 8) {
                    labeledSliderRow(label: "Cường độ", readout: pct(editState.effects.vignette)) {
                        StudioPrecisionTickSlider(value: $editState.effects.vignette, in: 0...1, defaultValue: 0, step: 0.01,
                                                  onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                  onDragEnded: { commitInteractiveDrag() })
                    }
                    if editState.effects.vignette >= 0.01 {
                        labeledSliderRow(label: "Bán kính", readout: String(format: "%.2f", editState.effects.vignetteRadius)) {
                            StudioPrecisionTickSlider(value: $editState.effects.vignetteRadius, in: 0.8...2.2, defaultValue: 1.45, step: 0.05,
                                                      onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                      onDragEnded: { commitInteractiveDrag() })
                        }
                    }
                }

            case .halation:
                StudioPrecisionTickSlider(value: $editState.effects.halation, in: 0...1, defaultValue: 0, step: 0.01,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })

            case .bloom:
                VStack(spacing: 8) {
                    labeledSliderRow(label: "Tỏa sáng", readout: pct(editState.effects.bloom)) {
                        StudioPrecisionTickSlider(value: $editState.effects.bloom, in: 0...1, defaultValue: 0, step: 0.01,
                                                  onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                  onDragEnded: { commitInteractiveDrag() })
                    }
                    if editState.effects.bloom >= 0.01 {
                        labeledSliderRow(label: "Độ lan", readout: "\(Int(round(editState.effects.bloomRadius)))") {
                            StudioPrecisionTickSlider(value: $editState.effects.bloomRadius, in: 4...24, defaultValue: 12, step: 1,
                                                      onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                      onDragEnded: { commitInteractiveDrag() })
                        }
                    }
                }

            case .flare:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.flare, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    chipRow(items: PhotoFlareStyle.allCases, selected: editState.effects.flareStyle, title: \.displayName) { style in
                        applyImmediateChange {
                            $0.effects.flareStyle = style
                            if $0.effects.flare < 0.05 { $0.effects.flare = 0.55 }
                        }
                    }
                }

            case .leak:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.leak, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<8, id: \.self) { idx in
                                let sel = editState.effects.leakPattern == idx
                                Button("Mẫu \(idx + 1)") {
                                    applyImmediateChange {
                                        $0.effects.leakPattern = idx
                                        if $0.effects.leak < 0.05 { $0.effects.leak = 0.55 }
                                    }
                                }
                                .font(.system(size: 11, weight: sel ? .bold : .medium, design: .rounded))
                                .foregroundColor(sel ? .black : .white.opacity(0.78))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(Capsule().fill(sel ? Color.white : AlignTheme.studioElevated))
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

            case .burn:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.burn, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    chipRow(items: PhotoBurnEdge.allCases, selected: editState.effects.burnEdge, title: \.displayName) { edge in
                        applyImmediateChange {
                            $0.effects.burnEdge = edge
                            if $0.effects.burn < 0.05 { $0.effects.burn = 0.60 }
                        }
                    }
                }

            case .expired:
                StudioPrecisionTickSlider(value: $editState.effects.expired, in: 0...1, defaultValue: 0, step: 0.01,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })

            case .fade:
                StudioPrecisionTickSlider(value: $editState.effects.fade, in: 0...1, defaultValue: 0, step: 0.01,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })

            case .dust:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.dust, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { idx in
                            let sel = editState.effects.dustSeed == idx
                            Button("Bụi \(idx + 1)") {
                                applyImmediateChange {
                                    $0.effects.dustSeed = idx
                                    if $0.effects.dust < 0.05 { $0.effects.dust = 0.50 }
                                }
                            }
                            .font(.system(size: 11, weight: sel ? .bold : .medium, design: .rounded))
                            .foregroundColor(sel ? .black : .white.opacity(0.78))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sel ? Color.white : AlignTheme.studioElevated))
                            .buttonStyle(.plain)
                        }
                    }
                }

            case .prism:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.prism, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    chipRow(items: PhotoPrismAxis.allCases, selected: editState.effects.prismAxis, title: \.displayName) { axis in
                        applyImmediateChange {
                            $0.effects.prismAxis = axis
                            if $0.effects.prism < 0.05 { $0.effects.prism = 0.55 }
                        }
                    }
                }

            case .star:
                VStack(spacing: 8) {
                    StudioPrecisionTickSlider(value: $editState.effects.star, in: 0...1, defaultValue: 0, step: 0.01,
                                              onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                              onDragEnded: { commitInteractiveDrag() })
                    chipRow(items: PhotoStarPoints.allCases, selected: editState.effects.starPoints, title: \.displayName) { pts in
                        applyImmediateChange {
                            $0.effects.starPoints = pts
                            if $0.effects.star < 0.05 { $0.effects.star = 0.55 }
                        }
                    }
                }

            case .date:
                HStack(spacing: 8) {
                    ForEach(PhotoDateStampMode.allCases) { mode in
                        let sel = editState.effects.dateStamp == mode
                        Button(action: {
                            applyImmediateChange { $0.effects.dateStamp = mode }
                        }) {
                            VStack(spacing: 3) {
                                Text(mode == .off ? "TẮT" : (mode == .retroLED ? "'26 11 28" : "11 28 '26"))
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(mode == .off ? (sel ? .black : .white.opacity(0.65)) : Color(red: 1.0, green: 0.42, blue: 0.14))
                                Text(mode.displayName)
                                    .font(.system(size: 10, weight: sel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(sel ? .black : .white.opacity(0.75))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(sel ? Color.white : AlignTheme.studioElevated))
                        }
                        .buttonStyle(.plain)
                    }
                }

            case .frame:
                VStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(PhotoFrameStyle.allCases) { style in
                                let sel = editState.effects.frameStyle == style
                                Button(style.displayName) {
                                    applyImmediateChange { $0.effects.frameStyle = style }
                                }
                                .font(.system(size: 11, weight: sel ? .bold : .medium, design: .rounded))
                                .foregroundColor(sel ? .black : .white.opacity(0.80))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sel ? Color.white : AlignTheme.studioElevated))
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if editState.effects.frameStyle.usesMasterWatermark {
                        chipRow(items: PhotoFrameLogoOption.allCases, selected: editState.effects.frameLogo, title: \.displayName) { logo in
                            applyImmediateChange { $0.effects.frameLogo = logo }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inline Panels: All 12 Tools
    @ViewBuilder
    private func toolAdjusterPanel(for kind: PhotoToolKind) -> some View {
        let isActive = editState.tools.isActive(kind)
        adjusterContainer(
            title: kind.title,
            subtitle: kind.localizedSubtitle,
            readout: toolReadout(for: kind),
            canReset: isActive,
            onReset: {
                applyImmediateChange { $0.tools.reset(kind) }
            },
            onClose: {
                withAnimation(.easeInOut(duration: 0.16)) { selectedTool = nil }
            }
        ) {
            switch kind {
            case .crop:
                cropAdjusterContent
            case .exposure:
                StudioPrecisionTickSlider(value: $editState.tools.exposureEV, in: -2.0...2.0, defaultValue: 0, step: 0.05,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .warmth:
                StudioPrecisionTickSlider(value: $editState.tools.warmth, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .tint:
                StudioPrecisionTickSlider(value: $editState.tools.tint, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .contrast:
                StudioPrecisionTickSlider(value: $editState.tools.contrast, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .highlights:
                StudioPrecisionTickSlider(value: $editState.tools.highlights, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .shadows:
                StudioPrecisionTickSlider(value: $editState.tools.shadows, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .saturation:
                StudioPrecisionTickSlider(value: $editState.tools.saturation, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .vibrance:
                StudioPrecisionTickSlider(value: $editState.tools.vibrance, in: -1.0...1.0, defaultValue: 0, step: 0.02,
                                          onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                          onDragEnded: { commitInteractiveDrag() })
            case .hsl:
                hslAdjusterContent
            case .curves:
                PhotoCurvesEditorView(
                    curves: $editState.tools.curves,
                    selectedChannel: $selectedCurveChannel,
                    histogram: histogram,
                    onCurveChanged: {
                        beginInteractiveDragIfNeeded()
                        onLiveChange()
                    },
                    onCurveCommitted: { commitInteractiveDrag() }
                )
            case .detail:
                VStack(spacing: 8) {
                    labeledSliderRow(label: "Độ nét", readout: pct(editState.tools.sharpness)) {
                        StudioPrecisionTickSlider(value: $editState.tools.sharpness, in: 0...1, defaultValue: 0, step: 0.02,
                                                  onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                  onDragEnded: { commitInteractiveDrag() })
                    }
                    labeledSliderRow(label: "Clarity", readout: pct(editState.tools.clarity)) {
                        StudioPrecisionTickSlider(value: $editState.tools.clarity, in: 0...1, defaultValue: 0, step: 0.02,
                                                  onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                                                  onDragEnded: { commitInteractiveDrag() })
                    }
                    Button(action: onToggleAIEnhance) {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(editState.isAIEnhanced ? "AI Cân Màu theo bối cảnh: Bật" : "Bật AI Cân Màu theo bối cảnh")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(editState.isAIEnhanced ? .black : .white.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(editState.isAIEnhanced ? AlignTheme.studioAccent : AlignTheme.studioElevated)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var cropAdjusterContent: some View {
        VStack(spacing: 10) {
            // Straighten angle slider (-45° ... +45°)
            labeledSliderRow(
                label: "Xoay góc",
                readout: String(format: "%+.1f°", editState.tools.crop.straightenDegrees)
            ) {
                StudioPrecisionTickSlider(
                    value: $editState.tools.crop.straightenDegrees,
                    in: -45.0...45.0,
                    defaultValue: 0.0,
                    step: 0.5,
                    onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                    onDragEnded: { commitInteractiveDrag() }
                )
            }

            // Aspect Ratio Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PhotoCropAspectRatio.allCases) { ratio in
                        let sel = editState.tools.crop.aspectRatio == ratio
                        Button(ratio.rawValue) {
                            applyImmediateChange { st in
                                st.tools.crop.aspectRatio = ratio
                                if let num = ratio.numericRatio {
                                    st.tools.crop.normalizedRect = PhotoCropState.centeredNormalizedRect(
                                        for: num,
                                        imageWidth: Double(max(1, currentImageSize.width)),
                                        imageHeight: Double(max(1, currentImageSize.height))
                                    )
                                } else if ratio == .original {
                                    st.tools.crop.normalizedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                                }
                            }
                        }
                        .font(.system(size: 11, weight: sel ? .bold : .medium, design: .monospaced))
                        .foregroundColor(sel ? .black : .white.opacity(0.80))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(sel ? Color.white : AlignTheme.studioElevated))
                        .buttonStyle(.plain)
                    }
                }
            }

            // Quick Rotate 90° & Flip Horizontal
            HStack(spacing: 8) {
                Button(action: {
                    applyImmediateChange { st in
                        st.tools.crop.quarterTurns = (st.tools.crop.quarterTurns + 1) % 4
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "rotate.right")
                        Text("Xoay 90°")
                    }
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7.5)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AlignTheme.studioElevated))
                }
                .buttonStyle(.plain)

                Button(action: {
                    applyImmediateChange { st in
                        st.tools.crop.flipHorizontal.toggle()
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        Text(editState.tools.crop.flipHorizontal ? "Đã lật ngang" : "Lật ngang")
                    }
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(editState.tools.crop.flipHorizontal ? .black : .white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7.5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(editState.tools.crop.flipHorizontal ? Color.white : AlignTheme.studioElevated)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hslAdjusterContent: some View {
        let bandBinding = Binding<PhotoHSLBandValue>(
            get: { editState.tools.hsl[selectedHSLChannel] },
            set: { editState.tools.hsl[selectedHSLChannel] = $0 }
        )
        let rgb = selectedHSLChannel.swatchRGB
        let swatchColor = Color(red: rgb.0, green: rgb.1, blue: rgb.2)

        return VStack(spacing: 9) {
            // 8 Vivid Color Band Chips
            HStack(spacing: 0) {
                ForEach(PhotoHSLColorChannel.allCases) { ch in
                    let sel = selectedHSLChannel == ch
                    let edited = !editState.tools.hsl[ch].isIdentity
                    let c = ch.swatchRGB
                    Button(action: { selectedHSLChannel = ch }) {
                        VStack(spacing: 3) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: c.0, green: c.1, blue: c.2))
                                    .frame(width: sel ? 24 : 20, height: sel ? 24 : 20)
                                    .overlay(
                                        Circle().stroke(Color.white, lineWidth: sel ? 2.2 : 0)
                                    )
                            }
                            .frame(height: 26)

                            Circle()
                                .fill(edited ? AlignTheme.studioAccent : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Hue / Saturation / Luminance Sliders for Selected Color Band
            labeledSliderRow(label: "Sắc màu", readout: signedInt(bandBinding.wrappedValue.hue * 100)) {
                StudioPrecisionTickSlider(
                    value: Binding(get: { bandBinding.wrappedValue.hue }, set: { var b = bandBinding.wrappedValue; b.hue = $0; bandBinding.wrappedValue = b }),
                    in: -1...1, defaultValue: 0, step: 0.02, accentColor: swatchColor,
                    onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                    onDragEnded: { commitInteractiveDrag() }
                )
            }
            labeledSliderRow(label: "Bão hòa", readout: signedInt(bandBinding.wrappedValue.saturation * 100)) {
                StudioPrecisionTickSlider(
                    value: Binding(get: { bandBinding.wrappedValue.saturation }, set: { var b = bandBinding.wrappedValue; b.saturation = $0; bandBinding.wrappedValue = b }),
                    in: -1...1, defaultValue: 0, step: 0.02, accentColor: swatchColor,
                    onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                    onDragEnded: { commitInteractiveDrag() }
                )
            }
            labeledSliderRow(label: "Độ sáng", readout: signedInt(bandBinding.wrappedValue.luminance * 100)) {
                StudioPrecisionTickSlider(
                    value: Binding(get: { bandBinding.wrappedValue.luminance }, set: { var b = bandBinding.wrappedValue; b.luminance = $0; bandBinding.wrappedValue = b }),
                    in: -1...1, defaultValue: 0, step: 0.02, accentColor: swatchColor,
                    onDragChanged: { _ in beginInteractiveDragIfNeeded(); onLiveChange() },
                    onDragEnded: { commitInteractiveDrag() }
                )
            }
        }
    }

    // MARK: - Shared Clean Adjuster Chrome Helpers
    @ViewBuilder
    private func adjusterContainer<Content: View>(
        title: String,
        subtitle: String,
        readout: String,
        canReset: Bool,
        onReset: @escaping () -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                }

                Spacer()

                if !readout.isEmpty {
                    Text(readout)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AlignTheme.studioAccentSoft))
                }

                if canReset {
                    Button("Đặt lại", action: onReset)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AlignTheme.studioElevated))
                        .buttonStyle(.plain)
                }

                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(AlignTheme.studioElevated))
                }
                .buttonStyle(.plain)
            }

            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            AlignTheme.studioSurface
                .overlay(alignment: .top) {
                    Rectangle().fill(AlignTheme.studioHairline).frame(height: 0.7)
                }
        )
    }

    @ViewBuilder
    private func labeledSliderRow<SliderContent: View>(
        label: String,
        readout: String,
        @ViewBuilder slider: () -> SliderContent
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(AlignTheme.studioInkSecondary)
                .frame(width: 56, alignment: .leading)
            slider()
            Text(readout)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func chipRow<Item: Identifiable & Equatable>(
        items: [Item],
        selected: Item,
        title: KeyPath<Item, String>,
        onSelect: @escaping (Item) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let sel = item == selected
                Button(item[keyPath: title]) { onSelect(item) }
                    .font(.system(size: 11, weight: sel ? .bold : .medium, design: .rounded))
                    .foregroundColor(sel ? .black : .white.opacity(0.80))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sel ? Color.white : AlignTheme.studioElevated))
                    .buttonStyle(.plain)
            }
        }
    }

    private func pct(_ val: Double) -> String { "\(Int(round(val * 100)))%" }
    private func signedInt(_ val: Double) -> String {
        let i = Int(round(val))
        return i > 0 ? "+\(i)" : "\(i)"
    }

    private func effectReadout(for kind: PhotoEffectKind) -> String {
        switch kind {
        case .grain: return pct(editState.effects.grain)
        case .vignette: return pct(editState.effects.vignette)
        case .halation: return pct(editState.effects.halation)
        case .bloom: return pct(editState.effects.bloom)
        case .flare: return pct(editState.effects.flare)
        case .leak: return pct(editState.effects.leak)
        case .burn: return pct(editState.effects.burn)
        case .expired: return pct(editState.effects.expired)
        case .fade: return pct(editState.effects.fade)
        case .dust: return pct(editState.effects.dust)
        case .prism: return pct(editState.effects.prism)
        case .star: return pct(editState.effects.star)
        case .date: return editState.effects.dateStamp.displayName
        case .frame: return editState.effects.frameStyle.displayName
        }
    }

    private func toolReadout(for kind: PhotoToolKind) -> String {
        switch kind {
        case .crop: return editState.tools.crop.aspectRatio.rawValue
        case .exposure: return String(format: "%+.2f EV", editState.tools.exposureEV)
        case .warmth: return signedInt(editState.tools.warmth * 100)
        case .tint: return signedInt(editState.tools.tint * 100)
        case .contrast: return signedInt(editState.tools.contrast * 100)
        case .highlights: return signedInt(editState.tools.highlights * 100)
        case .shadows: return signedInt(editState.tools.shadows * 100)
        case .saturation: return signedInt(editState.tools.saturation * 100)
        case .vibrance: return signedInt(editState.tools.vibrance * 100)
        case .hsl: return selectedHSLChannel.displayName
        case .curves: return selectedCurveChannel.rawValue
        case .detail: return pct(max(editState.tools.sharpness, editState.tools.clarity))
        }
    }
}

// MARK: - Full Looks & Recipes Grid Browser Sheet ("TẤT CẢ")
public struct PhotoDarkroomCatalogSheetView: View {
    @Environment(\.dismiss) private var dismiss

    public let initialSubTab: PhotoLooksSubTab
    public let currentEditState: PhotoDarkroomEditState
    public let originalImage: CGImage
    public let coordinator: PhotoDarkroomSessionCoordinator
    public let customRecipes: [PhotoDarkroomRecipe]
    public let favoriteFilmRawValues: Set<String>
    public let favoriteRecipeIDs: Set<String>
    public let onSelectFilm: (FilmPreset) -> Void
    public let onSelectRecipe: (PhotoDarkroomRecipe) -> Void
    public let onToggleFavoriteFilm: (String) -> Void
    public let onToggleFavoriteRecipe: (String) -> Void

    @State private var browseRecipes: Bool
    @State private var selectedCategory: FilmPresetCategory = .trending

    public init(
        initialSubTab: PhotoLooksSubTab,
        currentEditState: PhotoDarkroomEditState,
        originalImage: CGImage,
        coordinator: PhotoDarkroomSessionCoordinator,
        customRecipes: [PhotoDarkroomRecipe],
        favoriteFilmRawValues: Set<String>,
        favoriteRecipeIDs: Set<String>,
        onSelectFilm: @escaping (FilmPreset) -> Void,
        onSelectRecipe: @escaping (PhotoDarkroomRecipe) -> Void,
        onToggleFavoriteFilm: @escaping (String) -> Void,
        onToggleFavoriteRecipe: @escaping (String) -> Void
    ) {
        self.initialSubTab = initialSubTab
        self.currentEditState = currentEditState
        self.originalImage = originalImage
        self.coordinator = coordinator
        self.customRecipes = customRecipes
        self.favoriteFilmRawValues = favoriteFilmRawValues
        self.favoriteRecipeIDs = favoriteRecipeIDs
        self.onSelectFilm = onSelectFilm
        self.onSelectRecipe = onSelectRecipe
        self.onToggleFavoriteFilm = onToggleFavoriteFilm
        self.onToggleFavoriteRecipe = onToggleFavoriteRecipe
        _browseRecipes = State(initialValue: initialSubTab == .recipes || initialSubTab == .mine)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("", selection: $browseRecipes) {
                    Text("Phim màu").tag(false)
                    Text("Công thức").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if !browseRecipes {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FilmPresetCategory.allCases) { cat in
                                let sel = selectedCategory == cat
                                Button(cat.displayName) { selectedCategory = cat }
                                    .font(.system(size: 11.5, weight: sel ? .bold : .medium, design: .rounded))
                                    .foregroundColor(sel ? .black : .white.opacity(0.75))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(sel ? Color.white : AlignTheme.studioElevated))
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        if browseRecipes {
                            ForEach(customRecipes + PhotoDarkroomRecipe.builtInRecipes) { recipe in
                                PhotoDarkroomLiveThumbCard(
                                    title: recipe.name,
                                    badge: recipe.isBuiltIn ? nil : "ME",
                                    cacheKey: "cat_recipe_\(recipe.id)",
                                    previewState: PhotoDarkroomEditState(
                                        presetRawValue: recipe.presetRawValue,
                                        filmIntensity: recipe.filmIntensity,
                                        effects: recipe.effects,
                                        tools: recipe.tools
                                    ),
                                    fallbackOriginal: originalImage,
                                    coordinator: coordinator,
                                    isSelected: currentEditState.activeRecipeID == recipe.id,
                                    isFavorited: favoriteRecipeIDs.contains(recipe.id),
                                    onTap: {
                                        onSelectRecipe(recipe)
                                        dismiss()
                                    },
                                    onToggleFavorite: { onToggleFavoriteRecipe(recipe.id) }
                                )
                            }
                        } else {
                            ForEach(selectedCategory.presets) { preset in
                                PhotoDarkroomLiveThumbCard(
                                    title: preset.cameraDisplayTag,
                                    badge: preset.deviceBadge,
                                    cacheKey: "cat_film_\(preset.rawValue)",
                                    previewState: PhotoDarkroomEditState(presetRawValue: preset.rawValue, filmIntensity: 1.0),
                                    fallbackOriginal: originalImage,
                                    coordinator: coordinator,
                                    isSelected: currentEditState.activeRecipeID == nil && currentEditState.presetRawValue == preset.rawValue,
                                    isFavorited: favoriteFilmRawValues.contains(preset.rawValue),
                                    onTap: {
                                        onSelectFilm(preset)
                                        dismiss()
                                    },
                                    onToggleFavorite: { onToggleFavoriteFilm(preset.rawValue) }
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .padding(.top, 8)
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle(browseRecipes ? "Tất cả Công thức" : "Tất cả Màu phim")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Save Custom Recipe Prompt Sheet ("+ TẠO CÔNG THỨC MỚI")
public struct PhotoSaveRecipeSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recipeName: String = ""
    public let activePresetName: String
    public let onSave: (String) -> Void

    public init(activePresetName: String, onSave: @escaping (String) -> Void) {
        self.activePresetName = activePresetName
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Lưu toàn bộ màu phim (\(activePresetName)), hiệu ứng và thông số chỉnh hiện tại thành công thức riêng để áp dụng nhanh cho các ảnh sau.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkSecondary)

                TextField("Tên công thức (vd: Nắng Chiều Sài Gòn)", text: $recipeName)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(13)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(AlignTheme.studioElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AlignTheme.studioHairline, lineWidth: 0.8)
                            )
                    )

                Button(action: {
                    let trimmed = recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalName = trimmed.isEmpty ? "CÔNG THỨC MỚI" : trimmed
                    onSave(finalName)
                    dismiss()
                }) {
                    Text("Lưu công thức")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(20)
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle("Tạo Công thức mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hủy") { dismiss() }
                        .foregroundColor(.white.opacity(0.75))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
