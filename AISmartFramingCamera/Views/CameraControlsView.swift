import SwiftUI

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel

    public var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 64, height: 52)

                Spacer()

                MainCaptureButton(viewModel: viewModel)

                Spacer()

                FilterToggleButton(viewModel: viewModel)
                    .frame(width: 64, height: 52)
            }
            .padding(.horizontal, 12)

            CameraModeSegmentedSwitcher(viewModel: viewModel)
                .padding(.bottom, 6)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.025, green: 0.025, blue: 0.03))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

// MARK: - Reliable Custom App Icon Component (Assets Catalog + Bundle Fallback + SF Symbols)
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

// MARK: - Sliding Segmented Mode Switcher (Ảnh / Video / Pro)
struct CameraModeSegmentedSwitcher: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var modeAnimationNamespace

    private struct ModeItem: Identifiable {
        let mode: CameraCaptureMode
        let title: String
        var id: String { title }
    }

    private let modes: [ModeItem] = [
        ModeItem(mode: .photo, title: "Ảnh"),
        ModeItem(mode: .video, title: "Video"),
        ModeItem(mode: .proVideo, title: "Pro")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modes) { item in
                modeButton(for: item)
            }
        }
        .padding(3)
        .frame(width: 218)
        .background(
            Capsule()
                .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func modeButton(for item: ModeItem) -> some View {
        let isSelected = viewModel.captureMode == item.mode
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                viewModel.dismissCameraPanels()
                viewModel.captureMode = item.mode
            }
        }) {
            Text(item.title)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? .black : .white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(modePillBackground(isSelected: isSelected))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Chế độ \(item.title)")
    }

    @ViewBuilder
    private func modePillBackground(isSelected: Bool) -> some View {
        if isSelected {
            Capsule()
                .fill(Color.yellow)
                .matchedGeometryEffect(id: "active_mode_pill", in: modeAnimationNamespace)
        } else {
            Color.clear
        }
    }
}

// MARK: - Main Capture Button (Photo: Apple-style Shutter with Drag-Left to AI Compose / Video: Record)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingToAI: Bool = false
    @State private var hasReachedDock: Bool = false
    @State private var isTouchingShutter: Bool = false

    var body: some View {
        if viewModel.captureMode.isVideo {
            videoRecordButton
        } else {
            photoCaptureControls
        }
    }

    // MARK: - Photo Capture Controls (Central Shutter + Drag-Left to AI Compose Dock)
    private var photoCaptureControls: some View {
        ZStack {
            // 1. Rãnh trượt kết nối (Track Slot) - Chỉ hiện khi kéo sang trái
            if isDraggingToAI {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 72, height: 44)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                    .offset(x: -28)
                    .opacity(trackOpacity)
                    .animation(.easeOut(duration: 0.15), value: dragOffset)
            }

            // 2. AI Compose Left Dock Target (Chỉ hiện khi kéo sang trái)
            aiComposeDockTarget

            // 3. Nút Chụp Trung Tâm với viền cố định và lõi trượt mượt mà
            centralShutterView
        }
        .frame(width: 156, height: 74)
    }

    private var trackOpacity: Double {
        let offsetVal: Double = abs(Double(dragOffset))
        let progress: Double = (offsetVal - 6.0) / 30.0
        return min(1.0, max(0.0, progress))
    }

    private var dockOpacity: Double {
        guard isDraggingToAI else { return 0.0 }
        let offsetVal: Double = abs(Double(dragOffset))
        let progress: Double = (offsetVal - 6.0) / 25.0
        return min(1.0, max(0.0, progress))
    }

    private var dockScale: CGFloat {
        guard isDraggingToAI else { return 0.8 }
        let progress = min(CGFloat(1.0), abs(dragOffset) / CGFloat(56.0))
        return CGFloat(0.85) + progress * CGFloat(0.3)
    }

    private var shutterStretchX: CGFloat {
        let stretch = min(CGFloat(0.10), abs(dragOffset) / CGFloat(200.0))
        return CGFloat(1.0) + stretch
    }

    private var shutterStretchY: CGFloat {
        let squish = min(CGFloat(0.05), abs(dragOffset) / CGFloat(400.0))
        return CGFloat(1.0) - squish
    }

    // MARK: - AI Compose Left Dock Target (Tọa độ -56pt)
    private var aiComposeDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock ? Color.yellow : Color.white.opacity(0.35), lineWidth: hasReachedDock ? 2.5 : 1.2)
                    .frame(width: 44, height: 44)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(hasReachedDock ? Color.yellow : Color.white.opacity(0.75))
                    .scaleEffect(hasReachedDock ? 1.22 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hasReachedDock)
            }
            .offset(x: -56)
            .scaleEffect(dockScale)
            .opacity(dockOpacity)
            .animation(.easeOut(duration: 0.15), value: isDraggingToAI)

            Spacer()
        }
    }

    // MARK: - Central Shutter View (68×68)
    private var centralShutterView: some View {
        ZStack {
            // Viền ngoài cố định tại tâm: Trắng chuẩn, đổi sang vàng hoặc xanh lá khi AI session bám nét
            Circle()
                .stroke(shutterRingColor, lineWidth: 3.2)
                .frame(width: 68, height: 68)

            // Lõi trong: Màu trắng, trượt sang trái theo ngón tay khi kéo
            Circle()
                .fill(Color.white)
                .frame(
                    width: (isTouchingShutter || viewModel.isShutterPressing) ? 50 : 58,
                    height: (isTouchingShutter || viewModel.isShutterPressing) ? 50 : 58
                )
                .offset(x: dragOffset)
                .scaleEffect(x: shutterStretchX, y: shutterStretchY)

            if case .capturing = viewModel.aiSessionState {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTouchingShutter)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let transX = value.translation.width

                    isTouchingShutter = true

                    // Khi người dùng kéo trượt sang trái (transX < 0)
                    if transX < -6 {
                        isDraggingToAI = true
                        // Đàn hồi nhẹ nếu kéo vượt quá dock (-56pt)
                        if transX < -56 {
                            dragOffset = -56 + (transX + 56) * 0.25
                        } else {
                            dragOffset = transX
                        }

                        // Vượt ngưỡng -42pt: Chạm dock, kích hoạt haptic snap
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
                        // Kháng cự đàn hồi nếu kéo sang phải (không kích hoạt AI)
                        isDraggingToAI = false
                        hasReachedDock = false
                        dragOffset = min(15, transX * 0.2)
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
                        // Đã kéo vào dock AI Compose: Rung mạnh & Bật/Tắt AI Compose
                        let generator = UIImpactFeedbackGenerator(style: .heavy)
                        generator.prepare()
                        generator.impactOccurred()

                        if viewModel.aiSessionState.isSessionActive {
                            viewModel.cancelAISession()
                        } else {
                            viewModel.startAISession()
                        }
                    } else if !isDraggingToAI && abs(transX) < 14 && abs(transY) < 14 {
                        // Nhấp chạm thông thường (không kéo): Chụp ảnh bình thường
                        if viewModel.aiSessionState != .capturing {
                            viewModel.takePhotoManual()
                        }
                    }

                    // Hồi phục vị trí lõi nút chụp với animation nảy spring chuẩn Apple physics
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        dragOffset = 0
                        isDraggingToAI = false
                        hasReachedDock = false
                        isTouchingShutter = false
                    }
                }
        )
        .accessibilityLabel("Nút chụp ảnh: Chạm để chụp, giữ kéo sang trái để AI Compose")
    }

    private var shutterRingColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return .white
        case .analyzing, .targetPlaced:
            return .yellow
        case .alignmentPerfect:
            return .green
        case .capturing:
            return .white
        }
    }

    // MARK: - Video Record Button (Touch to Record / Hold-Drag-Left to AI Video Director)
    private var videoRecordButton: some View {
        ZStack {
            // 1. Rãnh trượt kết nối (Track Slot) - Chỉ hiện khi kéo sang trái
            if isDraggingToAI {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 72, height: 44)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                    .offset(x: -28)
                    .opacity(trackOpacity)
                    .animation(.easeOut(duration: 0.15), value: dragOffset)
            }

            // 2. AI Video Director Left Dock Target (Chỉ hiện khi kéo sang trái)
            aiVideoDirectorDockTarget

            // 3. Nút quay trung tâm với viền cố định và lõi đỏ trượt mượt mà
            centralVideoRecordView
        }
        .frame(width: 156, height: 74)
    }

    // MARK: - AI Video Director Left Dock Target (Tọa độ -56pt)
    private var aiVideoDirectorDockTarget: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(hasReachedDock ? Color.yellow : (viewModel.isAIVideoDirectorActive ? Color.yellow.opacity(0.85) : Color.white.opacity(0.35)), lineWidth: hasReachedDock ? 2.5 : 1.2)
                    .frame(width: 44, height: 44)

                Image(systemName: "sparkles.tv")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(hasReachedDock ? Color.yellow : (viewModel.isAIVideoDirectorActive ? Color.yellow : Color.white.opacity(0.75)))
                    .scaleEffect(hasReachedDock ? 1.22 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hasReachedDock)
            }
            .offset(x: -56)
            .scaleEffect(dockScale)
            .opacity(dockOpacity)
            .animation(.easeOut(duration: 0.15), value: isDraggingToAI)

            Spacer()
        }
    }

    // MARK: - Central Video Record View
    private var centralVideoRecordView: some View {
        ZStack {
            // Viền ngoài cố định tại tâm
            Circle()
                .stroke(viewModel.isAIVideoDirectorActive ? Color.yellow : Color.white, lineWidth: 3.5)
                .frame(width: 76, height: 76)

            // Lõi nút quay (đỏ): thu nhỏ lại hình vuông bo góc khi quay, hoặc trượt sang trái khi kéo
            if viewModel.isRecordingVideo {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red)
                    .frame(width: 28, height: 28)
                    .offset(x: dragOffset)
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(
                        width: isTouchingShutter ? 54 : 62,
                        height: isTouchingShutter ? 54 : 62
                    )
                    .offset(x: dragOffset)
                    .scaleEffect(x: shutterStretchX, y: shutterStretchY)
            }

            if viewModel.isAIVideoDirectorAnalyzing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .offset(x: dragOffset)
            }
        }
        .contentShape(Circle())
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isTouchingShutter)
        .gesture(
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
                        dragOffset = min(15, transX * 0.2)
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

                        if viewModel.isAIVideoDirectorActive {
                            viewModel.dismissAIVideoDirector()
                        } else {
                            viewModel.requestAIVideoCinematographyGuidance()
                        }
                    } else if !isDraggingToAI && abs(transX) < 14 && abs(transY) < 14 {
                        viewModel.toggleVideoRecording()
                    }

                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        dragOffset = 0
                        isDraggingToAI = false
                        hasReachedDock = false
                        isTouchingShutter = false
                    }
                }
        )
        .accessibilityLabel("Nút quay video: Chạm để quay, giữ kéo sang trái để AI Đạo diễn gợi ý cách quay")
    }
}

// MARK: - Viewfinder Zoom Switcher
struct ViewfinderZoomSwitcher: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var selectionNamespace
    private let amberGold = Color(red: 1.0, green: 0.72, blue: 0.0)
    private let options: [CGFloat] = [1, 2]

    var body: some View {
        VStack(spacing: 4) {
            if viewModel.isPinchingZoom && !isNearAnchor(viewModel.displayZoom) {
                Text(String(format: "%.1f×", viewModel.displayZoom))
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundColor(amberGold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.92))
                            .overlay(Capsule().stroke(amberGold.opacity(0.35), lineWidth: 1))
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            HStack(spacing: 10) {
                ForEach(options, id: \.self) { zoom in
                    let isSelected = selectedAnchor == zoom
                    Button(action: {
                        viewModel.setZoomFromButton(zoom)
                    }) {
                        Text(String(format: "%.0f×", zoom))
                            .font(.system(size: 13, weight: isSelected ? .heavy : .semibold, design: .rounded))
                            .foregroundColor(isSelected ? amberGold : .white.opacity(0.82))
                            .frame(width: 40, height: 40)
                            .background(selectionBackground(isSelected: isSelected))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Zoom " + String(Int(zoom)) + " lần")
                }
            }
            .padding(4)
            .background(
                Capsule()
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.11))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.76), value: selectedAnchor)
    }

    private var selectedAnchor: CGFloat {
        abs(viewModel.displayZoom - 1) <= abs(viewModel.displayZoom - 2) ? 1 : 2
    }

    private func isNearAnchor(_ zoom: CGFloat) -> Bool {
        options.contains { abs(zoom - $0) < 0.08 }
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .fill(Color(red: 0.04, green: 0.04, blue: 0.045))
                .overlay(Circle().stroke(amberGold.opacity(0.75), lineWidth: 1.5))
                .matchedGeometryEffect(id: "zoom-selection", in: selectionNamespace)
        } else {
            Circle()
                .fill(Color.clear)
        }
    }
}

// MARK: - Gallery Thumbnail Button
struct GalleryThumbnailButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            if viewModel.latestCapturedPhoto != nil {
                viewModel.isShowingPhotoDetail = true
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 50, height: 50)

                if let photo = viewModel.latestCapturedPhoto {
                    Image(decorative: photo.processedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                } else {
                    CustomAppIconView(
                        name: "iconnutxemanhganday",
                        fallbackSF: "photo.on.rectangle.angled",
                        size: 28,
                        color: .white.opacity(0.88)
                    )
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Filter Toggle Button
struct FilterToggleButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.toggleCameraPanel(.filmPresets)
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 50, height: 50)

                Circle()
                    .stroke(viewModel.activeCameraPanel == .filmPresets ? Color.yellow : Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 50, height: 50)

                CustomAppIconView(
                    name: "iconchonmau",
                    fallbackSF: "camera.filters",
                    size: 28,
                    color: viewModel.activeCameraPanel == .filmPresets ? .yellow : .white
                )
            }
            .contentShape(Circle())
        }
    }
}

// MARK: - Film Preset Drawer (Danh Sách Tên Màu Film Tối Giản Typography Chuẩn Pro)
struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Header: Tiêu đề & Nút đóng
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.yellow)
                    Text("Bộ lọc màu film")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        viewModel.dismissCameraPanels()
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                }
                .accessibilityLabel("Đóng bảng màu")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            // Danh sách tên preset dạng Capsule/Pill tối giản chuẩn Pro Camera
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilmPreset.allCases) { preset in
                        let isSelected = viewModel.selectedFilmPreset == preset
                        let isAIRecommended = viewModel.aiRecommendedPreset == preset

                        Button(action: {
                            let generator = UISelectionFeedbackGenerator()
                            generator.prepare()
                            generator.selectionChanged()
                            viewModel.selectPreset(preset)
                        }) {
                            HStack(spacing: 5) {
                                if preset.isAIFullAuto {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 11, weight: .bold))
                                } else if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .heavy))
                                } else if isAIRecommended {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.yellow)
                                }

                                Text(preset.displayName)
                                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium, design: .rounded))
                            }
                            .foregroundColor(isSelected ? .black : .white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.yellow : (isAIRecommended ? Color.yellow.opacity(0.18) : Color.white.opacity(0.08)))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? Color.yellow : (isAIRecommended ? Color.yellow.opacity(0.6) : Color.white.opacity(0.12)), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .scaleEffect(isSelected ? 1.04 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
                        .accessibilityLabel("Chọn màu \(preset.displayName)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 6)
        .frame(maxHeight: 88)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.075, green: 0.075, blue: 0.085))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height > 25 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            viewModel.dismissCameraPanels()
                        }
                    }
                }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
