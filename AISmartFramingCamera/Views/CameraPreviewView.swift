import SwiftUI
import AVFoundation

public struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel
    
    public func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.setupLayer(session: viewModel.cameraService.captureSession)
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)
        
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.delegate = context.coordinator
        view.addGestureRecognizer(pinchGesture)
        
        let longPressGesture = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = context.coordinator
        view.addGestureRecognizer(longPressGesture)
        
        return view
    }
    
    public func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.updateOrientation()
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
            
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            parent.viewModel.cameraService.focusAndExpose(at: devicePoint)
            view.showFocusRing(at: location)
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                initialZoom = parent.viewModel.currentZoom
            }
            let newZoom = max(1.0, min(initialZoom * gesture.scale, 10.0))
            parent.viewModel.setZoom(newZoom)
        }
        
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = gesture.view as? PreviewContainerView else { return }
            let location = gesture.location(in: view)
            let normalizedPoint = CGPoint(x: location.x / view.bounds.width, y: location.y / view.bounds.height)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            parent.viewModel.lockAEAF(at: normalizedPoint, devicePoint: devicePoint)
            view.showFocusRing(at: location, persist: true)
        }
        
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

@MainActor
public class PreviewContainerView: UIView {
    public let previewLayer = AVCaptureVideoPreviewLayer()
    private let focusRingView = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        
        focusRingView.layer.borderColor = UIColor.systemYellow.cgColor
        focusRingView.layer.borderWidth = 1.5
        focusRingView.layer.cornerRadius = 35
        focusRingView.alpha = 0
        addSubview(focusRingView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func setupLayer(session: AVCaptureSession) {
        previewLayer.session = session
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateOrientation()
    }
    
    public func updateOrientation() {
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
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
