import SwiftUI

public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()

    public init() {}

    public var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.026, blue: 0.03)
                .ignoresSafeArea()

            if viewModel.hasCameraPermission {
                VStack(spacing: 0) {
                    TopCameraBar(viewModel: viewModel)
                        .padding(.top, 2)

                    ZStack {
                        CameraPreviewView(viewModel: viewModel)
                        ARFramingOverlayView(viewModel: viewModel)
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    }
                    .overlay(alignment: .top) {
                        AIStatusHUDView(viewModel: viewModel)
                            .padding(.top, 10)
                    }
                    .overlay(alignment: .bottom) {
                        ZoomSelectorPills(viewModel: viewModel, options: [1.0, 2.0])
                            .offset(y: 18)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CameraControlsView(viewModel: viewModel)
                }
            } else {
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
            if viewModel.captureMode == .proVideo {
                viewModel.captureMode = .video
            }
            viewModel.requestPermissionsAndStart()
        }
    }
}

// MARK: - Quiet Pro Top Bar Component

struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        HStack(spacing: 10) {
            topBarButton(
                systemName: flashIconName,
                foregroundColor: viewModel.activeFlashMode == .off ? .white.opacity(0.88) : amberGold,
                accessibilityLabel: "Chế độ đèn flash",
                action: viewModel.toggleFlash
            )

            Spacer(minLength: 4)

            LiveColorHistogramHUDView(viewModel: viewModel)
                .frame(maxWidth: 230)
                .layoutPriority(1)

            Spacer(minLength: 4)

            topBarButton(
                systemName: "gearshape.fill",
                foregroundColor: .white.opacity(0.90),
                accessibilityLabel: "Cài đặt"
            ) {
                viewModel.isShowingSettings = true
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(Color.black.opacity(0.52))
    }

    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    private func topBarButton(
        systemName: String,
        foregroundColor: Color,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                        VStack(spacing: 10) {
                            Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(16)
                }

                bottomActionBar
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea())
            .navigationTitle("Bố cục thông minh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(.yellow)
                }
            }
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
                    dismiss()
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
                    dismiss()
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
                        .font(.system(size: 15, weight: .bold))
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
    }
}
