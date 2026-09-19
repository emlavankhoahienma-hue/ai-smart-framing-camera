import SwiftUI

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    private let haptic = UISelectionFeedbackGenerator()

    @State private var isAIPulsePhase: Bool = false

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 8) {
            // 1. Format / Codec Selector (Photo: JPEG/HEIC/DNG, Video: HEVC/H.264)
            formatSelectorView

            // Thin Vertical Separator
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 16)

            // 2. Realtime Exposure Info (Tốc độ màn trập & ISO)
            exposureInfoView

            // Thin Vertical Separator
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 16)

            // 3. Compact Histogram & Toggle Button (Không kéo dài, không dính nút)
            if viewModel.isHistogramBarExpanded {
                compactHistogramBarsView
            }

            histogramToggleButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
        )
        .frame(maxWidth: 225)
        .animation(.spring(response: 0.28, dampingFraction: 0.76), value: viewModel.isHistogramBarExpanded)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                isAIPulsePhase = true
            }
        }
    }

    // MARK: - 1. Format / Codec Selector
    @ViewBuilder
    private var formatSelectorView: some View {
        if viewModel.captureMode.isVideo {
            HStack(spacing: 3) {
                Text("HEVC")
                    .font(.system(size: 8.5, weight: viewModel.selectedVideoCodec == .hevc ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedVideoCodec == .hevc ? .cyan : .white.opacity(0.35))

                Text("H.264")
                    .font(.system(size: 8.5, weight: viewModel.selectedVideoCodec == .h264 ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedVideoCodec == .h264 ? .white : .white.opacity(0.35))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.toggleVideoCodec()
            }
        } else {
            HStack(spacing: 3) {
                Text("JPEG")
                    .font(.system(size: 8.5, weight: (viewModel.activeAIIndicatorType != .none || viewModel.selectedPhotoFormat == .jpeg) ? .heavy : .medium, design: .rounded))
                    .foregroundColor(jpegTextColor)
                    .opacity(jpegTextOpacity)
                    .shadow(color: jpegGlowColor, radius: 4, x: 0, y: 0)

                Text("HEIC")
                    .font(.system(size: 8.5, weight: viewModel.selectedPhotoFormat == .heic ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .heic ? .cyan : .white.opacity(0.35))

                Text("DNG")
                    .font(.system(size: 8.5, weight: viewModel.selectedPhotoFormat == .dng ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .dng ? .yellow : .white.opacity(0.35))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.togglePhotoFormat()
            }
        }
    }

    private var jpegTextColor: Color {
        switch viewModel.activeAIIndicatorType {
        case .local:
            return .red
        case .cloud:
            return .yellow
        case .none:
            return viewModel.selectedPhotoFormat == .jpeg ? .white : .white.opacity(0.35)
        }
    }

    private var jpegTextOpacity: Double {
        switch viewModel.activeAIIndicatorType {
        case .local, .cloud:
            return isAIPulsePhase ? 1.0 : 0.35
        case .none:
            return 1.0
        }
    }

    private var jpegGlowColor: Color {
        switch viewModel.activeAIIndicatorType {
        case .local:
            return Color.red.opacity(isAIPulsePhase ? 0.9 : 0.2)
        case .cloud:
            return Color.yellow.opacity(isAIPulsePhase ? 0.9 : 0.2)
        case .none:
            return .clear
        }
    }

    // MARK: - 2. Compact Realtime RGB Spectrum Histogram (16 mini bars)
    private var compactHistogramBarsView: some View {
        let sampleIndices = Array(stride(from: 0, to: min(32, viewModel.histogramBars.count), by: 2))
        return HStack(alignment: .bottom, spacing: 1.2) {
            ForEach(sampleIndices, id: \.self) { idx in
                let bar = viewModel.histogramBars[idx]
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(bar.color)
                    .frame(width: 2.2, height: max(2.0, bar.height * 16.0))
            }
        }
        .frame(height: 18, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
            haptic.selectionChanged()
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - 3. Toggle On/Off Thanh Màu (Icon mini tinh tế)
    private var histogramToggleButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
            haptic.selectionChanged()
        }) {
            if viewModel.isHistogramBarExpanded {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.70))
            } else {
                HStack(spacing: 2.5) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("HISTO")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.yellow.opacity(0.18))
                        .overlay(
                            Capsule().stroke(Color.yellow.opacity(0.4), lineWidth: 0.6)
                        )
                )
            }
        }
        .accessibilityLabel(viewModel.isHistogramBarExpanded ? "Thu gọn thanh màu báo cháy sáng" : "Mở rộng thanh màu báo cháy sáng")
    }

    // MARK: - 4. Realtime Exposure Info
    private var exposureInfoView: some View {
        HStack(spacing: 4) {
            Text(viewModel.liveShutterSpeed)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text(viewModel.liveISO)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}
