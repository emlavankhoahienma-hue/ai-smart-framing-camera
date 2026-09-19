import SwiftUI

// Presentation primitives shared by the camera and its sheets.
enum CameraUI {
    static let accent = Color(red: 1, green: 0.77, blue: 0.28)
    static let canvas = Color(red: 0.045, green: 0.05, blue: 0.06)
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

struct CameraGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { CameraUI.canvas }
            else { Rectangle().fill(.ultraThinMaterial) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
    }
}

struct CameraPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : CameraUI.spring, value: configuration.isPressed)
    }
}

struct CameraIconButton: View {
    let symbol: String
    let label: String
    var isActive = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundColor(isActive ? CameraUI.accent : .white)
                .frame(width: 44, height: 44)
                .background(isActive ? CameraUI.accent.opacity(0.14) : .white.opacity(0.07), in: Circle())
        }.buttonStyle(CameraPressStyle()).accessibilityLabel(label)
    }
}

struct CameraDrawerHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer(minLength: 8)
            CameraIconButton(symbol: "xmark", label: "Đóng \(title)", action: close)
        }
    }
}

public struct CameraControlsView: View {
    @ObservedObject var viewModel: CameraViewModel
    public var body: some View {
        VStack(spacing: 8) {
            LiveViewZoomSwitch(viewModel: viewModel)
            HStack {
                GalleryThumbnailButton(viewModel: viewModel).frame(maxWidth: .infinity)
                MainCaptureButton(viewModel: viewModel)
                CameraIconButton(symbol: "camera.filters", label: "Bộ lọc màu", isActive: viewModel.isShowingFilmDrawer) {
                    viewModel.isShowingFilmDrawer.toggle()
                    if viewModel.isShowingFilmDrawer { viewModel.isShowingProControlsDrawer = false }
                }.frame(maxWidth: .infinity)
            }.frame(height: 80)
            CameraModeSegmentedSwitcher(viewModel: viewModel)
        }.padding(.horizontal, 16).foregroundColor(.white)
    }
}

struct CameraModeSegmentedSwitcher: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 4) {
            ForEach(CameraCaptureMode.allCases) { mode in
                Button {
                    guard !viewModel.isRecordingVideo, viewModel.captureMode != mode else { return }
                    if viewModel.isAISessionActive { viewModel.cancelAISession() }
                    if viewModel.isAIVideoDirectorActive { viewModel.dismissAIVideoDirector() }
                    viewModel.captureMode = mode
                    viewModel.isShowingFilmDrawer = false
                    viewModel.isShowingProControlsDrawer = mode == .proVideo
                    viewModel.haptics.triggerSelectionChange()
                } label: {
                    Text(title(mode)).font(.subheadline.weight(.semibold))
                        .foregroundColor(viewModel.captureMode == mode ? CameraUI.accent : .white.opacity(0.65))
                        .frame(width: 76, height: 44)
                        .background {
                            if viewModel.captureMode == mode {
                                Capsule().fill(.white.opacity(0.09)).matchedGeometryEffect(id: "mode", in: selection)
                            }
                        }
                }.buttonStyle(CameraPressStyle())
                .accessibilityLabel("Chế độ \(title(mode))")
                .accessibilityAddTraits(viewModel.captureMode == mode ? .isSelected : [])
            }
        }
        .disabled(viewModel.isRecordingVideo || viewModel.aiSessionState == .capturing)
        .animation(reduceMotion ? nil : CameraUI.spring, value: viewModel.captureMode)
    }
    private func title(_ mode: CameraCaptureMode) -> String {
        switch mode { case .photo: return "Ảnh"; case .video: return "Video"; case .proVideo: return "Pro" }
    }
}

struct MainCaptureButton: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        Button {
            if viewModel.captureMode.isVideo { viewModel.toggleVideoRecording() }
            else { viewModel.takePhotoManual() }
        } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: viewModel.isRecordingVideo ? 8 : 34)
                    .fill(viewModel.captureMode.isVideo ? Color.red : .white)
                    .frame(width: viewModel.isRecordingVideo ? 32 : 64, height: viewModel.isRecordingVideo ? 32 : 64)
                if viewModel.aiSessionState == .capturing { ProgressView().tint(.black) }
            }.frame(width: 88, height: 80).contentShape(Rectangle())
        }.buttonStyle(CameraPressStyle())
        .disabled(!viewModel.isCameraReady || viewModel.aiSessionState == .capturing)
        .accessibilityLabel(viewModel.captureMode.isVideo ? (viewModel.isRecordingVideo ? "Dừng quay" : "Bắt đầu quay") : "Chụp ảnh")
    }
}

struct GalleryThumbnailButton: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        Button {
            if viewModel.captureMode.isVideo, viewModel.recordedVideoURL != nil { viewModel.isShowingVideoPreview = true }
            else if viewModel.latestCapturedPhoto != nil { viewModel.isShowingPhotoDetail = true }
            else if viewModel.recordedVideoURL != nil { viewModel.isShowingVideoPreview = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(.white.opacity(0.08))
                if viewModel.captureMode.isVideo, viewModel.recordedVideoURL != nil {
                    Image(systemName: "play.rectangle.fill").font(.title3)
                } else if let photo = viewModel.latestCapturedPhoto {
                    Image(decorative: photo.processedImage, scale: 1).resizable().scaledToFill()
                } else { Image(systemName: "photo.on.rectangle").font(.title3) }
            }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.25)))
        }.buttonStyle(CameraPressStyle())
        .disabled(viewModel.isRecordingVideo || (viewModel.latestCapturedPhoto == nil && viewModel.recordedVideoURL == nil))
        .accessibilityLabel("Xem ảnh hoặc video vừa chụp")
    }
}

struct FilmPresetDrawer: View {
    @ObservedObject var viewModel: CameraViewModel
    var body: some View {
        VStack(spacing: 0) {
            CameraDrawerHeader(title: "Màu film") { viewModel.isShowingFilmDrawer = false }.padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(FilmPreset.allCases) { preset in
                        Button { viewModel.selectPreset(preset) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.isAIFullAuto ? "wand.and.stars" : "camera.filters").frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.displayName).font(.subheadline.weight(.semibold))
                                    Text(preset.description).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 0)
                                if viewModel.selectedFilmPreset == preset { Image(systemName: "checkmark") }
                                else if viewModel.aiRecommendedPreset == preset { Image(systemName: "sparkles") }
                            }.padding(12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .foregroundColor(viewModel.selectedFilmPreset == preset ? CameraUI.accent : .white)
                            .background(viewModel.selectedFilmPreset == preset ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(CameraPressStyle())
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }.modifier(CameraGlass())
    }
}

public struct CustomAppIconView: View {
    let name: String
    let fallbackSF: String
    let size: CGFloat
    let color: Color
    public init(name: String, fallbackSF: String, size: CGFloat, color: Color = .white) {
        self.name = name; self.fallbackSF = fallbackSF; self.size = size; self.color = color
    }
    public var body: some View {
        Group {
            if let image = UIImage(named: name) { Image(uiImage: image).renderingMode(.template).resizable().scaledToFit() }
            else { Image(systemName: fallbackSF).resizable().scaledToFit() }
        }.frame(width: size, height: size).foregroundColor(color)
    }
}
