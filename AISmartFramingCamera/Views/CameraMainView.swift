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
                    
                    // Bottom Control Deck (Zoom, Shutter, Presets)
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
        .onAppear {
            viewModel.requestPermissionsAndStart()
        }
    }
}

// MARK: - Top Bar Component

struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    
    var body: some View {
        HStack(spacing: 16) {
            // Flash Mode Toggle
            Button(action: {
                viewModel.toggleFlash()
            }) {
                Image(systemName: flashIconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(viewModel.activeFlashMode == .off ? .white.opacity(0.8) : .yellow)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            // AI Framing Session Button (top bar shortcut)
            Button(action: {
                if viewModel.aiSessionState.isSessionActive {
                    viewModel.cancelAISession()
                } else {
                    viewModel.startAISession()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.aiSessionState.isSessionActive ? "stop.circle" : "wand.and.stars")
                        .font(.system(size: 15, weight: .bold))
                    
                    Text("AI")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                }
                .foregroundColor(viewModel.aiSessionState.isSessionActive ? .red : .white.opacity(0.75))
                .padding(.horizontal, 12)
                .frame(height: 42)
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
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            Spacer()
            
            // AR Spatial Mode Toggle
            Button(action: {
                viewModel.toggleARMode()
            }) {
                Image(systemName: viewModel.isARModeEnabled ? "arkit" : "viewfinder")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(viewModel.isARModeEnabled ? .cyan : .white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            
            // Settings Button
            Button(action: {
                viewModel.isShowingSettings = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
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
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.yellow)
            
            Text("Yêu cầu quyền truy cập Camera")
                .font(.title2.bold())
                .foregroundColor(.white)
            
            Text("Ứng dụng cần quyền Camera để phân tích bối cảnh thời gian thực bằng Neural Engine và hiển thị vòng tròn chỉ dẫn bố cục.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal, 32)
            
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Mở Cài đặt")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Color.yellow)
                    .cornerRadius(14)
            }
            .padding(.top, 10)
        }
    }
}
