import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Động cơ Tracking Không Gian Chuyên Dụng Đi Đường (Street & Commute Spatial Tracking Engine)
/// Tách biệt 100% với động cơ mặc định, được thiết kế chuyên biệt cho môi trường rung chấn cao (xe máy, ô tô, xe buýt, đi bộ đường gồ ghề).
///
/// ĐẶC TÍNH & THUẬT TOÁN:
/// 1. Deadband Suppression: Triệt tiêu hoàn toàn rung chấn vi mô (micro-vibrations 15-50Hz) từ động cơ xe và mặt đường.
/// 2. Rigid Anchor Clamping (Lực ghì mỏ neo siêu cứng): Tăng lực bám dính, giới hạn tối đa tốc độ dịch chuyển mỗi frame (Velocity Clamping).
/// 3. Shockwave & Pothole Filtering: Lọc bỏ xung gia tốc đột ngột từ ổ gà / gờ giảm tốc.
/// 4. Spatial Gate: Miễn nhiễm với vật thể lướt qua (xe chạy ngang, vạch kẻ đường, cây bên đường).
///
/// NHƯỢC ĐIỂM (Trade-off):
/// - Quán tính rất nặng: Khi người dùng cố tình lia máy nhanh, target sẽ có độ trễ ghì lại vị trí cũ một nhịp rồi mới trôi theo mượt mà.
/// - Độ linh hoạt thấp hơn chế độ thường: Không tự động nhảy sang mục tiêu mới nếu người dùng lia hẳn sang hướng khác.
public final class StreetSpatialTrackingEngine: @unchecked Sendable {
    public static let shared = StreetSpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Tọa độ mục tiêu chuẩn hóa trên màn hình (0.0 đến 1.0)
    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    
    // Bộ nhớ lọc rung chấn quán tính
    private var lastRawGyroX: Double = 0.0
    private var lastRawGyroY: Double = 0.0
    private var smoothedRotationX: Double = 0.0
    private var smoothedRotationY: Double = 0.0
    
    // Trạng thái hoạt động
    public private(set) var isTrackingActive: Bool = false
    public var activeSceneType: DetectedSceneType = .general
    private var currentZoom: Double = 1.0
    private var lastOpticalConfidence: Double = 1.0
    private var lastUpdateTime: CFTimeInterval = 0
    private var lastMotionTime: CFTimeInterval = 0
    private var deadReckoningFrameCount: Int = 0
    private var isLowTextureAnchor: Bool = false
    
    // Callback truyền tọa độ về ViewModel
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?
    
    public var currentEstimatedScreenPoint: CGPoint {
        return CGPoint(x: stateX, y: stateY)
    }
    
    public init() {
        motionQueue.name = "com.alignai.streetSpatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    public func setLowTextureFlag(_ isLowTexture: Bool) {
        self.isLowTextureAnchor = isLowTexture
    }
    
    public func updateZoomFactor(_ zoom: CGFloat) {
        self.currentZoom = Double(max(1.0, zoom))
    }
    
    // MARK: - 1. Khóa Mỏ Neo Siêu Bám (Street Anchor Lock)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        self.currentZoom = Double(max(1.0, zoom))
        self.anchorInitialPoint = screenPoint
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.lastOpticalConfidence = 1.0
        self.deadReckoningFrameCount = 0
        self.lastUpdateTime = CACurrentMediaTime()
        self.lastRawGyroX = 0.0
        self.lastRawGyroY = 0.0
        self.smoothedRotationX = 0.0
        self.smoothedRotationY = 0.0
        self.isTrackingActive = true
        
        CameraLogger.info("🚗 [Street Mode] Khóa mỏ neo đi đường tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startStreetMotionSensors()
    }
    
    // MARK: - 2. Cảm Biến Quán Tính Đi Đường (Heavy Inertial Gyro & Pothole Filtering)
    private func startStreetMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }
        
        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            let now = CACurrentMediaTime()
            let dt = self.lastMotionTime > 0 ? min(0.04, max(0.005, now - self.lastMotionTime)) : (1.0 / 60.0)
            self.lastMotionTime = now
            
            let rawRateY = motion.rotationRate.y
            let rawRateX = motion.rotationRate.x
            
            // --- THUẬT TOÁN 1: Lọc Xung Gia Tốc Đột Ngột (Ổ gà / Gờ giảm tốc / Rung xe máy) ---
            let jerkY = abs(rawRateY - self.lastRawGyroY) / dt
            let jerkX = abs(rawRateX - self.lastRawGyroX) / dt
            self.lastRawGyroY = rawRateY
            self.lastRawGyroX = rawRateX
            
            let isShockwave = (jerkY > 18.0 || jerkX > 18.0)
            let dampingFactor: Double = isShockwave ? 0.08 : 0.45
            
            self.smoothedRotationY = self.smoothedRotationY * (1.0 - dampingFactor) + rawRateY * dampingFactor
            self.smoothedRotationX = self.smoothedRotationX * (1.0 - dampingFactor) + rawRateX * dampingFactor
            
            // --- THUẬT TOÁN 2: Deadband Vi Mô Đi Đường ---
            let effectiveRateY = abs(self.smoothedRotationY) < 0.045 ? 0.0 : self.smoothedRotationY
            let effectiveRateX = abs(self.smoothedRotationX) < 0.045 ? 0.0 : self.smoothedRotationX
            
            let zoomScale = self.currentZoom
            let scaleX = 0.68 * zoomScale
            let scaleY = 0.78 * zoomScale
            
            var dx = effectiveRateY * dt * scaleX
            var dy = -effectiveRateX * dt * scaleY
            
            let maxStep = 0.015
            dx = max(-maxStep, min(maxStep, dx))
            dy = max(-maxStep, min(maxStep, dy))
            
            if self.lastOpticalConfidence <= 0.45 {
                self.deadReckoningFrameCount += 1
                
                self.stateX = min(0.96, max(0.04, self.stateX + dx))
                self.stateY = min(0.96, max(0.04, self.stateY + dy))
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                
                let decayedConf: Double
                let quality: TrackingQuality
                if self.deadReckoningFrameCount > 120 {
                    decayedConf = 0.20
                    quality = .lost
                } else if self.deadReckoningFrameCount > 60 {
                    let decayFactor = pow(0.98, Double(self.deadReckoningFrameCount - 60))
                    decayedConf = max(0.30, 0.50 * decayFactor)
                    quality = .predicting
                } else {
                    decayedConf = max(0.45, self.lastOpticalConfidence)
                    quality = .locked
                }
                
                DispatchQueue.main.async {
                    self.onSpatialTargetUpdated?(targetPoint, decayedConf, quality)
                }
            }
        }
    }
    
    // MARK: - 3. Cập Nhật Quang Học Siêu Bám (Street Optical Update with Spatial Gating)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        self.lastOpticalConfidence = confidence
        
        let now = CACurrentMediaTime()
        let dt = lastUpdateTime > 0 ? min(0.1, now - lastUpdateTime) : (1.0 / 30.0)
        lastUpdateTime = now
        
        var effectiveConfidence = confidence
        var activePoint = point
        
        if let visualPoint = point, let buffer = pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let (bestPt, neuralSim) = NeuralTargetTracker.shared.findBestMatchingPoint(in: buffer, around: visualPoint, searchRadius: 0.025)
            if neuralSim >= 0.60 {
                activePoint = bestPt
                effectiveConfidence = max(confidence, neuralSim * 0.95)
            }
        }
        
        let effectiveThreshold = isLowTextureAnchor ? 0.65 : 0.25
        if let visualPoint = activePoint, effectiveConfidence >= effectiveThreshold {
            self.deadReckoningFrameCount = 0
            let obsX = Double(visualPoint.x)
            let obsY = Double(visualPoint.y)
            
            // --- THUẬT TOÁN 3: Spatial Gating ---
            let distFromCurrent = hypot(obsX - self.stateX, obsY - self.stateY)
            if distFromCurrent > 0.08 && effectiveConfidence < 0.92 {
                return
            }
            
            // --- THUẬT TOÁN 4: Deadband Chống Rung Mặt Đường ---
            if distFromCurrent < 0.012 {
                let lockedTarget = CGPoint(x: self.stateX, y: self.stateY)
                self.onSpatialTargetUpdated?(lockedTarget, effectiveConfidence, .locked)
                return
            }
            
            // --- THUẬT TOÁN 5: Heavy Inertia Damping ---
            let kGain = max(0.18, min(0.32, effectiveConfidence * 0.35))
            var targetX = self.stateX * (1.0 - kGain) + obsX * kGain
            var targetY = self.stateY * (1.0 - kGain) + obsY * kGain
            
            let maxStepPerFrame = 0.012
            let stepX = max(-maxStepPerFrame, min(maxStepPerFrame, targetX - self.stateX))
            let stepY = max(-maxStepPerFrame, min(maxStepPerFrame, targetY - self.stateY))
            
            self.stateX += stepX
            self.stateY += stepY
            
            if effectiveConfidence > 0.65, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: CGPoint(x: self.stateX, y: self.stateY))
            }
            
            let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
            self.onSpatialTargetUpdated?(targetPoint, effectiveConfidence, .locked)
        } else {
            if !isLowTextureAnchor, let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                let voX = Double(voPoint.x)
                let voY = Double(voPoint.y)
                let voDist = hypot(voX - self.stateX, voY - self.stateY)
                if voDist < 0.06 {
                    let kVO = 0.15
                    self.stateX = self.stateX * (1.0 - kVO) + voX * kVO
                    self.stateY = self.stateY * (1.0 - kVO) + voY * kVO
                    let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                    self.onSpatialTargetUpdated?(targetPoint, 0.75, .locked)
                }
            }
        }
    }
    
    // MARK: - 4. Dừng Tracking
    public func stopTracking() {
        isTrackingActive = false
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        CameraLogger.info("🚗 [Street Mode] Đã dừng động cơ tracking không gian đi đường", category: .tracking)
    }
}