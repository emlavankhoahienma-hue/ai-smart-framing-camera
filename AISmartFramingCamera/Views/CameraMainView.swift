import SwiftUI
import AVFoundation

/// Works in the space SwiftUI has already inset away from the status bar and
/// Home Indicator. The live preview and every overlay receive one exact size.
struct CameraFormFactorLayout {
    let availableSize: CGSize
    let safeAreaInsets: EdgeInsets
    var isVideo: Bool = false

    var isCompact: Bool { availableSize.height < 700 || availableSize.width < 375 }
    var topHorizontalPadding: CGFloat { availableSize.width < 375 ? 8 : (availableSize.width < 390 ? 10 : 14) }
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
        if isVideo {
            // Chuẩn khung hình điện ảnh 16:9 chiều dọc (9:16 = 0.5625)
            // Khớp 100% tỷ lệ cảm biến 4K/1080P, tuyệt đối không bị vuông, không bị crop méo
            let targetAspect: CGFloat = 9.0 / 16.0
            var height = min(widthLimit / targetAspect, heightLimit)
            var width = height * targetAspect
            if width > widthLimit {
                width = widthLimit
                height = width / targetAspect
            }
            return CGSize(width: width, height: height)
        } else {
            let height = min(widthLimit * 4.0 / 3.0, heightLimit)
            return CGSize(width: height * 3.0 / 4.0, height: height)
        }
    }
    var histogramWidth: CGFloat {
        availableSize.width < 380 ? 46 : min(62, availableSize.width * 0.15)
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
                                                safeAreaInsets: geometry.safeAreaInsets,
                                                isVideo: viewModel.captureMode.isVideo)
            ZStack {
                // 1. Deep Obsidian Canvas
                canvasBackground
                    .ignoresSafeArea()

                if viewModel.hasCameraPermission {
                    VStack(spacing: 0) {
                        // 2. Minimalist Top Pro Toolbar
                        TopCameraBar(viewModel: viewModel, histogramWidth: layout.histogramWidth)
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, layout.topHorizontalPadding)
                            .padding(.top, layout.topVerticalPadding)
                            .padding(.bottom, layout.topBottomPadding)

                        Spacer(minLength: layout.minimumGap / 2)

                        // 3. High-End Viewfinder (Consistent Full-Width in Photo & Video)
                        ZStack {
                            CameraPreviewView(viewModel: viewModel)

                            // Realtime Film Atmosphere Overlay
                            if viewModel.isFilmSimulationActive {
                                FilmViewfinderAtmosphereOverlay(preset: viewModel.selectedFilmPreset)
                                    .opacity(viewModel.filmSimulationIntensity)
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

                            // Optical Zoom HUD Feedback Badge
                            if viewModel.isZoomHUDVisible, let hudText = viewModel.activeZoomHUDText {
                                VStack {
                                    HStack(spacing: 6) {
                                        Image(systemName: "camera.aperture")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(AlignTheme.electricCyan)
                                        Text(hudText)
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundColor(AlignTheme.platinumWhite)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(AlignTheme.obsidianBlack.opacity(0.85))
                                            .overlay(
                                                Capsule()
                                                    .stroke(AlignTheme.rimGradient, lineWidth: 1.0)
                                            )
                                    )
                                    .shadow(color: AlignTheme.electricCyan.opacity(0.35), radius: 8)
                                    .padding(.top, 16)
                                    Spacer()
                                }
                                .transition(.scale(scale: 0.88).combined(with: .opacity))
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
                        .animation(.easeInOut(duration: 0.28), value: viewModel.captureMode.isVideo)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(red: 0.15, green: 0.16, blue: 0.20), lineWidth: 1.0)
                        }
                        .shadow(color: Color.black.opacity(0.60), radius: 12, y: 4)
                        // In-Viewfinder Stereo Audio VU Level Meter (Top Leading)
                        .overlay(alignment: .topLeading) {
                            if viewModel.showAudioLevelMeter && !viewModel.isCameraHibernating && viewModel.captureMode.isVideo {
                                AudioVULevelMeterView(levels: viewModel.audioLevels)
                                    .padding(.top, layout.viewfinderTopInset)
                                    .padding(.leading, 10)
                                    .transition(.opacity)
                            }
                        }
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
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, layout.bottomComfort)
                    }
                    .frame(width: geometry.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CameraPermissionPlaceholderView(viewModel: viewModel)
                        .frame(width: geometry.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // 1. Flash Toggle Button
            Button(action: {
                viewModel.toggleFlash()
            }) {
                Image(systemName: flashIconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(viewModel.activeFlashMode == .off ? Color.white.opacity(0.85) : AlignTheme.amberGold)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đèn flash")

            // 2. Mini Live Color Histogram
            if viewModel.showHistogramInViewfinder {
                LiveColorHistogramHUDView(viewModel: viewModel, width: histogramWidth)
                    .frame(height: 26)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 4)

            // 3. Technical Specs Row: ISO, EV, Format/Codec, 4:3 (Hiển thị đầy đủ, không bị cắt chữ)
            HStack(spacing: 5) {
                Text(viewModel.liveISO)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize()

                Text(String(format: "EV %+.1f", viewModel.exposureBias))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize()

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
                                .fill(Color.white)
                                .frame(width: 4, height: 4)
                        }
                        Text(currentFormatLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.0)
                    .background(
                        viewModel.selectedPhotoFormat == .dng && !viewModel.captureMode.isVideo
                            ? RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.25))
                            : RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12))
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .fixedSize()
                .accessibilityLabel("Định dạng: \(currentFormatLabel). Chạm để thay đổi.")

                Text(viewModel.captureMode.isVideo ? "16:9" : (viewModel.isWindowedZoomActive ? viewModel.windowedZoomAspectRatio.rawValue : "4:3"))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize()
            }
            .lineLimit(1)

            Spacer(minLength: 4)

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
                    .foregroundColor(viewModel.isWindowedZoomActive ? AlignTheme.electricCyan : Color.white.opacity(0.85))
                    .frame(width: 36, height: 36)
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
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Cài đặt hệ thống")
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
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

// MARK: - Minimalist Optical Zoom Selector (Strictly 1x, 2x, 3x with Single Matched Ring, No Capsule Background)
struct ViewfinderZoomSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var zoomPillNamespace
    private var zoomOptions: [CGFloat] {
        let opts = viewModel.cameraService.availableDisplayZoomOptions.filter { $0 < 4.9 }
        if !opts.isEmpty {
            return opts
        }
        if viewModel.cameraService.hasUltraWideLens {
            return [0.5, 1.0, 2.0, 3.0]
        } else {
            return [1.0, 2.0, 3.0]
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(zoomOptions, id: \.self) { zoom in
                let isSelected = viewModel.selectedZoomPreset == zoom
                Button(action: {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.prepare()
                    impact.impactOccurred()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                        viewModel.setZoomFromButton(zoom)
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(isSelected ? 0.60 : 0.32))
                            .frame(width: 34, height: 34)

                        if isSelected {
                            Circle()
                                .stroke(AlignTheme.signatureGradient, lineWidth: 1.8)
                                .frame(width: 34, height: 34)
                                .shadow(color: AlignTheme.electricCyan.opacity(0.55), radius: 6)
                                .matchedGeometryEffect(id: "active_viewfinder_zoom_ring", in: zoomPillNamespace)
                        }

                        Text(zoom == 0.5 ? "0.5x" : "\(Int(zoom))x")
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? .white : Color.white.opacity(0.75))
                    }
                    .scaleEffect(isSelected ? 1.08 : 0.96)
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(zoom == 0.5 ? "Thu phong 0.5 lan" : "Thu phong \(Int(zoom)) lan")
            }
        }
    }
}

// MARK: - Composition Rule Quick Sheet
struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

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
                                .tint(AlignTheme.irisViolet)
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
                        .foregroundColor(AlignTheme.electricCyan)
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
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(AlignTheme.signatureGradient)
                    )
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

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? AlignTheme.irisViolet : Color.white.opacity(0.8))
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
                        .foregroundColor(AlignTheme.electricCyan)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AlignTheme.irisViolet.opacity(0.18) : Color(red: 0.075, green: 0.082, blue: 0.102))
                    .overlay(
                        Group {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AlignTheme.signatureGradient, lineWidth: 1.0)
                            } else {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1.0)
                            }
                        }
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Camera Permission Placeholder View
struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 54))
                .foregroundColor(AlignTheme.electricCyan)

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
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(AlignTheme.signatureGradient)
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
    @AppStorage("camera_standby_is_white_bg") private var isWhiteBackground: Bool = false

    private var currentBackground: Color {
        isWhiteBackground ? Color(red: 0.965, green: 0.968, blue: 0.975) : Color(red: 0.031, green: 0.035, blue: 0.047)
    }

    private var primaryTextColor: Color {
        isWhiteBackground ? Color(red: 0.12, green: 0.13, blue: 0.16) : Color.white
    }

    private var secondaryTextColor: Color {
        isWhiteBackground ? Color.black.opacity(0.48) : Color.white.opacity(0.55)
    }

    private var pillBackground: Color {
        isWhiteBackground ? Color.black.opacity(0.06) : Color.white.opacity(0.10)
    }

    private var pillBorderColor: Color {
        isWhiteBackground ? Color.black.opacity(0.12) : Color.white.opacity(0.16)
    }

    var body: some View {
        ZStack {
            currentBackground
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: isWhiteBackground)

            VStack(spacing: 14) {
                // Biểu tượng Logo mới tách nền
                if let uiImage = UIImage(named: "AppLogo") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "AppLogo", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .shadow(color: isWhiteBackground ? Color.black.opacity(0.10) : Color.black.opacity(0.50), radius: 12, y: 4)
                } else {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .shadow(color: isWhiteBackground ? Color.black.opacity(0.10) : Color.black.opacity(0.50), radius: 12, y: 4)
                }

                VStack(spacing: 4) {
                    Text("AlignAI Camera")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .tracking(0.6)
                        .foregroundColor(primaryTextColor)

                    Text("Hệ thống camera đang sẵn sàng")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(secondaryTextColor)
                }

                // Nút chuyển đổi nhanh Nền Đen / Nền Trắng
                Button(action: {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isWhiteBackground.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isWhiteBackground ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(isWhiteBackground ? "Nền đen" : "Nền trắng")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(primaryTextColor.opacity(0.80))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(pillBackground)
                            .overlay(
                                Capsule()
                                    .stroke(pillBorderColor, lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            withAnimation(.easeInOut(duration: 0.25)) {
                isWhiteBackground.toggle()
            }
        }
    }
}
