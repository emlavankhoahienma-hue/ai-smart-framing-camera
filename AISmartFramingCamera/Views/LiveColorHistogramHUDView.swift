import SwiftUI

public struct LiveColorHistogramHUDView: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.0)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(spacing: 12) {
            formatControl

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 30)

            histogram
                .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 30)

            exposure
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.075, green: 0.075, blue: 0.085))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var formatControl: some View {
        if viewModel.captureMode.isVideo {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { viewModel.toggleVideoFormat() }) {
                    Text(viewModel.activeVideoResolutionString)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .disabled(viewModel.isRecordingVideo)

                Button(action: { viewModel.toggleVideoCodec() }) {
                    Text(viewModel.selectedVideoCodec.rawValue)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(amber)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .frame(minWidth: 76, alignment: .leading)
        } else {
            Button(action: { viewModel.togglePhotoFormat() }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PHOTO")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.48))
                    Text(viewModel.selectedPhotoFormat.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(amber)
                }
                .frame(minWidth: 58, alignment: .leading)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var histogram: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HISTOGRAM")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))

            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(viewModel.histogramBars) { bar in
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(bar.color.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, bar.height * 22))
                }
            }
            .frame(height: 22, alignment: .bottom)
        }
    }

    private var exposure: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(viewModel.liveShutterSpeed)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text(viewModel.liveISO)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
        }
        .frame(minWidth: 58, alignment: .trailing)
    }
}
