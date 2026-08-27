import SwiftUI
import AVFoundation

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    let zoomOptions: [CGFloat] = [1.0, 2.0, 3.0, 5.0]
    
    public var body: some View {
        VStack(spacing: 16) {
            // 1. Film Preset Drawer (Expandable)
            if viewModel.isShowingFilmDrawer {
                FilmPresetDrawer(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // 2. Zoom Level Selector Pills
            ZoomSelectorPills(viewModel: viewModel, options: zoomOptions)
            
            // 3. Bottom Main Control Deck (Gallery, Shutter, Filter Switch)
            HStack(alignment: .center) {
                // Left: Photo Gallery Thumbnail
                GalleryThumbnailButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)
                
                Spacer()
                
                // Center: Pro Shutter Button
                ShutterButton(viewModel: viewModel)
                
                Spacer()
                
                // Right: Film Drawer Toggle & Auto Color
                FilterToggleButton(viewModel: viewModel)
                    .frame(width: 60, height: 60)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
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

// MARK: - Subcomponents

struct ZoomSelectorPills: View {
    @ObservedObject var viewModel: CameraViewModel
    let options: [CGFloat]
    
    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.self) { zoom in
                Button(action: {
                    viewModel.setZoom(zoom)
                }) {
                    Text(String(format: "%.0fx", zoom))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(abs(viewModel.currentZoom - zoom) < 0.2 ? .yellow : .white.opacity(0.8))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(abs(viewModel.currentZoom - zoom) < 0.2 ? Color.white.opacity(0.2) : Color.black.opacity(0.4))
                        )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}

struct ShutterButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        Button(action: {
            viewModel.takePhoto()
        }) {
            ZStack {
                // Outer Ring
                Circle()
                    .stroke(Color.white, lineWidth: 3.5)
                    .frame(width: 76, height: 76)
                
                // Inner Capture Core
                Circle()
                    .fill(Color.white)
                    .frame(
                        width: viewModel.isShutterPressing ? 56 : 64,
                        height: viewModel.isShutterPressing ? 56 : 64
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 6)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(viewModel.isShutterPressing ? 0.92 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: viewModel.isShutterPressing)
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 50, height: 50)
                        .overlay(
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.8))
                        )
                }
            }
        }
    }
}

struct FilterToggleButton: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                viewModel.isShowingFilmDrawer.toggle()
            }
        }) {
            VStack(spacing: 3) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(viewModel.isShowingFilmDrawer ? .yellow : .white)
                
                Text(viewModel.selectedFilmPreset.shortTitle)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(width: 50, height: 50)
            .background(Circle().fill(Color.white.opacity(0.15)))
        }
    }
}

struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(FilmPreset.allCases) { preset in
                    Button(action: {
                        viewModel.selectPreset(preset)
                    }) {
                        VStack(spacing: 6) {
                            Text(preset.shortTitle)
                                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                .foregroundColor(viewModel.selectedFilmPreset == preset ? .black : .white)
                            
                            Text(preset.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(viewModel.selectedFilmPreset == preset ? .black.opacity(0.8) : .white.opacity(0.7))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(viewModel.selectedFilmPreset == preset ? Color.yellow : Color.black.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
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
