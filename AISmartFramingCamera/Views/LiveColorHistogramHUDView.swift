import SwiftUI

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    private let haptic = UISelectionFeedbackGenerator()

    @State private var isAIPulsePhase: Bool = false

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 10) {
            // 1. Format / Codec Selector (Video: HEVC / H.264, Photo: JPEG / HEIC / DNG)
            formatSelectorView

            // 2. Realtime 32-Bar RGB Spectrum Histogram (Biểu đồ Histogram màu quang phổ Realtime báo cháy sáng)
            if viewModel.isHistogramBarExpanded {
                histogramBarsView
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // 3. Nút Toggle On/Off Thanh Màu (như kiểu video pro bên cạnh)
            histogramToggleButton

            // 4. Thin Vertical Separator
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 22)

            // 5. Realtime Exposure Info (Tốc độ màn trập & ISO luôn hiển thị như cũ)
            exposureInfoView

            // 6. Menu / Settings Dot ⋮
            settingsButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: viewModel.isHistogramBarExpanded)
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
            VStack(alignment: .leading, spacing: 1.5) {
                Text("HEVC")
                    .font(.system(size: 8, weight: viewModel.selectedVideoCodec == .hevc ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedVideoCodec == .hevc ? .cyan : .white.opacity(0.3))

                Text("H.264")
                    .font(.system(size: 8, weight: viewModel.selectedVideoCodec == .h264 ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedVideoCodec == .h264 ? .white : .white.opacity(0.3))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.toggleVideoCodec()
            }
            .padding(.trailing, 2)
        } else {
            VStack(alignment: .leading, spacing: 0.5) {
                // Nháy đỏ (AI Local) hoặc nháy vàng (AI Cloud) tại chữ JPEG
                Text("JPEG")
                    .font(.system(size: 8, weight: (viewModel.activeAIIndicatorType != .none || viewModel.selectedPhotoFormat == .jpeg) ? .heavy : .medium, design: .rounded))
                    .foregroundColor(jpegTextColor)
                    .opacity(jpegTextOpacity)
                    .shadow(color: jpegGlowColor, radius: 4, x: 0, y: 0)

                Text("HEIC")
                    .font(.system(size: 8, weight: viewModel.selectedPhotoFormat == .heic ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .heic ? .cyan : .white.opacity(0.3))

                Text("DNG")
                    .font(.system(size: 8, weight: viewModel.selectedPhotoFormat == .dng ? .heavy : .medium, design: .rounded))
                    .foregroundColor(viewModel.selectedPhotoFormat == .dng ? .yellow : .white.opacity(0.3))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.togglePhotoFormat()
            }
            .padding(.trailing, 2)
        }
    }

    private var jpegTextColor: Color {
        switch viewModel.activeAIIndicatorType {
        case .local:
            return .red
        case .cloud:
            return .yellow
        case .none:
            return viewModel.selectedPhotoFormat == .jpeg ? .white : .white.opacity(0.3)
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

    // MARK: - 2. Realtime 32-Bar RGB Spectrum Histogram
    private var histogramBarsView: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(viewModel.histogramBars) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar.color)
                    .frame(width: 3.2, height: max(2.5, bar.height * 24.0))
            }
        }
        .frame(height: 26, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
            haptic.selectionChanged()
        }
    }

    // MARK: - 3. Nút Toggle On/Off Thanh Màu Báo Cháy Sáng
    private var histogramToggleButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
            haptic.selectionChanged()
        }) {
            if viewModel.isHistogramBarExpanded {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.horizontal, 2)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("HISTO")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(Color.yellow.opacity(0.18))
                        .overlay(
                            Capsule().stroke(Color.yellow.opacity(0.4), lineWidth: 0.8)
                        )
                )
            }
        }
        .accessibilityLabel(viewModel.isHistogramBarExpanded ? "Thu gọn thanh màu báo cháy sáng" : "Mở rộng thanh màu báo cháy sáng")
    }

    // MARK: - 4. Realtime Exposure Info (Thông số hiển thị như cũ)
    private var exposureInfoView: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(viewModel.liveShutterSpeed)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)

            Text(viewModel.liveISO)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.90))
        }
    }

    // MARK: - 5. Menu / Settings Dot
    private var settingsButton: some View {
        Button(action: {
            viewModel.isShowingSettings = true
        }) {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 14, height: 26)
        }
        .accessibilityLabel("Cài đặt")
    }
}
