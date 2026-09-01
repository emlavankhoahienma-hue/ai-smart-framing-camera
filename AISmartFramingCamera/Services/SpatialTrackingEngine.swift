import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd

/// Động cơ Tracking Không Gian Chuẩn Xác Tuyệt Đối (Unified Spatial Visual-Inertial Fusion Engine)
/// Khóa chặt mỏ neo vào vật thể thực tế, bù trừ chuyển động lia máy với cực tính chuẩn xác 100%
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Mốc tọa độ quán tính khi khóa target
    private var referenceAttitude: CMAttitude? = nil
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    
    // Tọa độ mục tiêu hiện tại trên màn hình UI (0.0 đến 1.0)
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
    
    // Hệ số FOV camera chuẩn hóa (~65 độ FOV trên ống kính Wide iPhone)
    private let sensitivityFactor: Double = 0.88
    
    public var currentEstimatedScreenPoint: CGPoint {
        return CGPoint(x: stateX, y: stateY)
    }
    
    // Callback duy nhất truyền tọa độ về ViewModel
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?
    
    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Khởi tạo Mỏ Neo Không Gian (Pin Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        self.currentZoom = Double(max(1.0, zoom))
        self.anchorInitialPoint = screenPoint
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.velocityX = 0.0
        self.velocityY = 0.0
        self.lastOpticalConfidence = 1.0
        self.lastUpdateTime = CACurrentMediaTime()
        self.referenceAttitude = nil
        self.isTrackingActive = true
        
        CameraLogger.info("Khóa mỏ neo không gian tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
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
        
        referenceAttitude = nil
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            // Frame đầu tiên: Khóa mốc attitude cơ sở
            if self.referenceAttitude == nil {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                return
            }
            
            guard let ref = self.referenceAttitude else { return }
            
            // Tính góc quay tương đối chính xác tuyệt đối từ mốc ban đầu (Absolute Attitude Delta)
            let currentAttitude = motion.attitude
            currentAttitude.multiply(byInverseOf: ref)
            
            let yawDelta = Double(currentAttitude.yaw)
            let pitchDelta = Double(currentAttitude.pitch)
            
            // Cực tính chuyển động (Motion Polarity):
            // - Khi lia máy sang PHẢI (yaw > 0) -> Vật thể trên màn hình di chuyển sang TRÁI (projX giảm về tâm 0.5)
            // - Khi ngửa máy lên TRÊN (pitch > 0) -> Vật thể trên màn hình di chuyển xuống DƯỚI (projY tăng về tâm 0.5)
            let zoomScale = self.currentZoom
            let projX = Double(self.anchorInitialPoint.x) - yawDelta * self.sensitivityFactor * zoomScale
            let projY = Double(self.anchorInitialPoint.y) + pitchDelta * self.sensitivityFactor * zoomScale
            
            let clampedX = min(0.98, max(0.02, projX))
            let clampedY = min(0.98, max(0.02, projY))
            
            // Khi quang học tạm thời mờ/khuất (confidence <= 0.45), Gyroscope giữ mỏ neo vững vàng
            if self.lastOpticalConfidence <= 0.45 {
                let alpha = 0.75
                self.stateX = self.stateX * (1.0 - alpha) + clampedX * alpha
                self.stateY = self.stateY * (1.0 - alpha) + clampedY * alpha
                
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                DispatchQueue.main.async {
                    self.onSpatialTargetUpdated?(targetPoint, max(0.45, self.lastOpticalConfidence), .predicting)
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
        
        if let visualPoint = point, confidence >= 0.25 {
            let obsX = Double(visualPoint.x)
            let obsY = Double(visualPoint.y)
            
            // Lọc outlier cực đoan (> 0.40 màn hình trong 1 frame)
            let jump = hypot(obsX - self.stateX, obsY - self.stateY)
            if jump > 0.40 && confidence < 0.70 {
                return
            }
            
            // Quang học là Ground Truth: Bám trực tiếp vào vật thể thực tế
            let kGain = max(0.70, min(0.90, confidence))
            let smoothX = self.stateX * (1.0 - kGain) + obsX * kGain
            let smoothY = self.stateY * (1.0 - kGain) + obsY * kGain
            
            if dt > 0.005 {
                let rawVx = (smoothX - self.stateX) / dt
                let rawVy = (smoothY - self.stateY) / dt
                self.velocityX = self.velocityX * 0.6 + max(-2.0, min(2.0, rawVx)) * 0.4
                self.velocityY = self.velocityY * 0.6 + max(-2.0, min(2.0, rawVy)) * 0.4
            }
            
            self.stateX = smoothX
            self.stateY = smoothY
            
            // Tự động tái hiệu chuẩn lại mốc Gyro khi quang học bám rất tốt
            if confidence > 0.65, let motion = motionManager.deviceMotion {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                self.anchorInitialPoint = CGPoint(x: self.stateX, y: self.stateY)
            }
            
            if confidence > 0.60, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: CGPoint(x: self.stateX, y: self.stateY))
            }
            
            let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
            self.onSpatialTargetUpdated?(targetPoint, confidence, .locked)
        } else {
            // Khi quang học tạm thời mất nét: Thử Visual Odometry trước
            if let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                self.stateX = min(0.98, max(0.02, Double(voPoint.x)))
                self.stateY = min(0.98, max(0.02, Double(voPoint.y)))
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                self.onSpatialTargetUpdated?(targetPoint, 0.70, .locked)
            } else {
                // Gyroscope quán tính duy trì vị trí
                self.velocityX *= 0.85
                self.velocityY *= 0.85
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
        referenceAttitude = nil
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        CameraLogger.info("Đã dừng động cơ tracking không gian", category: .tracking)
    }
}
