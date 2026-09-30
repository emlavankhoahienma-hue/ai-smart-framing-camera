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
        return view
    }

    public func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.updateOrientation()
        if viewModel.previewLayer !== uiView.previewLayer {
            viewModel.previewLayer = uiView.previewLayer
        }
        let targetGravity: AVLayerVideoGravity = viewModel.captureMode.isVideo ? .resizeAspect : .resizeAspectFill
        if uiView.previewLayer?.videoGravity != targetGravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.20)
            uiView.previewLayer?.videoGravity = targetGravity
            CATransaction.commit()
        }
        uiView.updateMetalPreviewState(
            isActive: viewModel.isFilmSimulationActive,
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
    private weak var viewModel: CameraViewModel?
    private let stateLock = NSLock()
    private var isRenderingActive: Bool = false
    private var currentPreset: FilmPreset = .standard
    private var currentIntensity: Float = 1.0

    init?(device: MTLDevice, viewModel: CameraViewModel) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false
        ])
        self.viewModel = viewModel
        super.init()
    }

    func updateState(isActive: Bool, preset: FilmPreset, intensity: Float) {
        stateLock.lock()
        self.isRenderingActive = isActive && preset != .standard
        self.currentPreset = preset
        self.currentIntensity = intensity
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        let active = isRenderingActive
        let preset = currentPreset
        let intensity = currentIntensity
        stateLock.unlock()

        guard active, preset != .standard else { return }
        guard let vm = self.viewModel, let pixelBuffer = vm.latestCameraPixelBuffer() else { return }

        guard let currentDrawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        let inputCI = CIImage(cvPixelBuffer: pixelBuffer)
        let filteredCI = FilmFilterEngine.shared.applyPreset(to: inputCI, preset: preset, intensity: intensity) ?? inputCI

        let extent = filteredCI.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let scaleX = drawableSize.width / extent.width
        let scaleY = drawableSize.height / extent.height
        let scale = max(scaleX, scaleY)

        let scaledW = extent.width * scale
        let scaledH = extent.height * scale
        let ox = (drawableSize.width - scaledW) / 2.0
        let oy = (drawableSize.height - scaledH) / 2.0

        var transformed = filteredCI
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))

        transformed = transformed
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: drawableSize.height))

        let destinationBounds = CGRect(origin: .zero, size: drawableSize)

        ciContext.render(
            transformed,
            to: currentDrawable.texture,
            commandBuffer: commandBuffer,
            bounds: destinationBounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )

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

    private let focusRingView = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
    private var metalView: MTKView?
    private var metalRenderer: MetalFilmSimulationRenderer?

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

    public func setupMetalPreview(viewModel: CameraViewModel) {
        guard metalView == nil, let metalDevice = MTLCreateSystemDefaultDevice() else { return }
        let mtk = MTKView(frame: bounds, device: metalDevice)
        mtk.framebufferOnly = false
        mtk.colorPixelFormat = .bgra8Unorm
        mtk.preferredFramesPerSecond = 60
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

    public func updateMetalPreviewState(isActive: Bool, preset: FilmPreset, intensity: Float) {
        let shouldRender = isActive && preset != .standard
        metalRenderer?.updateState(isActive: shouldRender, preset: preset, intensity: intensity)

        if metalView?.isHidden != !shouldRender {
            metalView?.isHidden = !shouldRender
        }
        if metalView?.isPaused != !shouldRender {
            metalView?.isPaused = !shouldRender
        }
    }

    private var currentDisplayScale: CGFloat {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 1
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.contentsScale = currentDisplayScale
        previewLayer?.rasterizationScale = currentDisplayScale
        metalView?.frame = bounds
        updateOrientation()
    }

    public func updateOrientation() {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(90) {
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
