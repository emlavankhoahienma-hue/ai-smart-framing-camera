import SwiftUI

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel

    let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0, 5.0]

    public var body: some View {
        VStack(spacing: 6) {
            // Film Preset Drawer (Expandable)
            if viewModel.isShowingFilmDrawer {
                FilmPresetDrawer(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Zoom Selector Pills
            ZoomSelectorPills(viewModel: viewModel, options: zoomOptions)
                .padding(.bottom, 4)

            // Mode Switcher (Ảnh / Video / Pro) dạng Segmented Capsule trượt
            CameraModeSegmentedSwitcher(viewModel: viewModel)
                .padding(.bottom, 10)

            // Main Bottom Control Deck
            HStack(alignment: .center) {
                // Left: Gallery Thumbnail
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 52, height: 52)

                Spacer()

                // Center: Single Central Capture Controls (Photo: AI Pill + Central Shutter / Video: Record)
                MainCaptureButton(viewModel: viewModel)

                Spacer()

                // Right: Color Drawer Toggle
                FilterToggleButton(viewModel: viewModel)
                    .frame(width: 52, height: 52)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.88), Color.black]),
                startPoint: .top,
                endPoint: .bottom
            )
            .edgesIgnoringSafeArea(.bottom)
        )
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

    private let modes: [(mode: CaptureMode, title: String)] = [
        (.photo, "Ảnh"),
        (.video, "Video"),
        (.proVideo, "Pro")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(modes, id: \.mode) { item in
                let isSelected = viewModel.captureMode == item.mode
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        viewModel.captureMode = item.mode
                    }
                }) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            ZStack {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.yellow)
                                        .matchedGeometryEffect(id: "active_mode_pill", in: modeAnimationNamespace)
                                        .shadow(color: Color.yellow.opacity(0.35), radius: 4)
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
                .fill(Color.black.opacity(0.45))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

// MARK: - Main Capture Button (Photo: AI Compose Pill + Central Shutter / Video: Record)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        if viewModel.captureMode.isVideo {
            videoRecordButton
        } else {
            photoCaptureColumn
        }
    }

    // MARK: - Photo Capture Column (AI Pill + Central Shutter)
    private var photoCaptureColumn: some View {
        VStack(spacing: 8) {
            aiComposePill
            centralShutterButton
        }
    }

    // MARK: - AI Compose Pill (Compact ~28pt pill above shutter)
    private var aiComposePill: some View {
        Button(action: {
            if viewModel.aiSessionState.isSessionActive {
                viewModel.cancelAISession()
            } else {
                viewModel.startAISession()
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(aiPillColor)

                Text(aiPillTitle)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(aiPillColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                Capsule()
                    .stroke(aiPillBorderColor, lineWidth: 1.5)
            )
            .shadow(color: viewModel.aiSessionState.isSessionActive ? aiPillColor.opacity(0.4) : Color.clear, radius: 4)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.aiSessionState.isSessionActive ? "Hủy AI Compose" : "Bắt đầu AI Compose")
    }

    private var aiPillColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return .white.opacity(0.9)
        case .analyzing, .targetPlaced:
            return .yellow
        case .alignmentPerfect:
            return .green
        case .capturing:
            return .yellow
        }
    }

    private var aiPillBorderColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return Color.white.opacity(0.25)
        case .analyzing, .targetPlaced:
            return Color.yellow
        case .alignmentPerfect:
            return Color.green
        case .capturing:
            return Color.yellow
        }
    }

    private var aiPillTitle: String {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return "AI COMPOSE"
        case .analyzing:
            return "TÌM CHỦ THỂ…"
        case .targetPlaced:
            return "HỦY AI"
        case .alignmentPerfect:
            return "ĐÃ KHỚP"
        case .capturing:
            return "ĐANG CHỤP"
        }
    }

    // MARK: - Central Shutter Button (68×68)
    private var centralShutterButton: some View {
        Button(action: {
            if viewModel.aiSessionState != .capturing {
                viewModel.takePhotoManual()
            }
        }) {
            ZStack {
                // Viền ngoài: Trắng chuẩn, đổi sang vàng hoặc xanh lá khi AI session bám nét
                Circle()
                    .stroke(shutterRingColor, lineWidth: 3.2)
                    .frame(width: 68, height: 68)

                // Vòng trong: Màu trắng, co lại khi nhấn
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: viewModel.isShutterPressing ? 50 : 58,
                        height: viewModel.isShutterPressing ? 50 : 58
                    )

                if case .capturing = viewModel.aiSessionState {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(viewModel.isShutterPressing ? 0.92 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.isShutterPressing)
        .disabled(viewModel.aiSessionState == .capturing)
        .accessibilityLabel("Chụp ảnh")
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

    // MARK: - Video Record Button
    private var videoRecordButton: some View {
        Button(action: {
            viewModel.toggleVideoRecording()
        }) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3.5)
                    .frame(width: 76, height: 76)

                if viewModel.isRecordingVideo {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 62, height: 62)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(viewModel.isRecordingVideo ? "Dừng quay video" : "Bắt đầu quay video")
    }
}

// MARK: - Zoom Selector Pills
struct ZoomSelectorPills: View {
    @ObservedObject var viewModel: CameraViewModel
    let options: [CGFloat]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { zoom in
                let isSelected = abs(viewModel.currentZoom - zoom) < 0.15
                Button(action: {
                    viewModel.setZoomFromButton(zoom)
                }) {
                    Text(String(format: "%.0f×", zoom))
                        .font(.system(size: 12, weight: isSelected ? .heavy : .medium, design: .rounded))
                        .foregroundColor(isSelected ? .black : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? Color.yellow : Color.black.opacity(0.45))
                        )
                }
            }

            // Chỉ báo mức zoom thực tế khi người dùng pinch-to-zoom thủ công ở các khoảng giữa
            let matchesStandardPill = options.contains { abs(viewModel.currentZoom - $0) < 0.15 }
            if !matchesStandardPill {
                Text(String(format: "%.1f×", viewModel.currentZoom))
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow))
                    .transition(.scale.combined(with: .opacity))
            }
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                viewModel.isShowingFilmDrawer.toggle()
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 50, height: 50)

                Circle()
                    .stroke(viewModel.isAIFullColorEnabled ? Color.cyan : Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 50, height: 50)

                CustomAppIconView(
                    name: "iconchonmau",
                    fallbackSF: "camera.filters",
                    size: 28,
                    color: viewModel.isAIFullColorEnabled ? .cyan : .white
                )
            }
            .contentShape(Circle())
        }
    }
}

// MARK: - Film Preset Drawer (Thư Viện Màu Film Trực Quan Có Hình Ảnh Mẫu)
struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Header: Tiêu đề & Tắt
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.yellow)
                    Text("Màu sắc")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.isShowingFilmDrawer = false
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

            // Danh sách ảnh mẫu ngang
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(FilmPreset.allCases) { preset in
                        let isSelected = viewModel.selectedFilmPreset == preset
                        let thumbImage = PresetThumbnailProvider.shared.thumbnail(for: preset)

                        Button(action: {
                            viewModel.selectPreset(preset)
                        }) {
                            VStack(spacing: 5) {
                                ZStack(alignment: .bottom) {
                                    // 1. Ảnh mẫu trực quan thể hiện chuẩn màu của từng preset
                                    Image(uiImage: thumbImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 66, height: 66)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            // Gradient mờ ở đáy ảnh để chữ nổi bật
                                            LinearGradient(
                                                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.75)]),
                                                startPoint: .center,
                                                endPoint: .bottom
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        )
                                        .overlay(
                                            // Viền nổi bật khi được chọn
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(isSelected ? Color.yellow : Color.white.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                                        )
                                        .shadow(color: isSelected ? Color.yellow.opacity(0.4) : Color.clear, radius: 6)

                                    // 2. Tên viết tắt trên ảnh
                                    Text(preset.shortTitle)
                                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.white)
                                        .padding(.bottom, 3)

                                    // 3. Dấu tích chọn góc trên
                                    if isSelected {
                                        VStack {
                                            HStack {
                                                Spacer()
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundColor(.yellow)
                                                    .background(Circle().fill(Color.black).padding(1))
                                                    .padding(3)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                .frame(width: 66, height: 66)

                                // Tên thân thiện bên dưới
                                Text(preset.displayName)
                                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                                    .foregroundColor(isSelected ? .yellow : .white.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .scaleEffect(isSelected ? 1.04 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityLabel("Chọn màu \(preset.displayName)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
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
                            viewModel.isShowingFilmDrawer = false
                        }
                    }
                }
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
