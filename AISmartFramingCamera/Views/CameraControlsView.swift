import SwiftUI

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0, 5.0, 10.0]
    
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
            
            // Mode Switcher (ẢNH / VIDEO)
            HStack(spacing: 24) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = .photo
                    }
                }) {
                    Text("ẢNH")
                        .font(.system(size: 13, weight: viewModel.captureMode == .photo ? .heavy : .medium))
                        .foregroundColor(viewModel.captureMode == .photo ? .yellow : .gray)
                }
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.captureMode = .video
                    }
                }) {
                    Text("VIDEO")
                        .font(.system(size: 13, weight: viewModel.captureMode == .video ? .heavy : .medium))
                        .foregroundColor(viewModel.captureMode == .video ? .yellow : .gray)
                }
            }
            .padding(.bottom, 8)
            
            // Main Bottom Control Deck
            HStack(alignment: .center) {
                // Left: Gallery Thumbnail
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)
                
                Spacer()
                
                // Center: Capture / Record Button
                MainCaptureButton(viewModel: viewModel)
                
                Spacer()
                
                // Right: Filter / Color Toggle
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

// MARK: - Main Capture Button (Photo AI / Photo Manual / Video Recording)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        VStack(spacing: 6) {
            if viewModel.captureMode == .video {
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
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                // Photo Mode
                switch viewModel.aiSessionState {
                case .idle, .done:
                    HStack(spacing: 16) {
                        // AI START button
                        Button(action: {
                            viewModel.startAISession()
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.yellow, lineWidth: 2.5)
                                    .frame(width: 72, height: 72)
                                
                                VStack(spacing: 2) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundColor(.yellow)
                                    Text("AI")
                                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        // MANUAL SHUTTER
                        Button(action: {
                            viewModel.takePhotoManual()
                        }) {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .frame(width: 72, height: 72)
                                
                                Circle()
                                    .fill(Color.white)
                                    .frame(
                                        width: viewModel.isShutterPressing ? 52 : 60,
                                        height: viewModel.isShutterPressing ? 52 : 60
                                    )
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .scaleEffect(viewModel.isShutterPressing ? 0.92 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.isShutterPressing)
                    }
                    
                case .analyzing:
                    Button(action: {
                        viewModel.cancelAISession()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.yellow.opacity(0.18))
                                .frame(width: 80, height: 80)
                            
                            Circle()
                                .stroke(Color.yellow, lineWidth: 2.5)
                                .frame(width: 80, height: 80)
                            
                            VStack(spacing: 4) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                                Text("HỦY")
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                case .targetPlaced:
                    Button(action: {
                        viewModel.cancelAISession()
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.orange, lineWidth: 2)
                                .frame(width: 76, height: 76)
                            
                            VStack(spacing: 3) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.orange)
                                Text("HỦY AI")
                                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                case .alignmentPerfect:
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 76, height: 76)
                        
                        Image(systemName: "checkmark")
                            .font(.system(size: 26, weight: .black))
                            .foregroundColor(.black)
                    }
                    .scaleEffect(1.08)
                    
                case .capturing:
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 76, height: 76)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    }
                }
            }
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
                    viewModel.setZoom(zoom)
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
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
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
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 50, height: 50)
                
                Circle()
                    .stroke(viewModel.isAIFullColorEnabled ? Color.cyan : Color.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 50, height: 50)
                
                Image(systemName: "camera.filters")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(viewModel.isAIFullColorEnabled ? .cyan : .white)
            }
        }
    }
}

// MARK: - Film Preset Drawer
struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(FilmPreset.allCases) { preset in
                    let isSelected = viewModel.selectedFilmPreset == preset
                    Button(action: {
                        viewModel.selectPreset(preset)
                    }) {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.yellow.opacity(0.2) : Color.white.opacity(0.08))
                                    .frame(width: 54, height: 54)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(isSelected ? Color.yellow : Color.clear, lineWidth: 2)
                                    )
                                
                                Text(preset.shortTitle)
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(isSelected ? .yellow : .white)
                            }
                            
                            Text(preset.rawValue.components(separatedBy: " ").first ?? "")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(isSelected ? .yellow : .gray)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color.black.opacity(0.6))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}
