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
            .padding(.horizontal, 22)

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
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
        }
        .padding(.top, compact ? 2 : 4)
        .padding(.bottom, compact ? 4 : 6)
        .frame(height: deckHeight)
        .frame(maxWidth: .infinity)
        .background(
            Color(red: 0.031, green: 0.035, blue: 0.043)
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

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25) // #D9A441

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
                        .font(.system(size: 12, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isSelected ? amberGold : .white.opacity(0.55))
                        .frame(width: 82, height: 44)
                        .background(
                            ZStack {
                                if isSelected {
                                    Capsule()
                                        .stroke(amberGold, lineWidth: 1.2)
                                        .matchedGeometryEffect(id: "active_mode_border", in: modeAnimationNamespace)
                                }
                            }
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Chế độ \(item.title)")
            }
        }
        .padding(2)
        .frame(height: 36)
    }
}

// MARK: - Minimalist Shutter Button (Clean Outer Ring & Pure Core with Drag-Left to AI Dock)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingToAI: Bool = false
    @State private var hasReachedDock: Bool = false
    @State private var isTouchingShutter: Bool = false

    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

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

    // MARK: - Minimalist Photo Shutter (Thin White Outer Ring & Solid White Core)
    private var minimalistPhotoShutter: some View {
        ZStack {
            // Outer Ring: Pure White, Fixed 76x76 Size
            Circle()
                .stroke(shutterRingBorderColor, lineWidth: 3.5)
                .frame(width: 76, height: 76)

            // Inner Core: Solid White Circle, Scaled upon press
            Circle()
                .fill(Color.white)
                .frame(width: 62, height: 62)
                .offset(x: dragOffset)
                .scaleEffect((isTouchingShutter || viewModel.isShutterPressing) ? 0.92 : 1.0)

            // Progress Indicator when Capturing
            if case .capturing = viewModel.aiSessionState {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: amberGold))
                    .scaleEffect(0.95)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.70), value: isTouchingShutter)
        .gesture(dragAndTapGesture(isForVideo: false))
        .accessibilityLabel("Nút chụp ảnh: Chạm để chụp, giữ kéo sang trái để bật AI Bố cục")
    }

    // MARK: - Minimalist Video Shutter (Outer Ring Fixed 76x76 & Red Core Morphs to Rounded Square)
    private var minimalistVideoShutter: some View {
        ZStack {
            // Outer Ring: Fixed 76x76 Size
            Circle()
                .stroke(viewModel.isAIVideoDirectorActive ? amberGold : Color.white, lineWidth: 3.5)
                .frame(width: 76, height: 76)

            // Inner Core: Red Circle / Rounded Rectangle
            if viewModel.isRecordingVideo {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.15, blue: 0.20))
                    .frame(width: 28, height: 28)
                    .offset(x: dragOffset)
                    .animation(.spring(response: 0.25, dampingFraction: 0.72), value: viewModel.isRecordingVideo)
            } else {
                Circle()
                    .fill(Color(red: 0.95, green: 0.15, blue: 0.20))
                    .frame(width: 62, height: 62)
                    .offset(x: dragOffset)
                    .scaleEffect(isTouchingShutter ? 0.92 : 1.0)
            }

            if viewModel.isAIVideoDirectorAnalyzing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.95)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.70), value: isTouchingShutter)
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
                            viewModel.takePhotoManual()
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
            return Color.white
        case .analyzing, .targetPlaced:
            return amberGold
        case .alignmentPerfect:
            return Color.green
        case .capturing:
            return amberGold
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

    // MARK: - AI Compose Left Dock Target
    private var aiComposeDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.80))
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock ? amberGold : Color.white.opacity(0.35), lineWidth: hasReachedDock ? 2.2 : 1.0)
                    .frame(width: 44, height: 44)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(hasReachedDock ? amberGold : Color.white.opacity(0.75))
                    .scaleEffect(hasReachedDock ? 1.20 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hasReachedDock)
            }
            .shadow(color: hasReachedDock ? amberGold.opacity(0.60) : Color.clear, radius: 8)
            .offset(x: -56)
            .scaleEffect(dockScale)
            .opacity(dockOpacity)
            .animation(.easeOut(duration: 0.15), value: isDraggingToAI)

            Spacer()
        }
    }

    // MARK: - AI Video Director Left Dock Target
    private var aiVideoDirectorDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.80))
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock ? amberGold : (viewModel.isAIVideoDirectorActive ? amberGold.opacity(0.85) : Color.white.opacity(0.35)), lineWidth: hasReachedDock ? 2.2 : 1.0)
                    .frame(width: 44, height: 44)

                Image(systemName: "sparkles.tv")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(hasReachedDock ? amberGold : (viewModel.isAIVideoDirectorActive ? amberGold : Color.white.opacity(0.75)))
                    .scaleEffect(hasReachedDock ? 1.20 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hasReachedDock)
            }
            .shadow(color: (hasReachedDock || viewModel.isAIVideoDirectorActive) ? amberGold.opacity(0.60) : Color.clear, radius: 8)
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
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: 50, height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 1.0)
                    )

                if let photo = viewModel.latestCapturedPhoto {
                    Image(decorative: photo.processedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else if let thumb = viewModel.latestAlbumThumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    CustomAppIconView(
                        name: "iconnutxemanhganday",
                        fallbackSF: "photo.on.rectangle.angled",
                        size: 24,
                        color: .white.opacity(0.82)
                    )
                }
            }
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
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.20), lineWidth: 1.0)
                    )

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(flipDegrees))
            }
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!viewModel.canSwitchCamera)
        .accessibilityLabel("Đổi camera trước và sau")
    }
}

// MARK: - AI Viewfinder Button (nutAI Asset, No Background, No Border, 44x44pt Target)
struct AIViewfinderButton: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

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
            } else if viewModel.isWindowedZoomActive {
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
                        .frame(width: 32, height: 32)
                        .foregroundColor(isPulsing ? amberGold : Color.white.opacity(0.90))
                } else if let altImage = UIImage(named: "nuticonbocuc") ?? UIImage(contentsOfFile: Bundle.main.path(forResource: "nuticonbocuc", ofType: "png") ?? "") {
                    Image(uiImage: altImage)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 32)
                        .foregroundColor(isPulsing ? amberGold : Color.white.opacity(0.90))
                } else {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(isPulsing ? amberGold : Color.white.opacity(0.90))
                }
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isPulsing ? 1.06 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isPulsing)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.captureMode.isVideo ? "AI Đạo diễn video" : "Nút AI Bố cục")
    }

    private var isPulsing: Bool {
        if viewModel.captureMode.isVideo {
            return viewModel.isAIVideoDirectorActive
        }
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

// MARK: - Selected Camera Mini Badge Button (Opens Drawer)
public struct SelectedCameraBadgeButton: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Button(action: {
            HapticFeedbackService.shared.triggerSelectionChange()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                viewModel.isShowingFilmDrawer.toggle()
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.14))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(
                                viewModel.isShowingFilmDrawer ? amberGold :
                                    (viewModel.isFilmSimulationActive ? amberGold.opacity(0.70) : Color.white.opacity(0.18)),
                                lineWidth: 1.0
                            )
                    )

                if viewModel.isFilmSimulationActive {
                    Image(systemName: viewModel.selectedFilmPreset.deviceIconSF)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(viewModel.isShowingFilmDrawer ? amberGold : viewModel.selectedFilmPreset.previewColor)
                } else {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                }
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
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    var body: some View {
        VStack(spacing: 1.5) {
            // Top Badge Chip
            HStack {
                Text("GỐC")
                    .font(.system(size: 7.0, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? .black : .white.opacity(0.80))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.2)
                    .background(
                        Capsule()
                            .fill(isSelected ? amberGold : Color.white.opacity(0.15))
                    )
                Spacer()
            }
            .padding(.top, 3)
            .padding(.horizontal, 4)

            Spacer(minLength: 1)

            // Center Device Icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isSelected ? 0.25 : 0.08))
                    .frame(width: 30, height: 30)

                Image(systemName: "circle.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? amberGold : .white.opacity(0.70))
            }

            Spacer(minLength: 1)

            // Bottom Name Label
            Text("TẮT MÀU")
                .font(.system(size: 8.0, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? amberGold : .white.opacity(0.70))
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .padding(.horizontal, 2)
                .padding(.bottom, 3.5)
        }
        .frame(width: 54, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? amberGold : Color.white.opacity(0.12), lineWidth: isSelected ? 1.8 : 0.8)
        )
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.70), value: isSelected)
    }
}

// MARK: - Camera Card View (Compact Storyboard Filmstrip Card)
public struct CameraCardView: View {
    let preset: FilmPreset
    let isSelected: Bool
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(preset: FilmPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(spacing: 1.5) {
            // Top Badge Chip
            HStack {
                Text(preset.deviceBadge)
                    .font(.system(size: 7.0, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? .black : preset.previewColor)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1.2)
                    .background(
                        Capsule()
                            .fill(isSelected ? amberGold : Color.black.opacity(0.45))
                    )
                Spacer()
            }
            .padding(.top, 3)
            .padding(.horizontal, 4)

            Spacer(minLength: 1)

            // Center Device Icon
            ZStack {
                Circle()
                    .fill(preset.previewColor.opacity(isSelected ? 0.30 : 0.14))
                    .frame(width: 30, height: 30)

                Image(systemName: preset.deviceIconSF)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? amberGold : .white.opacity(0.92))
            }

            Spacer(minLength: 1)

            // Bottom Name Label
            Text(preset.shortTitle)
                .font(.system(size: 8.5, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? amberGold : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .padding(.horizontal, 2)
                .padding(.bottom, 3.5)
        }
        .frame(width: 54, height: 68)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? amberGold : Color.white.opacity(0.12), lineWidth: isSelected ? 1.8 : 0.8)
        )
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.70), value: isSelected)
    }
}

// MARK: - Film Preset Drawer (Compact Storyboard 35mm Reel & Tabs)
public struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 0.85, green: 0.64, blue: 0.25)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 4) {
            headerBar
            filmstripTrack
        }
        .padding(.vertical, 4)
        .background(drawerBackground)
        .gesture(dismissDragGesture)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            // Master ON / OFF Toggle Pill
            Button(action: {
                viewModel.toggleFilmSimulation()
            }) {
                HStack(spacing: 4.5) {
                    Circle()
                        .fill(viewModel.isFilmSimulationActive ? amberGold : Color.gray.opacity(0.60))
                        .frame(width: 6.5, height: 6.5)

                    Text(viewModel.isFilmSimulationActive ? "MÀU: BẬT" : "MÀU: TẮT")
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundColor(viewModel.isFilmSimulationActive ? amberGold : .white.opacity(0.70))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(viewModel.isFilmSimulationActive ? amberGold.opacity(0.16) : Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(viewModel.isFilmSimulationActive ? amberGold.opacity(0.45) : Color.white.opacity(0.16), lineWidth: 1.0)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.leading, 10)
            .accessibilityLabel("Bật tắt màu giả lập")

            Divider()
                .frame(height: 16)
                .background(Color.white.opacity(0.20))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmPresetCategory.allCases) { category in
                        let isSelected = viewModel.selectedFilmCategory == category
                        Button(action: {
                            viewModel.selectFilmCategory(category)
                        }) {
                            VStack(spacing: 3) {
                                Text(category.displayName)
                                    .font(.system(size: 11.0, weight: isSelected ? .bold : .medium, design: .rounded))
                                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.60))

                                // Selection bar indicator
                                Rectangle()
                                    .fill(isSelected ? amberGold : Color.clear)
                                    .frame(height: 1.8)
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

            // Close Drawer Button
            Button(action: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                    viewModel.isShowingFilmDrawer = false
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.trailing, 10)
            }
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
                        // Dedicated [ GỐC / TẮT MÀU ] Card
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
        .background(Color.black.opacity(0.40))
    }

    private var drawerBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1.0)
            )
            .shadow(color: Color.black.opacity(0.6), radius: 10, y: 3)
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
