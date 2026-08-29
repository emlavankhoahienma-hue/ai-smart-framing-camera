import UIKit

public final class HapticFeedbackService {
    public static let shared = HapticFeedbackService()
    
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactSoft = UIImpactFeedbackGenerator(style: .soft)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()
    
    private var lastSnapTime: TimeInterval = 0
    
    public init() {
        prepare()
    }
    
    public func prepare() {
        impactRigid.prepare()
        impactMedium.prepare()
        impactLight.prepare()
        impactSoft.prepare()
        selectionFeedback.prepare()
        notificationFeedback.prepare()
    }
    
    // MARK: - Magnetic Snap onto AI Target Circle
    public func triggerMagneticSnap() {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastSnapTime > 0.35 else { return } // Debounce to prevent haptic fatigue
        lastSnapTime = currentTime
        
        impactRigid.impactOccurred(intensity: 1.0)
    }
    
    // MARK: - Camera Shutter Click
    public func triggerShutterClick() {
        impactMedium.impactOccurred(intensity: 0.9)
    }
    
    // MARK: - Mode or Filter Selection
    public func triggerSelectionChange() {
        selectionFeedback.selectionChanged()
    }
    
    // MARK: - Success Notification
    public func triggerSuccess() {
        notificationFeedback.notificationOccurred(.success)
    }
    
    // MARK: - Guiding Proximity Pulse
    public func triggerProximityPulse(intensity: CGFloat) {
        impactSoft.impactOccurred(intensity: max(0.2, min(1.0, intensity)))
    }
    
    // MARK: - Tracking Lost Warning
    public func triggerTrackingLostWarning() {
        notificationFeedback.notificationOccurred(.warning)
    }
}
