import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd

public final class DeviceMotionService: @unchecked Sendable {
    public static let shared = DeviceMotionService()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    private var isTracking = false
    
    // 3D Spatial World Ray Anchor (Vector trong không gian 3D thế giới thực — Chuẩn Apple Measure App)
    private var worldTargetRay: SIMD3<Double>? = nil
    
    // Callback trả về tọa độ màn hình chuẩn hóa (0..1) của Target vàng bám dính 3D không gian thực
    public var onTargetProjected: ((CGPoint) -> Void)?
    
    // Camera Field of View constants for iPhone Wide Angle Lens
    // Horizontal FOV ~ 63° (0.55 rad half-angle), Vertical FOV ~ 78° (0.68 rad half-angle) in portrait
    private let tanHalfHFOV: Double = tan(63.0 * .pi / 360.0) // ~0.613
    private let tanHalfVFOV: Double = tan(78.0 * .pi / 360.0) // ~0.810
    
    public init() {
        motionQueue.name = "com.alignai.motionQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Pin 3D World Anchor at Target Screen Coordinate (Đo & Khóa vật thể như App Đo iPhone)
    public func pinWorldTarget(at screenPoint: CGPoint) {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        // Khởi động motion updates nếu chưa chạy
        if !isTracking {
            startTracking()
        }
        
        // Lấy attitude hiện tại của thiết bị để tạo Vector 3D trong không gian thế giới thực
        if let currentMotion = motionManager.deviceMotion {
            let rot = currentMotion.attitude.rotationMatrix
            
            // 1. Tính vector hướng tia trong hệ quy chiếu camera thiết bị
            let nx = (Double(screenPoint.x) - 0.5) * 2.0 * tanHalfHFOV
            let ny = -(Double(screenPoint.y) - 0.5) * 2.0 * tanHalfVFOV
            let camRay = simd_normalize(SIMD3<Double>(nx, ny, 1.0))
            
            // 2. Chuyển vector camera sang hệ tọa độ thế giới (World Frame) qua ma trận xoay R
            let worldX = rot.m11 * camRay.x + rot.m12 * camRay.y + rot.m13 * camRay.z
            let worldY = rot.m21 * camRay.x + rot.m22 * camRay.y + rot.m23 * camRay.z
            let worldZ = rot.m31 * camRay.x + rot.m32 * camRay.y + rot.m33 * camRay.z
            
            self.worldTargetRay = simd_normalize(SIMD3<Double>(worldX, worldY, worldZ))
        }
    }
    
    // MARK: - Start Tracking
    public func startTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        isTracking = true
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTracking else { return }
            guard let worldRay = self.worldTargetRay else { return }
            
            let rot = motion.attitude.rotationMatrix
            
            // Chiếu vector thế giới W ngược về hệ quy chiếu camera hiện tại qua R^T (Ma trận chuyển vị)
            let camX = rot.m11 * worldRay.x + rot.m21 * worldRay.y + rot.m31 * worldRay.z
            let camY = rot.m12 * worldRay.x + rot.m22 * worldRay.y + rot.m32 * worldRay.z
            let camZ = rot.m13 * worldRay.x + rot.m23 * worldRay.y + rot.m33 * worldRay.z
            
            // Nếu vật thể nằm phía trước camera (camZ > 0)
            if camZ > 0.05 {
                let projX = (camX / camZ) / (2.0 * self.tanHalfHFOV) + 0.5
                let projY = -(camY / camZ) / (2.0 * self.tanHalfVFOV) + 0.5
                
                let projectedPoint = CGPoint(
                    x: max(-0.5, min(1.5, projX)),
                    y: max(-0.5, min(1.5, projY))
                )
                
                DispatchQueue.main.async {
                    self.onTargetProjected?(projectedPoint)
                }
            } else {
                // Vật thể nằm phía sau lưng máy (góc lia quá 90 độ)
                let signX: CGFloat = camX >= 0 ? 1.5 : -0.5
                let signY: CGFloat = camY >= 0 ? -0.5 : 1.5
                DispatchQueue.main.async {
                    self.onTargetProjected?(CGPoint(x: signX, y: signY))
                }
            }
        }
    }
    
    // MARK: - Stop Tracking & Clear Anchor
    public func stopTracking() {
        isTracking = false
        worldTargetRay = nil
        motionManager.stopDeviceMotionUpdates()
    }
}
