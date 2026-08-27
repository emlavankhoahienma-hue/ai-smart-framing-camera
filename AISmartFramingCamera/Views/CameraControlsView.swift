import SwiftUI

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0, 5.0]
    
    public var body: some View {
        VStack(spacing: 0) {
            // Film Preset Drawer (Expandable)
            if viewModel.isShowingFilmDrawer {
                FilmPresetDrawer(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // Zoom Selector Pills
            ZoomSelectorPills(viewModel: viewModel, options: zoomOptions)
                .padding(.bottom, 10)
            
            // Main Bottom Control Deck
            HStack(alignment: .center) {
                // Left: Gallery Thumbnail
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)
                
                Spacer()
                
                // Center: Composite Button (AI or Manual Shutter)
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
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.85), Color.black]),
                startPoint: .top,
                endPoint: .bottom
            )
            .edgesIgnoringSafeArea(.bottom)
        )
    }
}

// MARK: - Main Capture Button (AI Session + Manual Shutter combined)
struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        VStack(spacing: 6) {
            switch viewModel.aiSessionState {
            case .idle:
                // Two buttons: AI session start + Manual shutter
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
                // Cancel button while analyzing
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
                                .scaleEffect(0.9)
                            
                            Text("Dừng")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.yellow)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
            case .targetPlaced:
                // Hướng dẫn: Di chuyển tâm trắng → tâm vàng
                VStack(spacing: 6) {
                    ZStack {
                        // Distance ring indicator
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 4)
                            .frame(width: 80, height: 80)
                        
                        let progress = max(0, 1.0 - viewModel.alignmentDistance / 0.35)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.1), value: viewModel.alignmentDistance)
                        
                        Button(action: {
                            viewModel.cancelAISession()
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: directionArrowIcon)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                
                                let pct = Int(max(0.0, min(1.0, 1.0 - viewModel.alignmentDistance / 0.35)) * 100)
                                Text("\(pct)%")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.yellow)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    Text("Di chuyển máy")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                
            case .alignmentPerfect:
                // Đang chuẩn bị chụp — hiển thị countdown
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 80, height: 80)
                    
                    Circle()
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: 80, height: 80)
                    
                    VStack(spacing: 2) {
                        if viewModel.autoCaptureCountdown > 0 {
                            Text("\(viewModel.autoCaptureCountdown)")
                                .font(.system(size: 28, weight: .black, design: .rounded))
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.green)
                        }
                    }
                }
                .scaleEffect(1.08)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: viewModel.autoCaptureCountdown)
                
            case .capturing:
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.2))
                        .frame(width: 80, height: 80)
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                        .scaleEffect(1.3)
                }
                
            case .done:
                // Bắt đầu phiên mới
                Button(action: {
                    viewModel.startAISession()
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.2))
                            .frame(width: 80, height: 80)
                        
                        Circle()
                            .stroke(Color.cyan, lineWidth: 2.5)
                            .frame(width: 80, height: 80)
                        
                        VStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.cyan)
                            
                            Text("Lại")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(.cyan)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: viewModel.aiSessionState)
    }
    
    private var directionArrowIcon: String {
        guard case .targetPlaced = viewModel.aiSessionState, let target = viewModel.pinnedTargetPoint else {
            return "scope"
        }
        let dx = target.x - viewModel.trackedSubjectPoint.x
        let dy = target.y - viewModel.trackedSubjectPoint.y
        let angle = atan2(dy, dx) * 180 / .pi
        let normalizedAngle = angle < 0 ? angle + 360 : angle
        switch normalizedAngle {
        case 315...360, 0..<45: return "arrow.right"
        case 45..<135: return "arrow.down"
        case 135..<225: return "arrow.left"
        case 225..<315: return "arrow.up"
        default: return "scope"
        }
    }
}

// MARK: - Other Subcomponents

struct ZoomSelectorPills: View {
    @ObservedObject var viewModel: CameraViewModel
    let options: [CGFloat]
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { zoom in
                Button(action: { viewModel.setZoom(zoom) }) {
                    Text(String(format: "%.0fx", zoom))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(abs(viewModel.currentZoom - zoom) < 0.3 ? .yellow : .white.opacity(0.8))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(abs(viewModel.currentZoom - zoom) < 0.3 ? Color.white.opacity(0.2) : Color.black.opacity(0.4)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}

struct GalleryThumbnailButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        Button(action: {
            if viewModel.latestCapturedPhoto != nil {
                viewModel.isShowingPhotoDetail = true
            }
        }) {
            ZStack {
                if let latest = viewModel.latestCapturedPhoto {
                    Image(decorative: latest.processedImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.8), lineWidth: 1.5))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20)).foregroundColor(.white.opacity(0.8)))
                }
            }
        }
    }
}

struct FilterToggleButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        VStack(spacing: 2) {
            // AI Full Color Toggle (top)
            Button(action: {
                viewModel.toggleAIFullColor()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "wand.and.stars.inverse")
                        .font(.system(size: 11, weight: .bold))
                    Text("AI✦")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(viewModel.isAIFullColorEnabled ? .black : .white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(viewModel.isAIFullColorEnabled ? Color.cyan : Color.white.opacity(0.2)))
            }
            
            // Manual filter drawer toggle
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    viewModel.isShowingFilmDrawer.toggle()
                }
            }) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(viewModel.isShowingFilmDrawer ? .yellow : .white.opacity(0.9))
                    .frame(width: 36, height: 36)
            }
        }
    }
}

struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FilmPreset.allCases) { preset in
                    Button(action: { viewModel.selectPreset(preset) }) {
                        VStack(spacing: 4) {
                            Text(preset.shortTitle)
                                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                                .foregroundColor(viewModel.selectedFilmPreset == preset ? .black : (preset.isAIFullAuto ? .cyan : .white))
                            
                            Text(preset == .aiFullAuto ? "AI Auto" : preset.rawValue.components(separatedBy: " ").prefix(2).joined(separator: " "))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(viewModel.selectedFilmPreset == preset ? .black.opacity(0.8) : .white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(viewModel.selectedFilmPreset == preset
                                      ? (preset.isAIFullAuto ? Color.cyan : Color.yellow)
                                      : Color.black.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(preset.isAIFullAuto ? Color.cyan.opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
