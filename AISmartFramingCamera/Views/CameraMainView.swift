import SwiftUI
import AVFoundation

// MARK: - Camera Main View (Dark Luxury Pro Cinema Edition)
public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBlinkingRed: Bool = false

    public init() {}

    private let canvasBackground = Color(red: 0.031, green: 0.035, blue: 0.043) // #08090B

    public var body: some View {
        ZStack {
            // 1. Deep Charcoal Canvas with Subtle Radial Depth
            canvasBackground
                .ignoresSafeArea()

            if viewModel.hasCameraPermission {
                VStack(spacing: 0) {
                    // 2. Floating Top Pro Toolbar
                    TopCameraBar(viewModel: viewModel)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    Spacer(minLength: 2)

                    // 3. Fixed 3:4 High-End Viewfinder (Live View)
                    ZStack {
                        CameraPreviewView(viewModel: viewModel)
                            .saturation(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveSaturation : 1.0)
                            .contrast(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveContrast : 1.0)
                            .brightness(viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.liveBrightness : 0.0)

                        // Realtime Film Atmosphere & Optical Tint Overlay (Zero-Latency GPU Composition)
                        if viewModel.isFilmSimulationActive {
                            FilmViewfinderAtmosphereOverlay(preset: viewModel.selectedFilmPreset)
                        }

                        ARFramingOverlayView(viewModel: viewModel)

                        // Khung ngắm thu nhỏ quang học Rangefinder (Windowed Zoom)
                        if viewModel.isWindowedZoomActive {
                            GeometryReader { proxy in
                                WindowedZoomOverlayView(viewModel: viewModel, containerSize: proxy.size)
                            }
                            .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                        }

                        // Màn hình chờ thương hiệu khi camera ngủ đông (tiết kiệm CPU/GPU/RAM)
                        if viewModel.isCameraHibernating {
                            CameraHibernationStandbyView()
                                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                        }
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(red: 0.18, green: 0.19, blue: 0.23), lineWidth: 1.5)
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
                        .padding(.top, 10)
                    }
                    // Bottom In-Viewfinder Pro Floating Controls
                    .overlay(alignment: .bottom) {
                        HStack(alignment: .bottom, spacing: 0) {
                            // Left: AI Compose Floating Trigger (Ai)
                            AIViewfinderButton(viewModel: viewModel)

                            Spacer(minLength: 8)

                            // Center: Optical Zoom Selector Pill (khi tắt Windowed Zoom)
                            if !viewModel.isWindowedZoomActive {
                                ViewfinderZoomSelectorPill(viewModel: viewModel)
                                Spacer(minLength: 8)
                            }

                            // Right: Framing Tool (nuticonbocucAI)
                            ViewfinderFramingButton(viewModel: viewModel)
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                    .padding(.horizontal, 6)

                    Spacer(minLength: 4)

                    // 4. Bottom Control Deck (Mechanical Shutter + Album + Camera Flip + Mode Switcher)
                    CameraControlsView(viewModel: viewModel)
                }
            } else {
                CameraPermissionPlaceholderView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(viewModel: viewModel)
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
            if viewModel.captureMode == .proVideo {
                viewModel.captureMode = .video
            }
            viewModel.requestPermissionsAndStart()
        }
        .onChange(of: viewModel.isRecordingVideo) { isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isBlinkingRed = true
                }
            } else {
                isBlinkingRed = false
            }
        }
        .onChange(of: scenePhase) { newPhase in
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

// MARK: - Top Camera Bar (Live Color Histogram HUD + Pro Tools Capsule)
struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: Live Color Histogram HUD (Histogram, ISO, EV, Format)
            if viewModel.showHistogramInViewfinder {
                LiveColorHistogramHUDView(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                HStack(spacing: 8) {
                    Text(viewModel.liveISO)
                    Text(String(format: "EV %+.1f", viewModel.exposureBias))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 10)
                .frame(height: 38)
            }

            Spacer(minLength: 8)

            // Right: Pro Tools Capsule (Camera Flip, Flash, Film Filters, Settings)
            HStack(spacing: 2) {
                // 0. Camera Switch Button (Trước / Sau - cạnh panel Histogram)
                Button(action: {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.prepare()
                    generator.impactOccurred()
                    viewModel.switchCamera()
                }) {
                    Image(systemName: "camera.rotate.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .luxuryGoldInteractive(baseColor: Color.white.opacity(0.85))
                .accessibilityLabel("Đổi camera trước và sau")

                // 1. Flash Toggle Button
                Button(action: {
                    viewModel.toggleFlash()
                }) {
                    Image(systemName: flashIconName)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .luxuryGoldInteractive(
                    baseColor: viewModel.activeFlashMode == .off ? Color.white.opacity(0.72) : amberGold
                )
                .accessibilityLabel("Chế độ đèn flash")

                // 2. Windowed Zoom Mode Toggle Button (Icon 4 cạnh reticle / viewfinder)
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
                        .frame(width: 40, height: 40)
                }
                .luxuryGoldInteractive(
                    baseColor: viewModel.isWindowedZoomActive ? amberGold : Color.white.opacity(0.72)
                )
                .accessibilityLabel("Chế độ khung ngắm thu nhỏ Windowed Zoom")

                // 3. Settings Sheet Button (9-Dot Grid Icon matching Reference)
                Button(action: {
                    viewModel.isShowingSettings = true
                }) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .luxuryGoldInteractive(
                    baseColor: Color.white.opacity(0.75)
                )
                .accessibilityLabel("Cài đặt hệ thống")
            }
            .padding(.horizontal, 4)
            .frame(height: 42)
            .background(
                Capsule()
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.94))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1.0)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 8, y: 2)
            )
        }
    }

    private var flashIconName: String {
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        @unknown default: return "bolt.fill"
        }
    }
}

// MARK: - In-Viewfinder Controls (Bottom Deck)

// 1. AI Compose Button (nutAI.png - Pure White, No Circle Border)
struct AIViewfinderButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.prepare()
            haptic.impactOccurred()

            if viewModel.isWindowedZoomActive {
                viewModel.applyAIWindowedFocalLengthRecommendation()
            } else {
                if viewModel.aiSessionState.isSessionActive {
                    viewModel.cancelAISession()
                } else {
                    viewModel.startAISession()
                }
            }
        }) {
            ZStack {
                if let uiImage = UIImage(named: "nutAI") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nutAI", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                } else {
                    Image("nutAI")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isPulsing ? 1.08 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isPulsing)
            .contentShape(Rectangle())
        }
        .luxuryGoldInteractive()
        .accessibilityLabel("Nút AI Bố cục")
    }

    private var isPulsing: Bool {
        if viewModel.isWindowedZoomActive {
            return viewModel.isAIWindowedFocalRecommended
        }
        switch viewModel.aiSessionState {
        case .analyzing, .targetPlaced, .alignmentPerfect:
            return true
        default:
            return false
        }
    }
}

// 2. Optical Zoom Selector (Strictly 1x, 2x, 3x - Minimalist Text with Stroke Ring)
struct ViewfinderZoomSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var zoomPillNamespace
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    private let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0]

    private var isPinchZoomOutsideOptions: Bool {
        guard viewModel.isPinchingZoom else { return false }
        for option in zoomOptions {
            if abs(viewModel.displayZoom - option) < 0.08 {
                return false
            }
        }
        return true
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isPinchZoomOutsideOptions {
                pinchZoomFloatingBadge
            }

            optionsRow
        }
    }

    private var pinchZoomFloatingBadge: some View {
        let zoomStr = String(format: "%.1fx", viewModel.displayZoom).replacingOccurrences(of: ".", with: ",")
        return Text(zoomStr)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(amberGold)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .overlay(Capsule().stroke(amberGold.opacity(0.40), lineWidth: 1.0))
            )
            .offset(y: -32)
            .transition(.opacity.combined(with: .scale(scale: 0.90)))
    }

    private var optionsRow: some View {
        HStack(spacing: 4) {
            ForEach(zoomOptions, id: \.self) { zoom in
                zoomButton(for: zoom)
            }
        }
    }

    @ViewBuilder
    private func zoomButton(for zoom: CGFloat) -> some View {
        let isSelected = viewModel.selectedZoomPreset == zoom
        Button(action: {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                viewModel.setZoomFromButton(zoom)
            }
        }) {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: 34, height: 34)
                        .matchedGeometryEffect(id: "active_viewfinder_zoom", in: zoomPillNamespace)
                }

                Text("\(Int(zoom))x")
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.78))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Thu phóng \(Int(zoom))x")
    }
}

// 3. Viewfinder Framing / Composition Button (nuticonbocuc.png - Pure White, No Circle Border)
struct ViewfinderFramingButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            viewModel.isCompositionRuleSheetPresented = true
        }) {
            ZStack {
                if let uiImage = UIImage(named: "nuticonbocuc") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nuticonbocuc", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                } else {
                    Image("nuticonbocuc")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .luxuryGoldInteractive()
        .accessibilityLabel("Chọn quy tắc bố cục thông minh")
    }
}

// MARK: - Composition Rule Quick Sheet
struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chọn quy tắc bố cục để hệ thống tự động nhận diện chủ thể và đưa ra hướng dẫn căn góc tối ưu.")
                            .font(.system(size: 13))
                            .foregroundColor(Color.gray)
                            .padding(.horizontal, 4)

                        ruleListView

                        Divider().background(Color.gray.opacity(0.3)).padding(.vertical, 4)

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
            .background(Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea())
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
            Divider().background(Color.gray.opacity(0.25))

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
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }
}

// MARK: - Composition Rule Row
struct CompositionRuleRow: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

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
                        .foregroundColor(Color.gray)
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? amberGold.opacity(0.12) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
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
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

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
                .foregroundColor(Color.gray)
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
    }
}

// MARK: - Live Viewfinder Film Atmosphere Overlay (Zero-Latency GPU Composition)
public struct FilmViewfinderAtmosphereOverlay: View {
    let preset: FilmPreset

    public init(preset: FilmPreset) {
        self.preset = preset
    }

    public var body: some View {
        ZStack {
            // 1. Color Tint Layer (Soft GPU Blend Mode)
            if let tintColor = preset.liveTintOverlayColor {
                tintColor
                    .opacity(preset.liveTintOpacity)
                    .blendMode(.color)
            }

            // 2. Optical Vignette Ring (For LOMO, ToyCam, 1998, Instant)
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

            // 3. Retro Video / LCD Scanline Texture (For DV, VHS, Nokia 3310)
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

// MARK: - Standby View khi Camera Ngủ Đông (Tiết kiệm CPU/GPU/RAM & Làm Mát Máy)
struct CameraHibernationStandbyView: View {
    private let canvasBackground = Color(red: 0.035, green: 0.039, blue: 0.051) // #090A0D

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
