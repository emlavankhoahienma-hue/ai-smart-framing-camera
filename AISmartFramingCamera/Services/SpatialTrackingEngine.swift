import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd

/// Động cơ Tracking Không Gian 6DOF Chuẩn AR (Spatial Visual-Inertial Fusion Engine)
/// Tương tự thuật toán bám mỏ neo không gian 3D của Apple ARKit và ứng dụng Đo (Measure)
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // MARK: - 3D Spatial Geometry & Camera Intrinsics
    // iPhone Wide Camera FOV ~65 độ -> Focal Length chuẩn hóa = 1 / (2 * tan(65° / 2)) ≈ 0.785
    private let baseFocalLength: Double = 0.785
    
    // Mỏ neo hướng vector 3D trong hệ quy chiếu thế giới (Unit Vector in World Space)
    private var anchorWorldVector: simd_double3? = nil
    private var initialAttitudeQuaternion: simd_quatd? = nil
    
    // Bộ lọc Kalman 2D State: [x, y, vx, vy]
    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var velocityX: Double = 0.0
    private var velocityY: Double = 0.0
    
    // Trạng thái hoạt động
    public private(set) var isTrackingActive: Bool = false
    public var activeSceneType: DetectedSceneType = .general
    private var currentZoom: Double = 1.0
    private var lastOpticalConfidence: Double = 1.0
    private var lastUpdateTime: CFTimeInterval = 0
    
    public var currentEstimatedScreenPoint: CGPoint {
        return CGPoint(x: stateX, y: stateY)
    }
    
    // Callbacks
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?
    
    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Khởi tạo Mỏ Neo Không Gian 3D (Pin 3D Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        self.currentZoom = Double(max(1.0, zoom))
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.velocityX = 0.0
        self.velocityY = 0.0
        self.lastOpticalConfidence = 1.0
        self.lastUpdateTime = CACurrentMediaTime()
        self.isTrackingActive = true
        
        CameraLogger.info("Khóa mỏ neo không gian 3D tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startMotionSensors()
    }
    
    public func updateZoomFactor(_ zoom: CGFloat) {
        self.currentZoom = Double(max(1.0, zoom))
    }
    
    // MARK: - Khởi động cảm biến 60Hz Gyroscope & Accelerometer
    private func startMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }
        
        anchorWorldVector = nil
        initialAttitudeQuaternion = nil
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS mượt mà
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            let q = motion.attitude.quaternion
            let currentQuat = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            
            // 1. Frame đầu tiên: Chuyển đổi toạ độ màn hình 2D thành Vector 3D trong không gian thực
            if self.anchorWorldVector == nil || self.initialAttitudeQuaternion == nil {
                self.initialAttitudeQuaternion = currentQuat
                
                // Ray unprojection từ 2D Screen sang 3D Camera Space
                let f = self.baseFocalLength * self.currentZoom
                let camX = (self.stateX - 0.5) / f
                let camY = -(self.stateY - 0.5) / f // Trục Y đảo ngược giữa UI và không gian 3D
                let camZ = 1.0
                
                let localRay = simd_normalize(simd_double3(camX, camY, camZ))
                // Nhân với ma trận quay để ra vector cố định trong World Space
                self.anchorWorldVector = currentQuat.act(localRay)
                return
            }
            
            // 2. Các frame tiếp theo: Chiếu lại vector 3D từ World Space sang Camera 2D theo góc quay mới
            guard let worldVec = self.anchorWorldVector else { return }
            
            // Vector mục tiêu trong hệ toạ độ Camera hiện tại: V_cam = Q_current^-1 * V_world
            let camRay = currentQuat.inverse.act(worldVec)
            
            // Nếu vật thể vẫn nằm phía trước camera (z > 0.05)
            if camRay.z > 0.05 {
                let f = self.baseFocalLength * self.currentZoom
                let projX = 0.5 + (camRay.x / camRay.z) * f
                let projY = 0.5 - (camRay.y / camRay.z) * f
                
                let clampedX = min(0.98, max(0.02, projX))
                let clampedY = min(0.98, max(0.02, projY))
                
                // Khi độ tin cậy quang học giảm (lia máy nhanh / thiếu sáng), dùng 3D Gyro làm động lực chính
                if self.lastOpticalConfidence <= 0.50 {
                    let alpha = 0.70
                    self.stateX = self.stateX * (1.0 - alpha) + clampedX * alpha
                    self.stateY = self.stateY * (1.0 - alpha) + clampedY * alpha
                    
                    let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                    DispatchQueue.main.async {
                        self.onSpatialTargetUpdated?(targetPoint, max(0.40, self.lastOpticalConfidence), .predicting)
                    }
                }
            }
        }
    }
    
    // MARK: - Dung hợp Dữ liệu Quang Học (Vision Optical Observation Update)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        self.lastOpticalConfidence = confidence
        
        let now = CACurrentMediaTime()
        let dt = lastUpdateTime > 0 ? min(0.1, now - lastUpdateTime) : (1.0 / 30.0)
        lastUpdateTime = now
        
        // Dynamic EKF Weighting cho Bầu trời / Mây / Chân trời (Sky / Infinite Horizon)
        // Ép trọng số quang học W_optical = 0.0, IMU = 1.0 vì bầu trời ở vô cực, thuần xoay góc
        if activeSceneType.isSkyOrInfiniteHorizon {
            if let motion = motionManager.deviceMotion, let worldVec = anchorWorldVector {
                let q = motion.attitude.quaternion
                let currentQuat = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
                let camRay = currentQuat.inverse.act(worldVec)
                if camRay.z > 0.05 {
                    let f = self.baseFocalLength * self.currentZoom
                    let projX = 0.5 + (camRay.x / camRay.z) * f
                    let projY = 0.5 - (camRay.y / camRay.z) * f
                    self.stateX = min(0.98, max(0.02, projX))
                    self.stateY = min(0.98, max(0.02, projY))
                    let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                    self.onSpatialTargetUpdated?(targetPoint, 0.95, .locked)
                    return
                }
            }
        }
        
        if let visualPoint = point, confidence >= 0.28 {
            let obsX = Double(visualPoint.x)
            let obsY = Double(visualPoint.y)
            
            // Lọc Outlier cực đoan (> 0.35 màn hình trong 1 frame)
            let jump = hypot(obsX - self.stateX, obsY - self.stateY)
            if jump > 0.35 && confidence < 0.70 {
                return
            }
            
            // Kalman-like Adaptive Smoothing Filter
            let kGain = max(0.40, min(0.85, confidence))
            let smoothX = self.stateX * (1.0 - kGain) + obsX * kGain
            let smoothY = self.stateY * (1.0 - kGain) + obsY * kGain
            
            if dt > 0.005 {
                let rawVx = (smoothX - self.stateX) / dt
                let rawVy = (smoothY - self.stateY) / dt
                self.velocityX = self.velocityX * 0.7 + max(-2.0, min(2.0, rawVx)) * 0.3
                self.velocityY = self.velocityY * 0.7 + max(-2.0, min(2.0, rawVy)) * 0.3
            }
            
            self.stateX = smoothX
            self.stateY = smoothY
            
            // Tái hiệu chuẩn lại Vector 3D không gian khi quang học có độ tin cậy cao
            if confidence > 0.60, let motion = motionManager.deviceMotion {
                let q = motion.attitude.quaternion
                let currentQuat = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
                let f = self.baseFocalLength * self.currentZoom
                let camX = (self.stateX - 0.5) / f
                let camY = -(self.stateY - 0.5) / f
                let localRay = simd_normalize(simd_double3(camX, camY, 1.0))
                self.anchorWorldVector = currentQuat.act(localRay)
            }
            
            if confidence > 0.60, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: CGPoint(x: self.stateX, y: self.stateY))
            }
            
            let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
            self.onSpatialTargetUpdated?(targetPoint, confidence, .locked)
        } else {
            if let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                if dt > 0.005 {
                    let rawVx = (Double(voPoint.x) - self.stateX) / dt
                    let rawVy = (Double(voPoint.y) - self.stateY) / dt
                    self.velocityX = self.velocityX * 0.7 + max(-2.0, min(2.0, rawVx)) * 0.3
                    self.velocityY = self.velocityY * 0.7 + max(-2.0, min(2.0, rawVy)) * 0.3
                }
                self.stateX = min(0.98, max(0.02, Double(voPoint.x)))
                self.stateY = min(0.98, max(0.02, Double(voPoint.y)))
                
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                self.onSpatialTargetUpdated?(targetPoint, 0.70, .locked)
            } else {
                // Rơi về Gyroscope 3D Anchor bù trừ chuyển động lia máy
                self.velocityX *= 0.90
                self.velocityY *= 0.90
                self.stateX = min(0.98, max(0.02, self.stateX + self.velocityX * dt))
                self.stateY = min(0.98, max(0.02, self.stateY + self.velocityY * dt))
                
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                self.onSpatialTargetUpdated?(targetPoint, 0.50, .predicting)
            }
        }
    }
    
    // MARK: - Dừng Tracking
    public func stopTracking() {
        isTrackingActive = false
        anchorWorldVector = nil
        initialAttitudeQuaternion = nil
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        CameraLogger.info("Đã dừng động cơ tracking không gian 6DOF", category: .tracking)
    }
}
