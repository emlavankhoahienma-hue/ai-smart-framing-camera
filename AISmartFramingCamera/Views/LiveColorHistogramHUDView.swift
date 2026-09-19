import SwiftUI
import Foundation

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel

    private let haptic = UISelectionFeedbackGenerator()
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 5) {
            histogramView

            HStack(spacing: 7) {
                Text(viewModel.liveISO)
                    .lineLimit(1)

                separatorDot

                Text(String(format: "EV %+.1f", viewModel.exposureBias))
                    .lineLimit(1)

                separatorDot

                formatButton
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.88))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 7, y: 3)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: viewModel.isHistogramBarExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Histogram, \(viewModel.liveISO), độ phơi sáng \(formattedExposure), định dạng \(activeFormatTitle)")
    }

    private var histogramView: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(viewModel.histogramBars) { bar in
                Capsule(style: .continuous)
                    .fill(bar.color)
                    .frame(
                        width: 2.2,
                        height: max(2.0, bar.height * (viewModel.isHistogramBarExpanded ? 23.0 : 15.0))
                    )
            }
        }
        .frame(height: viewModel.isHistogramBarExpanded ? 24 : 16, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                viewModel.isHistogramBarExpanded.toggle()
            }
            haptic.selectionChanged()
        }
        .accessibilityLabel(viewModel.isHistogramBarExpanded ? "Thu gọn histogram" : "Mở rộng histogram")
    }

    private var separatorDot: some View {
        Circle()
            .fill(Color.white.opacity(0.28))
            .frame(width: 2.5, height: 2.5)
    }

    private var formatButton: some View {
        Button(action: toggleActiveFormat) {
            Text(activeFormatTitle)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(amberGold)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Đổi định dạng \(activeFormatTitle)")
    }

    private var activeFormatTitle: String {
        if viewModel.captureMode.isVideo {
            return viewModel.selectedVideoCodec == .hevc ? "HEVC" : "H.264"
        }

        if viewModel.selectedPhotoFormat == .jpeg {
            return "JPEG"
        }

        if viewModel.selectedPhotoFormat == .heic {
            return "HEIC"
        }

        return "DNG"
    }

    private var formattedExposure: String {
        String(format: "%+.1f EV", viewModel.exposureBias)
    }

    private func toggleActiveFormat() {
        if viewModel.captureMode.isVideo {
            viewModel.toggleVideoCodec()
        } else {
            viewModel.togglePhotoFormat()
        }
        haptic.selectionChanged()
    }
}
