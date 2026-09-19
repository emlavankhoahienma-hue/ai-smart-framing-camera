import SwiftUI
import AVFoundation

/// Only viewport geometry determines the preview frame. Drawers never participate in its layout.
struct CameraViewportLayout {
    let size: CGSize
    let topBarHeight: CGFloat = 52
    let deckHeight: CGFloat = 184
    var stageHeight: CGFloat { max(0, size.height - topBarHeight - deckHeight - 12) }
    var previewSize: CGSize {
        let width = min(size.width, stageHeight * 3 / 4)
        return CGSize(width: width, height: width * 4 / 3)
    }
    var previewCenter: CGPoint { CGPoint(x: size.width / 2, y: topBarHeight + stageHeight / 2) }
    // 92 points are reserved for telemetry + AI status, even while they are hidden.
    var drawerHeight: CGFloat { max(0, min(300, stageHeight - 104)) }
}

public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let layout = CameraViewportLayout(size: proxy.size)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if viewModel.hasCameraPermission {
                    // This identity, frame and aspect ratio are independent of all overlay state.
                    ZStack {
                        CameraPreviewView(viewModel: viewModel)
                        ARFramingOverlayView(viewModel: viewModel)
                    }
                    .frame(width: layout.previewSize.width, height: layout.previewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .position(layout.previewCenter)

                    TopCameraBar(viewModel: viewModel).frame(height: layout.topBarHeight)
                    VStack(spacing: 6) {
                        if viewModel.showHistogramInViewfinder || viewModel.captureMode == .proVideo {
                            LiveColorHistogramHUDView(viewModel: viewModel)
                        }
                        AIStatusHUDView(viewModel: viewModel)
                    }
                    .padding(.top, 6)
                    .frame(width: max(0, layout.previewSize.width - 20), height: 92, alignment: .top)
                    .position(x: proxy.size.width / 2, y: layout.topBarHeight + 46)

                    // The drawer's upper edge cannot enter the HUD's reserved area.
                    if viewModel.isShowingFilmDrawer || (viewModel.captureMode == .proVideo && viewModel.isShowingProControlsDrawer) {
                        Group {
                            if viewModel.isShowingFilmDrawer { FilmPresetDrawer(viewModel: viewModel) }
                            else { ProVideoManualControlsView(viewModel: viewModel) }
                        }
                        .frame(width: min(proxy.size.width - 24, 520), height: layout.drawerHeight)
                        .clipped()
                        .position(x: proxy.size.width / 2,
                                  y: layout.topBarHeight + layout.stageHeight - layout.drawerHeight / 2 - 4)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                    CameraControlsView(viewModel: viewModel)
                        .frame(height: layout.deckHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height - layout.deckHeight / 2 - 4)
                } else {
                    CameraPermissionPlaceholderView(viewModel: viewModel)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .animation(reduceMotion ? nil : CameraUI.spring, value: viewModel.isShowingFilmDrawer)
            .animation(reduceMotion ? nil : CameraUI.spring, value: viewModel.isShowingProControlsDrawer)
        }
        .preferredColorScheme(.dark)
        .tint(CameraUI.accent)
        .sheet(isPresented: $viewModel.isShowingSettings) { SettingsSheetView(viewModel: viewModel) }
        .sheet(isPresented: $viewModel.isCompositionRuleSheetPresented) { CompositionRuleSheet(viewModel: viewModel) }
        .sheet(isPresented: $viewModel.isShowingPhotoDetail) {
            if let item = viewModel.latestCapturedPhoto { CapturedPhotoPreviewView(item: item, viewModel: viewModel) }
        }
        .sheet(isPresented: $viewModel.isShowingVideoPreview) {
            if let url = viewModel.recordedVideoURL { VideoPreviewSheetView(videoURL: url, viewModel: viewModel) }
        }
        .onAppear { viewModel.requestPermissionsAndStart() }
        .alert("Không thể hoàn tất", isPresented: Binding(
            get: { viewModel.saveErrorMessage != nil },
            set: { if !$0 { viewModel.saveErrorMessage = nil } }
        )) {
            Button("Đóng", role: .cancel) { viewModel.saveErrorMessage = nil }
        } message: { Text(viewModel.saveErrorMessage ?? "") }
    }
}

public struct LiveViewZoomSwitch: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight
    public init(viewModel: CameraViewModel) { self.viewModel = viewModel }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach([CGFloat(1), CGFloat(2)], id: \.self) { zoom in
                let selected = abs(viewModel.displayZoom - zoom) < 0.08
                Button { viewModel.setZoomFromButton(zoom) } label: {
                    Text("\(Int(zoom))×").font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundColor(selected ? CameraUI.accent : .white)
                        .frame(width: 44, height: 44)
                        .background {
                            if selected { Circle().fill(.white.opacity(0.14)).matchedGeometryEffect(id: "zoom", in: highlight) }
                        }
                }.buttonStyle(CameraPressStyle())
                    .accessibilityLabel("Thu phóng \(Int(zoom)) lần")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            if abs(viewModel.displayZoom - 1) >= 0.08 && abs(viewModel.displayZoom - 2) >= 0.08 {
                Text(String(format: "%.1f×", viewModel.displayZoom))
                    .font(.caption.monospacedDigit()).foregroundColor(CameraUI.accent).padding(.horizontal, 8)
            }
        }
        .background(.white.opacity(0.05), in: Capsule())
        .animation(reduceMotion ? nil : CameraUI.spring, value: viewModel.displayZoom)
        .accessibilityElement(children: .contain)
    }
}

/// Sole owner of light/settings controls. Torch UI uses the existing serial device boundary.
struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var torchOn = false
    @State private var lightBusy = false
    @State private var lightAvailable = false
    @State private var lightError: String?

    var body: some View {
        HStack(spacing: 8) {
            CameraIconButton(symbol: lightSymbol, label: lightLabel, isActive: lightIsActive, action: changeLight)
                .disabled(!viewModel.isCameraReady || !lightAvailable || lightBusy)
                .accessibilityValue(viewModel.captureMode.isVideo ? (torchOn ? "Bật" : "Tắt") : flashValue)
            Button(action: openComposition) {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.isRecordingVideo ? "record.circle" : "viewfinder")
                        .foregroundColor(viewModel.isRecordingVideo ? .red : CameraUI.accent)
                    Text(viewModel.isRecordingVideo ? viewModel.videoRecordingTimeString : "Bố cục AI")
                        .font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(CameraPressStyle()).foregroundColor(.white)
                .disabled(!viewModel.isCameraReady || viewModel.isRecordingVideo)
            if viewModel.captureMode == .proVideo {
                CameraIconButton(symbol: "slider.horizontal.3", label: "Điều khiển Pro", isActive: viewModel.isShowingProControlsDrawer) {
                    viewModel.isShowingProControlsDrawer.toggle()
                    viewModel.isShowingFilmDrawer = false
                }
            }
            CameraIconButton(symbol: "gearshape", label: "Cài đặt") { viewModel.isShowingSettings = true }
                .disabled(viewModel.isRecordingVideo)
        }
        .padding(.horizontal, 12)
        .onAppear { refreshLight() }
        .onChange(of: viewModel.isCameraReady) { _ in refreshLight() }
        .onChange(of: viewModel.captureMode) { mode in
            if !mode.isVideo { setTorch(false) }
            refreshLight()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { setTorch(false) } else { refreshLight() }
        }
        .onDisappear { setTorch(false) }
        .alert("Đèn camera", isPresented: Binding(get: { lightError != nil }, set: { if !$0 { lightError = nil } })) {
            Button("Đóng", role: .cancel) { lightError = nil }
        } message: { Text(lightError ?? "") }
    }
    private var lightIsActive: Bool { viewModel.captureMode.isVideo ? torchOn : viewModel.activeFlashMode != .off }
    private var flashValue: String {
        switch viewModel.activeFlashMode { case .auto: return "Tự động"; case .on: return "Bật"; default: return "Tắt" }
    }
    private var lightLabel: String { viewModel.captureMode.isVideo ? "Đèn pin liên tục" : "Flash ảnh" }
    private var lightSymbol: String {
        if viewModel.captureMode.isVideo { return torchOn ? "flashlight.on.fill" : "flashlight.off.fill" }
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic"
        case .on: return "bolt.fill"
        default: return "bolt.slash"
        }
    }
    private func changeLight() {
        if viewModel.captureMode.isVideo { setTorch(!torchOn) }
        else { viewModel.toggleFlash() }
    }
    private func refreshLight() {
        let video = viewModel.captureMode.isVideo
        viewModel.cameraService.scheduleDeviceConfiguration { device in
            let available = video ? (device.hasTorch && device.isTorchAvailable) : device.hasFlash
            let enabled = device.torchMode == .on
            DispatchQueue.main.async { lightAvailable = available; torchOn = enabled }
        }
    }
    private func setTorch(_ enabled: Bool) {
        guard viewModel.isCameraReady else { return }
        lightBusy = true
        viewModel.cameraService.scheduleDeviceConfiguration { device in
            var message: String?
            do {
                if device.hasTorch {
                    guard !enabled || (device.isTorchAvailable && device.isTorchModeSupported(.on)) else {
                        DispatchQueue.main.async { lightBusy = false; lightError = "Đèn pin hiện không khả dụng." }
                        return
                    }
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if enabled { try device.setTorchModeOn(level: 1) }
                    else { device.torchMode = .off }
                }
            } catch { message = error.localizedDescription }
            let active = device.torchMode == .on
            let resultMessage = message
            DispatchQueue.main.async { torchOn = active; lightBusy = false; lightError = resultMessage }
        }
    }
    private func openComposition() {
        if viewModel.captureMode.isVideo {
            if viewModel.isAIVideoDirectorActive { viewModel.dismissAIVideoDirector() }
            else { viewModel.requestAIVideoCinematographyGuidance() }
        } else { viewModel.isCompositionRuleSheetPresented = true }
    }
}

struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Chọn cách căn khung hình") {
                    ForEach(CompositionRule.allCases) { rule in
                        Button { viewModel.selectRule(rule) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: rule.iconName).frame(width: 28).foregroundColor(CameraUI.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.displayNameVietnamese).foregroundColor(.primary)
                                    Text(rule.descriptionVietnamese).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                                if viewModel.activeCompositionRule == rule { Image(systemName: "checkmark") }
                            }.padding(.vertical, 6)
                        }.accessibilityAddTraits(viewModel.activeCompositionRule == rule ? .isSelected : [])
                    }
                }
                Section {
                    Toggle("Tự chụp khi căn khớp", isOn: $viewModel.isAutoCaptureOnAlignEnabled)
                    Button(viewModel.isAISessionActive ? "Dừng căn bố cục" : "Bắt đầu căn bố cục") {
                        if viewModel.isAISessionActive { viewModel.cancelAISession() }
                        else { viewModel.startAISession() }
                        dismiss()
                    }.font(.headline).frame(minHeight: 44)
                }
            }.navigationTitle("Bố cục AI").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } } }
        }.tint(CameraUI.accent).preferredColorScheme(.dark)
    }
}

struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture").font(.system(size: 64, weight: .ultraLight)).foregroundColor(CameraUI.accent)
            Text("Một góc nhìn mới").font(.title2.bold())
            Text("Cho phép truy cập camera để chụp ảnh, quay video và nhận hướng dẫn bố cục.")
                .foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("Cho phép camera") { viewModel.requestPermissionsAndStart() }.buttonStyle(.borderedProminent)
            Button("Mở quyền ứng dụng") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.frame(minHeight: 44)
        }.padding(32)
    }
}
