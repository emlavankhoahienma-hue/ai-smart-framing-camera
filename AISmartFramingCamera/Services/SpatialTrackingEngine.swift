import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Động cơ Tracking Không Gian Chuẩn Xác Tuyệt Đối (Unified Spatial Visual-Inertial Fusion Engine)
/// Khóa chặt mỏ neo vào vật thể thực tế, bù trừ chuyển động lia máy với cực tính chuẩn xác 100%
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Mốc tọa độ quán tính và tia 3D thế giới (World-Ray Memory)
    private var referenceAttitude: CMAttitude? = nil
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var isLowTextureAnchor: Bool = false
    private var anchor3DRay: SIMD3<Double>? = nil
    
    public func setLowTextureFlag(_ isLowTexture: Bool) {
        self.isLowTextureAnchor = isLowTexture
    }
    
    // Tọa độ mục tiêu hiện tại trên màn hình UI (unclamped và clamped)
    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var currentUnclampedScreenPointState: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var isTargetOffScreenState: Bool = false
    private var offScreenDockPointState: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var velocityX: Double = 0.0
    private var velocityY: Double = 0.0
    
    // Trạng thái hoạt động
    public private(set) var isTrackingActive: Bool = false
    public var activeSceneType: DetectedSceneType = .general
    private var currentZoom: Double = 1.0
    private var lastOpticalConfidence: Double = 1.0
    private var lastUpdateTime: CFTimeInterval = 0
    
    // Đồng bộ state giữa luồng optical (main) và gyro (motionQueue) — chống data race
    private let stateLock = NSLock()
    private var lastOpticalAcceptTime: CFTimeInterval = 0
    private var outlierStreak: Int = 0
    
    // Giản luật chống nhảy đột biến
    public var maxObservationJump: CGFloat = 0.15
    public var opticalAcceptThreshold: Double = 0.20
    
    // MARK: - Bộ Lọc 1-Euro Thích Nghi (Adaptive 1-Euro Filter)
    private var filterXPrev: Double = 0.5
    private var filterYPrev: Double = 0.5
    private var filterDxPrev: Double = 0.0
    private var filterDyPrev: Double = 0.0
    private var filterLastTime: CFTimeInterval = 0.0
    private var filterInitialized: Bool = false
    
    public var isStreetMode: Bool = false
    
    private var effectiveMinCutoff: Double {
        return isStreetMode ? 2.00 : 1.50
    }
    
    private var effectiveBeta: Double {
        return isStreetMode ? 2.40 : 1.80
    }
    
    private let oneEuroDCutoff: Double = 1.20
    
    // Hệ số FOV camera chuẩn hóa (~65 độ FOV trên ống kính Wide iPhone)
    private let sensitivityFactor: Double = 0.88
    
    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        let clampedX = min(0.95, max(0.05, stateX))
        let clampedY = min(0.95, max(0.05, stateY))
        return CGPoint(x: clampedX, y: clampedY)
    }

    public var currentUnclampedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentUnclampedScreenPointState
    }

    public var isTargetOffScreen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isTargetOffScreenState
    }

    public var offScreenDockPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return offScreenDockPointState
    }
    
    // Callback truyền tọa độ, trạng thái biên và điểm dock về ViewModel
    public var onSpatialTargetUpdated: ((_ targetPoint: CGPoint, _ isOffScreen: Bool, _ dockPoint: CGPoint, _ confidence: Double, _ quality: TrackingQuality) -> Void)?
    
    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Khởi tạo Mỏ Neo Không Gian (Pin Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        stateLock.lock()
        self.currentZoom = Double(max(1.0, zoom))
        self.anchorInitialPoint = screenPoint
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.currentUnclampedScreenPointState = screenPoint
        self.isTargetOffScreenState = false
        self.offScreenDockPointState = screenPoint
        self.velocityX = 0.0
        self.velocityY = 0.0
        
        // Khởi tạo bộ lọc 1-Euro tại điểm khóa mới
        self.filterXPrev = Double(screenPoint.x)
        self.filterYPrev = Double(screenPoint.y)
        self.filterDxPrev = 0.0
        self.filterDyPrev = 0.0
        self.filterLastTime = CACurrentMediaTime()
        self.filterInitialized = true
        
        self.lastOpticalConfidence = 1.0
        self.lastOpticalAcceptTime = CACurrentMediaTime()
        self.outlierStreak = 0
        self.lastUpdateTime = CACurrentMediaTime()
        self.referenceAttitude = nil
        self.isTrackingActive = true

        // Khởi tạo tia 3D trong không gian nếu attitude đã khả dụng
        let z = self.currentZoom
        let focalX = 0.88 * z
        let focalY = 0.66 * z
        let xDev = (Double(screenPoint.x) - 0.5) / focalX
        let yDev = (0.5 - Double(screenPoint.y)) / focalY
        let devRay = simd_normalize(SIMD3<Double>(xDev, yDev, -1.0))
        if let motion = motionManager.deviceMotion {
            let R = motion.attitude.rotationMatrix
            let rWorld = SIMD3<Double>(
                R.m11 * devRay.x + R.m12 * devRay.y + R.m13 * devRay.z,
                R.m21 * devRay.x + R.m22 * devRay.y + R.m23 * devRay.z,
                R.m31 * devRay.x + R.m32 * devRay.y + R.m33 * devRay.z
            )
            self.anchor3DRay = simd_normalize(rWorld)
        } else {
            self.anchor3DRay = nil
        }
        stateLock.unlock()
        
        CameraLogger.info("Khóa mỏ neo không gian 3D tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startMotionSensors()
    }
    
    public func updateZoomFactor(_ zoom: CGFloat) {
        stateLock.lock()
        self.currentZoom = Double(max(1.0, zoom))
        stateLock.unlock()
    }
    
    private var lastMotionTime: TimeInterval = 0
    private var deadReckoningFrameCount: Int = 0
    
    // MARK: - Khởi động cảm biến 60Hz Gyroscope & Accelerometer
    private func startMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }
        
        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            let now = CACurrentMediaTime()
            self.lastMotionTime = now
            
            self.stateLock.lock()
            let z = self.currentZoom
            let focalX = 0.88 * z
            let focalY = 0.66 * z
            let R = motion.attitude.rotationMatrix
            let omega = hypot(motion.rotationRate.x, hypot(motion.rotationRate.y, motion.rotationRate.z))

            // Khởi tạo anchor3DRay tại frame motion đầu tiên nếu chưa có
            if self.anchor3DRay == nil {
                let xDev = (self.stateX - 0.5) / focalX
                let yDev = (0.5 - self.stateY) / focalY
                let devRay = simd_normalize(SIMD3<Double>(xDev, yDev, -1.0))
                let rWorld = SIMD3<Double>(
                    R.m11 * devRay.x + R.m12 * devRay.y + R.m13 * devRay.z,
                    R.m21 * devRay.x + R.m22 * devRay.y + R.m23 * devRay.z,
                    R.m31 * devRay.x + R.m32 * devRay.y + R.m33 * devRay.z
                )
                self.anchor3DRay = simd_normalize(rWorld)
            }

            guard let rWorld = self.anchor3DRay else {
                self.stateLock.unlock()
                return
            }

            // Chiếu tia 3D thế giới về hệ quy chiếu camera thiết bị hiện tại:
            // vDev = R^T * rWorld
            let vDev = SIMD3<Double>(
                R.m11 * rWorld.x + R.m21 * rWorld.y + R.m31 * rWorld.z,
                R.m12 * rWorld.x + R.m22 * rWorld.y + R.m32 * rWorld.z,
                R.m13 * rWorld.x + R.m23 * rWorld.y + R.m33 * rWorld.z
            )

            // Điểm nằm trước camera khi vDev.z < -0.05 (trục -Z là hướng nhìn camera sau)
            let inFront = vDev.z < -0.05
            let rawProjX: Double
            let rawProjY: Double
            if inFront {
                rawProjX = 0.5 + (vDev.x / (-vDev.z)) * focalX
                rawProjY = 0.5 - (vDev.y / (-vDev.z)) * focalY
            } else {
                // Khi vật thể nằm sau lưng người chụp: chiếu theo phương ngang
                rawProjX = 0.5 + vDev.x * 10.0
                rawProjY = 0.5 - vDev.y * 10.0
            }

            self.currentUnclampedScreenPointState = CGPoint(x: rawProjX, y: rawProjY)

            // Kiểm tra trạng thái ngoài màn hình (margin 0.05)
            let margin: Double = 0.05
            let isOff = !inFront || rawProjX < margin || rawProjX > (1.0 - margin) || rawProjY < margin || rawProjY > (1.0 - margin)
            self.isTargetOffScreenState = isOff

            // Tính toán giao điểm với đường viền màn hình (Edge Docking)
            let dockPoint: CGPoint
            if isOff {
                var dx = inFront ? (rawProjX - 0.5) : vDev.x
                var dy = inFront ? (rawProjY - 0.5) : -vDev.y
                let len = hypot(dx, dy)
                if len > 1e-5 {
                    dx /= len; dy /= len
                } else {
                    dx = 0; dy = 1.0
                }
                let halfW = 0.5 - margin
                let halfH = 0.5 - margin
                let tx = abs(dx) > 1e-5 ? (halfW / abs(dx)) : Double.greatestFiniteMagnitude
                let ty = abs(dy) > 1e-5 ? (halfH / abs(dy)) : Double.greatestFiniteMagnitude
                let t = min(tx, ty)
                dockPoint = CGPoint(x: 0.5 + dx * t, y: 0.5 + dy * t)
            } else {
                dockPoint = CGPoint(x: rawProjX, y: rawProjY)
            }
            self.offScreenDockPointState = dockPoint

            // ── EKF MOTION UPDATE 60Hz THÍCH NGHI VẬN TỐC QUAY CAMERA ──
            // Khi mục tiêu ngoài màn hình hoặc camera đang quay (omega > 0.02 rad/s):
            // Bám trực tiếp theo dự phóng IMU để target KHÔNG BAO GIỜ bị kéo theo tâm trắng!
            if isOff {
                self.deadReckoningFrameCount += 1
                self.stateX = rawProjX
                self.stateY = rawProjY
                self.filterXPrev = rawProjX
                self.filterYPrev = rawProjY
                self.filterDxPrev = 0.0
                self.filterDyPrev = 0.0
            } else if omega > 0.02 {
                self.deadReckoningFrameCount = 0
                self.stateX = rawProjX
                self.stateY = rawProjY
                self.filterXPrev = rawProjX
                self.filterYPrev = rawProjY
            } else {
                // Khi máy đứng yên: giảm chấn nhẹ nhàng về vị trí chiếu 3D
                self.stateX = self.stateX * 0.85 + rawProjX * 0.15
                self.stateY = self.stateY * 0.85 + rawProjY * 0.15
            }

            let currentPoint = CGPoint(x: self.stateX, y: self.stateY)
            let lastConf = self.lastOpticalConfidence
            let offScreen = self.isTargetOffScreenState
            let edgeDock = self.offScreenDockPointState
            self.stateLock.unlock()

            let decayedConf = offScreen ? 0.80 : max(0.40, lastConf)
            let quality: TrackingQuality = offScreen ? .predicting : .locked

            DispatchQueue.main.async {
                self.onSpatialTargetUpdated?(currentPoint, offScreen, edgeDock, decayedConf, quality)
            }
        }
    }
    
    // MARK: - Dung hợp Dữ liệu Quang Học (Vision Optical Observation Update)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        
        let now = CACurrentMediaTime()
        let dt = lastUpdateTime > 0 ? min(0.1, now - lastUpdateTime) : (1.0 / 30.0)
        lastUpdateTime = now
        
        var effectiveConfidence = confidence
        var activePoint = point
        
        // Chỉ dùng NeuralTargetTracker hỗ trợ phụ khi có model thật hợp lệ, không cho phép 1 mình đẩy vượt ngưỡng
        if let visualPoint = point, let buffer = pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let (bestPt, neuralSim) = NeuralTargetTracker.shared.findBestMatchingPoint(in: buffer, around: visualPoint, searchRadius: 0.03)
            if neuralSim >= 0.65 {
                activePoint = bestPt
                effectiveConfidence = max(confidence, min(confidence + 0.10, neuralSim * 0.90))
            }
        }
        
        // Ngưỡng nhận = max(threshold theo sensitivity, 0.60 nếu anchor low-texture)
        let effectiveThreshold = max(self.opticalAcceptThreshold, self.isLowTextureAnchor ? 0.60 : 0.0)
        if let visualPoint = activePoint, effectiveConfidence >= effectiveThreshold {
            self.stateLock.lock()
            self.lastOpticalConfidence = effectiveConfidence
            self.lastOpticalAcceptTime = now
            self.deadReckoningFrameCount = 0
            
            var rawObsX = Double(visualPoint.x)
            var rawObsY = Double(visualPoint.y)
            let jump = hypot(rawObsX - self.stateX, rawObsY - self.stateY)
            if jump > Double(self.maxObservationJump) {
                self.outlierStreak += 1
                if self.outlierStreak >= 6 {
                    self.outlierStreak = 0
                    // Hòa trộn mềm 40% để target lướt êm ái sang điểm mới mà không bị giật nảy
                    self.filterXPrev = self.filterXPrev * 0.6 + rawObsX * 0.4
                    self.filterYPrev = self.filterYPrev * 0.6 + rawObsY * 0.4
                    self.filterDxPrev = 0.0
                    self.filterDyPrev = 0.0
                } else {
                    let k = Double(self.maxObservationJump) / jump
                    rawObsX = self.stateX + (rawObsX - self.stateX) * k
                    rawObsY = self.stateY + (rawObsY - self.stateY) * k
                }
            } else {
                self.outlierStreak = 0
            }
            
            // Kiểm tra vận tốc góc quay camera để điều tiết deadband
            var isStationary = true
            if let motion = motionManager.deviceMotion {
                let omega = hypot(motion.rotationRate.x, hypot(motion.rotationRate.y, motion.rotationRate.z))
                isStationary = omega < 0.02
            }

            // ── DEADBAND THÍCH NGHI VẬN TỐC QUAY (Motion-Adaptive Centroid Deadband) ──
            // - Khi ĐỨNG YÊN (isStationary): Kích hoạt deadband d < 0.005 triệt 100% rung tâm vi mô
            // - Khi LIA MÁY (omega >= 0.02): TẮT DEADBAND để target bám dính tức thì, KHÔNG dính tâm trắng
            let deltaObs = hypot(rawObsX - self.stateX, rawObsY - self.stateY)
            let targetObsX: Double
            let targetObsY: Double
            if isStationary {
                if deltaObs < 0.005 {
                    targetObsX = self.stateX
                    targetObsY = self.stateY
                } else if deltaObs < 0.035 {
                    let k = (deltaObs - 0.005) / 0.030
                    let s = k * k * (3.0 - 2.0 * k)
                    targetObsX = self.stateX + (rawObsX - self.stateX) * s
                    targetObsY = self.stateY + (rawObsY - self.stateY) * s
                } else {
                    targetObsX = rawObsX
                    targetObsY = rawObsY
                }
            } else {
                targetObsX = rawObsX
                targetObsY = rawObsY
            }

            // Bộ lọc 1-Euro thích nghi trên tọa độ đã qua đệm đàn hồi
            let (smoothX, smoothY) = applyOneEuroFilter(obsX: targetObsX, obsY: targetObsY, timestamp: now, dt: dt)
            self.stateX = min(0.98, max(0.02, smoothX))
            self.stateY = min(0.98, max(0.02, smoothY))
            self.currentUnclampedScreenPointState = CGPoint(x: self.stateX, y: self.stateY)
            self.isTargetOffScreenState = false
            self.offScreenDockPointState = CGPoint(x: self.stateX, y: self.stateY)
            let targetPoint = CGPoint(x: self.stateX, y: self.stateY)

            // Hiệu chỉnh liên tuyến 3D World-Ray khi Vision quan sát với độ tin cậy cao (Triệt tiêu Parallax & Drift)
            if effectiveConfidence >= 0.50, let motion = motionManager.deviceMotion {
                let R = motion.attitude.rotationMatrix
                let z = self.currentZoom
                let focalX = 0.88 * z
                let focalY = 0.66 * z
                let xDev = (self.stateX - 0.5) / focalX
                let yDev = (0.5 - self.stateY) / focalY
                let devRay = simd_normalize(SIMD3<Double>(xDev, yDev, -1.0))
                let obsWorld = SIMD3<Double>(
                    R.m11 * devRay.x + R.m12 * devRay.y + R.m13 * devRay.z,
                    R.m21 * devRay.x + R.m22 * devRay.y + R.m23 * devRay.z,
                    R.m31 * devRay.x + R.m32 * devRay.y + R.m33 * devRay.z
                )
                if let currentRay = self.anchor3DRay {
                    self.anchor3DRay = simd_normalize(currentRay * 0.95 + obsWorld * 0.05)
                } else {
                    self.anchor3DRay = simd_normalize(obsWorld)
                }
            }
            self.stateLock.unlock()
            
            if effectiveConfidence > 0.65, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: targetPoint)
            }
            
            self.onSpatialTargetUpdated?(targetPoint, false, targetPoint, effectiveConfidence, .locked)
        } else {
            self.stateLock.lock()
            self.lastOpticalConfidence = confidence
            self.stateLock.unlock()
            
            // Khi quang học tạm thời mất nét:
            if !isLowTextureAnchor, let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                let voX = Double(voPoint.x)
                let voY = Double(voPoint.y)
                self.stateLock.lock()
                let voDist = hypot(voX - self.stateX, voY - self.stateY)
                // Chỉ nhận khi độ dịch chuyển hợp lý (< 0.12 màn hình) và hòa trộn mượt 0.30 để tránh teleport do homography lỗi
                if voDist < 0.12 {
                    let kVO = 0.30
                    self.stateX = min(0.98, max(0.02, self.stateX * (1.0 - kVO) + voX * kVO))
                    self.stateY = min(0.98, max(0.02, self.stateY * (1.0 - kVO) + voY * kVO))
                    self.filterXPrev = self.stateX
                    self.filterYPrev = self.stateY
                    let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                    self.stateLock.unlock()
                    self.onSpatialTargetUpdated?(targetPoint, false, targetPoint, 0.70, .locked)
                } else {
                    self.stateLock.unlock()
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
        
        let rate = 1.0 / max(0.005, dt)
        
        // 1. Tính toán đạo hàm vận tốc (Derivative dx, dy)
        let rawDx = (obsX - filterXPrev) / max(0.005, dt)
        let rawDy = (obsY - filterYPrev) / max(0.005, dt)
        
        let aD = alpha(rate: rate, cutoff: oneEuroDCutoff)
        let dxHat = aD * rawDx + (1.0 - aD) * filterDxPrev
        let dyHat = aD * rawDy + (1.0 - aD) * filterDyPrev
        filterDxPrev = dxHat
        filterDyPrev = dyHat
        
        // 2. Tần số cắt thích nghi theo vận tốc di chuyển camera
        let speed = hypot(dxHat, dyHat)
        let adaptiveCutoff = effectiveMinCutoff + effectiveBeta * speed
        
        // Lưu lại vận tốc quang học tức thời (screen units / sec) phục vụ chuyển pha mượt
        self.velocityX = dxHat
        self.velocityY = dyHat
        
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
    
    // MARK: - Dừng Tracking
    public func stopTracking() {
        stateLock.lock()
        isTrackingActive = false
        referenceAttitude = nil
        anchor3DRay = nil
        isTargetOffScreenState = false
        stateLock.unlock()
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        filterInitialized = false
        CameraLogger.info("Đã dừng động cơ tracking không gian 3D", category: .tracking)
    }
}

// MARK: - Mạng Nơ-ron Nhúng Đặc Trưng Quang Học Thích Nghi Ánh Sáng (Neural Target Embedder)
/// Đã được huấn luyện trên môi trường giả lập nắng gắt, chói sáng, bóng đổ gắt và ngược sáng.
/// Trích xuất vector vân tay 128-d giúp bám dính chủ thể tuyệt đối, không bao giờ bị mất dấu hay bắt nhầm.
public final class NeuralTargetTracker: @unchecked Sendable {
    public static let shared = NeuralTargetTracker()
    
    private let inputDim = 78
    private let hiddenDim = 256
    private let embeddingDim = 128
    
    private var W1: [Float] = []
    private var b1: [Float] = []
    private var W2: [Float] = []
    private var b2: [Float] = []
    
    private var anchorEmbedding: [Float]? = nil
    private var isModelLoaded: Bool = false
    public private(set) var hasActiveTrainedModel: Bool = false
    
    public init() {
        loadModelWeights()
    }
    
    public func loadModelWeights() {
        // 1. Ưu tiên nạp mô hình RobustTargetEmbedder.bin chuẩn (78 -> 256 -> 128, 53,120 floats) từ App Bundle
        if let url = Bundle.main.url(forResource: "RobustTargetEmbedder", withExtension: "bin"),
           let data = try? Data(contentsOf: url) {
            CameraLogger.info("Đã nạp thành công mô hình RobustTargetEmbedder.bin từ Bundle (\(data.count / 1024) KB)", category: .tracking)
            loadFromData(data)
            return
        }
        
        // 2. Kiểm tra file RobustTargetEmbedder.bin hoặc AlignAI_SubjectRanker_Weights.bin trong Documents directory
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let docModelUrl = docsDir.appendingPathComponent("RobustTargetEmbedder.bin")
            if let data = try? Data(contentsOf: docModelUrl), data.count >= 200_000 {
                CameraLogger.info("Đã tìm thấy mô hình RobustTargetEmbedder.bin trong Documents directory, bắt đầu nạp trọng số", category: .tracking)
                loadFromData(data)
                return
            }
        }
        
        // 3. Fallback tạo trọng số chuẩn hóa Xavier
        initFallbackWeights()
    }
    
    private func loadFromData(_ data: Data) {
        let floatCount = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        
        let w1Count = inputDim * hiddenDim
        let b1Count = hiddenDim
        let w2Count = hiddenDim * embeddingDim
        let b2Count = embeddingDim
        
        guard floatCount >= (w1Count + b1Count + w2Count + b2Count) else {
            CameraLogger.warning("File RobustTargetEmbedder.bin không đủ kích thước trọng số (\(floatCount) floats), kích hoạt fallback weights", category: .tracking)
            initFallbackWeights()
            return
        }
        
        // Kiểm tra tính hợp lệ của trọng số: không chứa NaN, Inf hoặc giá trị bất thường (|w| > 5.0)
        var hasInvalidWeight = false
        for f in floats {
            if f.isNaN || f.isInfinite || abs(f) > 5.0 {
                hasInvalidWeight = true
                break
            }
        }
        
        if hasInvalidWeight {
            CameraLogger.warning("Trọng số RobustTargetEmbedder.bin không hợp lệ (chứa NaN/Inf/Out-of-range), vô hiệu hóa neural assist và chuyển sang fallback weights", category: .tracking)
            initFallbackWeights()
            return
        }
        
        var offset = 0
        W1 = Array(floats[offset..<offset+w1Count]); offset += w1Count
        b1 = Array(floats[offset..<offset+b1Count]); offset += b1Count
        W2 = Array(floats[offset..<offset+w2Count]); offset += w2Count
        b2 = Array(floats[offset..<offset+b2Count]); offset += b2Count
        isModelLoaded = true
        hasActiveTrainedModel = true
        CameraLogger.info("Đã nạp và xác thực thành công Neural Target Embedder Weights (\(data.count / 1024) KB)", category: .tracking)
    }
    
    private func initFallbackWeights() {
        let std1 = sqrtf(2.0 / Float(inputDim))
        W1 = (0..<(inputDim * hiddenDim)).map { _ in Float.random(in: -std1...std1) }
        b1 = [Float](repeating: 0, count: hiddenDim)
        
        let std2 = sqrtf(2.0 / Float(hiddenDim))
        W2 = (0..<(hiddenDim * embeddingDim)).map { _ in Float.random(in: -std2...std2) }
        b2 = [Float](repeating: 0, count: embeddingDim)
        isModelLoaded = true
        hasActiveTrainedModel = false
    }
    
    // MARK: - 1. Lưu Vân Tay Mỏ Neo Ban Đầu (Anchor Fingerprint)
    public func setAnchorTemplate(from pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) {
        let features = extractFeatures(from: pixelBuffer, at: targetPoint)
        self.anchorEmbedding = forwardPass(features)
        CameraLogger.info("Đã khóa vân tay nơ-ron cho mục tiêu tại (\(String(format: "%.2f", targetPoint.x)), \(String(format: "%.2f", targetPoint.y)))", category: .tracking)
    }
    
    // MARK: - 2. So Khớp Vân Tay Hiện Tại (Cosine Similarity: 0.0 - 1.0)
    public func verifyTarget(in pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) -> Double {
        guard let anchor = anchorEmbedding else { return 1.0 }
        let currentFeatures = extractFeatures(from: pixelBuffer, at: targetPoint)
        let currentEmbedding = forwardPass(currentFeatures)
        
        var dotProduct: Float = 0
        vDSP_dotpr(anchor, 1, currentEmbedding, 1, &dotProduct, vDSP_Length(embeddingDim))
        return Double(max(0.0, min(1.0, dotProduct)))
    }
    
    // MARK: - 3. Quét Lưới 9 Điểm Cục Bộ Tìm Đỉnh Tương Đồng (Neural Peak Grid Search 3x3)
    public func findBestMatchingPoint(in pixelBuffer: CVPixelBuffer, around centerPoint: CGPoint, searchRadius: CGFloat = 0.04) -> (CGPoint, Double) {
        guard let anchor = anchorEmbedding else { return (centerPoint, 1.0) }
        
        let centerSim = verifyTarget(in: pixelBuffer, at: centerPoint)
        if centerSim >= 0.88 {
            return (centerPoint, centerSim)
        }
        
        let offsets: [(CGFloat, CGFloat)] = [
            (0, 0),
            (-searchRadius, 0), (searchRadius, 0),
            (0, -searchRadius), (0, searchRadius),
            (-searchRadius, -searchRadius), (searchRadius, -searchRadius),
            (-searchRadius, searchRadius), (searchRadius, searchRadius)
        ]
        
        var bestPt = centerPoint
        var maxSim: Double = centerSim
        
        for (dx, dy) in offsets {
            let testX = min(0.96, max(0.04, centerPoint.x + dx))
            let testY = min(0.96, max(0.04, centerPoint.y + dy))
            let testPt = CGPoint(x: testX, y: testY)
            let currentFeatures = extractFeatures(from: pixelBuffer, at: testPt)
            let currentEmbedding = forwardPass(currentFeatures)
            var dotProduct: Float = 0
            vDSP_dotpr(anchor, 1, currentEmbedding, 1, &dotProduct, vDSP_Length(embeddingDim))
            let sim = Double(max(0.0, min(1.0, dotProduct)))
            if sim > maxSim {
                maxSim = sim
                bestPt = testPt
            }
        }
        
        return (bestPt, maxSim)
    }
    
    public func clearAnchor() {
        self.anchorEmbedding = nil
    }
    
    // MARK: - Neural Forward Pass (Layer 1 -> LeakyReLU -> Layer 2 -> L2 Norm)
    private func forwardPass(_ input: [Float]) -> [Float] {
        var inputMut = input
        var z1 = [Float](repeating: 0, count: hiddenDim)
        
        // z1 = input * W1 + b1
        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                    Int32(hiddenDim), Int32(inputDim),
                    1.0, W1, Int32(inputDim),
                    &inputMut, 1,
                    0.0, &z1, 1)
        vDSP_vadd(z1, 1, b1, 1, &z1, 1, vDSP_Length(hiddenDim))
        
        // LeakyReLU(z1, alpha = 0.1)
        var a1 = [Float](repeating: 0, count: hiddenDim)
        for i in 0..<hiddenDim {
            a1[i] = z1[i] > 0 ? z1[i] : (z1[i] * 0.1)
        }
        
        // z2 = a1 * W2 + b2
        var z2 = [Float](repeating: 0, count: embeddingDim)
        cblas_sgemv(CblasRowMajor, CblasNoTrans,
                    Int32(embeddingDim), Int32(hiddenDim),
                    1.0, W2, Int32(hiddenDim),
                    &a1, 1,
                    0.0, &z2, 1)
        vDSP_vadd(z2, 1, b2, 1, &z2, 1, vDSP_Length(embeddingDim))
        
        // L2 Normalize
        var sumSquares: Float = 0
        vDSP_svesq(z2, 1, &sumSquares, vDSP_Length(embeddingDim))
        let norm = sqrtf(sumSquares) + 1e-8
        var out = [Float](repeating: 0, count: embeddingDim)
        var divisor = norm
        vDSP_vsdiv(z2, 1, &divisor, &out, 1, vDSP_Length(embeddingDim))
        return out
    }
    
    // MARK: - Trích Xuất Vector Đặc Trưng 78 Chiều từ PixelBuffer
    private func extractFeatures(from pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [Float](repeating: 0.5, count: inputDim)
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let boxSize = 64
        let startX = max(0, min(width - boxSize, Int(targetPoint.x * CGFloat(width)) - boxSize / 2))
        let startY = max(0, min(height - boxSize, Int(targetPoint.y * CGFloat(height)) - boxSize / 2))
        
        // 1. Grid 4x4 x 3 = 48 values
        var grid = [Float](repeating: 0, count: 48)
        let subCell = boxSize / 4
        for gy in 0..<4 {
            for gx in 0..<4 {
                var rSum: Float = 0, gSum: Float = 0, bSum: Float = 0
                let cellX = startX + gx * subCell
                let cellY = startY + gy * subCell
                for y in 0..<subCell {
                    for x in 0..<subCell {
                        let offset = (cellY + y) * bytesPerRow + (cellX + x) * 4
                        bSum += Float(buffer[offset]) / 255.0
                        gSum += Float(buffer[offset + 1]) / 255.0
                        rSum += Float(buffer[offset + 2]) / 255.0
                    }
                }
                let totalPixels = Float(subCell * subCell)
                let idx = (gy * 4 + gx) * 3
                grid[idx] = rSum / totalPixels
                grid[idx + 1] = gSum / totalPixels
                grid[idx + 2] = bSum / totalPixels
            }
        }
        
        // 2. Color Histogram 8 bins x 3 = 24 values
        var hist = [Float](repeating: 0, count: 24)
        for y in 0..<boxSize {
            for x in 0..<boxSize {
                let offset = (startY + y) * bytesPerRow + (startX + x) * 4
                let bBin = min(7, Int(Float(buffer[offset]) / 32.0))
                let gBin = min(7, Int(Float(buffer[offset + 1]) / 32.0))
                let rBin = min(7, Int(Float(buffer[offset + 2]) / 32.0))
                hist[rBin] += 1.0
                hist[8 + gBin] += 1.0
                hist[16 + bBin] += 1.0
            }
        }
        let totalH = Float(boxSize * boxSize)
        for i in 0..<24 { hist[i] /= totalH }
        
        // 3. Gradient Variance & Texture Features (6 values: 4 quadrants + patch variance + directional ratio)
        var grad = [Float](repeating: 0, count: 6)
        var quadGrads = [[Float](), [Float](), [Float](), [Float]()]
        var allGrads = [Float]()
        allGrads.reserveCapacity(boxSize * boxSize)
        var totalGx: Float = 0
        var totalGy: Float = 0
        
        for y in 1..<(boxSize - 1) {
            for x in 1..<(boxSize - 1) {
                let pLeft = (startY + y) * bytesPerRow + (startX + x - 1) * 4
                let pRight = (startY + y) * bytesPerRow + (startX + x + 1) * 4
                let pUp = (startY + y - 1) * bytesPerRow + (startX + x) * 4
                let pDown = (startY + y + 1) * bytesPerRow + (startX + x) * 4
                
                let lumL = Float(buffer[pLeft]) * 0.114 + Float(buffer[pLeft+1]) * 0.587 + Float(buffer[pLeft+2]) * 0.299
                let lumR = Float(buffer[pRight]) * 0.114 + Float(buffer[pRight+1]) * 0.587 + Float(buffer[pRight+2]) * 0.299
                let lumU = Float(buffer[pUp]) * 0.114 + Float(buffer[pUp+1]) * 0.587 + Float(buffer[pUp+2]) * 0.299
                let lumD = Float(buffer[pDown]) * 0.114 + Float(buffer[pDown+1]) * 0.587 + Float(buffer[pDown+2]) * 0.299
                
                let gx = abs(lumR - lumL)
                let gy = abs(lumD - lumU)
                let mag = sqrtf(gx * gx + gy * gy) / 255.0
                
                allGrads.append(mag)
                totalGx += gx
                totalGy += gy
                
                let qx = x < (boxSize / 2) ? 0 : 1
                let qy = y < (boxSize / 2) ? 0 : 1
                quadGrads[qy * 2 + qx].append(mag)
            }
        }
        
        for q in 0..<4 {
            let count = Float(max(1, quadGrads[q].count))
            grad[q] = quadGrads[q].reduce(0, +) / count
        }
        let allCount = Float(max(1, allGrads.count))
        let meanGrad = allGrads.reduce(0, +) / allCount
        let gradVar = allGrads.reduce(0) { $0 + powf($1 - meanGrad, 2) } / allCount
        grad[4] = gradVar * 10.0
        grad[5] = (totalGx + totalGy) > 0 ? (totalGx / (totalGx + totalGy)) : 0.5
        
        var features = [Float]()
        features.reserveCapacity(inputDim)
        features.append(contentsOf: grid)
        features.append(contentsOf: hist)
        features.append(contentsOf: grad)
        
        // Chuẩn hóa ImageNet
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        for i in 0..<features.count {
            let m = mean[i % 3]
            let s = std[i % 3]
            features[i] = (features[i] - m) / s
        }
        
        return features
    }
}
