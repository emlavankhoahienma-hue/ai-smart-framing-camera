import SwiftUI
import UIKit

// MARK: - Camera Controls View (Minimalist Obsidian Pro Edition)
public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    let compact: Bool

    public init(viewModel: CameraViewModel, compact: Bool = false) {
        self.viewModel = viewModel
        self.compact = compact
    }

    private var deckHeight: CGFloat { compact ? 148 : 156 }

    public var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            // Row 1: Balanced 3-Column Shutter Control Deck
            HStack(alignment: .center, spacing: 0) {
                // Left Column: Album Thumbnail
                HStack {
                    GalleryThumbnailButton(viewModel: viewModel)
                        .frame(width: 50, height: 50)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Center Column: Minimalist Shutter Button (Strictly Centered on Screen Axis)
                MainCaptureButton(viewModel: viewModel)
                    .frame(width: 80, height: 80)

                // Right Column: Camera Flip Button
                HStack {
                    Spacer()
                    CameraFlipButton(viewModel: viewModel)
                        .frame(width: 50, height: 50)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, compact ? 16 : 22)

            // Row 2: AI Button (Left) + Mode Switcher (Center under Shutter) + Balanced Spacer (Right)
            HStack(alignment: .center, spacing: 0) {
                // Left: AI Button (nutAI Asset, No Background, No Border)
                HStack {
                    AIViewfinderButton(viewModel: viewModel)
                        .frame(width: 44, height: 44)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Center: Camera Mode Switcher (ẢNH / VIDEO) directly under Shutter
                CameraModeSegmentedSwitcher(viewModel: viewModel)

                // Right: Film Drawer Mini Quick Trigger / Symmetrical Spacer
                HStack {
                    Spacer()
                    SelectedCameraBadgeButton(viewModel: viewModel)
                        .frame(width: 44, height: 44)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, compact ? 16 : 22)
            .padding(.bottom, 4)
        }
        .padding(.top, compact ? 2 : 4)
        .padding(.bottom, compact ? 4 : 6)
        .frame(height: deckHeight)
        .frame(maxWidth: .infinity)
        .background(
            Group {
                if viewModel.captureMode.isVideo {
                    Color.clear
                } else {
                    AlignTheme.studioCanvas
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        )
        .overlay(alignment: .bottom) {
            if viewModel.isShowingFilmDrawer {
                VStack(spacing: 0) {
                    FilmPresetDrawer(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    Color.clear.frame(height: deckHeight).allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Reliable Custom App Icon Component
public struct CustomAppIconView: View {
    let name: String
    let fallbackSF: String
    let size: CGFloat
    let color: Color

    public init(name: String, fallbackSF: String, size: CGFloat, color: Color = .white) {
        self.name = name
        self.fallbackSF = fallbackSF
        self.size = size
        self.color = color
    }

    public var body: some View {
        if let uiImage = UIImage(named: name) ?? UIImage(contentsOfFile: Bundle.main.path(forResource: name, ofType: "png") ?? "") {
            Image(uiImage: uiImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(color)
        } else {
            Image(systemName: fallbackSF)
                .font(.system(size: size * 0.70, weight: .bold))
                .foregroundColor(color)
        }
    }
}

// MARK: - Sliding Segmented Mode Switcher (ẢNH / PRO / VIDEO — Chạm 5 lần vào ẢNH mở Photobooth)
struct CameraModeSegmentedSwitcher: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var modeAnimationNamespace
    @State private var photoTabTapCount: Int = 0
    @State private var lastPhotoTabTapTime: TimeInterval = 0

    private enum SwitcherMode: String, CaseIterable, Identifiable {
        case photo = "ẢNH"
        case proPhoto = "PRO"
        case video = "VIDEO"

        var id: String { rawValue }
    }

    private var activeSwitcherMode: SwitcherMode {
        if viewModel.captureMode.isVideo { return .video }
        return viewModel.isProPhotoModeEnabled ? .proPhoto : .photo
    }

    var body: some View {
        let proAvailability = viewModel.featureAvailability(.proPhoto)
        HStack(spacing: 4) {
            ForEach(SwitcherMode.allCases) { item in
                let isSelected = (activeSwitcherMode == item)
                let isProTab = (item == .proPhoto)
                let isDisabledPro = isProTab && !proAvailability.isAvailable

                Button(action: {
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        switch item {
                        case .photo:
                            if viewModel.isPhotoboothModeActive {
                                photoTabTapCount = 0
                                viewModel.exitPhotoboothMode()
                                viewModel.selectCaptureMode(.photo)
                            } else {
                                if activeSwitcherMode != .photo {
                                    viewModel.selectCaptureMode(.photo)
                                }
                                let now = CACurrentMediaTime()
                                if now - lastPhotoTabTapTime <= 1.45 {
                                    photoTabTapCount += 1
                                } else {
                                    photoTabTapCount = 1
                                }
                                lastPhotoTabTapTime = now

                                if photoTabTapCount >= 5 {
                                    photoTabTapCount = 0
                                    HapticFeedbackService.shared.triggerMedium()
                                    viewModel.enterPhotoboothMode()
                                } else if photoTabTapCount >= 3 {
                                    HapticFeedbackService.shared.triggerLight()
                                    let remain = 5 - photoTabTapCount
                                    viewModel.showHUDNotice("Chạm thêm \(remain) lần vào ẢNH để mở Photobooth")
                                }
                            }
                        case .proPhoto:
                            photoTabTapCount = 0
                            if viewModel.isPhotoboothModeActive { viewModel.exitPhotoboothMode() }
                            viewModel.selectProPhotoMode()
                        case .video:
                            photoTabTapCount = 0
                            if viewModel.isPhotoboothModeActive { viewModel.exitPhotoboothMode() }
                            viewModel.selectCaptureMode(.video)
                        }
                    }
                }) {
                    Text(item.rawValue)
                        .font(.system(size: 11.2, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundColor(
                            isSelected
                                ? (isProTab ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary)
                                : (isDisabledPro ? AlignTheme.studioInkSecondary.opacity(0.45) : AlignTheme.studioInkSecondary)
                        )
                        .frame(width: 60, height: 32)
                        .background(
                            ZStack {
                                if isSelected {
                                    Capsule()
                                        .fill(isProTab ? AlignTheme.studioAccentSoft : Color.white.opacity(0.14))
                                        .overlay(
                                            Capsule()
                                                .stroke(isProTab ? AlignTheme.studioAccentBorder : Color.white.opacity(0.12), lineWidth: 0.65)
                                        )
                                        .matchedGeometryEffect(id: "active_mode_pill", in: modeAnimationNamespace)
                                }
                            }
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Chế độ \(item.rawValue)")
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(AlignTheme.studioSurface)
                .overlay {
                    Capsule()
                        .stroke(AlignTheme.studioHairline, lineWidth: 0.6)
                }
        )
        .frame(height: 38)
    }
}

// MARK: - Minimalist Shutter Button (Clean Outer Ring & Pure Core with Drag-Left to AI Dock)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingToAI: Bool = false
    @State private var hasReachedDock: Bool = false
    @State private var isTouchingShutter: Bool = false

    var body: some View {
        if viewModel.captureMode.isVideo {
            videoRecordControl
        } else {
            photoCaptureControl
        }
    }

    // MARK: - Photo Capture Control
    private var photoCaptureControl: some View {
        ZStack {
            // 1. Sliding Track Slot (Active when dragging to left AI Compose dock)
            if isDraggingToAI {
                Capsule()
                    .fill(Color.black.opacity(0.65))
                    .frame(width: 76, height: 46)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.20), lineWidth: 1.0)
                    )
                    .offset(x: -30)
                    .opacity(trackOpacity)
                    .animation(.easeOut(duration: 0.15), value: dragOffset)
            }

            // 2. AI Compose Left Dock Target (Coordinate -56pt)
            aiComposeDockTarget

            // 3. Central Minimalist Shutter
            minimalistPhotoShutter
        }
        .frame(width: 160, height: 80)
    }

    // MARK: - Video Record Control (Clean Tactile Record/Stop — Đã gỡ bỏ Đạo diễn AI Video)
    private var videoRecordControl: some View {
        minimalistVideoShutter
            .frame(width: 80, height: 80)
    }

    // MARK: - Machined Tactile Photo Shutter (Crisp Outer Ring & Subtle Ivory Core)
    private var minimalistPhotoShutter: some View {
        ZStack {
            // Outer Anodized Ring: Fixed 74x74
            Circle()
                .stroke(shutterRingBorderColor, lineWidth: 2.6)
                .frame(width: 74, height: 74)

            // Inner Core: Crisp Ivory Disc with subtle edge depth
            Circle()
                .fill(AlignTheme.studioInkPrimary)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.8)
                        .padding(1)
                )
                .frame(width: 60, height: 60)
                .offset(x: dragOffset)
                .scaleEffect((isTouchingShutter || viewModel.isShutterPressing) ? 0.91 : 1.0)

            // Progress Indicator when Capturing or Photobooth Sequence Countdown
            if viewModel.isPhotoboothSequenceRunning {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AlignTheme.studioRecordRed)
                    .frame(width: 22, height: 22)
                    .offset(x: dragOffset)
            } else if case .capturing = viewModel.aiSessionState {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioCanvas))
                    .scaleEffect(0.92)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isTouchingShutter)
        .gesture(dragAndTapGesture(isForVideo: false))
        .accessibilityLabel("Nút chụp ảnh: Chạm để chụp, giữ kéo sang trái để bật AI Bố cục")
    }

    // MARK: - Machined Tactile Video Shutter (Crisp Outer Ring & Matte Crimson Core)
    private var minimalistVideoShutter: some View {
        Button(action: {
            viewModel.toggleVideoRecording()
        }) {
            ZStack {
                Circle()
                    .stroke(AlignTheme.studioInkPrimary, lineWidth: 2.6)
                    .frame(width: 74, height: 74)

                if viewModel.isRecordingVideo {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AlignTheme.studioRecordRed)
                        .frame(width: 26, height: 26)
                        .animation(.spring(response: 0.25, dampingFraction: 0.74), value: viewModel.isRecordingVideo)
                } else {
                    Circle()
                        .fill(AlignTheme.studioRecordRed)
                        .frame(width: 60, height: 60)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Nút quay video: Chạm để bắt đầu hoặc dừng quay")
    }

    // MARK: - Gesture Handler (Tap & Drag to AI Dock for Photo Mode)
    private func dragAndTapGesture(isForVideo: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let transX = value.translation.width
                if !isTouchingShutter {
                    isTouchingShutter = true
                    HapticFeedbackService.shared.triggerShutterHalfPress()
                }

                if !isForVideo && !viewModel.isPhotoboothModeActive && transX < -6 && viewModel.featureAvailability(.aiComposition).isAvailable {
                    isDraggingToAI = true
                    if transX < -56 {
                        dragOffset = -56 + (transX + 56) * 0.25
                    } else {
                        dragOffset = transX
                    }

                    let reached = dragOffset <= -42
                    if reached && !hasReachedDock {
                        hasReachedDock = true
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.prepare()
                        generator.impactOccurred()
                    } else if !reached && hasReachedDock {
                        hasReachedDock = false
                    }
                } else if transX > 0 {
                    isDraggingToAI = false
                    hasReachedDock = false
                    dragOffset = min(14, transX * 0.20)
                } else {
                    dragOffset = 0
                    isDraggingToAI = false
                    hasReachedDock = false
                }
            }
            .onEnded { value in
                let transX = value.translation.width
                let transY = value.translation.height
                let didReachDock = hasReachedDock || dragOffset <= -42

                if didReachDock && !isForVideo {
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.prepare()
                    generator.impactOccurred()

                    viewModel.attemptFeature(.aiComposition) {
                        if viewModel.aiSessionState.isSessionActive {
                            viewModel.cancelAISession()
                        } else {
                            viewModel.startAISession()
                        }
                    }
                } else if !isDraggingToAI && abs(transX) < 14 && abs(transY) < 14 {
                    // Regular Tap
                    if isForVideo {
                        viewModel.toggleVideoRecording()
                    } else if viewModel.isPhotoboothModeActive {
                        viewModel.startPhotoboothCaptureOrSequence()
                    } else {
                        if viewModel.aiSessionState != .capturing {
                            if viewModel.isUltraSharpEnabled && viewModel.captureMode == .photo && viewModel.featureAvailability(.ultraSharp).isAvailable {
                                viewModel.performUltraSharpPhotoCapture()
                            } else {
                                viewModel.takePhotoManual()
                            }
                        }
                    }
                }

                withAnimation(.spring(response: 0.30, dampingFraction: 0.74)) {
                    dragOffset = 0
                    isDraggingToAI = false
                    hasReachedDock = false
                    isTouchingShutter = false
                }
            }
    }

    private var shutterRingBorderColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return AlignTheme.studioInkPrimary
        case .analyzing, .targetPlaced, .capturing:
            return AlignTheme.studioAccent
        case .alignmentPerfect:
            return AlignTheme.studioPositive
        }
    }

    private var trackOpacity: Double {
        let offsetVal = abs(Double(dragOffset))
        let progress = (offsetVal - 6.0) / 30.0
        return min(1.0, max(0.0, progress))
    }

    private var dockOpacity: Double {
        guard isDraggingToAI else { return 0.0 }
        let offsetVal = abs(Double(dragOffset))
        let progress = (offsetVal - 6.0) / 25.0
        return min(1.0, max(0.0, progress))
    }

    private var dockScale: CGFloat {
        guard isDraggingToAI else { return 0.82 }
        let progress = min(CGFloat(1.0), abs(dragOffset) / CGFloat(56.0))
        return CGFloat(0.85) + progress * CGFloat(0.25)
    }

    // MARK: - AI Compose Left Dock Target (Smoked Glass)
    private var aiComposeDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(AlignTheme.studioSurface)
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock ? AlignTheme.studioAccent : Color.white.opacity(0.22), lineWidth: hasReachedDock ? 1.5 : 0.8)
                    .frame(width: 44, height: 44)

                Image(systemName: "viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(hasReachedDock ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.80))
                    .scaleEffect(hasReachedDock ? 1.12 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hasReachedDock)
            }
            .offset(x: -56)
            .scaleEffect(dockScale)
            .opacity(dockOpacity)
            .animation(.easeOut(duration: 0.15), value: isDraggingToAI)

            Spacer()
        }
    }
}

// MARK: - Gallery Thumbnail Button (Balanced Left Deck Item)
struct GalleryThumbnailButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            let haptic = UISelectionFeedbackGenerator()
            haptic.prepare()
            haptic.selectionChanged()
            viewModel.isShowingGallerySheet = true
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AlignTheme.studioSurface)
                    .frame(width: 46, height: 46)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                    )

                if let thumb = viewModel.latestAlbumThumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else if let photo = viewModel.latestCapturedPhoto {
                    Image(decorative: photo.processedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    CustomAppIconView(
                        name: "iconnutxemanhganday",
                        fallbackSF: "photo.on.rectangle",
                        size: 20,
                        color: AlignTheme.studioInkPrimary.opacity(0.76)
                    )
                }
            }
            .frame(width: 50, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Mở thư viện ảnh")
    }
}

// MARK: - Camera Flip Button (Balanced Right Deck Item with 180° Spin & Capability Gating)
struct CameraFlipButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var flipDegrees: Double = 0

    var body: some View {
        let availability = viewModel.featureAvailability(.cameraFlip)
        Button(action: {
            viewModel.attemptFeature(.cameraFlip) {
                viewModel.switchCamera { didSwitch in
                    guard didSwitch else { return }
                    let haptic = UISelectionFeedbackGenerator()
                    haptic.prepare()
                    haptic.selectionChanged()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                        flipDegrees += 180
                    }
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(AlignTheme.studioSurface)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Circle()
                            .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                    )

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(AlignTheme.studioInkPrimary.opacity(0.90))
                    .rotationEffect(.degrees(flipDegrees))
            }
            .frame(width: 50, height: 50)
            .opacity(availability.isAvailable ? 1.0 : 0.36)
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Đổi camera trước và sau")
    }
}

// MARK: - AI Viewfinder Button (Photo-Only Capability Gated — Đã gỡ Đạo diễn AI Video)
struct AIViewfinderButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        let availability = viewModel.featureAvailability(.aiComposition)
        let activeHighlight = availability.isAvailable && isPulsing

        Button(action: {
            viewModel.attemptFeature(.aiComposition) {
                let haptic = UIImpactFeedbackGenerator(style: .medium)
                haptic.prepare()
                haptic.impactOccurred()
                if viewModel.aiSessionState.isSessionActive {
                    viewModel.cancelAISession()
                } else {
                    viewModel.startAISession()
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(activeHighlight ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(activeHighlight ? AlignTheme.studioAccentBorder : AlignTheme.studioHairline, lineWidth: activeHighlight ? 0.9 : 0.65)
                    )

                if let uiImage = UIImage(named: "nutAI") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nutAI", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .foregroundColor(activeHighlight ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                } else if let altImage = UIImage(named: "nuticonbocuc") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nuticonbocuc", ofType: "png") ?? "") {
                    Image(uiImage: altImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .foregroundColor(activeHighlight ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                } else {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(activeHighlight ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                }
            }
            .frame(width: 44, height: 44)
            .opacity(availability.isAvailable ? 1.0 : 0.34)
            .scaleEffect(activeHighlight ? 1.04 : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.72), value: activeHighlight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(availability.isAvailable ? "Nút AI Bố cục" : (availability.detailReason ?? "AI Bố cục đang khóa"))
    }

    private var isPulsing: Bool {
        switch viewModel.aiSessionState {
        case .analyzing, .targetPlaced, .alignmentPerfect:
            return true
        default:
            return false
        }
    }
}

// MARK: - Selected Camera Mini Badge Button (Symmetric Smoked Surface + Capability Gating)
public struct SelectedCameraBadgeButton: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    private var isHighlighted: Bool {
        viewModel.isShowingFilmDrawer
            || viewModel.isFilmSimulationActive
            || !viewModel.effectiveVintageLightLeak.isIdentity
            || viewModel.effectiveVintageDateStampStyle.isEnabled
    }

    public var body: some View {
        let availability = viewModel.featureAvailability(.filmColor)
        let activeHighlight = availability.isAvailable && isHighlighted

        Button(action: {
            viewModel.attemptFeature(.filmColor) {
                HapticFeedbackService.shared.triggerSelectionChange()
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    viewModel.isShowingFilmDrawer.toggle()
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(activeHighlight ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(activeHighlight ? AlignTheme.studioAccentBorder : AlignTheme.studioHairline, lineWidth: activeHighlight ? 0.9 : 0.65)
                    )

                if viewModel.isFilmSimulationActive,
                   let camIcon = VintageCameraIconCache.shared.icon(named: viewModel.selectedFilmPreset.cameraIconAssetName) {
                    Image(uiImage: camIcon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 26, height: 24)
                } else {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundColor(activeHighlight ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.80))
                }
            }
            .frame(width: 44, height: 44)
            .opacity(availability.isAvailable ? 1.0 : 0.34)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.isFilmSimulationActive ? "Bảng màu máy ảnh \(viewModel.selectedFilmPreset.displayName)" : "Màu giả lập đang tắt, chạm để mở bảng màu")
    }
}

// MARK: - Camera Card View (Delegates to Studio-Lit 3D Hardware Camera Card)
public struct CameraCardView: View {
    let preset: FilmPreset
    let isSelected: Bool

    public init(preset: FilmPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        VintageHardwareCameraCard(preset: preset, isSelected: isSelected)
    }
}

// MARK: - Film Preset Drawer (Redesigned Dazz-Style Vintage Camera Shelf + Light Leak + Date Stamp + Sample Look)
public struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VintageCameraDrawerView(viewModel: viewModel)
    }
}
