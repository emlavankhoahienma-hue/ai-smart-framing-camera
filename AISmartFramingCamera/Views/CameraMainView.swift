import SwiftUI

public enum CameraOverlayPanel: Equatable, Sendable {
    case none
    case telemetry
    case proControls
    case filmPresets
}

private enum CameraChromeStyle {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.04)
    static let primaryText = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let secondaryText = Color(red: 0.62, green: 0.62, blue: 0.65)
    static let divider = Color.white.opacity(0.10)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.0)
}

public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.hasCameraPermission {
                cameraInterface
            } else {
                CameraPermissionPlaceholderView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingPhotoDetail) {
            if let latest = viewModel.latestCapturedPhoto {
                CapturedPhotoPreviewView(item: latest, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isShowingVideoPreview) {
            if let videoURL = viewModel.recordedVideoURL {
                VideoPreviewSheetView(videoURL: videoURL, viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.requestPermissionsAndStart()
        }
    }

    private var cameraInterface: some View {
        GeometryReader { proxy in
            let previewGeometry = CameraPreviewGeometry(captureMode: viewModel.captureMode)
            let previewFrame = previewGeometry.centeredFrame(in: proxy.size)

            ZStack {
                viewfinder
                    .frame(width: previewFrame.width, height: previewFrame.height)
                    .position(x: previewFrame.midX, y: previewFrame.midY)

                cameraChrome
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.22), value: viewModel.captureMode)
        }
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreviewView(viewModel: viewModel)
            ARFramingOverlayView(viewModel: viewModel)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var cameraChrome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                TopCameraBar(viewModel: viewModel)

                if viewModel.activeCameraPanel == .telemetry {
                    LiveColorHistogramHUDView(viewModel: viewModel)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(CameraChromeStyle.background.opacity(0.96))

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                ViewfinderZoomSwitcher(viewModel: viewModel)

                if viewModel.captureMode == .proVideo {
                    ProVideoManualControlsView(viewModel: viewModel)
                        .frame(maxHeight: viewModel.activeCameraPanel == .proControls ? 216 : 58)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                CameraControlsView(viewModel: viewModel)
            }
            .padding(.top, 10)
            .background(CameraChromeStyle.background.opacity(0.96))
        }
    }
}

struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        ZStack {
            if viewModel.captureMode.isVideo && viewModel.isRecordingVideo {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text(viewModel.videoRecordingTimeString)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(CameraChromeStyle.primaryText)
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                chromeButton(
                    icon: flashIconName,
                    tint: viewModel.activeFlashMode == .off ? CameraChromeStyle.primaryText : CameraChromeStyle.amber,
                    label: "Chế độ đèn flash"
                ) {
                    viewModel.toggleFlash()
                }

                Spacer()

                HStack(spacing: 2) {
                    chromeButton(
                        icon: viewModel.activeCameraPanel == .telemetry ? "info.circle.fill" : "info.circle",
                        tint: viewModel.activeCameraPanel == .telemetry ? CameraChromeStyle.amber : CameraChromeStyle.primaryText,
                        label: "Thông tin ảnh và histogram"
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            viewModel.toggleCameraPanel(.telemetry)
                        }
                    }

                    chromeButton(
                        icon: "gearshape",
                        tint: CameraChromeStyle.primaryText,
                        label: "Cài đặt"
                    ) {
                        viewModel.dismissCameraPanels()
                        viewModel.isShowingSettings = true
                    }
                }
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CameraChromeStyle.divider)
                .frame(height: 1)
        }
    }

    private func chromeButton(
        icon: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(label)
    }

    private var flashIconName: String {
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash"
        @unknown default: return "bolt"
        }
    }
}

struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 54))
                .foregroundColor(CameraChromeStyle.amber)

            Text("Cho phép camera để bắt đầu")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("AlignAI Studio cần camera để hiển thị bản xem trước, lấy nét và hỗ trợ căn bố cục.")
                .font(.subheadline)
                .foregroundColor(CameraChromeStyle.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Mở Cài đặt")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(CameraChromeStyle.amber)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding()
    }
}
