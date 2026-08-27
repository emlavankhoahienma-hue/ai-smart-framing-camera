import Foundation
import CoreMotion
import CoreGraphics
import UIKit

public final class DeviceMotionService: @unchecked Sendable {
    public static let shared = DeviceMotionService()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    private var referenceAttitude: CMAttitude? = nil
    private var isTracking = false
    
    // Callback on main thread: (deltaX, deltaY) in normalized screen coordinates (-1.0 to 1.0)
    public var onMotionUpdate: ((CGFloat, CGFloat) -> Void)?
    
    private let sensitivityFactor: CGFloat = 0.85
    
    public init() {
        motionQueue.name = "com.alignai.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Start Tracking from Current Device Orientation
    public func startTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        referenceAttitude = nil
        isTracking = true
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTracking else { return }
            
            if self.referenceAttitude == nil {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                return
            }
            
            guard let ref = self.referenceAttitude else { return }
            
            let currentAttitude = motion.attitude
            currentAttitude.multiply(byInverseOf: ref)
            
            let yawDelta = CGFloat(currentAttitude.yaw)
            let pitchDelta = CGFloat(currentAttitude.pitch)
            let rollDelta = CGFloat(currentAttitude.roll)
            
            var deltaX: CGFloat = 0
            var deltaY: CGFloat = 0
            
            // Xử lý góc xoay thích ứng đa hướng (Portrait & Landscape ngang dọc đều mượt mà)
            let orientation = UIDevice.current.orientation
            switch orientation {
            case .landscapeLeft:
                deltaX = -pitchDelta * self.sensitivityFactor
                deltaY = -rollDelta * self.sensitivityFactor
            case .landscapeRight:
                deltaX = pitchDelta * self.sensitivityFactor
                deltaY = rollDelta * self.sensitivityFactor
            case .portraitUpsideDown:
                deltaX = -yawDelta * self.sensitivityFactor
                deltaY = pitchDelta * self.sensitivityFactor
            default: // .portrait, .unknown, .faceUp, .faceDown
                deltaX = yawDelta * self.sensitivityFactor
                deltaY = -pitchDelta * self.sensitivityFactor
            }
            
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
