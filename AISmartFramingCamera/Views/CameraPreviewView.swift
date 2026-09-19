import SwiftUI
import AVFoundation

/// The sole gesture surface for the viewfinder. Decorative overlays do not intercept touches.
public struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel
    public func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = viewModel.cameraService.captureSession
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.5
        tap.require(toFail: hold)
        tap.require(toFail: pinch)
        [tap, pinch, hold].forEach { view.addGestureRecognizer($0) }
        return view
    }
    public func updateUIView(_ view: PreviewContainerView, context: Context) {
        context.coordinator.viewModel = viewModel
        view.updateOrientation()
    }
    public func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }
    public static func dismantleUIView(_ view: PreviewContainerView, coordinator: Coordinator) {
        view.previewLayer.session = nil
    }

    @MainActor public final class Coordinator: NSObject {
        var viewModel: CameraViewModel
        private var initialZoom: CGFloat = 1
        init(viewModel: CameraViewModel) { self.viewModel = viewModel }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? PreviewContainerView else { return }
            let point = gesture.location(in: view)
            let normalized = CGPoint(x: point.x / max(1, view.bounds.width), y: point.y / max(1, view.bounds.height))
            if viewModel.isAEAFLocked { viewModel.unlockAEAF() }
            else if case .targetPlaced = viewModel.aiSessionState { viewModel.pinTargetAndStartMotion(at: normalized) }
            else {
                viewModel.userDidTapToFocus(at: normalized, devicePoint: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            }
        }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? PreviewContainerView else { return }
            let point = gesture.location(in: view)
            let normalized = CGPoint(x: point.x / max(1, view.bounds.width), y: point.y / max(1, view.bounds.height))
            viewModel.lockAEAF(at: normalized, devicePoint: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                initialZoom = viewModel.displayZoom
                viewModel.isPinchingZoom = true
            case .changed, .ended, .cancelled, .failed: break
            default: return
            }
            let service = viewModel.cameraService
            let minimum = service.convertDeviceZoomToDisplayZoom(service.minZoom)
            let maximum = service.convertDeviceZoomToDisplayZoom(service.maxZoom)
            let zoom = max(minimum, min(initialZoom * gesture.scale, maximum))
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                viewModel.isPinchingZoom = false
                viewModel.finishZoomGesture(zoom)
            } else { viewModel.setZoomContinuous(zoom) }
        }
    }
}

@MainActor public final class PreviewContainerView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    public var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        previewLayer.videoGravity = .resizeAspectFill
    }
    public override func layoutSubviews() { super.layoutSubviews(); updateOrientation() }
    public func updateOrientation() {
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}
