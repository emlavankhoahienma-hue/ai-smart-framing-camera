import SwiftUI
import AVFoundation
import Photos
import UIKit

// MARK: - Synchronized Playback Controller (Exact Aspect Layer + Seamless Looping + Clean Teardown)
@MainActor
private final class StudioVideoPlayerController: ObservableObject {
    @Published var player: AVPlayer? = nil
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false

    private var timeObserver: Any? = nil
    private var observedPlayer: AVPlayer? = nil
    private var endObserver: NSObjectProtocol? = nil
    private var activeURL: URL? = nil

    func load(url: URL, autoPlay: Bool) {
        if activeURL == url, let existing = player {
            if autoPlay && !isPlaying {
                existing.play()
                isPlaying = true
            }
            return
        }

        teardown()
        activeURL = url

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .none
        newPlayer.isMuted = isMuted
        self.player = newPlayer
        self.observedPlayer = newPlayer
        self.currentTime = 0

        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                let sec = CMTimeGetSeconds(time)
                if sec.isFinite && sec >= 0 {
                    self.currentTime = sec
                }
                if let itemDur = self.player?.currentItem?.duration {
                    let durSec = CMTimeGetSeconds(itemDur)
                    if durSec.isFinite && durSec > 0.01 {
                        self.duration = durSec
                    }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let activePlayer = self.player else { return }
                activePlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.isPlaying {
                            self.player?.play()
                        }
                    }
                }
            }
        }

        if autoPlay {
            newPlayer.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, max(duration, 0.01)))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        if let observer = timeObserver, let targetPlayer = observedPlayer {
            targetPlayer.removeTimeObserver(observer)
        }
        timeObserver = nil
        observedPlayer = nil
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
            endObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activeURL = nil
        isPlaying = false
        currentTime = 0
    }
}

// MARK: - Zero-Chrome Pixel-Fitted AVPlayerLayer Host
private struct StudioVideoLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerLayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Unified Full-Screen Studio Video Preview View
public struct VideoPreviewSheetView: View {
    let videoURL: URL
    @ObservedObject var viewModel: CameraViewModel
    let isAlreadySavedInPhotos: Bool
    @Environment(\.dismiss) private var dismiss

    @StateObject private var playback = StudioVideoPlayerController()

    @State private var activeMetadata: VideoPreviewMetadata = .placeholder
    @State private var posterThumbnail: UIImage? = nil
    @State private var isProcessingVideo: Bool = false
    @State private var exportProgress: Double = 0.0
    @State private var processingTitle: String = "Đang xử lý video chất lượng gốc..."
    @State private var statusBannerText: String? = nil
    @State private var exportErrorMessage: String? = nil
    @State private var isSavingToLibrary: Bool = false
    @State private var hasSavedToPhotos: Bool
    @State private var processedVideoURL: URL? = nil
    @State private var isWindowedZoomAlreadyCropped: Bool = false
    @State private var hasAppliedColorGrade: Bool = false
    @State private var activeFrameStyle: VideoExportFrameStyle = .off
    @State private var isShowingInfoSheet: Bool = false
    @State private var showCenterPlayPulse: Bool = false
    @State private var dismissDragOffsetY: CGFloat = 0
    @State private var metadataLoadTask: Task<Void, Never>? = nil

    public init(videoURL: URL, viewModel: CameraViewModel, isAlreadySavedInPhotos: Bool = false) {
        self.videoURL = videoURL
        self.viewModel = viewModel
        self.isAlreadySavedInPhotos = isAlreadySavedInPhotos
        _hasSavedToPhotos = State(initialValue: isAlreadySavedInPhotos)
    }

    private var activeDisplayURL: URL {
        processedVideoURL ?? videoURL
    }

    private var hasWindowedParams: Bool {
        guard !isAlreadySavedInPhotos else { return false }
        if let focal = viewModel.lastRecordedVideoWindowedFocal {
            return focal > 24.1 ||
                (viewModel.lastRecordedVideoWindowedAspect != nil && viewModel.lastRecordedVideoWindowedAspect != .ratio16_9) ||
                viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })
        }
        return viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })
    }

    private var shouldAutoApplyMasterFrame: Bool {
        !isAlreadySavedInPhotos &&
        viewModel.isMasterWatermarkEnabled &&
        viewModel.isVideoMasterFrameEnabled &&
        !viewModel.isDualCameraActive
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AlignTheme.studioCanvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    cleanTopHeaderBar

                    videoStageViewport
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    studioBottomPanel
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $isShowingInfoSheet) {
                videoInfoInspectorSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                CameraLogger.lifecycle("VIEW_APPEAR", detail: "VideoPreviewSheetView", category: .capture)
                inspectVideoAsset(at: videoURL)

                let initialStyle: VideoExportFrameStyle = shouldAutoApplyMasterFrame
                    ? .masterFrame
                    : (isAlreadySavedInPhotos ? .off : VideoExportFrameStyle(from: viewModel.videoInfoFrameStyle))
                activeFrameStyle = initialStyle

                if hasWindowedParams {
                    applyWindowedZoomCrop(autoSave: false)
                } else if initialStyle != .off {
                    processVideoExport(
                        applyColorGrading: false,
                        applyWindowCrop: false,
                        frameStyle: initialStyle,
                        autoSave: false
                    )
                } else {
                    playback.load(url: videoURL, autoPlay: true)
                }
            }
            .onDisappear {
                CameraLogger.lifecycle("VIEW_DISAPPEAR", detail: "VideoPreviewSheetView", category: .capture)
                metadataLoadTask?.cancel()
                playback.teardown()
            }
        }
    }

    // MARK: - 1. Clean Top Header Bar (1:1 Parity with CapturedPhotoPreviewView)
    private var cleanTopHeaderBar: some View {
        HStack {
            Button(action: {
                playback.teardown()
                dismiss()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng")

            Spacer()

            VStack(spacing: 2) {
                Text(activeMetadata.headerPrimaryLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(AlignTheme.studioInkPrimary)

                Text(activeMetadata.headerSecondaryLine)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(AlignTheme.studioInkSecondary)
            }

            Spacer()

            Button(action: { isShowingInfoSheet = true }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thông số video")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 2. Pixel-Synced Video Stage Viewport
    private var videoStageViewport: some View {
        GeometryReader { geo in
            let insetSize = CGSize(
                width: max(1, geo.size.width - 28),
                height: max(1, geo.size.height - 12)
            )
            let fittedSize = VideoPreviewMetadata.fittedViewportSize(
                videoSize: activeMetadata.displaySize,
                in: insetSize
            )

            ZStack {
                Color.clear

                ZStack {
                    // Instant First-Frame Poster (prevents blank box during player attach or export)
                    if let poster = posterThumbnail {
                        Image(uiImage: poster)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: fittedSize.width, height: fittedSize.height)
                            .clipped()
                    } else {
                        AlignTheme.studioSurface
                    }

                    // Pixel-Exact AVPlayerLayer Synced to Active Video Aspect
                    if let activePlayer = playback.player, !isProcessingVideo {
                        StudioVideoLayerView(player: activePlayer)
                            .id(activeDisplayURL)
                            .frame(width: fittedSize.width, height: fittedSize.height)
                    }

                    // Tap to Play / Pause Subtle Center Glyph
                    if !isProcessingVideo && (!playback.isPlaying || showCenterPlayPulse) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.46))
                                .frame(width: 54, height: 54)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                                )
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: playback.isPlaying ? 0 : 1.5)
                        }
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }

                    // Export Progress Frosted Overlay
                    if isProcessingVideo {
                        Color.black.opacity(0.56)

                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: AlignTheme.studioAccent))
                                .scaleEffect(1.05)

                            Text(processingTitle)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .multilineTextAlignment(.center)

                            if exportProgress > 0.01 {
                                VStack(spacing: 6) {
                                    ProgressView(value: min(max(exportProgress, 0), 1))
                                        .tint(AlignTheme.studioAccent)
                                        .frame(width: 170)

                                    Text("\(Int(round(exportProgress * 100)))% · Giữ nguyên độ phân giải & âm thanh gốc")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(AlignTheme.studioAccent)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(StudioGlassRoundedSurface(cornerRadius: 16, tintOpacity: 0.76, borderOpacity: 0.16))
                        .padding(.horizontal, 16)
                    }
                }
                .frame(width: fittedSize.width, height: fittedSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AlignTheme.studioHairline, lineWidth: 0.7)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 18, y: 8)
                .offset(y: dismissDragOffsetY)
                .animation(.spring(response: 0.30, dampingFraction: 0.86), value: activeMetadata.displaySize)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isProcessingVideo else { return }
                    playback.togglePlayPause()
                    triggerPlayPulse()
                }
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { val in
                            guard !isProcessingVideo,
                                  val.translation.height > 10,
                                  abs(val.translation.height) > abs(val.translation.width) * 1.35 else { return }
                            dismissDragOffsetY = max(0, val.translation.height * 0.72)
                        }
                        .onEnded { val in
                            if dismissDragOffsetY > 0 {
                                if val.translation.height > 110 || val.predictedEndTranslation.height > 190 {
                                    playback.teardown()
                                    dismiss()
                                } else {
                                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                        dismissDragOffsetY = 0
                                    }
                                }
                            }
                        }
                )

                // Floating Status / Error Pill (Anchored Cleanly at Bottom of Stage)
                VStack {
                    Spacer()
                    if let err = exportErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AlignTheme.studioRecordRed)
                            Text(err)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(AlignTheme.studioRecordRed.opacity(0.22))
                                .overlay(Capsule().stroke(AlignTheme.studioRecordRed.opacity(0.45), lineWidth: 0.7))
                        )
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if let note = statusBannerText, !isProcessingVideo {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(AlignTheme.studioAccent)
                            Text(note)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(AlignTheme.studioInkPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(StudioGlassCapsule(tintOpacity: 0.68, borderOpacity: 0.14))
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - 3. Studio Bottom Panel (Scrubber · Frame Strip · Unified Action Dock)
    private var studioBottomPanel: some View {
        VStack(spacing: 12) {
            // 3A. Minimalist Scrubber & Mute Transport Row
            playbackTransportBar
                .padding(.horizontal, 16)

            // 3B. Optional Windowed Zoom Quick Action
            if hasWindowedParams && !isWindowedZoomAlreadyCropped {
                let focal = viewModel.lastRecordedVideoWindowedFocal ?? 24.0
                Button(action: {
                    applyWindowedZoomCrop(autoSave: false)
                }) {
                    HStack(spacing: 7) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(AlignTheme.studioAccent)
                        Text("Cắt khung Windowed Zoom (\(Int(focal))mm)")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AlignTheme.studioInkTertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AlignTheme.studioSurface)
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

            // 3C. Compact Video Frame Style Strip
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("KHUNG VIDEO")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(AlignTheme.studioInkSecondary)

                    Spacer()

                    if activeFrameStyle == .masterFrame {
                        Text(viewModel.masterWatermarkTheme == .white ? "Trắng Leica" : "Đen Studio")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)
                    } else if activeFrameStyle != .off {
                        Text(activeFrameStyle.rawValue)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(AlignTheme.studioAccent)
                    }
                }
                .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(VideoExportFrameStyle.allCases) { style in
                            let isSelected = (activeFrameStyle == style)
                            Button(action: {
                                selectFrameStyle(style)
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: style.icon)
                                        .font(.system(size: 11, weight: .medium))
                                    Text(style.rawValue)
                                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7.5)
                                .background(isSelected ? AlignTheme.studioAccentSoft : AlignTheme.studioSurface)
                                .foregroundColor(isSelected ? AlignTheme.studioAccent : AlignTheme.studioInkSecondary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
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

            // 3D. Unified Bottom Action Dock (Exact Parity with CapturedPhotoPreviewView)
            HStack(spacing: 12) {
                // Left: Color Grade Action
                Button(action: {
                    processVideoExport(
                        applyColorGrading: true,
                        applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped,
                        frameStyle: activeFrameStyle,
                        autoSave: false
                    )
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: hasAppliedColorGrade ? "camera.filters" : "wand.and.stars")
                            .font(.system(size: 16.5, weight: .medium))
                        Text(hasAppliedColorGrade ? "Đã áp màu" : "Áp màu")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(hasAppliedColorGrade ? AlignTheme.studioAccent : .white.opacity(0.88))
                    .frame(width: 72, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(isProcessingVideo)

                // Center: High-Contrast Snow White Save Pill (Switches to Calm Green When Saved)
                Button(action: { saveVideoToPhotos() }) {
                    HStack(spacing: 7) {
                        if isSavingToLibrary {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .scaleEffect(0.78)
                        } else {
                            Image(systemName: hasSavedToPhotos ? "checkmark" : "arrow.down")
                                .font(.system(size: 13.5, weight: .bold))
                        }
                        Text(hasSavedToPhotos ? "Đã lưu" : "Lưu video")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Capsule()
                            .fill(hasSavedToPhotos ? AlignTheme.studioPositive : Color.white)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessingVideo || isSavingToLibrary)

                // Right: ShareLink
                ShareLink(item: activeDisplayURL) {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                        Text("Chia sẻ")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.88))
                    .frame(width: 72, height: 44)
                }
                .disabled(isProcessingVideo)
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
        .background(AlignTheme.studioCanvas)
    }

    // MARK: - Playback Transport Scrubber Row
    private var playbackTransportBar: some View {
        let totalDuration = max(playback.duration, activeMetadata.durationSeconds, 0.1)
        let currentClamped = min(max(playback.currentTime, 0), totalDuration)

        return HStack(spacing: 10) {
            Button(action: {
                guard !isProcessingVideo else { return }
                playback.togglePlayPause()
            }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AlignTheme.studioInkPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AlignTheme.studioSurface))
                    .overlay(Circle().stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .disabled(isProcessingVideo)

            Text(VideoPreviewMetadata.formatDuration(currentClamped))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkSecondary)
                .frame(minWidth: 32, alignment: .leading)

            Slider(
                value: Binding(
                    get: { currentClamped },
                    set: { newSec in
                        playback.seek(to: newSec)
                    }
                ),
                in: 0...totalDuration,
                onEditingChanged: { editing in
                    playback.isScrubbing = editing
                }
            )
            .tint(AlignTheme.studioAccent)
            .disabled(isProcessingVideo)

            Text(VideoPreviewMetadata.formatDuration(totalDuration))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(AlignTheme.studioInkTertiary)
                .frame(minWidth: 32, alignment: .trailing)

            Button(action: {
                playback.toggleMute()
            }) {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(playback.isMuted ? AlignTheme.studioInkSecondary : AlignTheme.studioInkPrimary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AlignTheme.studioSurface))
                    .overlay(Circle().stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 4. Video Info Inspector Sheet (Parity with CapturedPhotoPreviewView)
    private var videoInfoInspectorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("THÔNG SỐ VIDEO")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkSecondary)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            infoStatCell(
                                label: "Độ phân giải",
                                value: "\(Int(round(activeMetadata.displaySize.width))) × \(Int(round(activeMetadata.displaySize.height))) (\(activeMetadata.resolutionTierLabel))"
                            )
                            infoStatCell(
                                label: "Tốc độ khung hình",
                                value: activeMetadata.nominalFPS >= 1 ? "\(Int(round(activeMetadata.nominalFPS))) fps" : "—"
                            )
                            infoStatCell(
                                label: "Thời lượng",
                                value: VideoPreviewMetadata.formatDuration(max(activeMetadata.durationSeconds, playback.duration))
                            )
                            infoStatCell(
                                label: "Định dạng & Dung lượng",
                                value: "\(activeMetadata.codecLabel) · \(VideoPreviewMetadata.formatFileSize(activeMetadata.fileSizeBytes))"
                            )
                            infoStatCell(
                                label: "Tỉ lệ khung hình",
                                value: activeMetadata.aspectRatioLabel
                            )
                            infoStatCell(
                                label: "Khung trình chiếu",
                                value: activeFrameStyle.rawValue
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("QUANG HỌC & PHƠI SÁNG")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(AlignTheme.studioInkSecondary)

                        let specs = viewModel.lastRecordedVideoSpecs
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            infoStatCell(label: "Tiêu cự & Khẩu độ", value: "\(specs.focalLength) · \(specs.aperture)")
                            infoStatCell(label: "Phơi sáng", value: "\(specs.shutterSpeed) · \(specs.iso)")
                        }
                    }
                }
                .padding(18)
            }
            .background(AlignTheme.studioCanvas.ignoresSafeArea())
            .navigationTitle("Thông số video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Xong") { isShowingInfoSheet = false }
                        .foregroundColor(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoStatCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(AlignTheme.studioInkSecondary)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(AlignTheme.studioInkPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AlignTheme.studioSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(AlignTheme.studioHairlineSubtle, lineWidth: 0.6)
                )
        )
    }

    // MARK: - Actions & Asset Inspection
    private func triggerPlayPulse() {
        withAnimation(.easeOut(duration: 0.14)) {
            showCenterPlayPulse = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            withAnimation(.easeOut(duration: 0.22)) {
                showCenterPlayPulse = false
            }
        }
    }

    private func selectFrameStyle(_ style: VideoExportFrameStyle) {
        viewModel.haptics.triggerSelectionChange()
        activeFrameStyle = style
        viewModel.videoInfoFrameStyle = style.cinemaInfoStyle

        if style == .off && !hasWindowedParams && !hasAppliedColorGrade {
            processedVideoURL = nil
            hasSavedToPhotos = isAlreadySavedInPhotos
            statusBannerText = "Đang xem video gốc nguyên bản"
            inspectVideoAsset(at: videoURL)
            playback.load(url: videoURL, autoPlay: true)
        } else {
            processVideoExport(
                applyColorGrading: hasAppliedColorGrade,
                applyWindowCrop: hasWindowedParams && !isWindowedZoomAlreadyCropped,
                frameStyle: style,
                autoSave: false
            )
        }
    }

    private func inspectVideoAsset(at url: URL) {
        metadataLoadTask?.cancel()
        metadataLoadTask = Task {
            let asset = AVURLAsset(url: url)
            let fileBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

            var displaySize = CGSize(width: 1080, height: 1920)
            var durationSeconds: Double = 0
            var nominalFPS: Double = 0
            var codecLabel = viewModel.selectedVideoCodec == .hevc ? "HEVC" : "H.264"

            do {
                let durTime = try await asset.load(.duration)
                let sec = CMTimeGetSeconds(durTime)
                if sec.isFinite && sec > 0 {
                    durationSeconds = sec
                }
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if let track = videoTracks.first {
                    let (natSize, transform, fps, descriptions) = try await track.load(
                        .naturalSize,
                        .preferredTransform,
                        .nominalFrameRate,
                        .formatDescriptions
                    )
                    displaySize = VideoPreviewMetadata.orientedSize(
                        naturalSize: natSize,
                        preferredTransform: transform
                    )
                    if fps.isFinite && fps > 0 {
                        nominalFPS = Double(fps)
                    }
                    if let desc = descriptions.first {
                        let subType = CMFormatDescriptionGetMediaSubType(desc)
                        switch subType {
                        case kCMVideoCodecType_HEVC: codecLabel = "HEVC"
                        case kCMVideoCodecType_H264: codecLabel = "H.264"
                        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT:
                            codecLabel = "ProRes"
                        default:
                            break
                        }
                    }
                }
            } catch {
                CameraLogger.warning("VideoPreviewSheetView: Không đọc được metadata video: \(error.localizedDescription)", category: .capture)
            }

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1280, height: 1280)
            let thumbImage: UIImage?
            if let cg = try? await gen.image(at: .zero).image {
                thumbImage = UIImage(cgImage: cg)
            } else {
                thumbImage = nil
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.activeMetadata = VideoPreviewMetadata(
                    displaySize: displaySize,
                    durationSeconds: durationSeconds,
                    nominalFPS: nominalFPS,
                    codecLabel: codecLabel,
                    fileSizeBytes: fileBytes
                )
                if durationSeconds > 0.01 && self.playback.duration <= 0.01 {
                    self.playback.duration = durationSeconds
                }
                if let thumbImage {
                    self.posterThumbnail = thumbImage
                }
            }
        }
    }

    private func applyWindowedZoomCrop(autoSave: Bool) {
        let fallbackFocal = viewModel.recordedVideoWindowedKeyframes.last?.focalLength ?? viewModel.windowedZoomFocalLength
        let fallbackAspect = viewModel.recordedVideoWindowedKeyframes.last?.aspectRatio ?? viewModel.windowedZoomAspectRatio
        let windowFocal = viewModel.lastRecordedVideoWindowedFocal ?? fallbackFocal
        let windowAspect = viewModel.lastRecordedVideoWindowedAspect ?? fallbackAspect
        guard !isWindowedZoomAlreadyCropped,
              (windowFocal > 24.1 || windowAspect != .ratio16_9 || viewModel.recordedVideoWindowedKeyframes.contains(where: { $0.focalLength > 24.1 || $0.aspectRatio != .ratio16_9 })) else { return }
        processVideoExport(
            applyColorGrading: hasAppliedColorGrade,
            applyWindowCrop: true,
            frameStyle: activeFrameStyle,
            autoSave: autoSave
        )
    }

    // MARK: - High-Fidelity Video Rendering Pipeline (AVAssetReader + AVAssetWriter + Audio Passthrough)
    private func processVideoExport(
        applyColorGrading: Bool,
        applyWindowCrop: Bool,
        frameStyle: VideoExportFrameStyle,
        autoSave: Bool
    ) {
        guard !isProcessingVideo else { return }
        isProcessingVideo = true
        exportProgress = 0.02
        exportErrorMessage = nil
        statusBannerText = nil
        playback.pause()

        if applyWindowCrop && frameStyle == .masterFrame {
            processingTitle = "Đang cắt Windowed Zoom & ghép Khung Master..."
        } else if applyWindowCrop {
            processingTitle = "Đang cắt Windowed Zoom chất lượng gốc..."
        } else if frameStyle == .masterFrame {
            processingTitle = "Đang ghép Khung Master (giữ chất lượng gốc)..."
        } else if applyColorGrading {
            processingTitle = "Đang áp màu chất lượng gốc..."
        } else {
            processingTitle = "Đang xử lý khung video chất lượng gốc..."
        }

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
                    if applyColorGrading {
                        self.hasAppliedColorGrade = true
                    }
                    self.processedVideoURL = finalURL
                    self.hasSavedToPhotos = false

                    var notes: [String] = []
                    if applyWindowCrop { notes.append("Windowed \(windowAspect.rawValue)") }
                    if applyColorGrading && viewModel.selectedFilmPreset != .standard { notes.append(viewModel.selectedFilmPreset.displayName) }
                    if frameStyle != .off { notes.append(frameStyle.rawValue) }
                    notes.append("Chất lượng gốc")
                    self.statusBannerText = "Đã sẵn sàng: " + notes.joined(separator: " · ")

                    self.inspectVideoAsset(at: finalURL)
                    self.playback.load(url: finalURL, autoPlay: true)
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
                    if self.playback.player == nil {
                        self.playback.load(url: sourceURL, autoPlay: true)
                    }
                }
            }
        }
    }

    private func saveVideoToPhotos(url: URL? = nil) {
        guard !isSavingToLibrary else { return }
        let targetURL = url ?? activeDisplayURL
        isSavingToLibrary = true
        exportErrorMessage = nil

        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: targetURL)
                }
                await MainActor.run {
                    self.isSavingToLibrary = false
                    self.hasSavedToPhotos = true
                    self.statusBannerText = "Đã lưu video vào Apple Photos"
                    self.viewModel.haptics.triggerSuccess()
                }
            } catch {
                await MainActor.run {
                    self.isSavingToLibrary = false
                    self.exportErrorMessage = "Không thể lưu video: \(error.localizedDescription)"
                }
            }
        }
    }
}
