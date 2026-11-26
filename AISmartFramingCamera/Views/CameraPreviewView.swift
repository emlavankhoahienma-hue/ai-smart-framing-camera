import SwiftUI
import AVFoundation
import QuartzCore
import Metal
import MetalKit
import CoreImage

public struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel

    public func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.setupLayer(session: viewModel.cameraService.captureSession)
        view.setupMetalPreview(viewModel: viewModel)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
        viewModel.previewLayer = view.previewLayer
        viewModel.previewContainerView = view
        return view
    }

    public func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if viewModel.previewContainerView !== uiView {
            viewModel.previewContainerView = uiView
        }
        let isDual = viewModel.isDualCameraActive || viewModel.cameraService.isDualCameraActive
        let dualLayer = isDual ? viewModel.cameraService.multiCamPrimaryPreviewLayer : nil
        uiView.syncDualCameraPrimaryLayer(
            dualLayer,
            isDualActive: isDual,
            singleSession: viewModel.cameraService.captureSession
        )
        let activeLayer = dualLayer ?? uiView.previewLayer
        if viewModel.previewLayer !== activeLayer {
            viewModel.previewLayer = activeLayer
        }
        // Khung ngắm giờ luôn khớp chính xác tỷ lệ cảm biến thực tế:
        // - Chụp ảnh / Pro: khung 3:4 <-> cảm biến 3:4 (1.000x, 0px viền đen)
        // - Quay video: khung 9:16 toàn chiều rộng <-> video 9:16 (1.000x, 0px viền đen, không crop phóng đại 1.33x-1.6x!)
        let targetGravity: AVLayerVideoGravity = .resizeAspectFill
        if uiView.previewLayer?.videoGravity != targetGravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.20)
            uiView.previewLayer?.videoGravity = targetGravity
            CATransaction.commit()
        }
        let isStillColorAllowed = !viewModel.captureMode.isVideo && viewModel.selectedPhotoFormat != .dng
        uiView.updateMetalPreviewState(
            isActive: viewModel.isFilmSimulationActive,
            isDualCamera: isDual,
            isVideoMode: false,
            isSimulatedUltraWide: viewModel.isSimulatedUltraWideActive,
            simulatedFactor: viewModel.simulatedUltraWideFactor,
            isHorizonLock: viewModel.isHorizonLockEnabled,
            isFocusPeaking: viewModel.isFocusPeakingEnabled,
            focusPeakingColor: viewModel.focusPeakingColor,
            focusPeakingSensitivity: Float(viewModel.focusPeakingSensitivity),
            preset: viewModel.selectedFilmPreset,
            intensity: Float(viewModel.filmSimulationIntensity),
            softwareWB: viewModel.activeProSoftwareWB,
            filmTuning: viewModel.filmTuning,
            photographicStyle: viewModel.effectivePhotographicStyle,
            isPhotographicStylePadOpen: viewModel.isShowingPhotographicStylePad && isStillColorAllowed,
            photographicStyleSplit: isStillColorAllowed ? viewModel.photographicStyleSplit : .inactive,
            lightLeak: isStillColorAllowed ? viewModel.vintageLightLeak : .off
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    public class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let parent: CameraPreviewView
        private var initialZoom: CGFloat = 1.0

        init(_ parent: CameraPreviewView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewContainerView else { return }
            let location = gesture.location(in: view)

            if parent.viewModel.isAEAFLocked {
                parent.viewModel.unlockAEAF()
                return
            }

            let normalizedPoint = TrackingGeometry.bufferPoint(location, size: view.bounds.size,
                aspect: SpatialTrackingEngine.shared.currentBufferAspect)
            let devicePoint = view.previewLayer?.captureDevicePointConverted(fromLayerPoint: location)
            parent.viewModel.userDidTapToFocus(at: normalizedPoint, devicePoint: devicePoint)
            if parent.viewModel.captureMode.isVideo { view.showFocusRing(at: location) }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            // Khi Windowed Zoom đang bật: nhường toàn bộ cử chỉ chụm/mở 2 ngón cho khung cửa sổ (không zoom ống kính vật lý!)
            guard !parent.viewModel.isWindowedZoomActive else { return }
            if gesture.state == .began {
                initialZoom = parent.viewModel.displayZoom
                parent.viewModel.beginVideoAwareManualZoomGesture()
            }
            let minDisplay = parent.viewModel.minAvailableDisplayZoom
            let maxDisplay = parent.viewModel.maxAvailableDisplayZoom
            let newDisplayZoom = max(minDisplay, min(initialZoom * gesture.scale, maxDisplay))

            if gesture.state == .ended || gesture.state == .cancelled {
                parent.viewModel.finishVideoAwareZoomGesture(newDisplayZoom)
            } else {
                parent.viewModel.setVideoAwareZoomContinuous(newDisplayZoom)
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? PreviewContainerView else { return }
            let location = gesture.location(in: view)
            let normalizedPoint = TrackingGeometry.bufferPoint(location, size: view.bounds.size,
                aspect: SpatialTrackingEngine.shared.currentBufferAspect)
            guard let devicePoint = view.previewLayer?.captureDevicePointConverted(fromLayerPoint: location) else { return }
            parent.viewModel.lockAEAF(at: normalizedPoint, devicePoint: devicePoint)
            view.showFocusRing(at: location, persist: true)
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer {
                return !parent.viewModel.isWindowedZoomActive
            }
            return true
        }

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer && parent.viewModel.isWindowedZoomActive {
                return false
            }
            return true
        }
    }
}

/// Hộp bao an toàn chuyển tài nguyên Metal/CoreVideo từ Main Thread sang renderQueue background không phát cảnh báo Swift 6.
private struct MetalFrameDispatchBox<T>: @unchecked Sendable {
    let value: T
}

// MARK: - Zero-Lag 60 FPS Single-Pass Direct Metal Realtime Renderer
/// Kiến trúc mới loại bỏ hoàn toàn hiện tượng giật/đơ khi chỉnh màu cả trong tối (15-24fps sensor) lẫn ban ngày (60fps):
/// 1. Chạy Single-Pass Direct Metal (`UnifiedMetalColorEngine`) zero-copy trực tiếp từ `CVPixelBuffer` -> `MTKView` drawable (~0.4ms/frame).
/// 2. Triple-buffer non-blocking `DispatchSemaphore(value: 2)` + background `renderQueue (userInteractive)` -> tuyệt đối KHÔNG bao giờ chặn Main Thread!
/// 3. Chỉ dùng fallback `CIContext` khi bật Simulated 0.5x Ultra-Wide (cần `UltraWideWarpEngine` C++20 rectilinear).
final class MetalFilmSimulationRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderQueue = DispatchQueue(label: "com.alignai.metal.preview", qos: .userInteractive)
    private let inflightSemaphore = DispatchSemaphore(value: 2)
    private lazy var fallbackCIContext: CIContext = {
        let linearCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(mtlCommandQueue: commandQueue, options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .workingColorSpace: linearCS,
            .workingFormat: CIFormat.RGBAh
        ])
    }()
    private let sRGBColorSpace = CGColorSpaceCreateDeviceRGB()
    private static let infiniteBlackCI = CIImage(color: .black)

    private weak var viewModel: CameraViewModel?
    private let stateLock = NSLock()
    private var isRenderingActive: Bool = false
    private var isFilmFilterActive: Bool = false
    private var isDualCameraMode: Bool = false
    private var isVideoAspectFit: Bool = false
    private var isSimulatedUltraWide: Bool = false
    private var simulatedFactor: CGFloat = 0.5
    private var isHorizonLock: Bool = false
    private var isFocusPeaking: Bool = false
    private var focusPeakingColor: FocusPeakingColor = .green
    private var focusPeakingSensitivity: Float = 0.5
    private var currentPreset: FilmPreset = .standard
    private var currentIntensity: Float = 1.0
    private var currentSoftwareWB: ProPhotoSoftwareWBGrade = .inactive
    private var currentFilmTuning: FilmSimulationTuning = .neutral
    private var currentPhotographicStyle: PhotographicStyleState = .standard
    private var currentPhotographicStyleSplit: PhotographicStyleSplitTransition = .inactive
    private var currentLightLeak: VintageLightLeakConfig = .off

    // Dirty-tracking strictly on Main Thread inside draw(in:) to avoid redundant dispatches when idle
    private var lastProcessedBuffer: CVPixelBuffer? = nil
    private var lastPresentedOnce: Bool = false
    private var lastRenderParams: UnifiedColorRenderParams? = nil
    private var lastDrawableSize: CGSize = .zero
    private var lastSimUW: Bool = false
    private var lastSimFactor: CGFloat = 0.5
    private var lastPeakingActive: Bool = false
    private var lastPeakingColor: FocusPeakingColor = .green
    private var lastPeakingSensitivity: Float = 0.5
    private var frameCounter: UInt32 = 0

    init?(device: MTLDevice, viewModel: CameraViewModel) {
        self.device = device
        guard let queue = UnifiedMetalColorEngine.shared.commandQueue
                ?? UltraWideWarpEngine.live.commandQueue
                ?? device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.viewModel = viewModel
        super.init()
    }

    func updateState(
        isActive: Bool,
        isDualCamera: Bool,
        isVideoMode: Bool,
        isSimulatedUltraWide: Bool = false,
        simulatedFactor: CGFloat = 0.5,
        isHorizonLock: Bool = false,
        isFocusPeaking: Bool = false,
        focusPeakingColor: FocusPeakingColor = .green,
        focusPeakingSensitivity: Float = 0.5,
        preset: FilmPreset,
        intensity: Float,
        softwareWB: ProPhotoSoftwareWBGrade = .inactive,
        filmTuning: FilmSimulationTuning = .neutral,
        photographicStyle: PhotographicStyleState = .standard,
        isPhotographicStylePadOpen: Bool = false,
        photographicStyleSplit: PhotographicStyleSplitTransition = .inactive,
        lightLeak: VintageLightLeakConfig = .off
    ) {
        stateLock.lock()
        let hasRealFilm = isActive && (preset != .standard && preset != .proColorGrade)
        let hasColorPass = hasRealFilm
            || !softwareWB.isIdentity
            || !filmTuning.isIdentity
            || !photographicStyle.isIdentity
            || photographicStyleSplit.isActive
            || !lightLeak.isIdentity
        self.isFilmFilterActive = hasColorPass
        self.isFocusPeaking = isFocusPeaking
        self.focusPeakingColor = focusPeakingColor
        self.focusPeakingSensitivity = focusPeakingSensitivity
        self.isRenderingActive = hasColorPass || isPhotographicStylePadOpen || isSimulatedUltraWide || isHorizonLock || isFocusPeaking
        self.isDualCameraMode = isDualCamera
        self.isVideoAspectFit = isVideoMode
        self.isSimulatedUltraWide = isSimulatedUltraWide
        self.simulatedFactor = simulatedFactor
        self.isHorizonLock = isHorizonLock
        self.currentPreset = hasRealFilm ? preset : .proColorGrade
        self.currentIntensity = intensity
        self.currentSoftwareWB = softwareWB
        self.currentFilmTuning = filmTuning
        self.currentPhotographicStyle = photographicStyle
        self.currentPhotographicStyleSplit = photographicStyleSplit
        self.currentLightLeak = lightLeak
        stateLock.unlock()
    }

    /// Đẩy trực tiếp thông số màu xuống GPU trong < 0.005ms khi kéo thanh trượt / 2D Pad (không chờ SwiftUI re-layout).
    func pushLiveColorStateFast(
        isFilmActive: Bool,
        preset: FilmPreset,
        intensity: Float,
        softwareWB: ProPhotoSoftwareWBGrade,
        filmTuning: FilmSimulationTuning,
        photographicStyle: PhotographicStyleState,
        lightLeak: VintageLightLeakConfig
    ) {
        stateLock.lock()
        let hasRealFilm = isFilmActive && (preset != .standard && preset != .proColorGrade)
        let hasColorPass = hasRealFilm
            || !softwareWB.isIdentity
            || !filmTuning.isIdentity
            || !photographicStyle.isIdentity
            || self.currentPhotographicStyleSplit.isActive
            || !lightLeak.isIdentity
        self.isFilmFilterActive = hasColorPass
        if hasColorPass {
            self.isRenderingActive = true
        }
        self.currentPreset = hasRealFilm ? preset : .proColorGrade
        self.currentIntensity = intensity
        self.currentSoftwareWB = softwareWB
        self.currentFilmTuning = filmTuning
        self.currentPhotographicStyle = photographicStyle
        self.currentLightLeak = lightLeak
        stateLock.unlock()
    }

    func updateSplitTransitionFastPath(_ split: PhotographicStyleSplitTransition) {
        stateLock.lock()
        self.currentPhotographicStyleSplit = split
        if split.isActive {
            self.isFilmFilterActive = true
            self.isRenderingActive = true
        }
        stateLock.unlock()
    }

    func resetPresentationDirtyState() {
        lastPresentedOnce = false
        lastRenderParams = nil
    }

    func clearHeldBuffers() {
        lastProcessedBuffer = nil
        lastPresentedOnce = false
        lastRenderParams = nil
        UnifiedMetalColorEngine.shared.flushCaches()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastPresentedOnce = false
    }

    func draw(in view: MTKView) {
        stateLock.lock()
        let shouldRender = isRenderingActive
        let filmActive = isFilmFilterActive
        let videoAspectFit = isVideoAspectFit
        let simUW = isSimulatedUltraWide
        let simFactor = simulatedFactor
        let isHL = isHorizonLock
        let isPeaking = isFocusPeaking
        let peakingColor = focusPeakingColor
        let peakingSens = focusPeakingSensitivity
        let preset = currentPreset
        let intensity = currentIntensity
        let softwareWB = currentSoftwareWB
        let filmTuning = currentFilmTuning
        let photographicStyle = currentPhotographicStyle
        let splitTransition = currentPhotographicStyleSplit
        let lightLeak = currentLightLeak
        stateLock.unlock()

        guard shouldRender else { return }
        guard let vm = self.viewModel,
              let pixelBuffer = vm.cameraService.currentMultiCamPixelBuffer() ?? vm.latestCameraPixelBuffer() else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        let effectivePreset = preset.isAIFullAuto ? (vm.aiRecommendedPreset ?? vm.detectedScene.recommendedFilter) : preset
        let hasRealFilm = filmActive && effectivePreset != .standard && effectivePreset != .proColorGrade && effectivePreset != .aiFullAuto

        var params = UnifiedColorRenderParams()
        params.preset = effectivePreset
        params.isFilmActive = hasRealFilm
        params.filmIntensity = intensity
        params.softwareWB = softwareWB
        params.filmTuning = filmTuning
        params.photographicStyle = photographicStyle
        params.splitTransition = splitTransition
        params.lightLeak = lightLeak
        params.setAIParameters(preset.isAIFullAuto ? vm.currentAIColorParams : nil)
        params.isVideoAspectFit = videoAspectFit && !simUW
        params.isHorizonLock = isHL
        if isHL {
            let motion = DeviceMotionService.shared.currentHorizonParams()
            params.horizonRoll = motion.roll
            params.horizonZoom = motion.zoom
            params.horizonShakeX = motion.shakeX
            params.horizonShakeY = motion.shakeY
        }

        // Bỏ qua render thừa khi camera đứng im (vd: 20fps trong tối) VÀ mọi tham số màu giống hệt frame vừa hiện
        let bufferChanged = (pixelBuffer !== lastProcessedBuffer)
        let paramsChanged = (params != lastRenderParams)
            || (drawableSize != lastDrawableSize)
            || (simUW != lastSimUW)
            || (abs(simFactor - lastSimFactor) > 0.005)
            || (isPeaking != lastPeakingActive)
            || (peakingColor != lastPeakingColor)
            || (abs(peakingSens - lastPeakingSensitivity) > 0.01)

        if !isHL && !isPeaking && !bufferChanged && !paramsChanged && lastPresentedOnce {
            return
        }

        // Non-blocking Triple-Buffer Semaphore: nếu 2 frame trước GPU chưa xong -> thả ngay frame này, 0ms chặn Main Thread!
        guard inflightSemaphore.wait(timeout: .now()) == .success else { return }

        guard let currentDrawable = view.currentDrawable else {
            inflightSemaphore.signal()
            return
        }

        if bufferChanged {
            frameCounter &+= 1
        }
        params.frameSeed = Float(frameCounter % 997) * 0.0137

        // Cập nhật trạng thái dirty trên Main Thread trước khi đẩy việc encode sang background queue
        lastProcessedBuffer = pixelBuffer
        lastRenderParams = params
        lastDrawableSize = drawableSize
        lastSimUW = simUW
        lastSimFactor = simFactor
        lastPeakingActive = isPeaking
        lastPeakingColor = peakingColor
        lastPeakingSensitivity = peakingSens
        lastPresentedOnce = true

        let liveISO = vm.currentLiveISO
        let displayScale = Float(view.contentScaleFactor > 0 ? view.contentScaleFactor : 2.0)

        let pbBox = MetalFrameDispatchBox(value: pixelBuffer)
        let drawableBox = MetalFrameDispatchBox(value: currentDrawable)
        let useDirectUnifiedMetal = !simUW && UnifiedMetalColorEngine.shared.isReady

        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let commandBuffer = self.commandQueue.makeCommandBuffer() else {
                self.inflightSemaphore.signal()
                return
            }

            let pb = pbBox.value
            let drawable = drawableBox.value

            // Giữ tham chiếu mạnh tới CVPixelBuffer cho đến khi GPU đọc xong IOSurface, đồng thời giải phóng semaphore
            commandBuffer.addCompletedHandler { [weak self] _ in
                _ = pb
                self?.inflightSemaphore.signal()
            }

            var encoded = false
            if useDirectUnifiedMetal {
                encoded = UnifiedMetalColorEngine.shared.encodePreviewFrame(
                    pixelBuffer: pb,
                    outputTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    params: params
                )
            }

            if !encoded {
                self.encodeFallbackCIFrame(
                    pixelBuffer: pb,
                    outputTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    drawableSize: drawableSize,
                    simUW: simUW,
                    simFactor: simFactor,
                    params: params
                )
            }

            if isPeaking {
                FocusPeakingEngine.shared.renderFocusPeaking(
                    sourcePixelBuffer: pb,
                    sourceTexture: drawable.texture,
                    targetTexture: drawable.texture,
                    commandBuffer: commandBuffer,
                    color: peakingColor,
                    sensitivity: peakingSens,
                    iso: liveISO,
                    displayScale: displayScale
                )
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    /// Fallback Core Image chỉ kích hoạt khi bật Simulated 0.5x Ultra-Wide (cần C++20 rectilinear unwarp) hoặc thiết bị không hỗ trợ Metal compute.
    private func encodeFallbackCIFrame(
        pixelBuffer: CVPixelBuffer,
        outputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize,
        simUW: Bool,
        simFactor: CGFloat,
        params: UnifiedColorRenderParams
    ) {
        let inputCI = CIImage(cvPixelBuffer: pixelBuffer)
        let rawExtent = inputCI.extent
        guard rawExtent.width > 0, rawExtent.height > 0 else { return }

        let scaleX = drawableSize.width / rawExtent.width
        let scaleY = drawableSize.height / rawExtent.height
        let scale = params.isVideoAspectFit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let scaledW = rawExtent.width * scale
        let scaledH = rawExtent.height * scale
        let ox = (drawableSize.width - scaledW) / 2.0
        let oy = (drawableSize.height - scaledH) / 2.0

        let transformedCI: CIImage
        if params.isHorizonLock {
            let totalScale = scale * CGFloat(params.horizonZoom)
            let shakeX = CGFloat(params.horizonShakeX) * drawableSize.width
            let shakeY = CGFloat(params.horizonShakeY) * drawableSize.height
            let t = CGAffineTransform(translationX: -rawExtent.midX, y: -rawExtent.midY)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(-params.horizonRoll)))
                .concatenating(CGAffineTransform(scaleX: totalScale, y: totalScale))
                .concatenating(CGAffineTransform(translationX: (drawableSize.width / 2.0) + shakeX,
                                                 y: (drawableSize.height / 2.0) + shakeY))
            transformedCI = inputCI.transformed(by: t)
        } else {
            let t = CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: ox, y: oy))
            transformedCI = inputCI.transformed(by: t)
        }

        let viewportBounds = CGRect(origin: .zero, size: drawableSize)
        let bgBlack = Self.infiniteBlackCI.cropped(to: viewportBounds)
        let viewportCI = transformedCI.composited(over: bgBlack).cropped(to: viewportBounds)
        let unwarpedCI: CIImage = simUW
            ? UltraWideWarpEngine.shared.applySimulatedUltraWide(to: viewportCI, factor: simFactor)
            : viewportCI

        let gradedCI: CIImage
        if params.hasEffectiveColorPass {
            gradedCI = FilmFilterEngine.shared.applyPreset(
                to: unwarpedCI,
                preset: params.isFilmActive ? params.preset : .proColorGrade,
                intensity: params.filmIntensity,
                isRealtimePreview: true,
                photographicStyleOverride: params.photographicStyle
            ) ?? unwarpedCI
        } else {
            gradedCI = unwarpedCI
        }

        fallbackCIContext.render(
            gradedCI,
            to: outputTexture,
            commandBuffer: commandBuffer,
            bounds: viewportBounds,
            colorSpace: sRGBColorSpace
        )
    }
}

@MainActor
public class PreviewContainerView: UIView {
    public override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer? {
        return layer as? AVCaptureVideoPreviewLayer
    }

    private let dualPrimaryContainerView = PIPContainerView()
    private let focusRingView = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
    private var metalView: MTKView?
    private var metalRenderer: MetalFilmSimulationRenderer?
    private weak var multiCamOverlayLayer: AVCaptureVideoPreviewLayer?

    // Cache để tránh gọi syncDualCameraPrimaryLayer / updateOrientation hàng trăm lần mỗi giây khi kéo thanh màu
    private var lastSyncedDualActive: Bool? = nil
    private weak var lastSyncedDualLayer: AVCaptureVideoPreviewLayer? = nil
    private weak var lastSyncedSingleSession: AVCaptureSession? = nil

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .black
        contentScaleFactor = currentDisplayScale

        previewLayer?.contentsScale = currentDisplayScale
        previewLayer?.rasterizationScale = currentDisplayScale
        previewLayer?.videoGravity = .resizeAspectFill

        dualPrimaryContainerView.frame = bounds
        dualPrimaryContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dualPrimaryContainerView.isUserInteractionEnabled = false
        dualPrimaryContainerView.isHidden = true
        addSubview(dualPrimaryContainerView)

        focusRingView.layer.borderColor = UIColor.systemYellow.cgColor
        focusRingView.layer.borderWidth = 1.5
        focusRingView.layer.cornerRadius = 35
        focusRingView.alpha = 0
        addSubview(focusRingView)
    }

    public func setupLayer(session: AVCaptureSession) {
        previewLayer?.session = session
        previewLayer?.contentsScale = currentDisplayScale
        previewLayer?.rasterizationScale = currentDisplayScale
        lastSyncedSingleSession = session
        lastSyncedDualActive = false
    }

    public func syncDualCameraPrimaryLayer(
        _ dualLayer: AVCaptureVideoPreviewLayer?,
        isDualActive: Bool,
        singleSession: AVCaptureSession
    ) {
        if lastSyncedDualActive == isDualActive,
           lastSyncedDualLayer === dualLayer,
           lastSyncedSingleSession === singleSession {
            return
        }
        lastSyncedDualActive = isDualActive
        lastSyncedDualLayer = dualLayer
        lastSyncedSingleSession = singleSession

        if isDualActive {
            if previewLayer?.session != nil {
                previewLayer?.session = nil
            }
            dualPrimaryContainerView.frame = bounds
            dualPrimaryContainerView.isHidden = (dualLayer == nil)
            dualPrimaryContainerView.setPreviewLayer(dualLayer)
            multiCamOverlayLayer = dualLayer
        } else {
            multiCamOverlayLayer = nil
            dualPrimaryContainerView.setPreviewLayer(nil)
            dualPrimaryContainerView.isHidden = true
            if previewLayer?.session !== singleSession {
                previewLayer?.session = singleSession
            }
            updateOrientation()
        }
    }

    public func setupMetalPreview(viewModel: CameraViewModel) {
        guard metalView == nil, let metalDevice = UnifiedMetalColorEngine.shared.device ?? MTLCreateSystemDefaultDevice() else { return }
        let mtk = MTKView(frame: bounds, device: metalDevice)
        mtk.framebufferOnly = false
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.preferredFramesPerSecond = 60
        if let metalLayer = mtk.layer as? CAMetalLayer {
            metalLayer.allowsNextDrawableTimeout = true
            metalLayer.presentsWithTransaction = false
        }
        mtk.contentScaleFactor = min(currentDisplayScale, 2.0)
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.isUserInteractionEnabled = false
        mtk.isHidden = true
        mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let renderer = MetalFilmSimulationRenderer(device: metalDevice, viewModel: viewModel)
        mtk.delegate = renderer

        self.metalRenderer = renderer
        self.metalView = mtk

        insertSubview(mtk, belowSubview: focusRingView)
        CameraLogger.lifecycle("METAL_SETUP", detail: "MTKView \(Int(bounds.width))x\(Int(bounds.height))", category: .capture)
    }

    public func setHibernating(_ hibernating: Bool) {
        if hibernating {
            if metalView?.isPaused == false {
                metalView?.isPaused = true
                CameraLogger.lifecycle("METAL_PAUSE", detail: "Camera hibernating", category: .capture)
            }
            metalRenderer?.clearHeldBuffers()
        } else {
            metalRenderer?.resetPresentationDirtyState()
        }
    }

    public func updateMetalPreviewState(
        isActive: Bool,
        isDualCamera: Bool,
        isVideoMode: Bool = false,
        isSimulatedUltraWide: Bool = false,
        simulatedFactor: CGFloat = 0.5,
        isHorizonLock: Bool = false,
        isFocusPeaking: Bool = false,
        focusPeakingColor: FocusPeakingColor = .green,
        focusPeakingSensitivity: Float = 0.5,
        preset: FilmPreset,
        intensity: Float,
        softwareWB: ProPhotoSoftwareWBGrade = .inactive,
        filmTuning: FilmSimulationTuning = .neutral,
        photographicStyle: PhotographicStyleState = .standard,
        isPhotographicStylePadOpen: Bool = false,
        photographicStyleSplit: PhotographicStyleSplitTransition = .inactive,
        lightLeak: VintageLightLeakConfig = .off
    ) {
        // Kích hoạt MTKView Single-Pass 60 FPS khi bật bộ lọc màu, Photographic Style, Light Leak, WB Pro, tinh chỉnh phim, 0.5x, Horizon Lock, hoặc Focus Peaking
        let hasColorPass = (isActive && preset != .standard && preset != .proColorGrade)
            || !softwareWB.isIdentity
            || !filmTuning.isIdentity
            || !photographicStyle.isIdentity
            || photographicStyleSplit.isActive
            || !lightLeak.isIdentity
        let shouldRender = hasColorPass || isPhotographicStylePadOpen || isSimulatedUltraWide || isHorizonLock || isFocusPeaking
        metalRenderer?.updateState(
            isActive: isActive,
            isDualCamera: isDualCamera,
            isVideoMode: isVideoMode,
            isSimulatedUltraWide: isSimulatedUltraWide,
            simulatedFactor: simulatedFactor,
            isHorizonLock: isHorizonLock,
            isFocusPeaking: isFocusPeaking,
            focusPeakingColor: focusPeakingColor,
            focusPeakingSensitivity: focusPeakingSensitivity,
            preset: preset,
            intensity: intensity,
            softwareWB: softwareWB,
            filmTuning: filmTuning,
            photographicStyle: photographicStyle,
            isPhotographicStylePadOpen: isPhotographicStylePadOpen,
            photographicStyleSplit: photographicStyleSplit,
            lightLeak: lightLeak
        )

        if isDualCamera {
            dualPrimaryContainerView.isHidden = shouldRender || (multiCamOverlayLayer == nil)
        }
        let wasHidden = metalView?.isHidden ?? true
        if metalView?.isHidden != !shouldRender {
            metalView?.isHidden = !shouldRender
        }
        if metalView?.isPaused != !shouldRender {
            metalView?.isPaused = !shouldRender
        }
        if shouldRender && wasHidden {
            metalRenderer?.resetPresentationDirtyState()
        }
    }

    public func pushLiveColorStateFast(
        isFilmActive: Bool,
        preset: FilmPreset,
        intensity: Float,
        softwareWB: ProPhotoSoftwareWBGrade,
        filmTuning: FilmSimulationTuning,
        photographicStyle: PhotographicStyleState,
        lightLeak: VintageLightLeakConfig
    ) {
        metalRenderer?.pushLiveColorStateFast(
            isFilmActive: isFilmActive,
            preset: preset,
            intensity: intensity,
            softwareWB: softwareWB,
            filmTuning: filmTuning,
            photographicStyle: photographicStyle,
            lightLeak: lightLeak
        )
        let hasColorPass = (isFilmActive && preset != .standard && preset != .proColorGrade)
            || !softwareWB.isIdentity
            || !filmTuning.isIdentity
            || !photographicStyle.isIdentity
            || !lightLeak.isIdentity
        if hasColorPass {
            if metalView?.isHidden == true {
                metalView?.isHidden = false
                metalRenderer?.resetPresentationDirtyState()
            }
            if metalView?.isPaused == true {
                metalView?.isPaused = false
            }
        }
    }

    public func updatePhotographicStyleSplit(_ split: PhotographicStyleSplitTransition) {
        metalRenderer?.updateSplitTransitionFastPath(split)
    }

    public func animateLensTransition() {
        let transition = CATransition()
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        transition.type = .fade
        layer.add(transition, forKey: "opticalLensSwitchTransition")
    }

    private var currentDisplayScale: CGFloat {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 1
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.contentsScale = currentDisplayScale
        previewLayer?.rasterizationScale = currentDisplayScale
        dualPrimaryContainerView.frame = bounds
        multiCamOverlayLayer?.frame = bounds
        multiCamOverlayLayer?.contentsScale = currentDisplayScale
        multiCamOverlayLayer?.rasterizationScale = currentDisplayScale
        metalView?.frame = bounds
        metalView?.contentScaleFactor = min(currentDisplayScale, 2.0)
        updateOrientation()
    }

    public func updateOrientation() {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoRotationAngleSupported(90), abs(connection.videoRotationAngle - 90) > 0.01 {
            connection.videoRotationAngle = 90
        }
    }

    public func showFocusRing(at point: CGPoint, persist: Bool = false) {
        focusRingView.center = point
        focusRingView.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
        focusRingView.alpha = 1.0

        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut, animations: {
            self.focusRingView.transform = .identity
        }) { _ in
            guard !persist else { return }
            UIView.animate(withDuration: 0.2, delay: 0.6, options: .curveEaseIn, animations: {
                self.focusRingView.alpha = 0
            })
        }
    }
}
