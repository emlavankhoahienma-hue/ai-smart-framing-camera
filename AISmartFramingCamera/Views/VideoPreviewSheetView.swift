import SwiftUI
import AVKit
import Photos
import CoreImage

public struct VideoPreviewSheetView: View {
    let videoURL: URL
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var player: AVPlayer?
    @State private var isProcessingVideo: Bool = false
    @State private var gradingSuccessNote: String? = nil
    @State private var hasSavedToPhotos: Bool = false
    @State private var processedVideoURL: URL? = nil
    @State private var isWindowedZoomAlreadyCropped: Bool = false

    private let champagne = Color(red: 0.92, green: 0.82, blue: 0.65)
    private let darkBg = Color(red: 11/255, green: 11/255, blue: 12/255)

    private var hasWindowedParams: Bool {
        if let focal = viewModel.lastRecordedVideoWindowedFocal {
            return focal > 24.1 ||
                (viewModel.lastRecordedVideoWindowedAspect != nil && viewModel.lastRecordedVideoWindowedAspect != .ratio16_9) ||
                viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })
        }
        return false
    }

    public var body: some View {
        NavigationView {
            ZStack {
                darkBg.edgesIgnoringSafeArea(.all)

                VStack(spacing: 14) {
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

                    // 3. Khung Thông Tin Điện Ảnh (Video Cinema Info Frame Selector)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("KHUNG THÔNG TIN EXIF:")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.horizontal, 18)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(VideoInfoFrameStyle.allCases) { style in
                                    Button(action: {
                                        viewModel.videoInfoFrameStyle = style
                                        viewModel.haptics.triggerSelectionChange()
                                        processVideoExport(applyColorGrading: false, applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: style.icon)
                                                .font(.system(size: 11))
                                            Text(style.rawValue)
                                                .font(.system(size: 11, weight: viewModel.videoInfoFrameStyle == style ? .bold : .medium))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(viewModel.videoInfoFrameStyle == style ? AlignTheme.electricCyan.opacity(0.22) : Color.white.opacity(0.06))
                                        .foregroundColor(viewModel.videoInfoFrameStyle == style ? AlignTheme.electricCyan : Color.white.opacity(0.80))
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(viewModel.videoInfoFrameStyle == style ? AlignTheme.electricCyan.opacity(0.6) : Color.clear, lineWidth: 1)
                                        )
                                    }
                                    .disabled(isProcessingVideo)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // 4. Optional Windowed Zoom Crop Banner
                    if hasWindowedParams && !isWindowedZoomAlreadyCropped {
                        let focal = viewModel.lastRecordedVideoWindowedFocal ?? 24.0
                        Button(action: {
                            applyWindowedZoomCrop()
                        }) {
                            HStack(spacing: 6) {
                                if isProcessingVideo {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "viewfinder")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isProcessingVideo ? "Đang xử lý…" : "Cắt Windowed Zoom (\(Int(focal))mm)")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isProcessingVideo)
                        .padding(.horizontal, 16)
                    }

                    // 5. Action Buttons: [Chỉnh màu], [Lưu], [Chia sẻ]
                    HStack(spacing: 12) {
                        Button(action: {
                            processVideoExport(applyColorGrading: true, applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped)
                        }) {
                            HStack(spacing: 6) {
                                if isProcessingVideo {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text(isProcessingVideo ? "Đang xử lý…" : "Chỉnh màu")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(10)
                        }
                        .disabled(isProcessingVideo)

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
                if hasWindowedParams {
                    applyWindowedZoomCrop()
                }
            }
            .onDisappear {
                player?.pause()
            }
        }
    }

    private func applyWindowedZoomCrop() {
        guard !isWindowedZoomAlreadyCropped,
              let windowFocal = viewModel.lastRecordedVideoWindowedFocal,
              let windowAspect = viewModel.lastRecordedVideoWindowedAspect,
              (windowFocal > 24.1 || windowAspect != .ratio16_9 || viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })) else { return }
        let shouldApplyWindowedCrop = !self.isWindowedZoomAlreadyCropped
        processVideoExport(applyColorGrading: false, applyWindowCrop: shouldApplyWindowedCrop)
    }

    // MARK: - Core Video Rendering Pipeline (Windowed Zoom Crop + Info Frame + Film LUT)
    private func processVideoExport(applyColorGrading: Bool, applyWindowCrop: Bool) {
        guard !isProcessingVideo else { return }
        isProcessingVideo = true

        let asset = AVAsset(url: processedVideoURL ?? videoURL)
        let filterPreset = viewModel.selectedFilmPreset
        let aiColorParameters = viewModel.currentAIColorParams
        let windowAspect = viewModel.lastRecordedVideoWindowedAspect ?? viewModel.windowedZoomAspectRatio
        let infoStyle = viewModel.videoInfoFrameStyle
        let deviceName = viewModel.masterWatermarkDeviceName.isEmpty ? "ALIGN STUDIO" : viewModel.masterWatermarkDeviceName
        let recordedKeyframes = viewModel.recordedVideoWindowedKeyframes
        let fallbackKeyframe = WindowedZoomKeyframe(
            timestamp: 0,
            focalLength: viewModel.lastRecordedVideoWindowedFocal ?? viewModel.windowedZoomFocalLength,
            normalizedCenter: viewModel.lastRecordedVideoWindowedCenter,
            baseOpticalZoom: viewModel.lastRecordedVideoWindowedBaseZoom,
            aspectRatio: viewModel.lastRecordedVideoWindowedAspect ?? viewModel.windowedZoomAspectRatio
        )
        let proControls = ProVideoManualControlsService.shared
        let liveAperture = String(format: "f/%.1f", proControls.hardwareLensAperture > 0 ? proControls.hardwareLensAperture : 1.8)
        let activeShutterReciprocal = max(1, Int(round(proControls.isAutoShutter ? proControls.measuredLiveShutterSpeed : proControls.currentShutterSpeed)))
        let liveShutterText = "1/\(activeShutterReciprocal)s"
        let liveISOValue = max(25, Int(round(proControls.isAutoISO ? proControls.measuredLiveISO : proControls.currentISO)))
        let fallbackFPS = max(1, Int(round(viewModel.selectedVideoFormatOption.fps)))

        // Đọc track video để xác định độ phân giải gốc
        Task {
            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
                await MainActor.run {
                    self.isProcessingVideo = false
                }
                return
            }

            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? CGSize(width: 1080, height: 1920)
            let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            let exportFPS: Int = nominalFPS > 0 ? max(1, Int(round(Double(nominalFPS)))) : fallbackFPS

            // Kích thước hiển thị thực tế sau transform
            let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let effectiveSourceSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))

            // Tính toán kích thước Render chuẩn theo Aspect Ratio (không méo hình)
            let targetRenderSize: CGSize
            if applyWindowCrop {
                targetRenderSize = Self.computeTargetRenderSize(sourceSize: effectiveSourceSize, aspect: windowAspect)
            } else {
                targetRenderSize = CGSize(
                    width: CGFloat(Int(effectiveSourceSize.width) & ~1),
                    height: CGFloat(Int(effectiveSourceSize.height) & ~1)
                )
            }

            let composition = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
                let source = request.sourceImage.clampedToExtent()
                let origExtent = request.sourceImage.extent
                let frameTime = request.compositionTime.seconds

                var outputImage: CIImage

                // 1. Cắt Windowed Zoom mượt mà theo Hermite Keyframes
                if applyWindowCrop {
                    let state = CameraViewModel.interpolateKeyframe(
                        at: frameTime,
                        keyframes: recordedKeyframes,
                        fallback: fallbackKeyframe
                    )
                    let fractions = state.aspectRatio.windowFractions(
                        focalLength: state.focalLength,
                        baseOpticalZoom: state.baseOpticalZoom,
                        containerAspect: origExtent.width / origExtent.height
                    )

                    let cropW = origExtent.width * fractions.widthFraction
                    let cropH = origExtent.height * fractions.heightFraction
                    let normCenter = state.normalizedCenter

                    // Trục Y của CoreImage bắt đầu từ cạnh dưới
                    let ciCenterX = origExtent.origin.x + origExtent.width * normCenter.x
                    let ciCenterY = origExtent.origin.y + origExtent.height * (1.0 - normCenter.y)

                    let minCIX = origExtent.origin.x + cropW / 2.0
                    let maxCIX = origExtent.origin.x + origExtent.width - cropW / 2.0
                    let minCIY = origExtent.origin.y + cropH / 2.0
                    let maxCIY = origExtent.origin.y + origExtent.height - cropH / 2.0

                    let cropX = max(minCIX, min(ciCenterX, maxCIX)) - cropW / 2.0
                    let cropY = max(minCIY, min(ciCenterY, maxCIY)) - cropH / 2.0

                    let cropped = source.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
                    let translated = cropped.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

                    // Uniform Scale: Phóng to tỷ lệ đều cả 2 chiều, chống méo hình 100%
                    let uniformScale = max(targetRenderSize.width / max(1.0, cropW), targetRenderSize.height / max(1.0, cropH))
                    let scaled = translated.transformed(by: CGAffineTransform(scaleX: uniformScale, y: uniformScale))
                    let offsetX = (targetRenderSize.width - cropW * uniformScale) / 2.0
                    let offsetY = (targetRenderSize.height - cropH * uniformScale) / 2.0

                    outputImage = scaled
                        .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                        .cropped(to: CGRect(origin: .zero, size: targetRenderSize))

                    if uniformScale > 1.02, let sharpen = CIFilter(name: "CISharpenLuminance") {
                        sharpen.setValue(outputImage, forKey: kCIInputImageKey)
                        sharpen.setValue(min(0.42, 0.20 + Float(uniformScale - 1.0) * 0.10), forKey: kCIInputSharpnessKey)
                        if let sharpened = sharpen.outputImage {
                            outputImage = sharpened.cropped(to: CGRect(origin: .zero, size: targetRenderSize))
                        }
                    }
                } else {
                    outputImage = source.cropped(to: origExtent)
                }

                // 2. Chỉnh màu Film Simulation hoặc AI Cinematic Recipe
                if applyColorGrading {
                    if let filtered = FilmFilterEngine.shared.applyPreset(to: outputImage, preset: filterPreset) {
                        outputImage = filtered
                    }
                    if let aiParams = aiColorParameters,
                       let aiFiltered = FilmFilterEngine.shared.applyAIColorParameters(to: outputImage, params: aiParams) {
                        outputImage = aiFiltered
                    }
                }

                // 3. Ghép Khung Thông Tin Điện Ảnh (Video Info Frame) nếu bật
                if infoStyle != .off {
                    let totalFrames = Int(frameTime * Double(exportFPS))
                    let tcSec = Int(frameTime) % 60
                    let tcMin = (Int(frameTime) / 60) % 60
                    let tcHour = Int(frameTime) / 3600
                    let subFrame = totalFrames % exportFPS
                    let timecode = String(format: "%02d:%02d:%02d:%02d", tcHour, tcMin, tcSec, subFrame)

                    let currentFocal = applyWindowCrop ? Int(CameraViewModel.interpolateKeyframe(
                        at: frameTime,
                        keyframes: recordedKeyframes,
                        fallback: fallbackKeyframe
                    ).focalLength) : 24
                    let metadata = VideoFrameMetadata(
                        deviceName: deviceName,
                        lensDescription: "\(currentFocal)mm OPTICAL",
                        focalLengthMM: currentFocal,
                        aperture: liveAperture,
                        shutterSpeed: liveShutterText,
                        iso: liveISOValue,
                        fps: exportFPS,
                        resolutionTag: "\(Int(targetRenderSize.width))x\(Int(targetRenderSize.height))",
                        lutName: filterPreset.rawValue.uppercased(),
                        dateString: "",
                        timecode: timecode
                    )

                    outputImage = VideoInfoFrameCompositor.shared.composite(
                        frame: outputImage,
                        metadata: metadata,
                        style: infoStyle
                    )
                }

                request.finish(with: outputImage, context: nil)
            })

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("exported_\(UUID().uuidString).mov")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                await MainActor.run { self.isProcessingVideo = false }
                return
            }

            exportSession.videoComposition = composition
            exportSession.outputURL = tempURL
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true

            await exportSession.export()

            await MainActor.run {
                self.isProcessingVideo = false
                if exportSession.status == .completed {
                    if applyWindowCrop {
                        self.isWindowedZoomAlreadyCropped = true
                    }
                    self.processedVideoURL = tempURL
                    var notes: [String] = []
                    if applyWindowCrop { notes.append("Cắt Windowed Zoom (\(windowAspect.rawValue))") }
                    if applyColorGrading { notes.append("Màu Film \(filterPreset.displayName)") }
                    if infoStyle != .off { notes.append(infoStyle.rawValue) }
                    self.gradingSuccessNote = "Đã xuất: " + notes.joined(separator: " • ")
                    self.player = AVPlayer(url: tempURL)
                    self.player?.play()
                    self.saveVideoToPhotos(url: tempURL)
                } else {
                    CameraLogger.error("Xử lý video thất bại: \(String(describing: exportSession.error))", category: .photoKit)
                }
            }
        }
    }

    nonisolated private static func computeTargetRenderSize(sourceSize: CGSize, aspect: WindowedZoomAspectRatio) -> CGSize {
        let origW = sourceSize.width
        let origH = sourceSize.height
        let isPortrait = origW <= origH

        let targetW: CGFloat
        let targetH: CGFloat
        switch aspect {
        case .ratio1_1:
            let side = min(origW, origH)
            targetW = side
            targetH = side
        case .ratio3_4:
            if isPortrait {
                let h = origH
                let w = round(h * 3.0 / 4.0)
                if w <= origW {
                    targetW = w
                    targetH = h
                } else {
                    targetW = origW
                    targetH = round(origW * 4.0 / 3.0)
                }
            } else {
                let w = origW
                let h = round(w * 3.0 / 4.0)
                if h <= origH {
                    targetW = w
                    targetH = h
                } else {
                    targetH = origH
                    targetW = round(origH * 4.0 / 3.0)
                }
            }
        case .ratio16_9:
            if isPortrait {
                let h = origH
                let w = round(h * 9.0 / 16.0)
                if w <= origW {
                    targetW = w
                    targetH = h
                } else {
                    targetW = origW
                    targetH = round(origW * 16.0 / 9.0)
                }
            } else {
                let w = origW
                let h = round(w * 9.0 / 16.0)
                if h <= origH {
                    targetW = w
                    targetH = h
                } else {
                    targetH = origH
                    targetW = round(origH * 16.0 / 9.0)
                }
            }
        }
        let evenW = CGFloat(Int(targetW) & ~1)
        let evenH = CGFloat(Int(targetH) & ~1)
        return CGSize(width: max(2, evenW), height: max(2, evenH))
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
