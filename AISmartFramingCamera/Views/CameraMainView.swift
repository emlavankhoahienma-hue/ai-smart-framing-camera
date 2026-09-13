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
                        .padding(.top, 6)

                    Spacer()

                    // Realtime Pro Color Histogram HUD (Chỉ hiển thị trong Pro Video hoặc khi bật trong Cài đặt)
                    if viewModel.captureMode == .proVideo || viewModel.showHistogramInViewfinder {
                        LiveColorHistogramHUDView(viewModel: viewModel)
                            .padding(.bottom, 6)
                            .transition(.opacity)
                    }

                    // Pro Video Manual Controls View (Only in VIDEO PRO mode)
                    if viewModel.captureMode == .proVideo {
                        ProVideoManualControlsView(viewModel: viewModel)
                            .padding(.bottom, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

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
        .sheet(isPresented: $viewModel.isCompositionRuleSheetPresented) {
            CompositionRuleSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingPhotoDetail) {
            if let latest = viewModel.latestCapturedPhoto {
                CapturedPhotoPreviewView(item: latest, viewModel: viewModel)
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

// MARK: - Quiet Pro Top Bar Component

struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        if viewModel.captureMode.isVideo {
            // VIDEO MODE TOP BAR: [Flash/Torch] — 00:00 · 1080P 30FPS — [Cài đặt ⚙️]
            HStack(spacing: 12) {
                Button(action: {
                    viewModel.toggleFlash()
                }) {
                    Image(systemName: flashIconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(viewModel.activeFlashMode == .off ? .white.opacity(0.85) : .yellow)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .accessibilityLabel("Bật tắt đèn flash")

                Spacer()

                // Video HUD: Thời gian quay & Độ phân giải/FPS
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.isRecordingVideo ? Color.red : Color.gray.opacity(0.8))
                            .frame(width: 7, height: 7)

                        Text(viewModel.videoRecordingTimeString)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())

                    Button(action: {
                        viewModel.toggleVideoFormat()
                    }) {
                        Text(viewModel.activeVideoResolutionString)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                    }
                    .disabled(viewModel.isRecordingVideo)
                    .accessibilityLabel("Đổi định dạng quay video")
                }

                Spacer()

                Button(action: {
                    viewModel.isShowingSettings = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .accessibilityLabel("Cài đặt")
            }
            .padding(.horizontal, 16)
        } else {
            // PHOTO MODE TOP BAR: [Flash] — [Bố cục thông minh · Tự động] — [Cài đặt ⚙️]
            HStack(spacing: 12) {
                Button(action: {
                    viewModel.toggleFlash()
                }) {
                    Image(systemName: flashIconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(viewModel.activeFlashMode == .off ? .white.opacity(0.85) : .yellow)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .accessibilityLabel("Chế độ đèn flash")

                Spacer()

                // Smart Framing Center Pill: Chạm để mở Sheet Bố cục thông minh
                Button(action: {
                    viewModel.isCompositionRuleSheetPresented = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.activeCompositionRule.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(viewModel.aiSessionState.isSessionActive ? .green : .yellow)

                        Text(viewModel.activeCompositionRule.displayNameVietnamese)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(viewModel.aiSessionState.isSessionActive ? Color.green.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
                    )
                }
                .accessibilityLabel("Bố cục thông minh, chọn quy tắc bố cục")

                Spacer()

                Button(action: {
                    viewModel.isShowingSettings = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .accessibilityLabel("Cài đặt")
            }
            .padding(.horizontal, 16)
        }
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

// MARK: - Composition Rule Quick Sheet (Bố cục thông minh)

struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chọn quy tắc bố cục để hệ thống tự động nhận diện chủ thể và đưa ra hướng dẫn căn góc tối ưu.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 4)

                        ruleListView

                        Divider().background(Color.gray.opacity(0.3)).padding(.vertical, 4)

                        // Tiện ích nhanh
                        Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)
                            .padding(.horizontal, 4)
                    }
                    .padding(16)
                }

                bottomActionBar
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.06).edgesIgnoringSafeArea(.all))
            .navigationBarTitle("Bố cục thông minh", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Xong") { presentationMode.wrappedValue.dismiss() }
                    .foregroundColor(.yellow)
            )
        }
    }

    private var ruleListView: some View {
        VStack(spacing: 8) {
            ForEach(CompositionRule.allCases) { rule in
                CompositionRuleRow(
                    rule: rule,
                    isSelected: viewModel.activeCompositionRule == rule,
                    onSelect: { viewModel.selectRule(rule) }
                )
            }
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.gray.opacity(0.25))

            if viewModel.aiSessionState.isSessionActive {
                Button(action: {
                    viewModel.cancelAISession()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Dừng căn bố cục")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.red.opacity(0.85)))
                }
                .padding(16)
            } else {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                    viewModel.startAISession()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder")
                        Text("Bắt đầu căn bố cục")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow))
                }
                .padding(16)
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }
}

// MARK: - Composition Rule Row

struct CompositionRuleRow: View {
    let rule: CompositionRule
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? Color.yellow : Color.white.opacity(0.8))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayNameVietnamese)
                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                        .foregroundColor(Color.white)
                    Text(rule.descriptionVietnamese)
                        .font(.system(size: 12))
                        .foregroundColor(Color.gray)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Color.yellow)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(backgroundShape)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isSelected ? Color.yellow.opacity(0.12) : Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.yellow.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Permission Placeholder (Friendly & Non-technical)

struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 54))
                .foregroundColor(.yellow)

            Text("Cho phép camera để bắt đầu")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("AlignAI Studio cần camera để hiển thị bản xem trước, lấy nét và hỗ trợ căn bố cục.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text("Mở Cài đặt")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.yellow)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}
