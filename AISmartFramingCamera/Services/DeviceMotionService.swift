import Foundation
import CoreMotion
import CoreGraphics
import UIKit

public final class DeviceMotionService: @unchecked Sendable {
    public static let shared = DeviceMotionService()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    private var isTracking = false
    
    // Accumulated deltas
    private var accumulatedDeltaX: CGFloat = 0
    private var accumulatedDeltaY: CGFloat = 0
    
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
        
        isTracking = true
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz smooth updates
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTracking else { return }
            
            let dt = self.motionManager.deviceMotionUpdateInterval
            let rotationRate = motion.rotationRate
            
            // Vì UI bị khóa ở Portrait, cảm biến Gyro luôn mapping cố định 1-1 với tọa độ màn hình
            // rotY (Roll vật lý): Quay quanh trục dọc điện thoại -> Di chuyển ảnh theo trục X (ngang màn hình)
            // rotX (Pitch vật lý): Quay quanh trục ngang điện thoại -> Di chuyển ảnh theo trục Y (dọc màn hình)
            
            let rotX = CGFloat(rotationRate.x)
            let rotY = CGFloat(rotationRate.y)
            
            let dX = -rotY * dt
            let dY = rotX * dt
            
            self.accumulatedDeltaX += dX * self.sensitivityFactor
            self.accumulatedDeltaY += dY * self.sensitivityFactor
            
            let totalX = self.accumulatedDeltaX
            let totalY = self.accumulatedDeltaY
            
            DispatchQueue.main.async {
                self.onMotionUpdate?(totalX, totalY)
            }
        }
    }
    
    // MARK: - Stop Tracking
    public func stopTracking() {
        isTracking = false
        motionManager.stopDeviceMotionUpdates()
    }
}
