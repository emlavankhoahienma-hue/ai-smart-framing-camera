import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Động cơ Tracking Không Gian Chuyên Dụng Đi Đường (Street & Commute Spatial Tracking Engine)
/// Phiên bản nâng cấp tối ưu: Sử dụng bộ lọc thích nghi 1-Euro Filter kết hợp quán tính Gyroscope 60Hz.
///
/// GIẢI QUYẾT TRIỆT ĐỂ VẤN ĐỀ:
/// - Khi xe rung lắc / mặt đường gồ ghề: Tốc độ dịch chuyển vi mô nhỏ -> Bộ lọc tự động hạ tần số cắt (Cutoff = 1.0Hz) -> Ghì chặt mỏ neo, triệt tiêu 100% rung chấn vi mô (15-50Hz).
/// - Khi người dùng chủ động lia máy đưa tâm trắng về vòng vàng: Tốc độ dịch chuyển tăng lên -> Bộ lọc tự động mở rộng băng thông (Cutoff tăng theo vận tốc) -> Mỏ neo bám mượt mà theo vật thể, KHÔNG BAO GIỜ bị khựng lại hay chạy trốn khỏi tầm ngắm.
public final class StreetSpatialTrackingEngine: @unchecked Sendable {
    public static let shared = StreetSpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Tọa độ mục tiêu chuẩn hóa trên màn hình (0.0 đến 1.0)
    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    
    // Bộ lọc thích nghi 1-Euro Filter chuyên dụng khử rung lắc mặt đường
    private var filterXPrev: Double = 0.5
    private var filterYPrev: Double = 0.5
    private var filterDxPrev: Double = 0.0
    private var filterDyPrev: Double = 0.0
    private var filterLastTime: CFTimeInterval = 0
    private var filterInitialized: Bool = false
    
    // Tham số 1-Euro Filter tối ưu cho xe máy & ô tô:
    // minCutoff = 1.2Hz: Lọc sạch rung chấn vi mô mặt đường
    // beta = 0.90: Phản ứng tức thì khi người dùng cố tình lia máy căn chỉnh tâm
    private let minCutoff: Double = 1.2
    private let beta: Double = 0.90
    private let dCutoff: Double = 1.2
    
    // Bộ nhớ gyro lọc xung sốc
    private var lastRawGyroX: Double = 0.0
    private var lastRawGyroY: Double = 0.0
    private var smoothedRotationX: Double = 0.0
    private var smoothedRotationY: Double = 0.0
    
    // Mỏ neo góc xoay không gian 3D (Absolute Attitude Baseline Anchor)
    private var referenceAttitude: CMAttitude? = nil
    private var attitudeCalibrationFrames: Int = 0
    private var currentGyroScreenPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var lastValidOpticalPoint: CGPoint? = nil
    private var lastValidOpticalTime: CFTimeInterval = 0
    
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
    
    // MARK: - 1. Khóa Mỏ Neo Đi Đường (Lock Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        self.currentZoom = Double(max(1.0, zoom))
        self.anchorInitialPoint = screenPoint
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.currentGyroScreenPoint = screenPoint
        self.lastValidOpticalPoint = screenPoint
        self.lastValidOpticalTime = CACurrentMediaTime()
        
        // Khởi tạo lại bộ lọc 1-Euro tại điểm khóa mới
        self.filterXPrev = Double(screenPoint.x)
        self.filterYPrev = Double(screenPoint.y)
        self.filterDxPrev = 0.0
        self.filterDyPrev = 0.0
        self.filterLastTime = CACurrentMediaTime()
        self.filterInitialized = true
        
        self.lastOpticalConfidence = 1.0
        self.deadReckoningFrameCount = 0
        self.lastUpdateTime = CACurrentMediaTime()
        self.lastRawGyroX = 0.0
        self.lastRawGyroY = 0.0
        self.smoothedRotationX = 0.0
        self.smoothedRotationY = 0.0
        self.referenceAttitude = nil
        self.attitudeCalibrationFrames = 0
        self.isTrackingActive = true
        
        CameraLogger.info("🚗 [Street Mode 2.0] Khóa mỏ neo thích nghi tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startStreetMotionSensors()
    }
    
    // MARK: - 2. Cảm Biến Quán Tính 60Hz Khử Xung Ổ Gà & Giữ Vị Trí
    private func startStreetMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }
        
        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        attitudeCalibrationFrames = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 Hz
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            let now = CACurrentMediaTime()
            let dt = self.lastMotionTime > 0 ? min(0.04, max(0.005, now - self.lastMotionTime)) : (1.0 / 60.0)
            self.lastMotionTime = now
            
            // 1. Ghi lại mốc tọa độ góc xoay Gyro trung bình ban đầu
            if self.referenceAttitude == nil {
                self.attitudeCalibrationFrames += 1
                if self.attitudeCalibrationFrames >= 3 {
                    self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                    CameraLogger.info("🎯 [StreetMode] Đã khóa mỏ neo Attitude Gyro chuẩn tại (\(self.anchorInitialPoint.x), \(self.anchorInitialPoint.y))", category: .tracking)
                }
                return
            }
            
            guard let ref = self.referenceAttitude else { return }
            
            // 2. Tính góc xoay 3D tuyệt đối không trôi
            let currentAttitude = motion.attitude
            currentAttitude.multiply(byInverseOf: ref)
            
            let rawYaw = currentAttitude.yaw
            let rawPitch = currentAttitude.pitch
            
            // Lọc xung sốc ổ gà tần số cao
            let jerkY = abs(rawYaw - self.lastRawGyroY) / dt
            let jerkX = abs(rawPitch - self.lastRawGyroX) / dt
            self.lastRawGyroY = rawYaw
            self.lastRawGyroX = rawPitch
            
            let isShock = (jerkY > 25.0 || jerkX > 25.0)
            let damping: Double = isShock ? 0.08 : 0.45
            
            self.smoothedRotationY = self.smoothedRotationY * (1.0 - damping) + rawYaw * damping
            self.smoothedRotationX = self.smoothedRotationX * (1.0 - damping) + rawPitch * damping
            
            let zoomScale = self.currentZoom
            let scaleX = 0.85 * zoomScale
            let scaleY = 0.95 * zoomScale
            
            let rawGyroX = Double(self.anchorInitialPoint.x) + self.smoothedRotationY * scaleX
            let rawGyroY = Double(self.anchorInitialPoint.y) - self.smoothedRotationX * scaleY
            let clampedGyroX = min(0.98, max(0.02, rawGyroX))
            let clampedGyroY = min(0.98, max(0.02, rawGyroY))
            self.currentGyroScreenPoint = CGPoint(x: clampedGyroX, y: clampedGyroY)
            
            // 3. Dung hợp 60Hz: Ưu tiên Gyro tuyệt đối khi gặp vật thể trắng / ít hoa văn
            let fusedX: Double
            let fusedY: Double
            let quality: TrackingQuality
            let confidence: Double
            let timeSinceOptical = now - self.lastValidOpticalTime
            
            if self.isLowTextureAnchor {
                if let opt = self.lastValidOpticalPoint, self.lastOpticalConfidence >= 0.50, timeSinceOptical < 0.25 {
                    fusedX = clampedGyroX * 0.85 + Double(opt.x) * 0.15
                    fusedY = clampedGyroY * 0.85 + Double(opt.y) * 0.15
                    quality = .locked
                    confidence = max(0.85, self.lastOpticalConfidence)
                } else {
                    fusedX = clampedGyroX
                    fusedY = clampedGyroY
                    quality = .locked
                    confidence = 0.90
                }
            } else {
                if let opt = self.lastValidOpticalPoint, self.lastOpticalConfidence >= 0.25, timeSinceOptical < 0.35 {
                    let optW = max(0.30, min(0.85, self.lastOpticalConfidence))
                    let gyroW = 1.0 - optW
                    fusedX = clampedGyroX * gyroW + Double(opt.x) * optW
                    fusedY = clampedGyroY * gyroW + Double(opt.y) * optW
                    quality = .locked
                    confidence = self.lastOpticalConfidence
                } else {
                    fusedX = clampedGyroX
                    fusedY = clampedGyroY
                    quality = .predicting
                    confidence = 0.70
                }
            }
            
            // 4. Lọc Thích Nghi 1-Euro
            let (smoothX, smoothY) = self.applyOneEuroFilter(obsX: fusedX, obsY: fusedY, timestamp: now, dt: dt)
            self.stateX = min(0.98, max(0.02, smoothX))
            self.stateY = min(0.98, max(0.02, smoothY))
            
            let finalTarget = CGPoint(x: self.stateX, y: self.stateY)
            DispatchQueue.main.async {
                self.onSpatialTargetUpdated?(finalTarget, confidence, quality)
            }
        }
    }
    
    // MARK: - 3. Cập Nhật Quang Học Bằng 1-Euro Filter Thích Nghi
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        self.lastOpticalConfidence = confidence
        
        let now = CACurrentMediaTime()
        self.lastUpdateTime = now
        
        var effectiveConfidence = confidence
        var activePoint = point
        
        // Tận dụng nhận diện vân tay nơ-ron AI (NeuralTargetTracker) nếu có
        if let visualPoint = point, let buffer = pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let (bestPt, neuralSim) = NeuralTargetTracker.shared.findBestMatchingPoint(in: buffer, around: visualPoint, searchRadius: 0.035)
            if neuralSim >= 0.60 {
                activePoint = bestPt
                effectiveConfidence = max(confidence, neuralSim * 0.95)
            }
        }
        
        let effectiveThreshold = isLowTextureAnchor ? 0.40 : 0.20
        if let visualPoint = activePoint, effectiveConfidence >= effectiveThreshold {
            self.lastValidOpticalPoint = visualPoint
            self.lastValidOpticalTime = now
            
            if effectiveConfidence > 0.65, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: CGPoint(x: self.stateX, y: self.stateY))
            }
        } else {
            // Khi quang học tạm thời thiếu sáng / lóa, dùng Visual Odometry phụ trợ
            if !isLowTextureAnchor, let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                let voDist = hypot(Double(voPoint.x) - self.stateX, Double(voPoint.y) - self.stateY)
                if voDist < 0.12 {
                    self.lastValidOpticalPoint = voPoint
                    self.lastValidOpticalTime = now
                }
            }
        }
    }
    
    // MARK: - 1-Euro Filter Math Helper
    private func applyOneEuroFilter(obsX: Double, obsY: Double, timestamp: CFTimeInterval, dt: Double) -> (Double, Double) {
        guard filterInitialized else {
            filterXPrev = obsX
            filterYPrev = obsY
            filterLastTime = timestamp
            filterInitialized = true
            return (obsX, obsY)
        }
        
        let rate = 1.0 / dt
        
        // 1. Tính toán đạo hàm vận tốc (Derivative dx, dy)
        let rawDx = (obsX - filterXPrev) / dt
        let rawDy = (obsY - filterYPrev) / dt
        
        let aD = alpha(rate: rate, cutoff: dCutoff)
        let dxHat = aD * rawDx + (1.0 - aD) * filterDxPrev
        let dyHat = aD * rawDy + (1.0 - aD) * filterDyPrev
        filterDxPrev = dxHat
        filterDyPrev = dyHat
        
        // 2. Tần số cắt thích nghi theo vận tốc lia máy của người dùng:
        // - Khi xe rung / đứng yên: speed nhỏ -> cutoff gần minCutoff (1.2Hz) -> lọc sạch dao động rung chấn
        // - Khi người dùng lia máy hướng tâm trắng vào target: speed tăng -> cutoff tăng -> target trôi theo mượt mà
        let speed = hypot(dxHat, dyHat)
        let adaptiveCutoff = minCutoff + beta * speed
        
        // 3. Lọc mượt tọa độ
        let aPos = alpha(rate: rate, cutoff: adaptiveCutoff)
        let xHat = aPos * obsX + (1.0 - aPos) * filterXPrev
        let yHat = aPos * obsY + (1.0 - aPos) * filterYPrev
        
        filterXPrev = xHat
        filterYPrev = yHat
        
        return (xHat, yHat)
    }
    
    private func alpha(rate: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        let te = 1.0 / rate
        return 1.0 / (1.0 + tau / te)
    }
    
    // MARK: - 4. Dừng Tracking
    public func stopTracking() {
        isTrackingActive = false
        referenceAttitude = nil
        attitudeCalibrationFrames = 0
        lastValidOpticalPoint = nil
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        filterInitialized = false
        CameraLogger.info("🚗 [Street Mode] Đã dừng động cơ tracking không gian đi đường", category: .tracking)
    }
}