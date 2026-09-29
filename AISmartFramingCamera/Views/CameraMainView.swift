import SwiftUI
import AVFoundation

/// Works in the space SwiftUI has already inset away from the status bar and
/// Home Indicator. The live preview and every overlay receive one exact size.
struct CameraFormFactorLayout {
    let availableSize: CGSize
    let safeAreaInsets: EdgeInsets

    var isCompact: Bool { availableSize.height < 700 || availableSize.width < 375 }
    var topHorizontalPadding: CGFloat { availableSize.width < 375 ? 8 : 14 }
    var topVerticalPadding: CGFloat {
        isCompact ? 2 : min(18, max(4, (availableSize.height - 700) * 0.12))
    }
    var topBottomPadding: CGFloat { isCompact ? 4 : 6 }
    var controlDeckHeight: CGFloat { isCompact ? 148 : 156 }
    var minimumGap: CGFloat { isCompact ? 4 : 8 }
    var bottomComfort: CGFloat {
        safeAreaInsets.bottom >= 20 ? (isCompact ? 8 : 14) : (isCompact ? 6 : 10)
    }
    var viewfinderSize: CGSize {
        let widthLimit = max(1, availableSize.width - 12)
        let heightLimit = max(1, availableSize.height - 44 - topVerticalPadding -
                              topBottomPadding - controlDeckHeight - bottomComfort - minimumGap)
        let height = min(widthLimit * 4 / 3, heightLimit)
        return CGSize(width: height * 3 / 4, height: height)
    }
    var histogramWidth: CGFloat {
        max(70, min(100, availableSize.width * 0.22))
    }
    var viewfinderTopInset: CGFloat { max(6, min(12, viewfinderSize.height * 0.02)) }
    var viewfinderBottomInset: CGFloat { max(8, min(14, viewfinderSize.height * 0.025)) }
}

extension View {
    @ViewBuilder
    func onChangeCompatible<Value: Equatable>(of value: Value,
                                              perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value, initial: false) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

// MARK: - Camera Main View (Obsidian Minimalist Pro Edition)
public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBlinkingRed: Bool = false

    public init() {}

    private let canvasBackground = Color(red: 0.031, green: 0.035, blue: 0.047) // #08090C

    public var body: some View {
        GeometryReader { geometry in
            let layout = CameraFormFactorLayout(availableSize: geometry.size,
                                                safeAreaInsets: geometry.safeAreaInsets)
            ZStack {
                // 1. Deep Obsidian Canvas
                canvasBackground
                    .ignoresSafeArea()

                if viewModel.hasCameraPermission {
                    VStack(spacing: 0) {
                        // 2. Minimalist Top Pro Toolbar
                        TopCameraBar(viewModel: viewModel, histogramWidth: layout.histogramWidth)
                            .frame(height: 44)
                            .padding(.horizontal, layout.topHorizontalPadding)
                            .padding(.top, layout.topVerticalPadding)
                            .padding(.bottom, layout.topBottomPadding)

                        Spacer(minLength: layout.minimumGap / 2)

                        // 3. Fixed 3:4 High-End Viewfinder (Identical in Photo & Video)
                        ZStack {
                            CameraPreviewView(viewModel: viewModel)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .saturation(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveSaturation : 1.0)
                                .contrast(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveContrast : 1.0)
                                .brightness(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveBrightness : 0.0)

                            // Realtime Film Atmosphere Overlay
                            if viewModel.isFilmSimulationActive {
                                FilmViewfinderAtmosphereOverlay(preset: viewModel.selectedFilmPreset)
                            }

                            // AR AI Framing Lines & Reticle
                            ARFramingOverlayView(viewModel: viewModel)

                            // Rangefinder Windowed Zoom Overlay
                            if viewModel.isWindowedZoomActive {
                                GeometryReader { proxy in
                                    WindowedZoomOverlayView(viewModel: viewModel, containerSize: proxy.size)
                                }
                                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                            }

                            // Keep the viewfinder responsive when AVFoundation is
                            // configuring or temporarily unavailable.
                            if viewModel.isCameraHibernating || !viewModel.isCameraReady {
                                CameraHibernationStandbyView()
                                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                                if !viewModel.isCameraHibernating {
                                    VStack(spacing: 8) {
                                        Spacer()
                                        Text("Đang kết nối camera")
                                            .font(.caption.weight(.medium))
                                            .foregroundColor(.white.opacity(0.8))
                                        Button("Thử lại") {
                                            viewModel.requestPermissionsAndStart()
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.white)
                                        .padding(.bottom, 32)
                                    }
                                }
                            }
                        }
                        .frame(width: layout.viewfinderSize.width,
                               height: layout.viewfinderSize.height)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(red: 0.15, green: 0.16, blue: 0.20), lineWidth: 1.0)
                        }
                        .shadow(color: Color.black.opacity(0.60), radius: 12, y: 4)
                        // Top Viewfinder Overlays (Video Timer / AI Status)
                        .overlay(alignment: .top) {
                            VStack(spacing: 6) {
                                if viewModel.isRecordingVideo {
                                    videoRecordingHUD
                                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                                }

                                AIStatusHUDView(viewModel: viewModel)
                            }
                            .padding(.top, layout.viewfinderTopInset)
                        }
                        // Bottom In-Viewfinder Minimalist Zoom Selector (Centered, No Capsule Background)
                        .overlay(alignment: .bottom) {
                            if !viewModel.isWindowedZoomActive {
                                ViewfinderZoomSelectorPill(viewModel: viewModel)
                                    .padding(.bottom, layout.viewfinderBottomInset)
                            }
                        }
                        .padding(.horizontal, 6)

                        Spacer(minLength: layout.minimumGap / 2)

                        // 4. Bottom Control Deck (Album + Minimalist Shutter + Camera Flip + AI Button + Mode Switcher)
                        CameraControlsView(viewModel: viewModel, compact: layout.isCompact)
                            .frame(height: layout.controlDeckHeight)
                            .padding(.bottom, layout.bottomComfort)
                    }
                } else {
                    CameraPermissionPlaceholderView(viewModel: viewModel)
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.compositionPreviewPresentation) { presentation in
            CompositionPreviewSheet(choices: viewModel.localCompositionChoices,
                onSelect: viewModel.selectCompositionPreview,
                onCancel: { viewModel.cancelCompositionPreview(id: presentation.id) })
                .onDisappear { viewModel.compositionPreviewDidDismiss(id: presentation.id) }
        }
        .sheet(isPresented: $viewModel.isCompositionRuleSheetPresented) {
            CompositionRuleSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingGallerySheet) {
            PhotoGallerySheetView(viewModel: viewModel)
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
        .onChangeCompatible(of: viewModel.isRecordingVideo) { isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isBlinkingRed = true
                }
            } else {
                isBlinkingRed = false
            }
        }
        .onChangeCompatible(of: scenePhase) { newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
    }

    // MARK: - Video Recording Timer Badge
    private var videoRecordingHUD: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isBlinkingRed ? 1.0 : 0.25)

            Text(viewModel.videoRecordingTimeString)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .stroke(Color.red.opacity(0.35), lineWidth: 1.0)
                )
        )
    }
}

// MARK: - Top Camera Bar (Flash, Histogram, ISO, EV, Format, 4:3, Windowed Zoom, Settings)
struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    let histogramWidth: CGFloat
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25) // #D9A441

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // 1. Flash Toggle Button
            Button(action: {
                viewModel.toggleFlash()
            }) {
                Image(systemName: flashIconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(viewModel.activeFlashMode == .off ? Color.white.opacity(0.85) : amberGold)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đèn flash")

            // 2. Mini Live Color Histogram
            if viewModel.showHistogramInViewfinder {
                LiveColorHistogramHUDView(viewModel: viewModel, width: histogramWidth)
                    .frame(height: 28)
            }

            Spacer(minLength: 2)

            // 3. Technical Specs Row: ISO, EV, Format/Codec, 4:3
            HStack(spacing: 8) {
                Text(viewModel.liveISO)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))

                Text(String(format: "EV %+.1f", viewModel.exposureBias))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))

                Button(action: {
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    if viewModel.captureMode.isVideo {
                        viewModel.toggleVideoFormat()
                    } else {
                        viewModel.togglePhotoFormat()
                    }
                }) {
                    HStack(spacing: 3) {
                        if viewModel.selectedPhotoFormat == .dng && !viewModel.captureMode.isVideo {
                            Circle()
                                .fill(amberGold)
                                .frame(width: 4, height: 4)
                        }
                        Text(currentFormatLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(viewModel.selectedPhotoFormat == .dng && !viewModel.captureMode.isVideo ? .black : amberGold)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        viewModel.selectedPhotoFormat == .dng && !viewModel.captureMode.isVideo
                            ? RoundedRectangle(cornerRadius: 4).fill(amberGold)
                            : RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Định dạng: \(currentFormatLabel). Chạm để thay đổi.")

                Text("4:3")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.80)

            Spacer(minLength: 2)

            // 4. Windowed Zoom Mode Toggle Button
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                generator.impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    viewModel.isWindowedZoomActive.toggle()
                }
            }) {
                Image(systemName: viewModel.isWindowedZoomActive ? "viewfinder.circle.fill" : "viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(viewModel.isWindowedZoomActive ? amberGold : Color.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Chế độ khung ngắm Windowed Zoom")

            // 5. Settings Sheet Button (Gear Icon)
            Button(action: {
                viewModel.isShowingSettings = true
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Cài đặt hệ thống")
        }
        .frame(height: 44)
    }

    private var flashIconName: String {
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        @unknown default: return "bolt.fill"
        }
    }

    private var currentFormatLabel: String {
        if viewModel.captureMode.isVideo {
            return viewModel.activeVideoResolutionString
        }
        switch viewModel.selectedPhotoFormat {
        case .dng: return "RAW"
        case .heif, .heic: return "HEIF"
        case .jpeg: return "JPEG"
        }
    }
}

// MARK: - Minimalist Optical Zoom Selector (Strictly 1×, 2×, 3× with Single Matched Ring, No Capsule Background)
struct ViewfinderZoomSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var zoomPillNamespace
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)
    private let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(zoomOptions, id: \.self) { zoom in
                let isSelected = viewModel.selectedZoomPreset == zoom
                Button(action: {
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                        viewModel.setZoomFromButton(zoom)
                    }
                }) {
                    ZStack {
                        if isSelected {
                            Circle()
                                .stroke(amberGold, lineWidth: 1.5)
                                .frame(width: 32, height: 32)
                                .matchedGeometryEffect(id: "active_viewfinder_zoom_ring", in: zoomPillNamespace)
                        }

                        Text("\(Int(zoom))x")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.78))
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Thu phóng \(Int(zoom)) lần")
            }
        }
    }
}

// MARK: - Composition Rule Quick Sheet
struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chọn quy tắc bố cục để hệ thống tự động nhận diện chủ thể và đưa ra hướng dẫn căn góc tối ưu.")
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
                            .padding(.horizontal, 4)

                        ruleListView

                        Divider().background(Color.white.opacity(0.08)).padding(.vertical, 4)

                        VStack(spacing: 10) {
                            Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)
                                .tint(amberGold)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(16)
                }

                bottomActionBar
            }
            .background(Color(red: 0.031, green: 0.035, blue: 0.047).ignoresSafeArea())
            .navigationTitle("Bố cục thông minh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(amberGold)
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
    }

    private var ruleListView: some View {
        VStack(spacing: 8) {
            ForEach(CompositionRule.allCases) { rule in
                CompositionRuleRow(
                    rule: rule,
                    isSelected: viewModel.activeCompositionRule == rule,
                    onSelect: { viewModel.selectRule(rule) }
                )
            }
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))

            if viewModel.aiSessionState.isSessionActive {
                Button(action: {
                    viewModel.cancelAISession()
                    dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Dừng căn bố cục")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.85)))
                }
                .padding(16)
            } else {
                Button(action: {
                    dismiss()
                    viewModel.startAISession()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                        Text("Bắt đầu căn bố cục")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(amberGold))
                }
                .padding(16)
            }
        }
        .background(Color(red: 0.075, green: 0.082, blue: 0.102))
    }
}

// MARK: - Composition Rule Row
struct CompositionRuleRow: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.8))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayNameVietnamese)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color.white)
                    Text(rule.descriptionVietnamese)
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(amberGold)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? amberGold.opacity(0.12) : Color(red: 0.075, green: 0.082, blue: 0.102))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? amberGold.opacity(0.50) : Color.white.opacity(0.08), lineWidth: 1.0)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Camera Permission Placeholder View
struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 54))
                .foregroundColor(amberGold)

            Text("Cho phép camera để bắt đầu")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("AlignAI Camera cần quyền truy cập camera để hiển thị khung ngắm thời gian thực và hỗ trợ căn bố cục chuẩn xác.")
                .font(.subheadline)
                .foregroundColor(Color(red: 0.58, green: 0.60, blue: 0.66))
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
                    .background(amberGold)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding()
    }
}

// MARK: - Live Viewfinder Film Atmosphere Overlay
public struct FilmViewfinderAtmosphereOverlay: View {
    let preset: FilmPreset

    public init(preset: FilmPreset) {
        self.preset = preset
    }

    public var body: some View {
        ZStack {
            // 1. Color Tint Layer
            if let tintColor = preset.liveTintOverlayColor {
                tintColor
                    .opacity(preset.liveTintOpacity)
                    .blendMode(.color)
            }

            // 2. Optical Vignette Ring
            if preset.liveVignetteIntensity > 0 {
                GeometryReader { geo in
                    let maxDim = max(geo.size.width, geo.size.height)
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.clear,
                            Color.black.opacity(preset.liveVignetteIntensity * 0.40),
                            Color.black.opacity(preset.liveVignetteIntensity)
                        ]),
                        center: .center,
                        startRadius: maxDim * 0.28,
                        endRadius: maxDim * 0.72
                    )
                }
            }

            // 3. Retro Video / LCD Scanline Texture
            if preset.hasScanlines {
                ScanlineRasterView()
                    .opacity(0.12)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.20), value: preset)
    }
}

// MARK: - Lightweight Scanline Raster Pattern
private struct ScanlineRasterView: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let spacing: CGFloat = 3.5
                let count = Int(geo.size.height / spacing)
                for i in 0..<count {
                    let y = CGFloat(i) * spacing
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.black, lineWidth: 1.0)
        }
    }
}

// MARK: - Standby View khi Camera Ngủ Đông
struct CameraHibernationStandbyView: View {
    private let canvasBackground = Color(red: 0.031, green: 0.035, blue: 0.047) // #08090C

    var body: some View {
        ZStack {
            canvasBackground
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if let uiImage = UIImage(named: "AppLogo") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "AppLogo", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                } else {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                }

                Text("AlignAI Camera")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
