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
    @State private var gradingSuccessNote: String? = nil
    @State private var hasSavedToPhotos: Bool = false
    @State private var processedVideoURL: URL? = nil

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let player { VideoPlayer(player: player).frame(maxHeight: .infinity) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                if let note = gradingSuccessNote {
                    Text(note).font(.caption).foregroundColor(.secondary).padding(.horizontal)
                }
                VStack(spacing: 12) {
                    Button(action: applyAICinematicColor) {
                        HStack {
                            if isGradingWithAI { ProgressView() } else { Image(systemName: "wand.and.stars") }
                            Text(isGradingWithAI ? "Đang xử lý…" : "Áp dụng màu film & lưu bản mới")
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).disabled(isGradingWithAI)
                    HStack(spacing: 12) {
                        Button { saveVideoToPhotos() } label: {
                            Label(hasSavedToPhotos ? "Đã lưu" : "Lưu video", systemImage: hasSavedToPhotos ? "checkmark" : "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(isGradingWithAI || hasSavedToPhotos)
                        ShareLink(item: processedVideoURL ?? videoURL) {
                            Label("Chia sẻ", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).disabled(isGradingWithAI)
                    }
                }.font(.subheadline).padding(.horizontal, 16).padding(.bottom, 12)
            }
            .background(CameraUI.canvas).navigationTitle("Video vừa quay").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Xong") { presentationMode.wrappedValue.dismiss() } } }
            .onAppear { if player == nil { player = AVPlayer(url: videoURL) }; player?.play() }
            .onDisappear { player?.pause() }
        }.tint(CameraUI.accent).preferredColorScheme(.dark)
    }
    private func applyAICinematicColor() {
        isGradingWithAI = true
        let asset = AVAsset(url: videoURL)
        let filterPreset = viewModel.selectedFilmPreset
        let aiColorParameters = viewModel.currentAIColorParams

        let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.clampedToExtent()
            var output = source

            if let filtered = FilmFilterEngine.shared.applyPreset(to: output, preset: filterPreset) {
                output = filtered
            }

            if let aiParams = aiColorParameters,
               let aiFiltered = FilmFilterEngine.shared.applyAIColorParameters(to: output, params: aiParams) {
                output = aiFiltered
            }

            output = output.cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: nil)
        })

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("graded_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tempURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            self.isGradingWithAI = false
            return
        }

        exportSession.videoComposition = composition
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                self.isGradingWithAI = false
                if exportSession.status == .completed {
                    self.processedVideoURL = tempURL
                    self.gradingSuccessNote = "Đã áp dụng màu film điện ảnh (\(filterPreset.displayName))"
                    self.player = AVPlayer(url: tempURL)
                    self.player?.play()
                    self.saveVideoToPhotos(url: tempURL)
                } else {
                    CameraLogger.error("Xuất video chỉnh màu thất bại: \(String(describing: exportSession.error))", category: .photoKit)
                    self.saveVideoToPhotos(url: self.videoURL)
                }
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
                }
            }
        }
    }
}
