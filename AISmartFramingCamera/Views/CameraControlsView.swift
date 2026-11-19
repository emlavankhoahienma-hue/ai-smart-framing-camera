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
            AlignTheme.studioCanvas
                .ignoresSafeArea(edges: .bottom)
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

// MARK: - Sliding Segmented Mode Switcher (ẢNH / VIDEO)
struct CameraModeSegmentedSwitcher: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var modeAnimationNamespace

    private struct ModeItem: Identifiable {
        let mode: CameraCaptureMode
        let title: String
        var id: String { title }
    }

    private let modes: [ModeItem] = [
        ModeItem(mode: .photo, title: "ẢNH"),
        ModeItem(mode: .video, title: "VIDEO")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modes) { item in
                let isSelected = (viewModel.captureMode == item.mode) || (item.mode == .video && viewModel.captureMode == .proVideo)
                Button(action: {
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                        viewModel.selectCaptureMode(item.mode)
                    }
                }) {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                        .frame(width: 78, height: 32)
                        .background(
                            ZStack {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.white.opacity(0.14))
                                        .overlay(
                                            Capsule()
                                                .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
                                        )
                                        .matchedGeometryEffect(id: "active_mode_pill", in: modeAnimationNamespace)
                                }
                            }
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Chế độ \(item.title)")
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

    // MARK: - Video Record Control
    private var videoRecordControl: some View {
        ZStack {
            // 1. Sliding Track Slot
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

            // 2. AI Video Director Left Dock Target
            aiVideoDirectorDockTarget

            // 3. Central Minimalist Video Shutter
            minimalistVideoShutter
        }
        .frame(width: 160, height: 80)
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

            // Progress Indicator when Capturing
            if case .capturing = viewModel.aiSessionState {
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
        ZStack {
            Circle()
                .stroke(viewModel.isAIVideoDirectorActive ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary, lineWidth: 2.6)
                .frame(width: 74, height: 74)

            if viewModel.isRecordingVideo {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AlignTheme.studioRecordRed)
                    .frame(width: 26, height: 26)
                    .offset(x: dragOffset)
                    .animation(.spring(response: 0.25, dampingFraction: 0.74), value: viewModel.isRecordingVideo)
            } else {
                Circle()
                    .fill(AlignTheme.studioRecordRed)
                    .frame(width: 60, height: 60)
                    .offset(x: dragOffset)
                    .scaleEffect(isTouchingShutter ? 0.91 : 1.0)
            }

            if viewModel.isAIVideoDirectorAnalyzing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.92)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isTouchingShutter)
        .gesture(dragAndTapGesture(isForVideo: true))
        .accessibilityLabel("Nút quay video: Chạm để quay hoặc dừng, giữ kéo sang trái để AI Đạo diễn")
    }

    // MARK: - Gesture Handler (Tap & Drag to AI Dock)
    private func dragAndTapGesture(isForVideo: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let transX = value.translation.width
                isTouchingShutter = true

                if transX < -6 {
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

                if didReachDock {
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.prepare()
                    generator.impactOccurred()

                    if isForVideo {
                        if viewModel.isAIVideoDirectorActive {
                            viewModel.dismissAIVideoDirector()
                        } else {
                            viewModel.requestAIVideoCinematographyGuidance()
                        }
                    } else {
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
                    } else {
                        if viewModel.aiSessionState != .capturing {
                            if viewModel.isUltraSharpEnabled && viewModel.captureMode == .photo {
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

    // MARK: - AI Video Director Left Dock Target (Smoked Glass)
    private var aiVideoDirectorDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(AlignTheme.studioSurface)
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock || viewModel.isAIVideoDirectorActive ? AlignTheme.studioAccent : Color.white.opacity(0.22), lineWidth: hasReachedDock ? 1.5 : 0.8)
                    .frame(width: 44, height: 44)

                Image(systemName: "video")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(hasReachedDock || viewModel.isAIVideoDirectorActive ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.80))
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

                if let photo = viewModel.latestCapturedPhoto {
                    Image(decorative: photo.processedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else if let thumb = viewModel.latestAlbumThumbnail {
                    Image(uiImage: thumb)
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

// MARK: - Camera Flip Button (Balanced Right Deck Item with 180° Spin)
struct CameraFlipButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var flipDegrees: Double = 0

    var body: some View {
        Button(action: {
            guard viewModel.canSwitchCamera else { return }
            viewModel.switchCamera { didSwitch in
                guard didSwitch else { return }
                let haptic = UISelectionFeedbackGenerator()
                haptic.prepare()
                haptic.selectionChanged()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    flipDegrees += 180
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
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!viewModel.canSwitchCamera)
        .accessibilityLabel("Đổi camera trước và sau")
    }
}

// MARK: - AI Viewfinder Button (Unified Monochrome Smoked Surface, Symmetric with Film Button)
struct AIViewfinderButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.prepare()
            haptic.impactOccurred()

            if viewModel.captureMode.isVideo {
                if viewModel.isAIVideoDirectorActive {
                    viewModel.dismissAIVideoDirector()
                } else {
                    viewModel.requestAIVideoCinematographyGuidance()
                }
            } else {
                if viewModel.aiSessionState.isSessionActive {
                    viewModel.cancelAISession()
                } else {
                    viewModel.startAISession()
                }
            }
        }) {
            ZStack {
                Circle()
                    .fill(isPulsing ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(isPulsing ? AlignTheme.studioAccentBorder : AlignTheme.studioHairline, lineWidth: isPulsing ? 0.9 : 0.65)
                    )

                if let uiImage = UIImage(named: "nutAI") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nutAI", ofType: "png") ?? "") {
                    Image(uiImage: uiImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .foregroundColor(isPulsing ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                } else if let altImage = UIImage(named: "nuticonbocuc") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nuticonbocuc", ofType: "png") ?? "") {
                    Image(uiImage: altImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .foregroundColor(isPulsing ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                } else {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isPulsing ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
                }
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isPulsing ? 1.04 : 1.0)
            .animation(.spring(response: 0.30, dampingFraction: 0.72), value: isPulsing)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.captureMode.isVideo ? "AI Đạo diễn video" : "Nút AI Bố cục")
    }

    private var isPulsing: Bool {
        if viewModel.captureMode.isVideo {
            return viewModel.isAIVideoDirectorActive
        }
        switch viewModel.aiSessionState {
        case .analyzing, .targetPlaced, .alignmentPerfect:
            return true
        default:
            return false
        }
    }
}

// MARK: - Selected Camera Mini Badge Button (Symmetric Smoked Surface Matching AI Button)
public struct SelectedCameraBadgeButton: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    private var isHighlighted: Bool {
        viewModel.isShowingFilmDrawer || viewModel.isFilmSimulationActive
    }

    public var body: some View {
        Button(action: {
            HapticFeedbackService.shared.triggerSelectionChange()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                viewModel.isShowingFilmDrawer.toggle()
            }
        }) {
            ZStack {
                Circle()
                    .fill(isHighlighted ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .stroke(isHighlighted ? AlignTheme.studioAccentBorder : AlignTheme.studioHairline, lineWidth: isHighlighted ? 0.9 : 0.65)
                    )

                Image(systemName: viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset.deviceIconSF : "camera.filters")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(isHighlighted ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.80))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.isFilmSimulationActive ? "Bảng màu máy ảnh \(viewModel.selectedFilmPreset.displayName)" : "Màu giả lập đang tắt, chạm để mở bảng màu")
    }
}

// MARK: - 35mm Film Sprocket Perforation Track
private struct SprocketPerforationsRow: View {
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<45, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 4.5, height: 3.2)
            }
        }
        .frame(height: 4)
        .clipped()
    }
}

// MARK: - Raw Original Clean Card (Turn Off Simulation)
private struct RawCleanCardView: View {
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("GỐC")
                    .font(.system(size: 7.0, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .black : AlignTheme.studioInkSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? AlignTheme.studioAccent : Color.white.opacity(0.10))
                    )
                Spacer()
            }
            .padding(.top, 4)
            .padding(.horizontal, 5)

            Spacer(minLength: 1)

            ZStack {
                Circle()
                    .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                    .frame(width: 28, height: 28)

                Image(systemName: "circle.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
            }

            Spacer(minLength: 1)

            Text("TẮT MÀU")
                .font(.system(size: 8.0, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
        }
        .frame(width: 56, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 1.1 : 0.6)
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isSelected)
    }
}

// MARK: - Camera Card View (Compact Monochrome Studio Filmstrip Card)
public struct CameraCardView: View {
    let preset: FilmPreset
    let isSelected: Bool

    public init(preset: FilmPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(preset.deviceBadge)
                    .font(.system(size: 7.0, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .black : AlignTheme.studioInkSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? AlignTheme.studioAccent : Color.white.opacity(0.10))
                    )
                Spacer()
            }
            .padding(.top, 4)
            .padding(.horizontal, 5)

            Spacer(minLength: 1)

            ZStack {
                Circle()
                    .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.07))
                    .frame(width: 28, height: 28)

                Image(systemName: preset.deviceIconSF)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkPrimary.opacity(0.84))
            }

            Spacer(minLength: 1)

            Text(preset.shortTitle)
                .font(.system(size: 8.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
        }
        .frame(width: 56, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AlignTheme.studioAccentSoft : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 1.1 : 0.6)
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.74), value: isSelected)
    }
}

// MARK: - Film Preset Drawer (Smoked Frosted Glass Storyboard)
public struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 6) {
            headerBar
            if viewModel.isFilmSimulationActive {
                intensitySliderBar
            }
            filmstripTrack
        }
        .padding(.vertical, 8)
        .background(drawerBackground)
        .gesture(dismissDragGesture)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var intensitySliderBar: some View {
        HStack(spacing: 8) {
            Text("CƯỜNG ĐỘ")
                .font(.system(size: 9.0, weight: .semibold, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkSecondary)

            Slider(value: $viewModel.filmSimulationIntensity, in: 0.1...1.0, step: 0.05)
                .tint(AlignTheme.studioAccent)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.filmSimulationIntensity = 1.0
                }
            }) {
                Text("\(Int(round(viewModel.filmSimulationIntensity * 100)))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(AlignTheme.studioAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(AlignTheme.studioAccentSoft)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đặt lại cường độ 100%")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .transition(.opacity)
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                viewModel.toggleFilmSimulation()
            }) {
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(viewModel.isFilmSimulationActive ? AlignTheme.studioAccent : AlignTheme.studioInkTertiary)
                        .frame(width: 6, height: 6)

                    Text(viewModel.isFilmSimulationActive ? "MÀU BẬT" : "MÀU TẮT")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(viewModel.isFilmSimulationActive ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(viewModel.isFilmSimulationActive ? AlignTheme.studioAccentSoft : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(viewModel.isFilmSimulationActive ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: 0.6)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.leading, 10)
            .accessibilityLabel("Bật tắt màu giả lập")

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 0.6, height: 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmPresetCategory.allCases) { category in
                        let isSelected = viewModel.selectedFilmCategory == category
                        Button(action: {
                            viewModel.selectFilmCategory(category)
                        }) {
                            VStack(spacing: 3) {
                                Text(category.displayName)
                                    .font(.system(size: 11.0, weight: isSelected ? .semibold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? AlignTheme.studioInkPrimary : AlignTheme.studioInkSecondary)

                                Rectangle()
                                    .fill(isSelected ? AlignTheme.studioAccent : Color.clear)
                                    .frame(height: 1.5)
                                    .cornerRadius(1)
                            }
                            .padding(.horizontal, 1)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            Button(action: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    viewModel.isShowingFilmDrawer = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(AlignTheme.studioInkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .padding(.trailing, 10)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Đóng bảng màu máy ảnh")
        }
    }

    @ViewBuilder
    private var filmstripTrack: some View {
        VStack(spacing: 3) {
            SprocketPerforationsRow()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: {
                            viewModel.disableFilmSimulation()
                        }) {
                            RawCleanCardView(isSelected: !viewModel.isFilmSimulationActive)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .id("raw_off_card")

                        ForEach(viewModel.selectedFilmCategory.presets) { preset in
                            let isSelected = viewModel.isFilmSimulationActive && viewModel.selectedFilmPreset == preset

                            Button(action: {
                                viewModel.selectPreset(preset)
                            }) {
                                CameraCardView(preset: preset, isSelected: isSelected)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(preset.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
                .onAppear {
                    if viewModel.isFilmSimulationActive {
                        proxy.scrollTo(viewModel.selectedFilmPreset.id, anchor: .center)
                    } else {
                        proxy.scrollTo("raw_off_card", anchor: .center)
                    }
                }
            }

            SprocketPerforationsRow()
        }
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.24))
    }

    private var drawerBackground: some View {
        StudioGlassRoundedSurface(cornerRadius: 20, tintOpacity: 0.76, borderOpacity: 0.15)
            .shadow(color: Color.black.opacity(0.55), radius: 18, y: 4)
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onEnded { value in
                if value.translation.height > 20 {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                        viewModel.isShowingFilmDrawer = false
                    }
                }
            }
    }
}
