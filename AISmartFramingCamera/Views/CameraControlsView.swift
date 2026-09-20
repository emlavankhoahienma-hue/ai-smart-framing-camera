import SwiftUI
import UIKit

// MARK: - Camera Controls View (Dark Luxury Pro Cinema Edition)
public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Film Preset Drawer (Floating Overlay above Controls)
            if viewModel.isShowingFilmDrawer {
                FilmPresetDrawer(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Row 1: Balanced 3-Column Shutter Control Deck with Live Camera Badge
            HStack(alignment: .center, spacing: 0) {
                // Left Column: Recent Photo Thumbnail (Equal Width)
                HStack(spacing: 8) {
                    GalleryThumbnailButton(viewModel: viewModel)
                        .frame(width: 48, height: 48)
                    CameraFlipButton(viewModel: viewModel)
                        .frame(width: 44, height: 44)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

                // Center Column: Mechanical Shutter Button (Strictly Centered on Screen Axis)
                MainCaptureButton(viewModel: viewModel)
                    .frame(width: 80, height: 80)

                // Right Column: Selected Camera Mini Badge (Storyboard Style)
                HStack {
                    Spacer()
                    SelectedCameraBadgeButton(viewModel: viewModel)
                        .frame(width: 54, height: 54)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)

            // Row 2: Camera Mode Switcher (ẢNH / VIDEO) directly under Shutter
            CameraModeSegmentedSwitcher(viewModel: viewModel)
                .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color(red: 0.031, green: 0.035, blue: 0.043) // Match Canvas Background
                .ignoresSafeArea(edges: .bottom)
        )
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
        let icon: String
        var id: String { title }
    }

    private let modes: [ModeItem] = [
        ModeItem(mode: .photo, title: "ẢNH", icon: "camera.fill"),
        ModeItem(mode: .video, title: "VIDEO", icon: "video.fill")
    ]

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { item in
                let isSelected = (viewModel.captureMode == item.mode) || (item.mode == .video && viewModel.captureMode == .proVideo)
                Button(action: {
                    guard viewModel.captureMode != item.mode else { return }
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare()
                    generator.selectionChanged()
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                        viewModel.captureMode = item.mode
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                        Text(item.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium, design: .rounded))
                    }
                    .foregroundColor(isSelected ? amberGold : .white.opacity(0.55))
                    .frame(width: 82, height: 32)
                    .background(
                        ZStack {
                            if isSelected {
                                Capsule()
                                    .fill(Color(red: 0.16, green: 0.17, blue: 0.22))
                                    .matchedGeometryEffect(id: "active_mode_pill", in: modeAnimationNamespace)
                                    .overlay(
                                        Capsule()
                                            .stroke(amberGold.opacity(0.38), lineWidth: 1.0)
                                    )
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
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.09), lineWidth: 1.0)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)
        )
    }
}

// MARK: - Mechanical Capture Button (Pro Cinema Dial with Drag-Left to AI Dock)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingToAI: Bool = false
    @State private var hasReachedDock: Bool = false
    @State private var isTouchingShutter: Bool = false

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

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

            // 3. Central Mechanical Shutter Dial
            mechanicalShutterDial
        }
        .frame(width: 160, height: 78)
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

            // 3. Central Mechanical Video Dial
            mechanicalVideoDial
        }
        .frame(width: 160, height: 78)
    }

    // MARK: - Mechanical Shutter Dial (Multi-ring Graphite + Radial Gradient Core)
    private var mechanicalShutterDial: some View {
        ZStack {
            // Layer 1: Beveled Graphite Outer Ring
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.19, blue: 0.23),
                            Color(red: 0.09, green: 0.10, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 74, height: 74)
                .overlay(
                    Circle()
                        .stroke(shutterRingBorderColor, lineWidth: 1.8)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 6, y: 3)

            // Layer 2: Dark Metallic Groove
            Circle()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .frame(width: 66, height: 66)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.85), lineWidth: 1.2)
                )

            // Layer 3: Concentric Mechanical Core with Specular Highlight
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.38, green: 0.40, blue: 0.45),
                            Color(red: 0.20, green: 0.21, blue: 0.25),
                            Color(red: 0.11, green: 0.12, blue: 0.14)
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 28
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    // Specular Highlight Arc
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.38), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.65), radius: 3, x: 0, y: 2)
                .offset(x: dragOffset)
                .scaleEffect((isTouchingShutter || viewModel.isShutterPressing) ? 0.94 : 1.0)

            // Progress Indicator when Capturing
            if case .capturing = viewModel.aiSessionState {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: amberGold))
                    .scaleEffect(0.90)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isTouchingShutter)
        .gesture(dragAndTapGesture(isForVideo: false))
        .accessibilityLabel("Nút chụp ảnh: Chạm để chụp, giữ kéo sang trái để bật AI Compose")
    }

    // MARK: - Mechanical Video Record Dial
    private var mechanicalVideoDial: some View {
        ZStack {
            // Layer 1: Beveled Graphite Outer Ring
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.19, blue: 0.23),
                            Color(red: 0.09, green: 0.10, blue: 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 74, height: 74)
                .overlay(
                    Circle()
                        .stroke(viewModel.isAIVideoDirectorActive ? amberGold : Color.white.opacity(0.24), lineWidth: 1.8)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 6, y: 3)

            // Layer 2: Dark Groove
            Circle()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07))
                .frame(width: 66, height: 66)

            // Layer 3: Red Recording Core
            if viewModel.isRecordingVideo {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.15, blue: 0.20))
                    .frame(width: 26, height: 26)
                    .offset(x: dragOffset)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: viewModel.isRecordingVideo)
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.35, blue: 0.38),
                                Color(red: 0.85, green: 0.12, blue: 0.18),
                                Color(red: 0.55, green: 0.05, blue: 0.09)
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: 28
                        )
                    )
                    .frame(width: 56, height: 56)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.40), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .offset(x: dragOffset)
                    .scaleEffect(isTouchingShutter ? 0.94 : 1.0)
            }

            if viewModel.isAIVideoDirectorAnalyzing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(0.90)
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isTouchingShutter)
        .gesture(dragAndTapGesture(isForVideo: true))
        .accessibilityLabel("Nút quay video: Chạm để quay/dừng, giữ kéo sang trái để AI Đạo diễn")
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
            return Color.white.opacity(0.24)
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
                            .stroke(Color.white.opacity(0.28), lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)

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
            let haptic = UISelectionFeedbackGenerator()
            haptic.prepare()
            haptic.selectionChanged()

            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                flipDegrees += 180
            }
            viewModel.switchCamera()
        }) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 4, y: 2)

                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .rotationEffect(.degrees(flipDegrees))
            }
            .contentShape(Circle())
        }
        .luxuryGoldInteractive(baseColor: .white.opacity(0.92))
        .accessibilityLabel("Đổi camera trước và sau")
    }
}

// MARK: - Selected Camera Mini Badge Button (Storyboard Right Shutter Deck)
public struct SelectedCameraBadgeButton: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Button(action: {
            let haptic = UISelectionFeedbackGenerator()
            haptic.prepare()
            haptic.selectionChanged()

            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                viewModel.isShowingFilmDrawer.toggle()
            }
        }) {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
                        .frame(width: 48, height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(viewModel.isShowingFilmDrawer ? amberGold : Color.white.opacity(0.25), lineWidth: 1.2)
                        )
                        .shadow(color: viewModel.isShowingFilmDrawer ? amberGold.opacity(0.40) : Color.black.opacity(0.4), radius: 4, y: 2)

                    Image(systemName: viewModel.selectedFilmPreset.deviceIconSF)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(viewModel.isShowingFilmDrawer ? amberGold : viewModel.selectedFilmPreset.previewColor)
                }

                Text(viewModel.selectedFilmPreset.shortTitle)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(viewModel.isShowingFilmDrawer ? amberGold : .white.opacity(0.85))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Mở bảng màu máy ảnh \(viewModel.selectedFilmPreset.displayName)")
    }
}

// MARK: - Camera Card View (Storyboard Filmstrip Card with Badge & Icon)
public struct CameraCardView: View {
    let preset: FilmPreset
    let isSelected: Bool
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(preset: FilmPreset, isSelected: Bool) {
        self.preset = preset
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(spacing: 2) {
            // Top Badge Chip
            HStack {
                Text(preset.deviceBadge)
                    .font(.system(size: 7.5, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? .black : preset.previewColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? amberGold : Color.black.opacity(0.45))
                    )
                Spacer()
            }
            .padding(.top, 4)
            .padding(.horizontal, 5)

            Spacer(minLength: 2)

            // Center Device Icon
            ZStack {
                Circle()
                    .fill(preset.previewColor.opacity(isSelected ? 0.28 : 0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: preset.deviceIconSF)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(isSelected ? amberGold : .white.opacity(0.92))
            }

            Spacer(minLength: 2)

            // Bottom Name Label
            Text(preset.shortTitle)
                .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? amberGold : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 3)
                .padding(.bottom, 5)
        }
        .frame(width: 66, height: 84)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.12, green: 0.13, blue: 0.17))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? amberGold : Color.white.opacity(0.14), lineWidth: isSelected ? 2.0 : 1.0)
        )
        .shadow(color: isSelected ? amberGold.opacity(0.50) : Color.clear, radius: 6)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.68), value: isSelected)
    }
}

// MARK: - Film Preset Drawer (Storyboard 11 Categories & Filmstrip Reel)
public struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    public init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 1. Category Tab Bar Header
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(FilmPresetCategory.allCases) { category in
                            let isSelected = viewModel.selectedFilmCategory == category
                            Button(action: {
                                viewModel.selectFilmCategory(category)
                            }) {
                                VStack(spacing: 4) {
                                    Text(category.displayName)
                                        .font(.system(size: 12.5, weight: isSelected ? .bold : .medium, design: .rounded))
                                        .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.60))

                                    // Selection bar indicator
                                    Rectangle()
                                        .fill(isSelected ? amberGold : Color.clear)
                                        .frame(height: 2)
                                        .cornerRadius(1)
                                }
                                .padding(.horizontal, 2)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }

                // Close Drawer Button
                Button(action: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                        viewModel.isShowingFilmDrawer = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.trailing, 12)
                }
                .accessibilityLabel("Đóng bảng màu máy ảnh")
            }

            // 2. Filmstrip Camera Cards Reel
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(viewModel.selectedFilmCategory.presets) { preset in
                            let isSelected = viewModel.selectedFilmPreset == preset

                            Button(action: {
                                viewModel.selectPreset(preset)
                            }) {
                                CameraCardView(preset: preset, isSelected: isSelected)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .id(preset.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .onAppear {
                    proxy.scrollTo(viewModel.selectedFilmPreset.id, anchor: .center)
                }
            }

            // 3. Preset Description Subtitle
            HStack {
                Text(viewModel.selectedFilmPreset.description)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1.0)
                )
                .shadow(color: Color.black.opacity(0.6), radius: 12, y: 4)
        )
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height > 25 {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                            viewModel.isShowingFilmDrawer = false
                        }
                    }
                }
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }
}
