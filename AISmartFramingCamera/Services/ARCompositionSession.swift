import Foundation
import Combine
import UIKit

public final class ARCompositionSession: NSObject, ObservableObject {
    public static let shared = ARCompositionSession()
    
    @Published public var isARSupported: Bool = false
    @Published public var isTrackingNormal: Bool = true
    @Published public var trackingWarningText: String? = nil
    @Published public var isTargetBehindCamera: Bool = false
    
    public var onTargetProjected: ((CGPoint, Bool, String?) -> Void)?
    
    public override init() {
        super.init()
    }
    
    // MARK: - Start / Pause Session (Vô hiệu hóa ARSession.run để không tranh quyền camera của AVCaptureSession)
    public func startSession() {
        // Không chạy ARWorldTrackingConfiguration để AVCaptureVideoPreviewLayer không bị đơ
    }
    
    public func pauseSession() {
        // No-op
    }
    
    public func pinTarget(at normalizedPoint: CGPoint, viewportSize: CGSize, orientation: UIInterfaceOrientation = .portrait) {
        // No-op: Việc bám target do Vision Optical Tracking + Gyroscope 60Hz phụ trách 100%
    }
    
    public func clearTarget() {
        self.trackingWarningText = nil
        self.isTargetBehindCamera = false
    }
}
