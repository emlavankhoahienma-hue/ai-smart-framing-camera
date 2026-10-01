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

    private func applyWindowedZoomCrop() {
        guard let windowFocal = viewModel.lastRecordedVideoWindowedFocal,
              let windowAspect = viewModel.lastRecordedVideoWindowedAspect,
              windowFocal > 24.5 else { return }

        isCroppingWindowedZoom = true
        let asset = AVAsset(url: processedVideoURL ?? videoURL)

        let fractions = windowAspect.windowFractions(focalLength: windowFocal)
        let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.clampedToExtent()
            let origExtent = request.sourceImage.extent
            let cropW = origExtent.width * fractions.widthFraction
            let cropH = origExtent.height * fractions.heightFraction
            let cropX = origExtent.origin.x + (origExtent.width - cropW) / 2.0
            let cropY = origExtent.origin.y + (origExtent.height - cropH) / 2.0
            let cropped = source.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
            request.finish(with: cropped, context: nil)
        })

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("cropped_\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: tempURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            self.isCroppingWindowedZoom = false
            return
        }

        exportSession.videoComposition = composition
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = true

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                self.isCroppingWindowedZoom = false
                if exportSession.status == .completed {
                    self.processedVideoURL = tempURL
                    self.gradingSuccessNote = "Đã cắt theo khung Windowed Zoom (\(Int(windowFocal))mm)"
                    self.player = AVPlayer(url: tempURL)
                    self.player?.play()
                    self.saveVideoToPhotos(url: tempURL)
                } else {
                    CameraLogger.error("Cắt video Windowed Zoom thất bại: \(String(describing: exportSession.error))", category: .photoKit)
                }
            }
        }
    }

    private func applyAICinematicColor() {
        isGradingWithAI = true
        let asset = AVAsset(url: processedVideoURL ?? videoURL)
        let filterPreset = viewModel.selectedFilmPreset
        let aiColorParameters = viewModel.currentAIColorParams
        let windowFocal = viewModel.lastRecordedVideoWindowedFocal
        let windowAspect = viewModel.lastRecordedVideoWindowedAspect

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

            if let wf = windowFocal, let wa = windowAspect, wf > 24.5 {
                let fractions = wa.windowFractions(focalLength: wf)
                if fractions.widthFraction < 0.999 && fractions.heightFraction < 0.999 {
                    let origExtent = request.sourceImage.extent
                    let cropW = origExtent.width * fractions.widthFraction
                    let cropH = origExtent.height * fractions.heightFraction
                    let cropX = origExtent.origin.x + (origExtent.width - cropW) / 2.0
                    let cropY = origExtent.origin.y + (origExtent.height - cropH) / 2.0
                    output = output.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
                }
            } else {
                output = output.cropped(to: request.sourceImage.extent)
            }

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
