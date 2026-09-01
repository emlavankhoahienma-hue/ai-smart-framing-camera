import SwiftUI

public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if viewModel.hasCameraPermission {
                // 1. Live Camera Feed Layer
                CameraPreviewView(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all)
                
                // 2. AI Framing Overlay (Grids, Target Circle, Guidance Ray)
                ARFramingOverlayView(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all)
                
                // 3. UI Chrome (Top Bar, HUD, Bottom Controls)
                VStack(spacing: 0) {
                    // Top Bar Controls
                    TopCameraBar(viewModel: viewModel)
                        .padding(.top, 8)
                    
                    // Floating AI Dynamic HUD Pill
                    AIStatusHUDView(viewModel: viewModel)
                        .padding(.top, 8)
                    
                    Spacer()
                    
                    // Realtime Pro Color Histogram HUD (Biểu đồ Histogram màu, JPEG/DNG, Shutter, ISO)
                    LiveColorHistogramHUDView(viewModel: viewModel)
                        .padding(.bottom, 6)
                    
                    // Bottom Control Deck (Zoom, Mode, Shutter, Presets)
                    CameraControlsView(viewModel: viewModel)
                }
            } else {
                // Permission Request Screen
                CameraPermissionPlaceholderView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingPhotoDetail) {
            if let latest = viewModel.latestCapturedPhoto {
                CapturedPhotoPreviewView(item: latest)
            }
        }
        .sheet(isPresented: $viewModel.isShowingVideoPreview) {
            if let videoURL = viewModel.recordedVideoURL {
                VideoPreviewSheetView(videoURL: videoURL, viewModel: viewModel)
            }
        }
        .onAppear {
            viewModel.requestPermissionsAndStart()
        }
    }
}

// MARK: - Top Bar Component

struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        HStack(spacing: 14) {
            // Flash Mode Toggle
            Button(action: {
                viewModel.toggleFlash()
            }) {
                Image(systemName: flashIconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(viewModel.activeFlashMode == .off ? .white.opacity(0.8) : .yellow)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            // Live Photo Toggle (Bật / Tắt Live Photo như Camera gốc của iOS)
            Button(action: {
                viewModel.toggleLivePhoto()
            }) {
                Image(systemName: viewModel.isLivePhotoEnabled ? "livephoto" : "livephoto.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(viewModel.isLivePhotoEnabled ? .yellow : .white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            // AI Framing Session Button (Top bar shortcut)
            Button(action: {
                if viewModel.aiSessionState.isSessionActive {
                    viewModel.cancelAISession()
                } else {
                    viewModel.startAISession()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.aiSessionState.isSessionActive ? "stop.circle" : "wand.and.stars")
                        .font(.system(size: 14, weight: .bold))
                    
                    Text("AI")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundColor(viewModel.aiSessionState.isSessionActive ? .red : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }
            
            // Rule Selector Menu
            Menu {
                ForEach(CompositionRule.allCases) { rule in
                    Button(action: {
                        viewModel.selectRule(rule)
                    }) {
                        HStack {
                            Image(systemName: rule.iconName)
                            Text(rule.displayNameVietnamese)
                            if viewModel.activeCompositionRule == rule {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: viewModel.activeCompositionRule.iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            Spacer()
            
            // AR Spatial Mode Toggle
            Button(action: {
                viewModel.toggleARMode()
            }) {
                Image(systemName: viewModel.isARModeEnabled ? "arkit" : "viewfinder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(viewModel.isARModeEnabled ? .cyan : .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            // Settings Button
            Button(action: {
                viewModel.isShowingSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
        }
        .padding(.horizontal, 16)
    }
    
    private var flashIconName: String {
        switch viewModel.activeFlashMode {
        case .auto: return "bolt.badge.automatic.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        @unknown default: return "bolt.fill"
        }
    }
}

// MARK: - Permission Placeholder

struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.trianglebadge.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(.yellow)
            
            Text("AlignAI Studio cần quyền Camera")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("Để phân tích bố cục thời gian thực, AI cần quyền truy cập cảm biến camera.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Mở Cài đặt hệ thống")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.yellow)
                    .cornerRadius(12)
            }
        }
    }
}
