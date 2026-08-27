import Foundation
import CoreMotion
import CoreGraphics

public final class DeviceMotionService: @unchecked Sendable {
    public static let shared = DeviceMotionService()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    private var referenceAttitude: CMAttitude? = nil
    private var isTracking = false
    
    // Callback on main thread: (deltaX, deltaY) in normalized screen coordinates (-1.0 to 1.0)
    public var onMotionUpdate: ((CGFloat, CGFloat) -> Void)?
    
    // Camera Field of View factor (~65 degrees horizontal FOV on iPhone wide lens)
    // 1 radian ~ 57.3 deg -> normalized FOV factor ~ 0.88
    private let sensitivityFactor: CGFloat = 0.85
    
    public init() {
        motionQueue.name = "com.aismartframing.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Start Tracking from Current Device Orientation
    public func startTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        referenceAttitude = nil
        isTracking = true
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz smooth updates
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTracking else { return }
            
            if self.referenceAttitude == nil {
                // First frame: capture baseline attitude
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                return
            }
            
            guard let ref = self.referenceAttitude else { return }
            
            // Compute relative rotation from reference
            let currentAttitude = motion.attitude
            currentAttitude.multiply(byInverseOf: ref)
            
            // In portrait orientation:
            // yaw (rotation around vertical axis) -> horizontal movement (X)
            // pitch (tilt up/down around lateral axis) -> vertical movement (Y)
            let yawDelta = CGFloat(currentAttitude.yaw)
            let pitchDelta = CGFloat(currentAttitude.pitch)
            
            // Convert angle deltas to normalized screen coordinate shifts
            let deltaX = yawDelta * self.sensitivityFactor
            let deltaY = -pitchDelta * self.sensitivityFactor
            
            DispatchQueue.main.async {
                self.onMotionUpdate?(deltaX, deltaY)
            }
        }
    }
    
    // MARK: - Stop Tracking
    public func stopTracking() {
        isTracking = false
        referenceAttitude = nil
        motionManager.stopDeviceMotionUpdates()
    }
}
