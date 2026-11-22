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
    private var lastPadTickTime: TimeInterval = 0
    
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
    
    // MARK: - Camera Shutter Click (Mechanical Audio + Synchronized CoreHaptics)
    public func triggerShutterClick() {
        MechanicalShutterEngine.shared.fireShutter()
    }

    // MARK: - Shutter Half-Press Mechanical Detent
    public func triggerShutterHalfPress() {
        MechanicalShutterEngine.shared.fireShutterHalfPress()
    }

    // MARK: - Aperture / Zoom Mechanical Dial Tick
    public func triggerMechanicalDialTick() {
        MechanicalShutterEngine.shared.fireMechanicalDialTick()
    }

    // MARK: - Studio Countdown Beep + Haptic
    public func triggerCountdownTick(secondsLeft: Int) {
        MechanicalShutterEngine.shared.fireCountdownTick(secondsLeft: secondsLeft)
    }

    // MARK: - Photobooth Studio Flash Pop
    public func triggerPhotoboothFlashPop() {
        MechanicalShutterEngine.shared.fireStudioFlashPop()
    }
    
    // MARK: - Light Tap / Zoom Snap
    public func triggerLight() {
        impactLight.impactOccurred(intensity: 0.7)
    }

    // MARK: - Medium Center Origin Detent (Photographic Styles Control Pad)
    public func triggerMedium() {
        impactMedium.impactOccurred(intensity: 0.78)
    }

    // MARK: - Throttled Micro-Detent Grid Tick (>= 35ms debounce)
    public func triggerPadGridTick() {
        let now = CACurrentMediaTime()
        guard now - lastPadTickTime >= 0.035 else { return }
        lastPadTickTime = now
        selectionFeedback.selectionChanged()
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

    // MARK: - Error Notification
    public func triggerError() {
        notificationFeedback.notificationOccurred(.error)
    }
}
