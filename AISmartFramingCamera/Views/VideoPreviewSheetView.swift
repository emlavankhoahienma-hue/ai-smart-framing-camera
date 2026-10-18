import SwiftUI
import AVKit
import Photos
import CoreImage

public struct VideoPreviewSheetView: View {
    let videoURL: URL
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var player: AVPlayer?
    @State private var isGradingWithAI: Bool = false
    @State private var isCroppingWindowedZoom: Bool = false
    @State private var gradingSuccessNote: String? = nil
    @State private var hasSavedToPhotos: Bool = false
    @State private var processedVideoURL: URL? = nil
    @State private var hasAppliedColor = false
    @State private var processingError: String?
    @State private var renderTask: Task<Void, Never>?

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    public var body: some View {
        NavigationView {
            ZStack {
                darkBg.edgesIgnoringSafeArea(.all)

                VStack(spacing: 16) {
                    // 1. Video Player
                    if let player = player {
                        VideoPlayer(player: player)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)
                            .onAppear { player.play() }
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: champagne))
                            .frame(maxHeight: .infinity)
                    }

                    // 2. Status Note
                    if let note = gradingSuccessNote {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(champagne)
                            Text(note)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }

                    // 3. Optional Windowed Zoom Crop Banner
                    if let focal = viewModel.lastRecordedVideoWindowedFocal, focal > 24.5 {
                        Button(action: applyWindowedZoomCrop) {
                            HStack(spacing: 6) {
                                if isCroppingWindowedZoom {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isCroppingWindowedZoom ? "Đang xử lý…" : "Cắt Windowed Zoom (\(Int(focal))mm)")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isCroppingWindowedZoom || isGradingWithAI)
                        .padding(.horizontal, 16)
                    }

                    // 4. Action Buttons: [Chỉnh màu], [Lưu], [Chia sẻ]
                    HStack(spacing: 12) {
                        Button(action: applyAICinematicColor) {
                            HStack(spacing: 6) {
                                if isGradingWithAI {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isGradingWithAI ? "Đang xử lý…" : "Chỉnh màu")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isGradingWithAI || isCroppingWindowedZoom)

                        Button(action: { saveVideoToPhotos() }) {
                            HStack(spacing: 6) {
                                Image(systemName: hasSavedToPhotos ? "checkmark" : "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(hasSavedToPhotos ? "Đã lưu" : "Lưu")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(champagne)
                            .cornerRadius(10)
                        }
                        .disabled(isGradingWithAI || isCroppingWindowedZoom)

                        ShareLink(item: processedVideoURL ?? videoURL) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Chia sẻ")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
            .navigationBarTitle("Chi tiết video", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Đóng") {
                    player?.pause()
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(champagne)
            )
            .onAppear {
                player = AVPlayer(url: videoURL)
                if let focal = viewModel.lastRecordedVideoWindowedFocal, focal > 24.5 {
                    applyWindowedZoomCrop()
                }
            }
            .onDisappear {
                player?.pause()
                renderTask?.cancel()
            }
            .alert("Không thể xử lý video", isPresented: Binding(
                get: { processingError != nil }, set: { if !$0 { processingError = nil } })) {
                Button("Đóng", role: .cancel) { processingError = nil }
            } message: { Text(processingError ?? "") }
        }
    }

    private func applyWindowedZoomCrop() {
        renderOriginal(applyColor: hasAppliedColor)
    }

    private func applyAICinematicColor() {
        renderOriginal(applyColor: true)
    }

    private func renderOriginal(applyColor: Bool) {
        guard !isCroppingWindowedZoom, !isGradingWithAI else { return }
        isGradingWithAI = applyColor
        isCroppingWindowedZoom = !applyColor
        let asset = AVURLAsset(url: videoURL)
        let preset = viewModel.selectedFilmPreset
        let parameters = viewModel.currentAIColorParams
        let window: VideoFrameRenderer.Window?
        if let focal = viewModel.lastRecordedVideoWindowedFocal,
           let aspect = viewModel.lastRecordedVideoWindowedAspect, focal > 24.5 {
            window = VideoFrameRenderer.Window(focalLength: focal,
                baseZoom: viewModel.lastRecordedVideoWindowedBaseZoom,
                outputAspect: 1 / aspect.ratioHeightOverWidth,
                center: viewModel.lastRecordedVideoWindowedCenter)
        } else { window = nil }
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            defer { isGradingWithAI = false; isCroppingWindowedZoom = false; renderTask = nil }
            do {
                let composition = try await VideoFrameRenderer.composition(asset: asset, window: window) { image in
                    guard applyColor else { return image }
                    var result = FilmFilterEngine.shared.applyPreset(to: image, preset: preset) ?? image
                    if let parameters,
                       let colored = FilmFilterEngine.shared.applyAIColorParameters(to: result, params: parameters) {
                        result = colored
                    }
                    return result
                }
                try Task.checkCancellation()
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("rendered_\(UUID().uuidString).mov")
                try await VideoFrameRenderer.export(asset: asset, composition: composition, to: output)
                try Task.checkCancellation()
                player?.pause()
                processedVideoURL = output
                hasAppliedColor = applyColor
                hasSavedToPhotos = false
                gradingSuccessNote = applyColor ? "Đã áp dụng màu và khung chụp" : "Đã cắt đúng khung Windowed Zoom"
                player = AVPlayer(url: output)
                player?.play()
            } catch is CancellationError {
                CameraLogger.info("Video processing cancelled", category: .capture)
            } catch {
                processingError = error.localizedDescription
                CameraLogger.error("Video rendering failed", error: error, category: .capture)
            }
        }
    }

    private func saveVideoToPhotos(url: URL? = nil) {
        let targetURL = url ?? processedVideoURL ?? videoURL
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetURL)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.hasSavedToPhotos = true
                    self.viewModel.haptics.triggerSuccess()
                } else {
                    self.processingError = error?.localizedDescription ?? "Không lưu được video vào thư viện."
                    CameraLogger.error("Video save failed: \(String(describing: error))", category: .photoKit)
                }
            }
        }
    }
}
