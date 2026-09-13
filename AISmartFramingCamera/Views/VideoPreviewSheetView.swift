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

                    // 3. Action Buttons: [Chỉnh màu], [Lưu], [Chia sẻ]
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
                        .disabled(isGradingWithAI)

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
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func applyAICinematicColor() {
        isGradingWithAI = true
        let asset = AVAsset(url: videoURL)
        let filterPreset = viewModel.selectedFilmPreset

        let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.clampedToExtent()
            var output = source

            if let filtered = FilmFilterEngine.shared.applyPreset(to: output, preset: filterPreset) {
                output = filtered
            }

            if let aiParams = viewModel.currentAIColorParams,
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
