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

            // Mode Switcher (Ảnh / Video / Pro)
            HStack(spacing: 24) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = .photo
                    }
                }) {
                    Text("Ảnh")
                        .font(.system(size: 14, weight: viewModel.captureMode == .photo ? .bold : .medium))
                        .foregroundColor(viewModel.captureMode == .photo ? .yellow : .gray)
                }
                .accessibilityLabel("Chế độ chụp ảnh")

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = .video
                    }
                }) {
                    Text("Video")
                        .font(.system(size: 14, weight: viewModel.captureMode == .video ? .bold : .medium))
                        .foregroundColor(viewModel.captureMode == .video ? .yellow : .gray)
                }
                .accessibilityLabel("Chế độ quay video")

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = .proVideo
                    }
                }) {
                    Text("Pro")
                        .font(.system(size: 14, weight: viewModel.captureMode == .proVideo ? .bold : .medium))
                        .foregroundColor(viewModel.captureMode == .proVideo ? .yellow : .gray)
                }
                .accessibilityLabel("Chế độ quay video Pro")
            }
            .padding(.bottom, 8)

            // Main Bottom Control Deck
            HStack(alignment: .center) {
                // Left: Gallery Thumbnail
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)

                Spacer()

                // Center: Single Primary Capture / Record Button
                MainCaptureButton(viewModel: viewModel)

                Spacer()

                // Right: Color Drawer Toggle
                FilterToggleButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)
            }
            .padding(.horizontal, 28)
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

// MARK: - Main Capture Button (Quiet Pro: Single Primary Shutter)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        if viewModel.captureMode.isVideo {
            // Video Record Button (Red circle with square when recording)
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
        } else {
            // Photo Mode: Single primary shutter button (White ring + white inner circle)
            Button(action: {
                if viewModel.aiSessionState != .capturing {
                    viewModel.takePhotoManual()
                }
            }) {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3.5)
                        .frame(width: 76, height: 76)

                    Circle()
                        .fill(Color.white)
                        .frame(
                            width: viewModel.isShutterPressing ? 54 : 62,
                            height: viewModel.isShutterPressing ? 54 : 62
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
