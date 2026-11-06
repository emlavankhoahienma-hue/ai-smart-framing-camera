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
        viewModel.previewLayer = view.previewLayer
        viewModel.previewContainerView = view
        return view
    }

    public func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        viewModel.previewContainerView = uiView
        let isDual = viewModel.isDualCameraActive || viewModel.cameraService.isDualCameraActive
        let dualLayer = isDual ? viewModel.cameraService.multiCamPrimaryPreviewLayer : nil
        uiView.syncDualCameraPrimaryLayer(
            dualLayer,
            isDualActive: isDual,
            singleSession: viewModel.cameraService.captureSession
        )
        uiView.updateOrientation()
        let activeLayer = dualLayer ?? uiView.previewLayer
        if viewModel.previewLayer !== activeLayer {
            viewModel.previewLayer = activeLayer
        }
        // Che do Quay Video (16:9 / 9:16): dung .resizeAspect trong khung ngam de hien thi tron ven 100% khung hinh 1.0x dung nhu file video quay ra, khong bi phong dai 1.33x do .resizeAspectFill cat vao khung 4:3!
        let targetGravity: AVLayerVideoGravity = (viewModel.captureMode.isVideo && !isDual && !viewModel.isSimulatedUltraWideActive) ? .resizeAspect : .resizeAspectFill
        if uiView.previewLayer?.videoGravity != targetGravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.20)
            uiView.previewLayer?.videoGravity = targetGravity
            CATransaction.commit()
        }
        uiView.updateMetalPreviewState(
            isActive: viewModel.isFilmSimulationActive,
            isDualCamera: isDual,
            isVideoMode: viewModel.captureMode.isVideo && !isDual && !viewModel.isSimulatedUltraWideActive,
            isSimulatedUltraWide: viewModel.isSimulatedUltraWideActive,
            simulatedFactor: viewModel.simulatedUltraWideFactor,
            isHorizonLock: viewModel.isHorizonLockEnabled,
            isFocusPeaking: viewModel.isFocusPeakingEnabled,
            focusPeakingColor: viewModel.focusPeakingColor,
            preset: viewModel.selectedFilmPreset,
            intensity: Float(viewModel.filmSimulationIntensity)
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
            if gesture.state == .began {
                initialZoom = parent.viewModel.displayZoom
            }
            let minDisplay = parent.viewModel.cameraService.convertDeviceZoomToDisplayZoom(parent.viewModel.cameraService.minZoom)
            let maxDisplay = parent.viewModel.cameraService.convertDeviceZoomToDisplayZoom(parent.viewModel.cameraService.maxZoom)
            let newDisplayZoom = max(minDisplay, min(initialZoom * gesture.scale, maxDisplay))

            if gesture.state == .ended || gesture.state == .cancelled {
                parent.viewModel.finishZoomGesture(newDisplayZoom)
            } else {
                parent.viewModel.setZoomContinuous(newDisplayZoom)
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

        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

// MARK: - Metal Film Simulation Realtime Renderer (Zero-Lag Core Image to Metal)
final class MetalFilmSimulationRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
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
    private var currentPreset: FilmPreset = .standard
    private var currentIntensity: Float = 1.0

    // Frame cache to avoid redundant filter graphs on idle or identical frames
    private var lastProcessedBuffer: CVPixelBuffer? = nil
    private var lastPresentedOnce: Bool = false
    private var lastFilteredCI: CIImage? = nil
    private var lastPreset: FilmPreset = .standard
    private var lastIntensity: Float = 1.0
    private var lastFilterActive: Bool = false
    private var lastVideoAspectFit: Bool = false
    private var lastDrawableSize: CGSize = .zero
    private var lastPeakingActive: Bool = false
    private var lastPeakingColor: FocusPeakingColor = .green

    init?(device: MTLDevice, viewModel: CameraViewModel) {
        self.device = device
        let queue = UltraWideWarpEngine.live.commandQueue ?? device.makeCommandQueue()!
        self.commandQueue = queue
        self.ciContext = CIContext(mtlCommandQueue: queue, options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false
        ])
        self.viewModel = viewModel
        super.init()
    }

    func updateState(isActive: Bool, isDualCamera: Bool, isVideoMode: Bool, isSimulatedUltraWide: Bool = false, simulatedFactor: CGFloat = 0.5, isHorizonLock: Bool = false, isFocusPeaking: Bool = false, focusPeakingColor: FocusPeakingColor = .green, preset: FilmPreset, intensity: Float) {
        stateLock.lock()
        self.isFilmFilterActive = isActive && (preset != .standard)
        self.isFocusPeaking = isFocusPeaking
        self.focusPeakingColor = focusPeakingColor
        self.isRenderingActive = self.isFilmFilterActive || isSimulatedUltraWide || isHorizonLock || isFocusPeaking
        self.isDualCameraMode = isDualCamera
        self.isVideoAspectFit = isVideoMode
        self.isSimulatedUltraWide = isSimulatedUltraWide
        self.simulatedFactor = simulatedFactor
        self.isHorizonLock = isHorizonLock
        self.currentPreset = preset
        self.currentIntensity = intensity
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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
        let preset = currentPreset
        let intensity = currentIntensity
        stateLock.unlock()

        guard shouldRender else { return }
        guard let vm = self.viewModel,
              let pixelBuffer = vm.cameraService.currentMultiCamPixelBuffer() ?? vm.latestCameraPixelBuffer() else { return }

        let effectivePreset = preset.isAIFullAuto ? (vm.aiRecommendedPreset ?? vm.detectedScene.recommendedFilter) : preset

        // Khong co frame camera moi + moi tham so giong het => khong render lai (tranh 60 lan/giay chay lai graph CoreImage)
        if !isHL && !isPeaking && !simUW,
           pixelBuffer === lastProcessedBuffer,
           filmActive == lastFilterActive,
           videoAspectFit == lastVideoAspectFit,
           effectivePreset == lastPreset,
           abs(intensity - lastIntensity) < 0.005,
           view.drawableSize == lastDrawableSize,
           lastFilteredCI != nil,
           lastPresentedOnce {
            return
        }

        guard let currentDrawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        let finalImageToRender: CIImage

        // Optimization: reuse last filtered image if buffer, preset, intensity and size haven't changed (disable when horizon lock or peaking is active)
        if !isHL && !isPeaking,
           isPeaking == lastPeakingActive,
           peakingColor == lastPeakingColor,
           pixelBuffer === lastProcessedBuffer,
           filmActive == lastFilterActive,
           videoAspectFit == lastVideoAspectFit,
           effectivePreset == lastPreset,
           abs(intensity - lastIntensity) < 0.005,
           drawableSize == lastDrawableSize,
           let cached = lastFilteredCI {
            finalImageToRender = cached
        } else {
            let inputCI = CIImage(cvPixelBuffer: pixelBuffer)
            let rawExtent = inputCI.extent
            guard rawExtent.width > 0, rawExtent.height > 0 else { return }

            let scaleX = drawableSize.width / rawExtent.width
            let scaleY = drawableSize.height / rawExtent.height
            let scale = (videoAspectFit && !simUW) ? min(scaleX, scaleY) : max(scaleX, scaleY)

            let scaledW = rawExtent.width * scale
            let scaledH = rawExtent.height * scale
            let ox = (drawableSize.width - scaledW) / 2.0
            let oy = (drawableSize.height - scaledH) / 2.0

            let transformedCI: CIImage
            if isHL {
                let motionParams = DeviceMotionService.shared.currentHorizonParams()
                let rollAngle = CGFloat(-motionParams.roll)
                let zoomFactor = CGFloat(motionParams.zoom)
                let totalScale = scale * zoomFactor
                let shakeOffsetX = CGFloat(motionParams.shakeX) * drawableSize.width
                let shakeOffsetY = CGFloat(motionParams.shakeY) * drawableSize.height

                // 1. Dịch tâm của inputCI về (0,0)
                // 2. Xoay ngược góc nghiêng của máy (-rollAngle)
                // 3. Phóng theo tỷ lệ bù góc nghiêng đồng nhất 100% theo pixel vuông (0% méo hình)
                // 4. Dịch về tâm drawableSize và bù rung tay vi mô
                let horizonTransform = CGAffineTransform(translationX: -rawExtent.midX, y: -rawExtent.midY)
                    .concatenating(CGAffineTransform(rotationAngle: rollAngle))
                    .concatenating(CGAffineTransform(scaleX: totalScale, y: totalScale))
                    .concatenating(CGAffineTransform(translationX: (drawableSize.width / 2.0) + shakeOffsetX,
                                                     y: (drawableSize.height / 2.0) + shakeOffsetY))
                transformedCI = inputCI.transformed(by: horizonTransform)
            } else {
                let centerTransform = CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: ox, y: oy))
                transformedCI = inputCI.transformed(by: centerTransform)
            }

            let viewportBounds = CGRect(origin: .zero, size: drawableSize)
            let bgBlack = Self.infiniteBlackCI.cropped(to: viewportBounds)
            let viewportCI = transformedCI.composited(over: bgBlack).cropped(to: viewportBounds)
            let unwarpedCI: CIImage = simUW ? UltraWideWarpEngine.shared.applySimulatedUltraWide(
                to: viewportCI,
                factor: simFactor
            ) : viewportCI

            let filteredCI: CIImage
            if filmActive {
                let maxWorkingDim: CGFloat = 1440.0
                let longSide = max(drawableSize.width, drawableSize.height)
                let workingScale: CGFloat = (longSide > maxWorkingDim && longSide > 0) ? (maxWorkingDim / longSide) : 1.0
                let workingInput = workingScale < 0.999
                    ? unwarpedCI.transformed(by: CGAffineTransform(scaleX: workingScale, y: workingScale))
                    : unwarpedCI
                var workingOut = FilmFilterEngine.shared.applyPreset(
                    to: workingInput,
                    preset: effectivePreset,
                    intensity: intensity,
                    isRealtimePreview: true
                ) ?? workingInput
                if preset.isAIFullAuto, let aiParams = vm.currentAIColorParams {
                    workingOut = FilmFilterEngine.shared.applyAIColorParameters(to: workingOut, params: aiParams) ?? workingOut
                }
                if workingScale < 0.999 {
                    let invScale = 1.0 / workingScale
                    filteredCI = workingOut
                        .transformed(by: CGAffineTransform(scaleX: invScale, y: invScale))
                        .cropped(to: viewportBounds)
                } else {
                    filteredCI = workingOut
                }
            } else {
                filteredCI = unwarpedCI
            }
            let peakedCI: CIImage
            if isPeaking {
                peakedCI = FocusPeakingEngine.shared.applyLaserFocusPeaking(to: filteredCI, color: peakingColor)
            } else {
                peakedCI = filteredCI
            }
            finalImageToRender = peakedCI

            lastProcessedBuffer = pixelBuffer
            lastFilteredCI = finalImageToRender
            lastFilterActive = filmActive
            lastVideoAspectFit = videoAspectFit
            lastPreset = effectivePreset
            lastIntensity = intensity
            lastDrawableSize = drawableSize
            lastPeakingActive = isPeaking
            lastPeakingColor = peakingColor
        }

        let destinationBounds = CGRect(origin: .zero, size: drawableSize)

        ciContext.render(
            finalImageToRender,
            to: currentDrawable.texture,
            commandBuffer: commandBuffer,
            bounds: destinationBounds,
            colorSpace: sRGBColorSpace
        )

        lastPresentedOnce = true
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
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
    }

    public func syncDualCameraPrimaryLayer(
        _ dualLayer: AVCaptureVideoPreviewLayer?,
        isDualActive: Bool,
        singleSession: AVCaptureSession
    ) {
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
        guard metalView == nil, let metalDevice = MTLCreateSystemDefaultDevice() else { return }
        let mtk = MTKView(frame: bounds, device: metalDevice)
        mtk.framebufferOnly = false
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.preferredFramesPerSecond = 60
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
    }

    public func updateMetalPreviewState(isActive: Bool, isDualCamera: Bool, isVideoMode: Bool = false, isSimulatedUltraWide: Bool = false, simulatedFactor: CGFloat = 0.5, isHorizonLock: Bool = false, isFocusPeaking: Bool = false, focusPeakingColor: FocusPeakingColor = .green, preset: FilmPreset, intensity: Float) {
        // Kich hoat MTKView khi bat bo loc mau, simulated 0.5x, Horizon Lock 360 do, hoac Focus Peaking 60 FPS
        let shouldRender = (isActive && preset != .standard) || isSimulatedUltraWide || isHorizonLock || isFocusPeaking
        metalRenderer?.updateState(isActive: isActive, isDualCamera: isDualCamera, isVideoMode: isVideoMode, isSimulatedUltraWide: isSimulatedUltraWide, simulatedFactor: simulatedFactor, isHorizonLock: isHorizonLock, isFocusPeaking: isFocusPeaking, focusPeakingColor: focusPeakingColor, preset: preset, intensity: intensity)

        if isDualCamera {
            dualPrimaryContainerView.isHidden = shouldRender || (multiCamOverlayLayer == nil)
        }
        if metalView?.isHidden != !shouldRender {
            metalView?.isHidden = !shouldRender
        }
        if metalView?.isPaused != !shouldRender {
            metalView?.isPaused = !shouldRender
        }
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
        if connection.isVideoRotationAngleSupported(90) {
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
