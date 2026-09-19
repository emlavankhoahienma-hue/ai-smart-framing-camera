import SwiftUI
import AVFoundation

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

private enum CameraLayoutMetrics {
    static let topBarHeight: CGFloat = 52
    static let controlDeckHeight: CGFloat = 132
    static let overlayGap: CGFloat = 10
    static let zoomControlHeight: CGFloat = 48
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
                // The viewfinder owns a fixed frame and never participates in control layout.
                viewfinder
                    .frame(width: previewFrame.width, height: previewFrame.height)
                    .position(x: previewFrame.midX, y: previewFrame.midY)

                floatingCameraChrome(in: proxy.size, previewFrame: previewFrame)
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

    private func floatingCameraChrome(in size: CGSize, previewFrame: CGRect) -> some View {
        let controlDeckTop = size.height - CameraLayoutMetrics.controlDeckHeight
        let hudCenterY = max(
            CameraLayoutMetrics.topBarHeight + 38,
            previewFrame.minY + 41
        )
        let preferredZoomCenterY = min(
            previewFrame.maxY - 34,
            controlDeckTop - 32
        )
        let zoomCenterY = max(hudCenterY + 78, preferredZoomCenterY)
        let floatingPanelBottom = zoomCenterY
            - CameraLayoutMetrics.zoomControlHeight / 2
            - CameraLayoutMetrics.overlayGap

        return ZStack {
            VStack(spacing: 0) {
                TopBarView(viewModel: viewModel)
                    .frame(height: CameraLayoutMetrics.topBarHeight)

                Spacer(minLength: 0)

                CameraControlsView(viewModel: viewModel)
                    .frame(height: CameraLayoutMetrics.controlDeckHeight)
            }

            if viewModel.activeCameraPanel == .telemetry {
                LiveColorHistogramHUDView(viewModel: viewModel)
                    .frame(width: max(280, previewFrame.width - 24))
                    .position(x: previewFrame.midX, y: hudCenterY)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }

            ViewfinderZoomSwitcher(viewModel: viewModel)
                .frame(height: CameraLayoutMetrics.zoomControlHeight)
                .position(x: previewFrame.midX, y: zoomCenterY)
                .zIndex(4)

            floatingDrawer(
                availableWidth: size.width,
                bottomY: floatingPanelBottom,
                minimumTopY: hudCenterY + 42
            )
            .zIndex(2)
        }
    }

    @ViewBuilder
    private func floatingDrawer(
        availableWidth: CGFloat,
        bottomY: CGFloat,
        minimumTopY: CGFloat
    ) -> some View {
        if viewModel.activeCameraPanel == .filmPresets {
            let drawerHeight: CGFloat = 88
            FilmPresetDrawer(viewModel: viewModel)
                .frame(width: availableWidth, height: drawerHeight, alignment: .bottom)
                .position(x: availableWidth / 2, y: bottomY - drawerHeight / 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if viewModel.captureMode == .proVideo {
            let requestedHeight: CGFloat = viewModel.activeCameraPanel == .proControls ? 216 : 58
            let availableHeight = max(58, bottomY - minimumTopY - CameraLayoutMetrics.overlayGap)
            let drawerHeight = min(requestedHeight, availableHeight)

            ProVideoManualControlsView(viewModel: viewModel)
                .frame(width: availableWidth, height: drawerHeight, alignment: .bottom)
                .position(x: availableWidth / 2, y: bottomY - drawerHeight / 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct TopBarView: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var isTorchEnabled = false

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
                    icon: lightIconName,
                    tint: isLightActive ? CameraChromeStyle.amber : CameraChromeStyle.primaryText,
                    label: viewModel.captureMode.isVideo ? "Đèn pin" : "Chế độ đèn flash"
                ) {
                    handleLightButtonTap()
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
        .background(CameraChromeStyle.background)
        .onChange(of: viewModel.captureMode) { mode in
            if !mode.isVideo && isTorchEnabled {
                setTorchEnabled(false)
            }
        }
        .onDisappear {
            if isTorchEnabled {
                setTorchEnabled(false)
            }
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

    private var isLightActive: Bool {
        if viewModel.captureMode.isVideo {
            return isTorchEnabled
        }
        return viewModel.activeFlashMode != .off
    }

    private var lightIconName: String {
        if viewModel.captureMode.isVideo {
            return isTorchEnabled ? "flashlight.on.fill" : "flashlight.off.fill"
        }

        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash"
        @unknown default: return "bolt"
        }
    }

    private func handleLightButtonTap() {
        if viewModel.captureMode.isVideo {
            setTorchEnabled(!isTorchEnabled)
        } else {
            viewModel.toggleFlash()
        }
    }

    private func setTorchEnabled(_ enabled: Bool) {
        viewModel.cameraService.scheduleDeviceConfiguration { device in
            let requestedMode: AVCaptureDevice.TorchMode = enabled ? .on : .off
            guard device.hasTorch, device.isTorchModeSupported(requestedMode) else {
                DispatchQueue.main.async {
                    self.isTorchEnabled = false
                }
                return
            }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if enabled {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }

                DispatchQueue.main.async {
                    self.isTorchEnabled = enabled
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTorchEnabled = false
                }
            }
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
