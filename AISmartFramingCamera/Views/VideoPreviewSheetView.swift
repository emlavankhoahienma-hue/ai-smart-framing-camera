import SwiftUI
import AVKit
import Photos
import CoreImage

public struct VideoPreviewSheetView: View {
    let videoURL: URL
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var currentPlaybackURL: URL
    @State private var gradedVideoURL: URL? = nil
    @State private var player: AVPlayer?
    @State private var isGradingWithAI: Bool = false
    @State private var gradingSuccessNote: String? = nil
    @State private var hasSavedToPhotos: Bool = false

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    public init(videoURL: URL, viewModel: CameraViewModel) {
        self.videoURL = videoURL
        self.viewModel = viewModel
        self._currentPlaybackURL = State(initialValue: videoURL)
    }

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
                                Text(isGradingWithAI ? "Đang xuất video…" : (gradedVideoURL != nil ? "Đã chỉnh màu" : "Chỉnh màu"))
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isGradingWithAI)

                        Button(action: saveVideoToPhotos) {
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

                        ShareLink(item: currentPlaybackURL) {
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
                if player == nil {
                    player = AVPlayer(url: currentPlaybackURL)
                }
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func applyAICinematicColor() {
        guard !isGradingWithAI else { return }
        isGradingWithAI = true
        hasSavedToPhotos = false

        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let sampleTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImage = try? imageGenerator.copyCGImage(at: sampleTime, actualTime: nil) {
            GeminiService.shared.analyzeForComposition(image: cgImage) { result in
                let colorParams: AIColorParameters
                switch result {
                case .success(let resp):
                    colorParams = resp.colorRecipe.asAIColorParameters
                case .failure:
                    colorParams = self.viewModel.currentAIColorParams ?? self.viewModel.detectedScene.aiFullColorParameters
                }
                self.renderGradedVideo(asset: asset, colorParams: colorParams)
            }
        } else {
            let fallbackParams = self.viewModel.currentAIColorParams ?? self.viewModel.detectedScene.aiFullColorParameters
            self.renderGradedVideo(asset: asset, colorParams: fallbackParams)
        }
    }

    private func renderGradedVideo(asset: AVAsset, colorParams: AIColorParameters) {
        let composition = AVVideoComposition(asset: asset) { request in
            let sourceImage = request.sourceImage.clampedToExtent()
            let outputImage = FilmFilterEngine.shared.applyAIColorParameters(to: sourceImage, params: colorParams) ?? sourceImage
            request.finish(with: outputImage.cropped(to: request.sourceImage.extent), context: nil)
        }

        let tempOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("graded_video_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tempOutputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            DispatchQueue.main.async {
                self.isGradingWithAI = false
                self.gradingSuccessNote = "Không thể khởi tạo bộ xuất video"
            }
            return
        }

        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = composition

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                self.isGradingWithAI = false
                if exportSession.status == .completed {
                    self.gradedVideoURL = tempOutputURL
                    self.currentPlaybackURL = tempOutputURL
                    self.player?.pause()
                    self.player = AVPlayer(url: tempOutputURL)
                    self.player?.play()
                    self.gradingSuccessNote = "Đã tối ưu & render màu AI Cinematic"
                    self.viewModel.haptics.triggerSuccess()
                } else {
                    let errMsg = exportSession.error?.localizedDescription ?? "Không xác định"
                    self.gradingSuccessNote = "Lỗi render video: \(errMsg)"
                    CameraLogger.error("Lỗi xuất video màu film: \(errMsg)", error: exportSession.error, category: .capture)
                }
            }
        }
    }

    private func saveVideoToPhotos() {
        let targetURL = gradedVideoURL ?? videoURL
        let originalURL = (self.viewModel.isSaveOriginalPhotoEnabled && self.gradedVideoURL != nil) ? self.videoURL : nil

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetURL)
            if let orig = originalURL {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: orig)
            }
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    self.hasSavedToPhotos = true
                    self.viewModel.haptics.triggerSuccess()
                    self.gradingSuccessNote = "Đã lưu video vào Cuộn Camera thành công"
                } else {
                    CameraLogger.error("Lỗi lưu video vào Photos: \(error?.localizedDescription ?? "")", error: error, category: .photoKit)
                }
            }
        }
    }
}
