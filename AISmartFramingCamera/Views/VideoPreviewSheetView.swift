import SwiftUI
import AVFoundation
import AVKit
import Photos
import CoreImage

public struct VideoPreviewSheetView: View {
    let videoURL: URL
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var player: AVPlayer?
    @State private var isProcessingVideo: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var processingTitle: String = "Đang xử lý video chất lượng gốc..."
    @State private var gradingSuccessNote: String? = nil
    @State private var exportErrorMessage: String? = nil
    @State private var hasSavedToPhotos: Bool = false
    @State private var processedVideoURL: URL? = nil
    @State private var isWindowedZoomAlreadyCropped: Bool = false
    @State private var activeFrameStyle: VideoInfoFrameStyle = .off

    private let accent = AlignTheme.studioAccent
    private let darkBg = AlignTheme.studioCanvas

    private var hasWindowedParams: Bool {
        if let focal = viewModel.lastRecordedVideoWindowedFocal {
            return focal > 24.1 ||
                (viewModel.lastRecordedVideoWindowedAspect != nil && viewModel.lastRecordedVideoWindowedAspect != .ratio16_9) ||
                viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })
        }
        return viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })
    }

    private var shouldAutoApplyMasterFrame: Bool {
        viewModel.isMasterWatermarkEnabled && viewModel.isVideoMasterFrameEnabled && !viewModel.isDualCameraActive
    }

    public var body: some View {
        NavigationView {
            ZStack {
                darkBg.edgesIgnoringSafeArea(.all)

                VStack(spacing: 14) {
                    // 1. Video Player (kèm lớp phủ tiến trình % chất lượng gốc)
                    ZStack {
                        if let player = player {
                            VideoPlayer(player: player)
                                .frame(maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                                )
                                .onAppear {
                                    if !isProcessingVideo {
                                        player.play()
                                    }
                                }
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AlignTheme.studioSurface)
                                .frame(maxHeight: .infinity)
                        }

                        if isProcessingVideo {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.62))
                            VStack(spacing: 10) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: accent))
                                    .scaleEffect(1.05)

                                Text(processingTitle)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(AlignTheme.studioInkPrimary)

                                if exportProgress > 0.01 {
                                    Text("\(Int(round(exportProgress * 100)))% · Giữ nguyên độ phân giải & âm thanh gốc")
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(accent)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 15)
                            .background(StudioGlassRoundedSurface(cornerRadius: 16, tintOpacity: 0.74, borderOpacity: 0.18))
                        }
                    }
                    .padding(.horizontal, 16)

                    // 2. Status / Error Note
                    if let err = exportErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(AlignTheme.studioRecordRed)
                            Text(err)
                                .font(.caption.weight(.medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(AlignTheme.studioRecordRed.opacity(0.16)))
                    } else if let note = gradingSuccessNote {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(accent)
                            Text(note)
                                .font(.caption.weight(.medium))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(StudioGlassCapsule(tintOpacity: 0.60, borderOpacity: 0.14))
                    }

                    // 3. Khung Master & Khung Điện Ảnh Cho Video (Giữ Nguyên Chất Lượng Gốc)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("KHUNG MASTER & ĐIỆN ẢNH")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .tracking(0.6)
                                .foregroundColor(AlignTheme.studioInkSecondary)
                            Spacer()
                            if activeFrameStyle == .masterFrame {
                                Text(viewModel.masterWatermarkTheme == .white ? "Trắng Leica" : "Đen Studio")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(accent)
                            }
                        }
                        .padding(.horizontal, 18)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(VideoInfoFrameStyle.allCases) { style in
                                    let isSelected = (activeFrameStyle == style)
                                    Button(action: {
                                        viewModel.haptics.triggerSelectionChange()
                                        activeFrameStyle = style
                                        viewModel.videoInfoFrameStyle = style
                                        if style == .off && !hasWindowedParams {
                                            processedVideoURL = nil
                                            gradingSuccessNote = "Đang phát video gốc nguyên bản"
                                            player?.pause()
                                            let origPlayer = AVPlayer(url: videoURL)
                                            player = origPlayer
                                            origPlayer.play()
                                        } else {
                                            processVideoExport(
                                                applyColorGrading: false,
                                                applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped,
                                                frameStyle: style,
                                                autoSave: true
                                            )
                                        }
                                    }) {
                                        HStack(spacing: 5) {
                                            Image(systemName: style.icon)
                                                .font(.system(size: 11, weight: .medium))
                                            Text(style.rawValue)
                                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                                        }
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                                        .foregroundColor(isSelected ? accent : AlignTheme.studioInkSecondary)
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .stroke(isSelected ? AlignTheme.studioAccentBorder : AlignTheme.studioHairlineSubtle, lineWidth: isSelected ? 0.9 : 0.65)
                                        )
                                    }
                                    .buttonStyle(.plain)
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
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Cắt Windowed Zoom (\(Int(focal))mm)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(AlignTheme.studioElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingVideo)
                        .padding(.horizontal, 16)
                    }

                    // 5. Action Buttons: [Chỉnh màu], [Lưu], [Chia sẻ]
                    HStack(spacing: 10) {
                        Button(action: {
                            processVideoExport(
                                applyColorGrading: true,
                                applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped,
                                frameStyle: activeFrameStyle,
                                autoSave: true
                            )
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.filters")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(isProcessingVideo ? "Đang xử lý…" : "Áp màu")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AlignTheme.studioElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingVideo)

                        Button(action: { saveVideoToPhotos() }) {
                            HStack(spacing: 6) {
                                Image(systemName: hasSavedToPhotos ? "checkmark" : "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(hasSavedToPhotos ? "Đã lưu" : "Lưu")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isProcessingVideo)

                        ShareLink(item: processedVideoURL ?? videoURL) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Chia sẻ")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(AlignTheme.studioInkPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(AlignTheme.studioElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                            )
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
                .foregroundColor(accent)
            )
            .onAppear {
                let initialStyle: VideoInfoFrameStyle = shouldAutoApplyMasterFrame ? .masterFrame : viewModel.videoInfoFrameStyle
                activeFrameStyle = initialStyle
                if hasWindowedParams {
                    applyWindowedZoomCrop()
                } else if initialStyle != .off {
                    processVideoExport(applyColorGrading: false, applyWindowCrop: false, frameStyle: initialStyle, autoSave: true)
                } else {
                    player = AVPlayer(url: videoURL)
                }
            }
            .onDisappear {
                player?.pause()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func applyWindowedZoomCrop() {
        let fallbackFocal = viewModel.recordedVideoWindowedKeyframes.last?.focalLength ?? viewModel.windowedZoomFocalLength
        let fallbackAspect = viewModel.recordedVideoWindowedKeyframes.last?.aspectRatio ?? viewModel.windowedZoomAspectRatio
        let windowFocal = viewModel.lastRecordedVideoWindowedFocal ?? fallbackFocal
        let windowAspect = viewModel.lastRecordedVideoWindowedAspect ?? fallbackAspect
        guard !isWindowedZoomAlreadyCropped,
              (windowFocal > 24.1 || windowAspect != .ratio16_9 || viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })) else { return }
        let shouldApplyWindowedCrop = !self.isWindowedZoomAlreadyCropped
        processVideoExport(
            applyColorGrading: false,
            applyWindowCrop: shouldApplyWindowedCrop,
            frameStyle: activeFrameStyle,
            autoSave: true
        )
    }

    // MARK: - High-Fidelity Video Rendering Pipeline (AVAssetReader + AVAssetWriter + Audio Passthrough)
    private func processVideoExport(
        applyColorGrading: Bool,
        applyWindowCrop: Bool,
        frameStyle: VideoInfoFrameStyle,
        autoSave: Bool
    ) {
        guard !isProcessingVideo else { return }
        isProcessingVideo = true
        exportProgress = 0.02
        exportErrorMessage = nil
        player?.pause()

        if applyWindowCrop && frameStyle == .masterFrame {
            processingTitle = "Đang cắt Windowed Zoom & ghép Khung Master..."
        } else if applyWindowCrop {
            processingTitle = "Đang cắt Windowed Zoom chất lượng gốc..."
        } else if frameStyle == .masterFrame {
            processingTitle = "Đang ghép Khung Master (giữ chất lượng gốc)..."
        } else {
            processingTitle = "Đang xuất video chất lượng gốc..."
        }

        // Luôn đọc từ videoURL gốc khi đổi khung để KHÔNG BAO GIỜ nén chồng nhiều thế hệ làm giảm chất lượng!
        // Chỉ dùng processedVideoURL nếu video đã cắt Windowed Zoom trước đó và lần này không cắt lại.
        let sourceURL = (isWindowedZoomAlreadyCropped && !applyWindowCrop) ? (processedVideoURL ?? videoURL) : videoURL
        let windowAspect = viewModel.lastRecordedVideoWindowedAspect ?? viewModel.recordedVideoWindowedKeyframes.last?.aspectRatio ?? viewModel.windowedZoomAspectRatio
        let deviceName = viewModel.masterWatermarkDeviceName.isEmpty ? "ALIGN STUDIO" : viewModel.masterWatermarkDeviceName
        let recordedKeyframes = viewModel.recordedVideoWindowedKeyframes
        let fallbackKeyframe = WindowedZoomKeyframe(
            timestamp: 0,
            focalLength: viewModel.lastRecordedVideoWindowedFocal ?? viewModel.windowedZoomFocalLength,
            normalizedCenter: viewModel.lastRecordedVideoWindowedCenter,
            baseOpticalZoom: viewModel.lastRecordedVideoWindowedBaseZoom,
            aspectRatio: windowAspect
        )
        let proControls = ProVideoManualControlsService.shared
        let liveAperture = String(format: "f/%.1f", proControls.hardwareLensAperture > 0 ? proControls.hardwareLensAperture : 1.8)
        let activeShutterReciprocal = max(1, Int(round(proControls.isAutoShutter ? proControls.measuredLiveShutterSpeed : proControls.currentShutterSpeed)))
        let liveShutterText = "1/\(activeShutterReciprocal)s"
        let liveISOValue = max(25, Int(round(proControls.isAutoISO ? proControls.measuredLiveISO : proControls.currentISO)))
        let fallbackFPS = max(1, Int(round(viewModel.selectedVideoFormatOption.fps)))

        let masterConfig = HighFidelityVideoExporter.MasterFrameConfig(
            deviceName: deviceName,
            theme: viewModel.masterWatermarkTheme,
            logoStyle: viewModel.masterWatermarkLogoStyle,
            customLogo: viewModel.masterWatermarkCustomLogoImage,
            specs: viewModel.lastRecordedVideoSpecs,
            videoTag: "\(viewModel.selectedVideoFormatOption.width >= 3840 ? "4K" : "1080p") · \(fallbackFPS)fps"
        )

        let options = HighFidelityVideoExporter.ExportOptions(
            sourceURL: sourceURL,
            preferredCodec: viewModel.selectedVideoCodec,
            applyWindowCrop: applyWindowCrop,
            windowAspect: windowAspect,
            recordedKeyframes: recordedKeyframes,
            fallbackKeyframe: fallbackKeyframe,
            applyColorGrading: applyColorGrading,
            filterPreset: viewModel.isFilmSimulationActive ? viewModel.selectedFilmPreset : .standard,
            aiColorParams: viewModel.isAIFullColorEnabled ? viewModel.currentAIColorParams : nil,
            infoFrameStyle: frameStyle,
            masterFrameConfig: masterConfig,
            liveAperture: liveAperture,
            liveShutterText: liveShutterText,
            liveISOValue: liveISOValue,
            fallbackFPS: fallbackFPS
        )

        Task {
            do {
                let finalURL = try await HighFidelityVideoExporter.export(options: options) { progress in
                    Task { @MainActor in
                        self.exportProgress = progress
                    }
                }

                await MainActor.run {
                    self.isProcessingVideo = false
                    self.exportProgress = 1.0
                    if applyWindowCrop {
                        self.isWindowedZoomAlreadyCropped = true
                    }
                    self.processedVideoURL = finalURL
                    var notes: [String] = []
                    if applyWindowCrop { notes.append("Windowed \(windowAspect.rawValue)") }
                    if applyColorGrading && viewModel.selectedFilmPreset != .standard { notes.append(viewModel.selectedFilmPreset.displayName) }
                    if frameStyle != .off { notes.append(frameStyle.rawValue) }
                    notes.append("Chất lượng gốc")
                    self.gradingSuccessNote = "Đã xuất: " + notes.joined(separator: " · ")

                    self.player?.pause()
                    let newPlayer = AVPlayer(url: finalURL)
                    self.player = newPlayer
                    newPlayer.play()
                    if autoSave {
                        self.saveVideoToPhotos(url: finalURL)
                    }
                }
            } catch {
                CameraLogger.error("HighFidelityVideoExporter thất bại: \(error.localizedDescription)", category: .photoKit)
                await MainActor.run {
                    self.isProcessingVideo = false
                    self.exportProgress = 0
                    self.exportErrorMessage = "Xuất video thất bại: \(error.localizedDescription)"
                    if self.player == nil {
                        let fallbackPlayer = AVPlayer(url: sourceURL)
                        self.player = fallbackPlayer
                        fallbackPlayer.play()
                    }
                }
            }
        }
    }

    private func saveVideoToPhotos(url: URL? = nil) {
        let targetURL = url ?? processedVideoURL ?? videoURL
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetURL)
        }) { success, _ in
            DispatchQueue.main.async {
                if success {
                    self.hasSavedToPhotos = true
                    self.viewModel.haptics.triggerSuccess()
                }
            }
        }
    }
}
