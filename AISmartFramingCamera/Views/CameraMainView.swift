import SwiftUI
import AVFoundation

// MARK: - Camera Main View (Dark Luxury Pro Cinema Edition)
public struct CameraMainView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var isBlinkingRed: Bool = false

    public init() {}

    private let canvasBackground = Color(red: 0.031, green: 0.035, blue: 0.043) // #08090B

    public var body: some View {
        ZStack {
            // 1. Deep Charcoal Canvas with Subtle Radial Depth
            canvasBackground
                .ignoresSafeArea()

            if viewModel.hasCameraPermission {
                VStack(spacing: 0) {
                    // 2. Floating Top Pro Toolbar
                    TopCameraBar(viewModel: viewModel)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    Spacer(minLength: 2)

                    // 3. Fixed 3:4 High-End Viewfinder (Live View)
                    ZStack {
                        CameraPreviewView(viewModel: viewModel)
                        ARFramingOverlayView(viewModel: viewModel)
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(red: 0.18, green: 0.19, blue: 0.23), lineWidth: 1.5)
                    }
                    .shadow(color: Color.black.opacity(0.60), radius: 12, y: 4)
                    // Top Viewfinder Overlays (Video Timer / Histogram HUD / AI Status)
                    .overlay(alignment: .top) {
                        VStack(spacing: 6) {
                            if viewModel.isRecordingVideo {
                                videoRecordingHUD
                                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                            }

                            if viewModel.showHistogramInViewfinder {
                                LiveColorHistogramHUDView(viewModel: viewModel)
                                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            }

                            AIStatusHUDView(viewModel: viewModel)
                        }
                        .padding(.top, 10)
                    }
                    // Bottom In-Viewfinder Pro Floating Controls
                    .overlay(alignment: .bottom) {
                        HStack(alignment: .bottom, spacing: 0) {
                            // Left: AI Compose Floating Trigger (Ai)
                            AIViewfinderButton(viewModel: viewModel)

                            Spacer(minLength: 8)

                            // Center: Optical Zoom Selector Pill (0,5x / 2)
                            ViewfinderZoomSelectorPill(viewModel: viewModel)

                            Spacer(minLength: 8)

                            // Right: Pro Exposure & Framing Tool Stack
                            VStack(spacing: 8) {
                                ViewfinderSunExposureButton(viewModel: viewModel)
                                ViewfinderFramingButton(viewModel: viewModel)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                    .padding(.horizontal, 6)

                    Spacer(minLength: 4)

                    // 4. Bottom Control Deck (Mechanical Shutter + Album + Camera Flip + Mode Switcher)
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
        .onChange(of: viewModel.isRecordingVideo) { isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isBlinkingRed = true
                }
            } else {
                isBlinkingRed = false
            }
        }
    }

    // MARK: - Video Recording Timer Badge
    private var videoRecordingHUD: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isBlinkingRed ? 1.0 : 0.25)

            Text(viewModel.videoRecordingTimeString)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .stroke(Color.red.opacity(0.35), lineWidth: 1.0)
                )
        )
    }
}

// MARK: - Top Camera Bar (Amber Diamond Film Preset + Top Tools Capsule)
struct TopCameraBar: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        HStack(alignment: .center) {
            // Left: Amber Diamond Film Preset Button
            Button(action: {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                generator.impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                    viewModel.isShowingFilmDrawer.toggle()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(amberGold.opacity(viewModel.isShowingFilmDrawer ? 0.90 : 0.40), lineWidth: 1.2)
                        )
                        .shadow(color: viewModel.isShowingFilmDrawer ? amberGold.opacity(0.35) : Color.clear, radius: 6)

                    Image(systemName: "diamond.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(amberGold)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel("Mở bộ màu film điện ảnh")

            Spacer()

            // Right: Pro Tools Capsule (Flash, Format Badge, Composition, Settings)
            HStack(spacing: 2) {
                // 1. Flash Toggle Button
                Button(action: {
                    viewModel.toggleFlash()
                }) {
                    Image(systemName: flashIconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(viewModel.activeFlashMode == .off ? Color.white.opacity(0.72) : amberGold)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Chế độ đèn flash")

                // 2. Format / Resolution Badge Button (12 MP / 4K)
                Button(action: {
                    if viewModel.captureMode.isVideo {
                        viewModel.toggleVideoFormat()
                    } else {
                        viewModel.togglePhotoFormat()
                    }
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.40), lineWidth: 1.0)
                            .frame(width: 40, height: 22)

                        Text(formatBadgeTitle)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.92))
                    }
                    .frame(width: 44, height: 42)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Định dạng: \(formatBadgeTitle)")

                // 3. Composition Rule Quick Viewfinder Sheet
                Button(action: {
                    viewModel.isCompositionRuleSheetPresented = true
                }) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(viewModel.activeCompositionRule != .none ? amberGold : Color.white.opacity(0.72))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Quy tắc bố cục camera")

                // 4. Settings Sheet Button (9-Dot Grid Icon matching Reference)
                Button(action: {
                    viewModel.isShowingSettings = true
                }) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Cài đặt hệ thống")
            }
            .padding(.horizontal, 4)
            .frame(height: 44)
            .background(
                Capsule()
                    .fill(Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.94))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1.0)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 8, y: 2)
            )
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

    private var formatBadgeTitle: String {
        if viewModel.captureMode.isVideo {
            if viewModel.activeVideoResolutionString.contains("4K") {
                return "4K"
            } else {
                return "HD"
            }
        } else {
            if viewModel.selectedPhotoFormat == .dng {
                return "RAW"
            } else {
                return "12 MP"
            }
        }
    }
}

// MARK: - In-Viewfinder Controls (Bottom Deck)

// 1. AI Compose Button (Ai)
struct AIViewfinderButton: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.prepare()
            haptic.impactOccurred()

            if viewModel.aiSessionState.isSessionActive {
                viewModel.cancelAISession()
            } else {
                viewModel.startAISession()
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(aiBorderColor, lineWidth: 1.4)
                    )
                    .shadow(color: aiShadowColor, radius: 6)

                if case .capturing = viewModel.aiSessionState {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.85)
                } else {
                    HStack(spacing: 1.5) {
                        Text("(")
                            .font(.system(size: 14, weight: .light, design: .rounded))
                        Text("Ai")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Text(")")
                            .font(.system(size: 14, weight: .light, design: .rounded))
                    }
                    .foregroundColor(aiTextColor)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Nút căn bố cục AI")
    }

    private var aiBorderColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return Color.white.opacity(0.35)
        case .analyzing, .targetPlaced:
            return amberGold
        case .alignmentPerfect:
            return Color.green
        case .capturing:
            return Color.white
        }
    }

    private var aiTextColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return Color.white.opacity(0.90)
        case .analyzing, .targetPlaced:
            return amberGold
        case .alignmentPerfect:
            return Color.green
        case .capturing:
            return Color.white
        }
    }

    private var aiShadowColor: Color {
        switch viewModel.aiSessionState {
        case .idle, .done:
            return Color.clear
        case .analyzing, .targetPlaced:
            return amberGold.opacity(0.45)
        case .alignmentPerfect:
            return Color.green.opacity(0.50)
        case .capturing:
            return Color.white.opacity(0.35)
        }
    }
}

// 2. Optical Zoom Selector Pill (0,5x / 2)
struct ViewfinderZoomSelectorPill: View {
    @ObservedObject var viewModel: CameraViewModel
    @Namespace private var zoomPillNamespace
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    private var displayedZoomOptions: [CGFloat] {
        let options = viewModel.availableDisplayZoomOptions
        return options.isEmpty ? [1.0, 2.0] : options
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Decimal Pinch Zoom Float Indicator
            if viewModel.isPinchingZoom && !displayedZoomOptions.contains(where: { abs(viewModel.displayZoom - $0) < 0.08 }) {
                Text(String(format: "%.1fx", viewModel.displayZoom).replacingOccurrences(of: ".", with: ","))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(amberGold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.85))
                            .overlay(Capsule().stroke(amberGold.opacity(0.40), lineWidth: 1.0))
                    )
                    .offset(y: -30)
                    .transition(.opacity.combined(with: .scale(scale: 0.90)))
            }

            // Pill of Options
            HStack(spacing: 2) {
                ForEach(displayedZoomOptions, id: \.self) { zoom in
                    let isSelected = abs(viewModel.displayZoom - zoom) < 0.14
                    Button(action: {
                        let generator = UISelectionFeedbackGenerator()
                        generator.prepare()
                        generator.selectionChanged()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                            viewModel.setZoomFromButton(zoom)
                        }
                    }) {
                        Text(zoomFormattedText(zoom))
                            .font(.system(size: 13, weight: isSelected ? .bold : .semibold, design: .rounded))
                            .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.85))
                            .frame(minWidth: 36, height: 32)
                            .padding(.horizontal, 4)
                            .background(
                                ZStack {
                                    if isSelected {
                                        Circle()
                                            .fill(Color(red: 0.12, green: 0.13, blue: 0.16))
                                            .matchedGeometryEffect(id: "active_viewfinder_zoom", in: zoomPillNamespace)
                                            .overlay(
                                                Circle()
                                                    .stroke(amberGold.opacity(0.35), lineWidth: 1.0)
                                            )
                                    }
                                }
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.48))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1.0)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
            )
        }
    }

    private func zoomFormattedText(_ val: CGFloat) -> String {
        if val < 1.0 {
            return String(format: "%.1fx", val).replacingOccurrences(of: ".", with: ",")
        } else if val == floor(val) {
            return String(format: "%.0f", val)
        } else {
            return String(format: "%.1f", val).replacingOccurrences(of: ".", with: ",")
        }
    }
}

// 3. Sun Exposure & Metering Button
struct ViewfinderSunExposureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                viewModel.isShowingSunSlider.toggle()
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Circle()
                            .stroke(viewModel.isShowingSunSlider ? amberGold : Color.white.opacity(0.24), lineWidth: 1.0)
                    )

                Image(systemName: "thermometer.sun.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(viewModel.isShowingSunSlider ? amberGold : Color.white.opacity(0.85))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Điều chỉnh phơi sáng & nhiệt độ")
    }
}

// 4. Viewfinder Framing / Composition Button (Square Dashed Icon ⛶)
struct ViewfinderFramingButton: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        Button(action: {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            viewModel.isCompositionRuleSheetPresented = true
        }) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 1.0)
                    )

                Image(systemName: "square.dashed")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.90))
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Chọn quy tắc bố cục thông minh")
    }
}

// MARK: - Composition Rule Quick Sheet
struct CompositionRuleSheet: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Chọn quy tắc bố cục để hệ thống tự động nhận diện chủ thể và đưa ra hướng dẫn căn góc tối ưu.")
                            .font(.system(size: 13))
                            .foregroundColor(Color.gray)
                            .padding(.horizontal, 4)

                        ruleListView

                        Divider().background(Color.gray.opacity(0.3)).padding(.vertical, 4)

                        VStack(spacing: 10) {
                            Toggle("Live Photo", isOn: $viewModel.isLivePhotoEnabled)
                                .tint(amberGold)
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
                        .foregroundColor(amberGold)
                        .font(.system(size: 16, weight: .bold))
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
                    .background(RoundedRectangle(cornerRadius: 14).fill(amberGold))
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
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: rule.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isSelected ? amberGold : Color.white.opacity(0.8))
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
                        .foregroundColor(amberGold)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? amberGold.opacity(0.12) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? amberGold.opacity(0.50) : Color.white.opacity(0.08), lineWidth: 1.0)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Camera Permission Placeholder View
struct CameraPermissionPlaceholderView: View {
    @ObservedObject var viewModel: CameraViewModel
    private let amberGold = Color(red: 1.0, green: 0.69, blue: 0.16)

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 54))
                .foregroundColor(amberGold)

            Text("Cho phép camera để bắt đầu")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("AlignAI Camera cần quyền truy cập camera để hiển thị khung ngắm thời gian thực và hỗ trợ căn bố cục chuẩn xác.")
                .font(.subheadline)
                .foregroundColor(Color.gray)
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
                    .background(amberGold)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
    }
}
