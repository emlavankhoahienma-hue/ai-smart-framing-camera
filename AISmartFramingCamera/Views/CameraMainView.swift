import SwiftUI
import UIKit
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
    var photoViewfinderSize: CGSize {
        let widthLimit = max(1, availableSize.width - 12)
        let heightLimit = max(1, availableSize.height - 44 - topVerticalPadding -
                              topBottomPadding - controlDeckHeight - bottomComfort - minimumGap)
        let height = min(widthLimit * 4.0 / 3.0, heightLimit)
        return CGSize(width: height * 3.0 / 4.0, height: height)
    }

    /// Khung hình 9:16 toàn chiều rộng cho chế độ Quay Video (chuẩn iOS Camera gốc):
    /// Khớp chính xác tỷ lệ 9:16 (0.5625) của video 1080p/4K -> 0px viền đen 2 bên, 1.000x đúng tiêu cự (không crop ảo 1.33x-1.6x).
    var videoViewfinderSize: CGSize {
        let targetAspect: CGFloat = 9.0 / 16.0
        let fullScreenHeight = max(1, availableSize.height + safeAreaInsets.top + safeAreaInsets.bottom)
        let width = max(1, availableSize.width)
        let idealHeight = width / targetAspect
        if idealHeight <= fullScreenHeight + 1.0 {
            return CGSize(width: width, height: idealHeight)
        } else {
            return CGSize(width: fullScreenHeight * targetAspect, height: fullScreenHeight)
        }
    }

    var viewfinderSize: CGSize {
        isVideo ? videoViewfinderSize : photoViewfinderSize
    }

    var topBarBottomY: CGFloat {
        topVerticalPadding + 44 + topBottomPadding
    }

    var deckTopY: CGFloat {
        availableSize.height - controlDeckHeight - bottomComfort
    }

    var viewfinderTopY: CGFloat {
        if isVideo {
            let vidH = videoViewfinderSize.height
            // Trên iPhone hiện đại (X/XS/12-16/Pro Max): đặt ngay dưới thanh Top Bar (không bị Top Bar che)
            if topBarBottomY + vidH <= availableSize.height + safeAreaInsets.bottom * 0.35 {
                return topBarBottomY
            }
            // Trên màn hình 16:9 ngắn (iPhone SE): căn giữa trọn màn hình 9:16, thanh trên và dưới nổi mờ phía trên
            let fullScreenHeight = availableSize.height + safeAreaInsets.top + safeAreaInsets.bottom
            return (fullScreenHeight - vidH) * 0.5 - safeAreaInsets.top
        } else {
            let middleSpan = max(0, deckTopY - topBarBottomY)
            return topBarBottomY + max(0, (middleSpan - photoViewfinderSize.height) * 0.5)
        }
    }

    var videoOverlapsTopBar: Bool {
        isVideo && (topBarBottomY > viewfinderTopY + 1.0)
    }

    var viewfinderCornerRadius: CGFloat {
        if isVideo {
            return videoOverlapsTopBar ? 0 : 18
        }
        return 20
    }

    var histogramWidth: CGFloat {
        availableSize.width < 380 ? 46 : min(62, availableSize.width * 0.15)
    }
    var viewfinderTopInset: CGFloat { max(6, min(12, viewfinderSize.height * 0.02)) }
    var viewfinderBottomInset: CGFloat { max(8, min(14, viewfinderSize.height * 0.025)) }

    /// Tự động bù phần chồng lấn thanh Top Bar (trên iPhone SE 16:9) để HUD trên-trong-khung-ngắm luôn lộ rõ.
    var viewfinderTopOverlayInset: CGFloat {
        let topOverlap = max(0, topBarBottomY - viewfinderTopY)
        return topOverlap + viewfinderTopInset
    }

    /// Tự động đẩy nút Zoom (.5 | 1x | 2 | 3) lên ngay phía trên Bottom Control Deck khi quay Video 9:16 toàn chiều rộng.
    var viewfinderBottomOverlayInset: CGFloat {
        let vfBottomY = viewfinderTopY + viewfinderSize.height
        let deckOverlap = max(0, vfBottomY - deckTopY)
        return deckOverlap + viewfinderBottomInset
    }
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

// MARK: - Camera Main View (Monochrome Carbon & Smoked Glass Pro Edition)
public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBlinkingRed: Bool = false

    public init() {}

    // Simulator UI Snapshot Harness (hoàn toàn không ảnh hưởng máy thật nếu không có launch argument)
    private static let isUISnapshotMode: Bool = ProcessInfo.processInfo.arguments.contains("-UI_SNAPSHOT_MODE")

    private static var snapshotScreen: String {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-UI_SNAPSHOT_SCREEN"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return "main_photo"
    }

    private static var snapshotBackdropPath: String? {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-UI_SNAPSHOT_BG"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }

    private static var snapshotSettingsTab: SettingsSheetTab {
        switch snapshotScreen {
        case "settings_ai": return .ai
        case "settings_advanced": return .advanced
        default: return .capture
        }
    }

    private let canvasBackground = AlignTheme.studioCanvas

    public var body: some View {
        GeometryReader { geometry in
            let visualIsVideo = viewModel.visualCaptureMode.isVideo
            let layout = CameraFormFactorLayout(availableSize: geometry.size,
                                                safeAreaInsets: geometry.safeAreaInsets,
                                                isVideo: visualIsVideo)
            ZStack {
                // 1. Pure Matte Carbon Canvas
                canvasBackground
                    .ignoresSafeArea()

                if viewModel.hasCameraPermission || Self.isUISnapshotMode {
                    let isPhotoStylePadActive = viewModel.isShowingPhotographicStylePad
                        && !visualIsVideo
                        && !viewModel.isCameraHibernating

                    ZStack(alignment: .top) {
                        // 1. Single Persistent Viewfinder (3:4 in Photo/Pro, Full-Width Exact 9:16 in Video — 0 black bars, 1.000x true FOV)
                        ZStack {
                            if Self.isUISnapshotMode {
                                UISnapshotBackdropView(imagePath: Self.snapshotBackdropPath)
                            } else {
                                CameraPreviewView(viewModel: viewModel)
                            }

                            // Realtime Film Atmosphere Overlay
                            if viewModel.isFilmSimulationActive {
                                FilmViewfinderAtmosphereOverlay(preset: viewModel.selectedFilmPreset)
                                    .opacity(viewModel.filmSimulationIntensity)
                            }

                            // AR AI Framing Lines & Reticle
                            ARFramingOverlayView(viewModel: viewModel)

                            // Optional Zoom Debug Overlay (default OFF in Settings -> Bố cục)
                            if viewModel.isZoomDebugOverlayEnabled {
                                ZoomDebugOverlayView(viewModel: viewModel)
                            }

                            // Optional Tracking Performance Debug HUD (default OFF in Settings -> Bố cục)
                            if viewModel.isTrackingPerfHUDEnabled {
                                TrackingPerfDebugHUDView(perfState: viewModel.trackingPerfHUDState)
                            }

                            // Rangefinder Windowed Zoom Overlay (Khớp trực tiếp 1:1 khung ngắm 3:4 Photo hoặc 9:16 Video)
                            if viewModel.isWindowedZoomActive {
                                GeometryReader { proxy in
                                    WindowedZoomOverlayView(viewModel: viewModel, containerSize: proxy.size)
                                        .frame(width: proxy.size.width, height: proxy.size.height)
                                }
                                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                            }

                            // Dual Concurrent Camera PIP Overlay
                            if viewModel.isDualCameraActive {
                                DualCameraPIPOverlayView(viewModel: viewModel, containerSize: layout.viewfinderSize)
                                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                            }

                            // 360° Horizon Lock HUD Badge (Quiet Smoked Glass)
                            if viewModel.isHorizonLockEnabled {
                                VStack {
                                    HStack {
                                        Spacer()
                                        HStack(spacing: 5) {
                                            Image(systemName: "level.fill")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(AlignTheme.studioAccent)
                                            Text("360°")
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                .foregroundColor(AlignTheme.studioInkPrimary)
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4.5)
                                        .background(StudioGlassCapsule(tintOpacity: 0.52, borderOpacity: 0.14))
                                        .padding(.top, (viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo) ? 72 : max(12, layout.viewfinderTopOverlayInset))
                                        .padding(.trailing, 12)
                                    }
                                    Spacer()
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            }

                            // Optical Zoom HUD Feedback Badge (Smoked Glass)
                            if viewModel.isZoomHUDVisible, let hudText = viewModel.activeZoomHUDText {
                                VStack {
                                    HStack(spacing: 6) {
                                        Image(systemName: "camera.aperture")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(AlignTheme.studioAccent)
                                        Text(hudText)
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundColor(AlignTheme.studioInkPrimary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(StudioGlassCapsule(tintOpacity: 0.54, borderOpacity: 0.14))
                                    .padding(.top, (viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo) ? 74 : max(14, layout.viewfinderTopOverlayInset + 2))
                                    Spacer()
                                }
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                            }

                            // Ultra Sharp Progress HUD & Cancel Button (Smoked Glass)
                            if let progressText = viewModel.ultraSharpProgressString {
                                VStack {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                                            .scaleEffect(0.78)

                                        Text(progressText)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundColor(AlignTheme.studioInkPrimary)

                                        Button(action: {
                                            viewModel.cancelUltraSharpCapture()
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10.5, weight: .bold))
                                                .foregroundColor(AlignTheme.studioInkSecondary)
                                                .frame(width: 22, height: 22)
                                                .background(Circle().fill(Color.white.opacity(0.10)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.leading, 13)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 6.5)
                                    .background(StudioGlassCapsule(tintOpacity: 0.60, borderOpacity: 0.16))
                                    .padding(.top, max(14, layout.viewfinderTopOverlayInset + 2))
                                    Spacer()
                                }
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                            }

                            // GPU Smoked-Glass Mode Transition Veil (eliminates black flash & aspect pop during Photo <-> Video switch)
                            if viewModel.isModeTransitionVeilVisible && !Self.isUISnapshotMode {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(AlignTheme.studioCanvas.opacity(0.32))
                                    .allowsHitTesting(false)
                                    .transition(.opacity)
                            }

                            // Standby when AVFoundation is configuring
                            if !Self.isUISnapshotMode && (viewModel.isCameraHibernating || !viewModel.isCameraReady) {
                                CameraHibernationStandbyView()
                                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                                if !viewModel.isCameraHibernating {
                                    VStack(spacing: 8) {
                                        Spacer()
                                        Text("Đang kết nối camera")
                                            .font(.caption.weight(.medium))
                                            .foregroundColor(AlignTheme.studioInkSecondary)
                                        Button("Thử lại") {
                                            viewModel.requestPermissionsAndStart()
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.white)
                                        .padding(.bottom, max(32, layout.viewfinderBottomOverlayInset + 20))
                                    }
                                }
                            }
                        }
                        .frame(width: layout.viewfinderSize.width,
                               height: layout.viewfinderSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: layout.viewfinderCornerRadius, style: .continuous))
                        .overlay {
                            if !layout.videoOverlapsTopBar {
                                RoundedRectangle(cornerRadius: layout.viewfinderCornerRadius, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 0.65)
                            }
                        }
                        // In-Viewfinder Stereo Audio VU Level Meter (Top Leading)
                        .overlay(alignment: .topLeading) {
                            if viewModel.showAudioLevelMeter && !viewModel.isCameraHibernating && viewModel.captureMode.isVideo {
                                AudioVULevelMeterView(levels: viewModel.audioLevels)
                                    .padding(.top, layout.viewfinderTopOverlayInset)
                                    .padding(.leading, 10)
                                    .transition(.opacity)
                            }
                        }
                        // Expanded Pro RGB + Luma Scope HUD / Photographic Styles 5x5 Quick Trigger (Top Trailing, ẩn ở chế độ PRO để giữ khung ngắm tinh gọn)
                        .overlay(alignment: .topTrailing) {
                            let proTopOffset: CGFloat = (viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo) ? 64 : 0
                            let horizonOffset: CGFloat = viewModel.isHorizonLockEnabled ? 34 : 0

                            if !isPhotoStylePadActive && !viewModel.isPhotoboothModeActive {
                                // Histogram card và nút Photographic Styles cùng tồn tại (xếp dọc), không còn loại trừ nhau.
                                VStack(alignment: .trailing, spacing: 8) {
                                    if viewModel.showHistogramInViewfinder && !viewModel.isCameraHibernating {
                                        if viewModel.isHistogramBarExpanded {
                                            ProHistogramExpandedHUDView(viewModel: viewModel)
                                                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                                        } else {
                                            HistogramAlertPillView(viewModel: viewModel, expandsOnTap: true)
                                        }
                                    }
                                    if !viewModel.captureMode.isVideo &&
                                       !viewModel.isProPhotoModeEnabled &&
                                       !viewModel.isCameraHibernating &&
                                       !viewModel.isWindowedZoomActive {
                                        PhotographicStyleQuickTriggerButton(viewModel: viewModel)
                                            .transition(.scale(scale: 0.90, anchor: .topTrailing).combined(with: .opacity))
                                    }
                                }
                                .padding(.top, layout.viewfinderTopOverlayInset + proTopOffset + horizonOffset)
                                .padding(.trailing, 10)
                            } else if isPhotoStylePadActive && viewModel.showHistogramInViewfinder && !viewModel.isCameraHibernating {
                                // Khi chỉnh Tone/Color vẫn thấy cảnh báo cháy sáng / bết tối / nhiễu
                                HistogramAlertPillView(viewModel: viewModel, expandsOnTap: false)
                                    .allowsHitTesting(false)
                                    .padding(.top, layout.viewfinderTopOverlayInset + 6)
                                    .padding(.trailing, 10)
                            }
                        }
                        // Unobstructed Viewfinder Swipe Overlay khi bật Photographic Styles hoặc Photobooth Studio
                        .overlay {
                            if isPhotoStylePadActive {
                                PhotographicStylesViewfinderOverlay(
                                    viewModel: viewModel,
                                    topInset: layout.viewfinderTopOverlayInset,
                                    bottomInset: layout.viewfinderBottomOverlayInset
                                )
                                .transition(.opacity)
                            } else if viewModel.isPhotoboothModeActive && !viewModel.captureMode.isVideo {
                                PhotoboothViewfinderOverlay(
                                    viewModel: viewModel,
                                    topInset: layout.viewfinderTopOverlayInset,
                                    bottomInset: layout.viewfinderBottomOverlayInset
                                )
                                .transition(.opacity)
                            }
                        }
                        // Top Viewfinder Overlays (Pro Photo Telemetry / Video Timer / AI Status)
                        .overlay(alignment: .top) {
                            VStack(spacing: 6) {
                                if !isPhotoStylePadActive && viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo && !viewModel.isCameraHibernating {
                                    ProPhotoTelemetryHUDView(viewModel: viewModel)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                if viewModel.isRecordingVideo {
                                    videoRecordingHUD
                                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                                }

                                AIStatusHUDView(viewModel: viewModel)
                            }
                            .padding(.top, layout.viewfinderTopOverlayInset)
                        }
                        // Live 35mm Glowing Quartz Date Stamp Overlay in Viewfinder Bottom-Right Corner
                        .overlay(alignment: .bottomTrailing) {
                            if !viewModel.isCameraHibernating && viewModel.effectiveVintageDateStampStyle.isEnabled {
                                let stampBottomPadding: CGFloat = (viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo)
                                    ? max(82, layout.viewfinderBottomOverlayInset + 72)
                                    : (isPhotoStylePadActive ? 16 : (viewModel.isPhotoboothModeActive ? max(66, layout.viewfinderBottomOverlayInset + 56) : max(50, layout.viewfinderBottomOverlayInset + 40)))
                                VintageDateStampViewfinderOverlay(viewModel: viewModel)
                                    .padding(.trailing, 14)
                                    .padding(.bottom, stampBottomPadding)
                            }
                        }
                        // Bottom In-Viewfinder Smoked Glass Zoom Capsule / Pro Photo Manual Deck
                        .overlay(alignment: .bottom) {
                            if !viewModel.isWindowedZoomActive && !isPhotoStylePadActive && !viewModel.isPhotoboothModeActive {
                                if viewModel.isProPhotoModeEnabled && !viewModel.captureMode.isVideo && !viewModel.isCameraHibernating {
                                    ProPhotoManualDeckView(viewModel: viewModel)
                                        .padding(.bottom, max(6, layout.viewfinderBottomOverlayInset - 2))
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                } else {
                                    ViewfinderZoomSelectorPill(viewModel: viewModel)
                                        .padding(.bottom, layout.viewfinderBottomOverlayInset)
                                }
                            }
                        }
                        .position(
                            x: geometry.size.width * 0.5,
                            y: layout.viewfinderTopY + layout.viewfinderSize.height * 0.5
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.90), value: visualIsVideo)
                        .animation(.easeOut(duration: 0.16), value: viewModel.isModeTransitionVeilVisible)
                        .zIndex(0)

                        // 2. Persistent Top Toolbar + Bottom Control Deck Chrome (Stands Still, Translucent over 9:16 Video)
                        VStack(spacing: 0) {
                            Group {
                                if isPhotoStylePadActive {
                                    PhotographicStylesTopHUDBar(viewModel: viewModel, compact: layout.isCompact)
                                        .transition(.opacity)
                                } else if viewModel.isPhotoboothModeActive && !viewModel.captureMode.isVideo {
                                    PhotoboothTopBar(viewModel: viewModel, compact: layout.isCompact)
                                        .transition(.opacity)
                                } else {
                                    TopCameraBar(viewModel: viewModel, histogramWidth: layout.histogramWidth)
                                        .transition(.opacity)
                                }
                            }
                            .frame(height: 44)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, layout.topHorizontalPadding)
                            .padding(.top, layout.topVerticalPadding)
                            .padding(.bottom, layout.topBottomPadding)
                            .background(
                                Group {
                                    if layout.videoOverlapsTopBar {
                                        LinearGradient(
                                            colors: [Color.black.opacity(0.55), Color.black.opacity(0.0)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        .ignoresSafeArea(edges: .top)
                                    }
                                }
                            )
                            .animation(.easeInOut(duration: 0.22), value: isPhotoStylePadActive)

                            Spacer(minLength: 0)

                            // Unified Tactile Bottom Control Deck (hoặc Photographic Styles Control Pad khi đang bật)
                            Group {
                                if isPhotoStylePadActive {
                                    PhotographicStylesBottomControlDeck(viewModel: viewModel, compact: layout.isCompact)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                } else {
                                    CameraControlsView(viewModel: viewModel, compact: layout.isCompact)
                                        .transition(.opacity)
                                }
                            }
                            .frame(height: layout.controlDeckHeight)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, layout.bottomComfort)
                            .background(
                                Group {
                                    if visualIsVideo && !isPhotoStylePadActive {
                                        LinearGradient(
                                            colors: [
                                                Color.black.opacity(0.30),
                                                Color.black.opacity(0.58)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                        .ignoresSafeArea(edges: .bottom)
                                    }
                                }
                            )
                            .animation(.spring(response: 0.30, dampingFraction: 0.84), value: isPhotoStylePadActive)
                        }
                        .zIndex(20)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    CameraPermissionPlaceholderView(viewModel: viewModel)
                        .frame(width: geometry.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Low-Light Selfie Screen Flash Overlay (Warm 3000K soft flattering light)
                if viewModel.isScreenFlashOverlayVisible {
                    Color(red: 1.0, green: 0.96, blue: 0.90)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .zIndex(999)
                }

                // Self-Timer Countdown Center Display
                if viewModel.countdownSecondsRemaining > 0 {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay(Circle().fill(AlignTheme.studioGlassTint.opacity(0.55)))
                            .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.7))
                            .frame(width: 86, height: 86)
                        Text("\(viewModel.countdownSecondsRemaining)")
                            .font(.system(size: 42, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                    }
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(500)
                }

                // Kho Chức Năng Backdrop & Smoked Frosted Glass Sheet
                if viewModel.isFunctionDrawerOpen {
                    Color.black.opacity(0.36)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                                viewModel.isFunctionDrawerOpen = false
                            }
                        }
                        .transition(.opacity)
                        .zIndex(600)

                    CameraFunctionDrawerView(viewModel: viewModel)
                        .zIndex(601)
                }

                // Abnormal Exit Crash Forensics Card (auto-surfaces exact last step + 1-tap Copy/View after any crash/OOM)
                if viewModel.showAbnormalExitBanner && !Self.isUISnapshotMode {
                    VStack {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Phiên trước bị văng — Đã lưu log pháp y")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundColor(.white)
                                    Text(CameraLogger.lastCrashHeadlineSummary())
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(white: 0.88))
                                        .lineLimit(3)
                                }

                                Spacer(minLength: 4)

                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        viewModel.showAbnormalExitBanner = false
                                    }
                                    CameraLogger.acknowledgeAbnormalExitBanner()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundColor(Color.white.opacity(0.65))
                                }
                            }

                            HStack(spacing: 8) {
                                Button {
                                    viewModel.showAbnormalExitBanner = false
                                    viewModel.isShowingCrashDiagnosticsSheet = true
                                } label: {
                                    Label("Xem & Chia sẻ Log", systemImage: "doc.text.magnifyingglass")
                                        .font(.system(size: 11.5, weight: .bold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(AlignTheme.studioAccent)
                                        .clipShape(Capsule())
                                }

                                Button {
                                    UIPasteboard.general.string = CameraLogger.readPreviousSessionQuickCopy(maxLines: 90)
                                    viewModel.showHUDNotice("Đã copy 90 dòng log cuối (dán gửi ngay)")
                                } label: {
                                    Label("Copy nhanh", systemImage: "doc.on.doc.fill")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.16))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Color.black.opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.orange.opacity(0.75), lineWidth: 1.2)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.top, max(54, geometry.safeAreaInsets.top + 8))

                        Spacer()
                    }
                    .zIndex(750)
                }

                // Live Stress Test HUD Pill (>= 30 cycles memory telemetry)
                if viewModel.isRunningStressTest {
                    VStack {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(AlignTheme.studioAccent)
                                .scaleEffect(0.85)
                            Text(viewModel.stressTestStatusText)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Button("Dừng") {
                                viewModel.cancelLifecycleStressTest()
                            }
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.red)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.86))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.top, max(8, geometry.safeAreaInsets.top + 6))

                        Spacer()
                    }
                    .zIndex(760)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(viewModel: viewModel, initialTab: Self.snapshotSettingsTab)
        }
        .sheet(isPresented: $viewModel.isShowingCrashDiagnosticsSheet) {
            PreviousSessionLogSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingMasterWatermarkConfig) {
            MasterWatermarkConfigSheet(viewModel: viewModel)
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
        .fullScreenCover(isPresented: $viewModel.isShowingGallerySheet) {
            PhotoGallerySheetView(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isShowingPhotoDetail) {
            if let latest = viewModel.latestCapturedPhoto {
                CapturedPhotoPreviewView(item: latest, viewModel: viewModel)
            }
        }
        .fullScreenCover(isPresented: $viewModel.isShowingPhotoboothEditor) {
            PhotoboothEditorSheetView(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isShowingVideoPreview) {
            if let videoURL = viewModel.recordedVideoURL {
                VideoPreviewSheetView(videoURL: videoURL, viewModel: viewModel)
            }
        }
        .onAppear {
            CameraLogger.lifecycle("VIEW_APPEAR", detail: "CameraMainView", category: .general)
            if Self.isUISnapshotMode {
                viewModel.applyUISnapshotState(screen: Self.snapshotScreen)
            } else {
                viewModel.requestPermissionsAndStart()
            }
        }
        .onDisappear {
            CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "CameraMainView", category: .general)
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
            if !Self.isUISnapshotMode {
                viewModel.handleScenePhaseChange(newPhase)
            }
        }
    }

    // MARK: - Video Recording Timer Badge
    private var videoRecordingHUD: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(AlignTheme.studioRecordRed)
                .frame(width: 7, height: 7)
                .opacity(isBlinkingRed ? 1.0 : 0.30)

            Text(viewModel.videoRecordingTimeString)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkPrimary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(StudioGlassCapsule(tintOpacity: 0.56, borderOpacity: 0.14))
    }
}

// MARK: - Simulator UI Snapshot Backdrop (Rendered ONLY under -UI_SNAPSHOT_MODE)
private struct UISnapshotBackdropView: View {
    let imagePath: String?

    var body: some View {
        if let path = imagePath, let img = UIImage(contentsOfFile: path) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            // Subtle warm studio architectural backdrop for realistic glass-blur inspection
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.84, green: 0.82, blue: 0.78),
                        Color(red: 0.62, green: 0.58, blue: 0.52),
                        Color(red: 0.28, green: 0.22, blue: 0.17)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.34, green: 0.25, blue: 0.18), Color(red: 0.18, green: 0.13, blue: 0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 190)
                }
            }
        }
    }
}

// MARK: - Six Dots Icon (Custom Vector 3x2 Grid for Kho Chức Năng Drawer)
public struct SixDotsIcon: View {
    var color: Color = .white
    public init(color: Color = .white) {
        self.color = color
    }
    public var body: some View {
        HStack(spacing: 3.5) {
            VStack(spacing: 3.5) {
                Circle().fill(color).frame(width: 3.5, height: 3.5)
                Circle().fill(color).frame(width: 3.5, height: 3.5)
            }
            VStack(spacing: 3.5) {
                Circle().fill(color).frame(width: 3.5, height: 3.5)
                Circle().fill(color).frame(width: 3.5, height: 3.5)
            }
            VStack(spacing: 3.5) {
                Circle().fill(color).frame(width: 3.5, height: 3.5)
                Circle().fill(color).frame(width: 3.5, height: 3.5)
            }
        }
    }
}

// MARK: - Top Camera Bar (Balanced Twin Smoked-Glass Capsules + Center Telemetry)
struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    let histogramWidth: CGFloat

    var body: some View {
        ZStack {
            // Center: Quiet Tabular Exposure / Mode Telemetry Pill
            HStack(spacing: 5) {
                if viewModel.isVisualProPhotoSelected {
                    Text("PRO")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)

                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 0.7, height: 10)
                }

                HStack(spacing: 3.5) {
                    Text("ISO")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                    Text(viewModel.currentLiveISO > 0 ? "\(Int(round(viewModel.currentLiveISO)))" : "AUTO")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioInkPrimary)
                }

                if viewModel.isUltraSharpEnabled && !viewModel.visualCaptureMode.isVideo && !viewModel.isVisualProPhotoSelected {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 0.7, height: 10)

                    Text("US")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(AlignTheme.studioAccent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(AlignTheme.studioSurface)
                    .overlay(
                        Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6)
                    )
            )

            // Left & Right Symmetric Smoked Glass Capsules
            HStack(alignment: .center, spacing: 0) {
                let flashAvail = viewModel.featureAvailability(.flash)
                // Left Capsule: Flash + Real Rec.709 RGB/Luma Histogram (or Format Label)
                HStack(spacing: 6) {
                    Button(action: {
                        viewModel.attemptFeature(.flash) {
                            viewModel.toggleFlash()
                        }
                    }) {
                        Image(systemName: flashIconName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                !flashAvail.isAvailable
                                    ? AlignTheme.studioInkPrimary.opacity(0.30)
                                    : (viewModel.activeFlashMode == .off ? AlignTheme.studioInkPrimary.opacity(0.82) : AlignTheme.studioAccent)
                            )
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Đèn flash")

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 0.6, height: 14)

                    if viewModel.showHistogramInViewfinder {
                        LiveColorHistogramHUDView(viewModel: viewModel, width: histogramWidth)
                            .frame(height: 22)
                            .padding(.trailing, 2)
                    } else {
                        Button(action: {
                            if viewModel.visualCaptureMode.isVideo {
                                viewModel.attemptFeature(.videoQualityAndCodec) {
                                    viewModel.toggleVideoFormat()
                                }
                            } else {
                                viewModel.attemptFeature(.photoFormat) {
                                    viewModel.togglePhotoFormat()
                                }
                            }
                        }) {
                            Text(currentFormatLabel)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.86))
                                .padding(.horizontal, 4)
                                .frame(height: 28)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(
                            Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6)
                        )
                )

                Spacer()

                // Right Capsule: Live Photo, Windowed Zoom, 6-Dot Control Sheet (Capability Gated)
                let liveAvail = viewModel.featureAvailability(.livePhoto)
                let windowedAvail = viewModel.featureAvailability(.windowedZoom)
                HStack(spacing: 6) {
                    Button(action: {
                        viewModel.attemptFeature(.livePhoto) {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.prepare()
                            generator.impactOccurred()
                            viewModel.isLivePhotoEnabled.toggle()
                        }
                    }) {
                        Image(systemName: (liveAvail.isAvailable && viewModel.isLivePhotoEnabled) ? "livephoto" : "livephoto.slash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(
                                !liveAvail.isAvailable
                                    ? AlignTheme.studioInkPrimary.opacity(0.28)
                                    : (viewModel.isLivePhotoEnabled ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.80))
                            )
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Chế độ Live Photo")

                    Button(action: {
                        viewModel.attemptFeature(.windowedZoom) {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.prepare()
                            generator.impactOccurred()
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                viewModel.isWindowedZoomActive.toggle()
                                if viewModel.isWindowedZoomActive && viewModel.windowedZoomFocalLength <= 24.5 {
                                    viewModel.windowedZoomFocalLength = 50.0
                                }
                            }
                        }
                    }) {
                        Image(systemName: viewModel.isWindowedZoomActive ? "viewfinder.circle.fill" : "viewfinder")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundColor(
                                !windowedAvail.isAvailable
                                    ? AlignTheme.studioInkPrimary.opacity(0.28)
                                    : (viewModel.isWindowedZoomActive ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.82))
                            )
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Chế độ khung ngắm Windowed Zoom")

                    Button(action: {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.prepare()
                        generator.impactOccurred()
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                            viewModel.isFunctionDrawerOpen.toggle()
                        }
                    }) {
                        SixDotsIcon(color: viewModel.isFunctionDrawerOpen ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.86))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Mở kho chức năng máy ảnh")
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(
                    Capsule()
                        .fill(AlignTheme.studioSurface)
                        .overlay(
                            Capsule().stroke(AlignTheme.studioHairline, lineWidth: 0.6)
                        )
                )
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }

    private var flashIconName: String {
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash"
        @unknown default: return "bolt"
        }
    }

    private var currentFormatLabel: String {
        if viewModel.visualCaptureMode.isVideo {
            let w = viewModel.selectedVideoFormatOption.width
            let fps = Int(round(viewModel.selectedVideoFormatOption.fps))
            return w >= 3840 ? "4K·\(fps)" : "1080·\(fps)"
        }
        switch viewModel.selectedPhotoFormat {
        case .dng: return "RAW"
        case .heif, .heic: return "HEIF"
        case .jpeg: return "JPG"
        }
    }
}

// MARK: - Smoked Frosted Glass Optical Zoom Capsule (0.5x, 1x, 2x, 3x + Smooth Scrubbing)
struct ViewfinderZoomSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var zoomPillNamespace
    @State private var dragStartZoom: CGFloat = 1.0
    @State private var isScrubbingZoom: Bool = false

    private var zoomOptions: [CGFloat] {
        viewModel.availableDisplayZoomOptions.filter { $0 < 4.9 }
    }

    private func label(for zoom: CGFloat, isSelected: Bool) -> String {
        if isSelected {
            let liveZ = viewModel.displayZoom
            let roundedTenth = (liveZ * 10.0).rounded() / 10.0
            if abs(roundedTenth - roundedTenth.rounded()) > 0.04 || roundedTenth < 0.95 {
                return String(format: "%.1fx", roundedTenth)
            }
            return "\(Int(roundedTenth.rounded()))x"
        }
        return zoom == 0.5 ? ".5" : "\(Int(zoom))"
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(zoomOptions, id: \.self) { zoom in
                let isSelected = viewModel.selectedZoomPreset == zoom
                Button(action: {
                    HapticFeedbackService.shared.triggerMechanicalDialTick()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                        viewModel.setVideoAwareZoomFromButton(zoom)
                    }
                }) {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .overlay(
                                    Circle()
                                        .stroke(AlignTheme.studioAccent.opacity(0.45), lineWidth: 0.7)
                                )
                                .frame(width: 32, height: 32)
                                .matchedGeometryEffect(id: "active_viewfinder_zoom_ring", in: zoomPillNamespace)
                        }

                        Text(label(for: zoom, isSelected: isSelected))
                            .font(.system(size: isSelected ? 11.5 : 11, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundColor(isSelected ? AlignTheme.studioAccent : Color.white.opacity(0.76))
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                    }
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(zoom == 0.5 ? "Thu phong 0.5 lan" : "Thu phong \(Int(zoom)) lan")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(StudioGlassCapsule(tintOpacity: 0.48, borderOpacity: 0.14))
        .contentShape(Capsule())
        .highPriorityGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    if !isScrubbingZoom {
                        isScrubbingZoom = true
                        dragStartZoom = viewModel.displayZoom
                        viewModel.beginVideoAwareManualZoomGesture()
                    }
                    // Vuốt sang phải tăng zoom, sang trái giảm zoom theo thang logarit mượt mà
                    let octaves = Double(value.translation.width) / 95.0
                    let rawTarget = dragStartZoom * CGFloat(pow(2.0, octaves))
                    let minZ = viewModel.minAvailableDisplayZoom
                    let maxZ = min(5.0, viewModel.maxAvailableDisplayZoom)
                    let clamped = max(minZ, min(rawTarget, maxZ))
                    viewModel.setVideoAwareZoomContinuous(clamped)
                }
                .onEnded { value in
                    let octaves = Double(value.translation.width) / 95.0
                    let rawTarget = dragStartZoom * CGFloat(pow(2.0, octaves))
                    let minZ = viewModel.minAvailableDisplayZoom
                    let maxZ = min(5.0, viewModel.maxAvailableDisplayZoom)
                    let clamped = max(minZ, min(rawTarget, maxZ))
                    viewModel.finishVideoAwareZoomGesture(clamped)
                    isScrubbingZoom = false
                }
        )
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
                    }
                    .padding(16)
                }

                bottomActionBar
            }
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle("Bố cục thông minh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(AlignTheme.studioAccent)
                        .font(.system(size: 15, weight: .semibold))
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
            Divider().background(AlignTheme.studioHairlineSubtle)

            if viewModel.aiSessionState.isSessionActive {
                Button(action: {
                    viewModel.cancelAISession()
                    dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Dừng căn bố cục")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AlignTheme.studioRecordRed.opacity(0.88)))
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(AlignTheme.studioAccent)
                    )
                }
                .padding(16)
            }
        }
        .background(AlignTheme.studioSurface)
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
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.75))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayNameVietnamese)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(AlignTheme.studioInkPrimary)
                    Text(rule.descriptionVietnamese)
                        .font(.system(size: 12))
                        .foregroundColor(AlignTheme.studioInkSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(AlignTheme.studioAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 0.9 : 0.7)
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
            Image(systemName: "camera.aperture")
                .font(.system(size: 46, weight: .light))
                .foregroundColor(AlignTheme.studioAccent)

            Text("Cho phép camera để bắt đầu")
                .font(.title3.weight(.semibold))
                .foregroundColor(AlignTheme.studioInkPrimary)

            Text("AlignAI Camera cần quyền truy cập camera để hiển thị khung ngắm thời gian thực và hỗ trợ căn bố cục chuẩn xác.")
                .font(.subheadline)
                .foregroundColor(AlignTheme.studioInkSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Mở Cài đặt")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(AlignTheme.studioAccent)
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


// MARK: - Animated Multi-Mode Grid Mini Icon (Hiệu ứng chuyển đổi hình học từng loại lưới ngay trong nút)
struct AnimatedGridStyleIcon: View {
    let style: ViewfinderGridStyle
    let accentColor: Color

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                gridVectorCanvas(for: style)
                    .id(style)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.70).combined(with: .opacity),
                            removal: .scale(scale: 1.18).combined(with: .opacity)
                        )
                    )
            }
            .frame(width: 19, height: 19)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: style)

            // 5 chấm mini chỉ tiến trình chuyển đổi giữa các kiểu lưới
            HStack(spacing: 2.2) {
                ForEach(1...ViewfinderGridStyle.activeStylesCount, id: \.self) { step in
                    Circle()
                        .fill(step == style.activeStepIndex ? accentColor : Color.white.opacity(style.isVisible ? 0.20 : 0.10))
                        .frame(width: step == style.activeStepIndex ? 3.2 : 2.2, height: step == style.activeStepIndex ? 3.2 : 2.2)
                }
            }
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: style)
        }
    }

    private func gridVectorCanvas(for gridStyle: ViewfinderGridStyle) -> some View {
        Canvas { context, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1.2, dy: 1.2)
            let isOn = gridStyle.isVisible
            let lineCol = isOn ? accentColor : Color.white.opacity(0.55)
            let frameCol = isOn ? accentColor.opacity(0.65) : Color.white.opacity(0.32)

            // Khung vuông bo góc nhẹ bên ngoài
            let border = Path(roundedRect: r, cornerRadius: 3.0)
            context.stroke(border, with: .color(frameCol), lineWidth: 1.0)

            var inner = Path()
            switch gridStyle {
            case .off:
                for frac in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    inner.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY + 1))
                    inner.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY - 1))
                    inner.move(to: CGPoint(x: r.minX + 1, y: r.minY + r.height * frac))
                    inner.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY + r.height * frac))
                }
                context.stroke(inner, with: .color(Color.white.opacity(0.28)), lineWidth: 0.7)
                // Gạch chéo báo tắt
                var slash = Path()
                slash.move(to: CGPoint(x: r.minX - 0.5, y: r.maxY + 0.5))
                slash.addLine(to: CGPoint(x: r.maxX + 0.5, y: r.minY - 0.5))
                context.stroke(slash, with: .color(Color.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

            case .ruleOfThirds:
                for frac in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    inner.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY))
                    inner.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY))
                    inner.move(to: CGPoint(x: r.minX, y: r.minY + r.height * frac))
                    inner.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * frac))
                }
                context.stroke(inner, with: .color(lineCol), lineWidth: 1.05)

            case .goldenRatio:
                for frac in [CGFloat(0.382), CGFloat(0.618)] {
                    inner.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY))
                    inner.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY))
                    inner.move(to: CGPoint(x: r.minX, y: r.minY + r.height * frac))
                    inner.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * frac))
                }
                context.stroke(inner, with: .color(lineCol), lineWidth: 1.05)

            case .diagonal:
                inner.move(to: CGPoint(x: r.minX, y: r.minY))
                inner.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                inner.move(to: CGPoint(x: r.maxX, y: r.minY))
                inner.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                context.stroke(inner, with: .color(lineCol), lineWidth: 1.1)

            case .square4x4:
                for i in 1...3 {
                    let frac = CGFloat(i) / 4.0
                    inner.move(to: CGPoint(x: r.minX + r.width * frac, y: r.minY))
                    inner.addLine(to: CGPoint(x: r.minX + r.width * frac, y: r.maxY))
                    inner.move(to: CGPoint(x: r.minX, y: r.minY + r.height * frac))
                    inner.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * frac))
                }
                context.stroke(inner, with: .color(lineCol), lineWidth: 0.85)

            case .centerCrosshair:
                let cx = r.midX
                let cy = r.midY
                let arm = r.width * 0.24
                inner.move(to: CGPoint(x: cx - arm, y: cy))
                inner.addLine(to: CGPoint(x: cx + arm, y: cy))
                inner.move(to: CGPoint(x: cx, y: cy - arm))
                inner.addLine(to: CGPoint(x: cx, y: cy + arm))
                let centerBox = r.insetBy(dx: r.width * 0.24, dy: r.height * 0.24)
                inner.addRect(centerBox)
                context.stroke(inner, with: .color(lineCol), lineWidth: 1.05)
            }
        }
    }
}

// MARK: - Drawer Function Item Button (Minimalist Obsidian Squircle Tile + Capability Gating)
struct DrawerFunctionButton: View {
    let icon: String
    var customIcon: AnyView? = nil
    let title: String
    let subtitle: String?
    let isActive: Bool
    var availability: FeatureAvailability = .available
    var onBlocked: ((String) -> Void)? = nil
    let action: () -> Void

    private let accentGold = AlignTheme.studioAccent

    var body: some View {
        let isEnabled = availability.isAvailable
        let effectiveActive = isEnabled && isActive
        let displayedSubtitle = isEnabled ? subtitle : (availability.shortHint ?? "Không khả dụng")

        Button(action: {
            if isEnabled {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                generator.impactOccurred()
                action()
            } else if let reason = availability.detailReason {
                onBlocked?(reason)
            }
        }) {
            VStack(spacing: 5) {
                if let custom = customIcon {
                    custom
                        .frame(height: 24)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: effectiveActive ? .semibold : .medium))
                        .foregroundColor(effectiveActive ? accentGold : Color.white.opacity(0.84))
                        .frame(height: 22)
                }

                VStack(spacing: 1.5) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(effectiveActive ? .white : .white.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if let sub = displayedSubtitle {
                        Text(sub)
                            .font(.system(size: 9.2, weight: isEnabled ? .bold : .medium, design: .rounded))
                            .foregroundColor(
                                !isEnabled
                                    ? .white.opacity(0.50)
                                    : (effectiveActive ? accentGold : .white.opacity(0.42))
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .contentTransition(.numericText())
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(effectiveActive ? accentGold.opacity(0.14) : Color.white.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(effectiveActive ? accentGold.opacity(0.42) : Color.white.opacity(0.075), lineWidth: effectiveActive ? 1.0 : 0.6)
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.40)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Drawer Hero Quick-Mode Card (Top Featured Strip + Capability Gating)
private struct DrawerHeroCard: View {
    let icon: String
    let title: String
    let valueText: String
    let isActive: Bool
    var availability: FeatureAvailability = .available
    var onBlocked: ((String) -> Void)? = nil
    let action: () -> Void

    private let accentGold = AlignTheme.studioAccent

    var body: some View {
        let isEnabled = availability.isAvailable
        let effectiveActive = isEnabled && isActive
        let shownValue = isEnabled ? valueText : (availability.shortHint ?? "Khóa")

        Button(action: {
            if isEnabled {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.prepare()
                generator.impactOccurred()
                action()
            } else if let reason = availability.detailReason {
                onBlocked?(reason)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(effectiveActive ? Color.black : (isEnabled ? accentGold : AlignTheme.studioInkSecondary))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(effectiveActive ? accentGold : Color.white.opacity(0.09))
                        )

                    Spacer()

                    if isEnabled {
                        Circle()
                            .fill(effectiveActive ? accentGold : Color.white.opacity(0.16))
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(effectiveActive ? .white : .white.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(shownValue)
                        .font(.system(size: 10, weight: isEnabled ? .bold : .medium, design: .rounded))
                        .foregroundColor(effectiveActive ? accentGold : .white.opacity(0.48))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        effectiveActive
                            ? LinearGradient(
                                colors: [accentGold.opacity(0.20), accentGold.opacity(0.09)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [Color.white.opacity(0.08), Color.white.opacity(0.045)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(effectiveActive ? accentGold.opacity(0.48) : Color.white.opacity(0.09), lineWidth: effectiveActive ? 1.0 : 0.7)
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Camera Function Drawer (Bảng Điều Khiển Obsidian Pro - Menu 6 Chấm)
struct CameraFunctionDrawerView: View {
    @ObservedObject var viewModel: CameraViewModel

    private let accentGold = AlignTheme.studioAccent

    private var videoQualityBadge: String {
        let w = viewModel.selectedVideoFormatOption.width
        let fps = Int(round(viewModel.selectedVideoFormatOption.fps))
        return w >= 3840 ? "4K · \(fps)fps" : "1080P · \(fps)fps"
    }

    private var photoFormatBadge: String {
        switch viewModel.selectedPhotoFormat {
        case .dng: return "RAW DNG"
        case .heif, .heic: return "HEIF 10-bit"
        case .jpeg: return "JPEG"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                // 1. Drag Handle + Header Bar
                VStack(spacing: 10) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 38, height: 4)
                        .padding(.top, 10)

                    HStack(spacing: 8) {
                        HStack(spacing: 7) {
                            Text("Bảng điều khiển")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)

                            Text(viewModel.captureMode.isVideo ? "VIDEO" : "ẢNH")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundColor(accentGold)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(accentGold.opacity(0.14))
                                        .overlay(
                                            Capsule()
                                                .stroke(accentGold.opacity(0.32), lineWidth: 0.6)
                                        )
                                )
                        }

                        Spacer()

                        // Quick Settings Pill
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.prepare()
                            generator.impactOccurred()
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                                viewModel.isFunctionDrawerOpen = false
                            }
                            viewModel.isShowingSettings = true
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text("Cài đặt")
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white.opacity(0.88))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.09))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Close Button
                        Button(action: {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                                viewModel.isFunctionDrawerOpen = false
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.white.opacity(0.75))
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Đóng bảng điều khiển")
                    }
                    .padding(.horizontal, 18)
                }

                // 2. Hero Featured Strip (3 Balanced Quick-Mode Cards + Capability Gating)
                HStack(spacing: 9) {
                    if viewModel.captureMode.isVideo {
                        DrawerHeroCard(
                            icon: "video.fill",
                            title: "Chất lượng",
                            valueText: videoQualityBadge,
                            isActive: viewModel.selectedVideoFormatOption.width >= 3840,
                            availability: viewModel.featureAvailability(.videoQualityAndCodec),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.toggleVideoFormat() }
                        )
                    } else {
                        DrawerHeroCard(
                            icon: "square.stack.3d.up.fill",
                            title: "Ultra Sharp",
                            valueText: viewModel.isUltraSharpEnabled ? "Bật · 12MP" : "Tắt",
                            isActive: viewModel.isUltraSharpEnabled,
                            availability: viewModel.featureAvailability(.ultraSharp),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.isUltraSharpEnabled.toggle() }
                        )
                    }

                    DrawerHeroCard(
                        icon: "camera.filters",
                        title: "Màu phim",
                        valueText: viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.displayName : "Tự nhiên",
                        isActive: viewModel.isFilmSimulationActive,
                        availability: viewModel.featureAvailability(.filmColor),
                        onBlocked: { reason in
                            viewModel.haptics.triggerError()
                            viewModel.showHUDNotice(reason)
                        },
                        action: {
                            if viewModel.isFilmSimulationActive {
                                viewModel.disableFilmSimulation()
                            } else {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                                    viewModel.isFunctionDrawerOpen = false
                                    viewModel.isShowingFilmDrawer = true
                                }
                            }
                        }
                    )

                    if viewModel.captureMode.isVideo {
                        DrawerHeroCard(
                            icon: "film",
                            title: "Mã hóa",
                            valueText: viewModel.selectedVideoCodec == .hevc ? "HEVC" : "H.264",
                            isActive: viewModel.selectedVideoCodec == .hevc,
                            availability: viewModel.featureAvailability(.videoQualityAndCodec),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.toggleVideoCodec() }
                        )
                    } else {
                        DrawerHeroCard(
                            icon: "doc.plaintext",
                            title: "Định dạng",
                            valueText: photoFormatBadge,
                            isActive: viewModel.selectedPhotoFormat == .dng,
                            availability: viewModel.featureAvailability(.photoFormat),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.togglePhotoFormat() }
                        )
                    }
                }
                .padding(.horizontal, 16)

                Rectangle()
                    .fill(Color.white.opacity(0.065))
                    .frame(height: 0.7)
                    .padding(.horizontal, 18)

                // 3. Section 1: Khung Ngắm & Hỗ Trợ (4 Balanced Squircle Tiles + Multi-Grid Animated Cycle)
                VStack(alignment: .leading, spacing: 8) {
                    Text("KHUNG NGẮM & BỐ CỤC")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.42))
                        .padding(.horizontal, 2)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        DrawerFunctionButton(
                            icon: "aspectratio",
                            title: "Tỷ lệ",
                            subtitle: viewModel.windowedZoomAspectRatio.rawValue,
                            isActive: viewModel.isWindowedZoomActive,
                            availability: viewModel.featureAvailability(.aspectRatio),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.cycleAspectRatio() }
                        )

                        DrawerFunctionButton(
                            icon: "timer",
                            title: "Hẹn giờ",
                            subtitle: viewModel.captureTimerSeconds == 0 ? "Tắt" : "\(viewModel.captureTimerSeconds)s",
                            isActive: viewModel.captureTimerSeconds > 0,
                            availability: viewModel.featureAvailability(.captureTimer),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.cycleCaptureTimer() }
                        )

                        DrawerFunctionButton(
                            icon: "grid",
                            customIcon: AnyView(AnimatedGridStyleIcon(style: viewModel.viewfinderGridStyle, accentColor: accentGold)),
                            title: "Lưới",
                            subtitle: viewModel.viewfinderGridStyle.shortLabel,
                            isActive: viewModel.viewfinderGridStyle.isVisible,
                            action: { viewModel.cycleViewfinderGridStyle() }
                        )

                        DrawerFunctionButton(
                            icon: viewModel.isHorizonLevelerEnabled ? "scope" : "circle.dashed",
                            title: "Cân bằng",
                            subtitle: viewModel.isHorizonLevelerEnabled ? "Bật" : "Tắt",
                            isActive: viewModel.isHorizonLevelerEnabled,
                            availability: viewModel.featureAvailability(.horizonLeveler),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.isHorizonLevelerEnabled.toggle() }
                        )
                    }
                }
                .padding(.horizontal, 16)

                // 4. Section 2: Công Cụ Nâng Cao (4 Balanced Squircle Tiles + Capability Gating)
                VStack(alignment: .leading, spacing: 8) {
                    Text("CÔNG CỤ NÂNG CAO")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.42))
                        .padding(.horizontal, 2)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        DrawerFunctionButton(
                            icon: viewModel.isHorizonLockEnabled ? "level.fill" : "level",
                            title: "Chân trời",
                            subtitle: viewModel.isHorizonLockEnabled ? "360° Khóa" : "Tắt",
                            isActive: viewModel.isHorizonLockEnabled,
                            availability: viewModel.featureAvailability(.horizonLock),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.toggleHorizonLock() }
                        )

                        DrawerFunctionButton(
                            icon: viewModel.isMasterWatermarkEnabled ? "seal.fill" : "seal",
                            title: "Master",
                            subtitle: viewModel.isMasterWatermarkEnabled ? (viewModel.captureMode.isVideo ? "Ảnh & Video" : "Bật") : "Tắt",
                            isActive: viewModel.isMasterWatermarkEnabled,
                            availability: viewModel.featureAvailability(.masterWatermark),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.isMasterWatermarkEnabled.toggle() }
                        )

                        DrawerFunctionButton(
                            icon: viewModel.isDualCameraActive ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle",
                            title: "Dual Cam",
                            subtitle: viewModel.isDualCameraActive ? "Bật" : "Tắt",
                            isActive: viewModel.isDualCameraActive,
                            availability: viewModel.featureAvailability(.dualCamera),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: { viewModel.toggleDualCamera() }
                        )

                        DrawerFunctionButton(
                            icon: "chart.bar.xaxis",
                            title: "Biểu đồ",
                            subtitle: viewModel.showHistogramInViewfinder ? (viewModel.isHistogramBarExpanded ? "Pro RGB" : "Bật") : "Tắt",
                            isActive: viewModel.showHistogramInViewfinder,
                            action: { viewModel.showHistogramInViewfinder.toggle() }
                        )

                        DrawerFunctionButton(
                            icon: "photo.stack.fill",
                            title: "Photobooth",
                            subtitle: viewModel.isPhotoboothModeActive ? "Đang bật" : "Ngoài tiệm",
                            isActive: viewModel.isPhotoboothModeActive,
                            availability: viewModel.featureAvailability(.photobooth),
                            onBlocked: { reason in
                                viewModel.haptics.triggerError()
                                viewModel.showHUDNotice(reason)
                            },
                            action: {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                                    viewModel.isFunctionDrawerOpen = false
                                }
                                if viewModel.isPhotoboothModeActive {
                                    viewModel.exitPhotoboothMode()
                                } else {
                                    viewModel.enterPhotoboothMode()
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background(
                StudioGlassRoundedSurface(cornerRadius: 28, tintOpacity: 0.78, borderOpacity: 0.16)
                    .shadow(color: Color.black.opacity(0.65), radius: 28, y: -8)
            )
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onEnded { value in
                        if value.translation.height > 40 {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                viewModel.isFunctionDrawerOpen = false
                            }
                        }
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
