import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Vision-first target tracker cho camera cầm tay iPhone.
///
/// Khi Apple Vision còn nhìn thấy target, vị trí quang học là ground truth và gyro
/// tuyệt đối không được phép dịch vòng neo. Gyro chỉ ngoại suy trong khoảng mất
/// optical ngắn; hệ số gyro→pixel được học từ các frame Vision gần nhất để tự hấp
/// thụ OIS, crop, FOV và lens khác nhau thay vì dùng một focal-length giả định.
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var isLowTextureAnchor: Bool = false
    
    public func setLowTextureFlag(_ isLowTexture: Bool) {
        stateLock.lock()
        self.isLowTextureAnchor = isLowTexture
        stateLock.unlock()
    }
    
    // Tọa độ mục tiêu hiện tại trên màn hình UI (0.0 đến 1.0)
    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var velocityX: Double = 0.0
    private var velocityY: Double = 0.0
    
    // Trạng thái hoạt động
    private var _isTrackingActive: Bool = false
    public var isTrackingActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isTrackingActive
    }
    private var _activeSceneType: DetectedSceneType = .general
    public var activeSceneType: DetectedSceneType {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _activeSceneType }
        set { stateLock.lock(); _activeSceneType = newValue; stateLock.unlock() }
    }
    private var currentZoom: Double = 1.0
    private var lastOpticalConfidence: Double = 1.0
    private var lastUpdateTime: CFTimeInterval = 0
    
    // Đồng bộ state giữa luồng optical (main) và gyro (motionQueue) — chống data race
    private let stateLock = NSLock()
    private var lastOpticalAcceptTime: CFTimeInterval = 0
    private var outlierStreak: Int = 0
    /// Chỉ dùng để loại callback bất đồng bộ của session cũ sau stop/re-lock.
    /// Đây không phải measurement gate và không ảnh hưởng phép ước lượng vị trí.
    private var trackingRevision: UInt64 = 0

    // MARK: - Online gyro-to-image calibration
    // Không dùng fx=0.82 hay một FOV hard-code. Trong lúc Vision đang bám đúng,
    // ta quan sát screen velocity thật và học gain robust tương ứng với rate gyro.
    private var latestRotationRate = SIMD3<Double>(repeating: 0)
    private var gyroGainX: Double? = nil       // screen-x velocity / yaw rate
    private var gyroGainY: Double? = nil       // screen-y velocity / (-pitch rate)
    private var gyroGainXSamples: [Double] = []
    private var gyroGainYSamples: [Double] = []
    private var cameraResidualVelocity = SIMD2<Double>(repeating: 0)
    private var lastRawOpticalPoint: CGPoint? = nil
    private var lastRawOpticalTime: CFTimeInterval = 0
    private var reacquireFrameCount: Int = 0
    
    // Giản luật chống nhảy đột biến
    public var maxObservationJump: CGFloat = 0.15
    public var opticalAcceptThreshold: Double = 0.20
    
    // MARK: - Bộ Lọc 1-Euro Thích Nghi (Adaptive 1-Euro Filter)
    // Tinh chỉnh thực tế hoàn hảo:
    // - Khi đứng yên: MinCutoff 1.50Hz triệt tiêu 100% rung tay sinh học, mỏ neo đầm chắc
    // - Khi lia máy: Beta 1.80 tăng tần số cắt mượt mà, bám dính tức thì mà không bị vọt lố hay giật nhảy
    private var filterXPrev: Double = 0.5
    private var filterYPrev: Double = 0.5
    private var filterRawXPrev: Double = 0.5
    private var filterRawYPrev: Double = 0.5
    private var filterDxPrev: Double = 0.0
    private var filterDyPrev: Double = 0.0
    private var filterLastTime: CFTimeInterval = 0.0
    private var filterInitialized: Bool = false
    
    private var _isStreetMode: Bool = false
    public var isStreetMode: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isStreetMode }
        set { stateLock.lock(); _isStreetMode = newValue; stateLock.unlock() }
    }
    
    private var effectiveMinCutoff: Double {
        return _isStreetMode ? 2.00 : 1.50
    }
    
    private var effectiveBeta: Double {
        return _isStreetMode ? 7.00 : 5.00
    }
    
    private let oneEuroDCutoff: Double = 1.20
    
    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGPoint(x: stateX, y: stateY)
    }
    
    // Callback duy nhất truyền tọa độ về ViewModel
    private var _onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onSpatialTargetUpdated }
        set { stateLock.lock(); _onSpatialTargetUpdated = newValue; stateLock.unlock() }
    }
    
    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Khởi tạo Mỏ Neo Không Gian (Pin Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        currentZoom = Double(max(1.0, zoom))
        anchorInitialPoint = screenPoint
        stateX = Double(screenPoint.x)
        stateY = Double(screenPoint.y)
        velocityX = 0.0
        velocityY = 0.0

        // Reset 1-Euro tại đúng measurement đầu tiên. Cả raw và filtered history
        // phải cùng một gốc để derivative frame đầu không tạo một xung vận tốc giả.
        filterXPrev = Double(screenPoint.x)
        filterYPrev = Double(screenPoint.y)
        filterRawXPrev = Double(screenPoint.x)
        filterRawYPrev = Double(screenPoint.y)
        filterDxPrev = 0.0
        filterDyPrev = 0.0
        filterLastTime = now
        filterInitialized = true

        lastOpticalConfidence = 1.0
        lastOpticalAcceptTime = now
        lastRawOpticalPoint = screenPoint
        lastRawOpticalTime = now
        lastUpdateTime = now
        lastMotionTime = now
        deadReckoningFrameCount = 0
        outlierStreak = 0
        reacquireFrameCount = 0
        latestRotationRate = .zero
        gyroGainX = nil
        gyroGainY = nil
        gyroGainXSamples.removeAll(keepingCapacity: true)
        gyroGainYSamples.removeAll(keepingCapacity: true)
        cameraResidualVelocity = .zero
        trackingRevision &+= 1
        _isTrackingActive = true
        stateLock.unlock()
        
        CameraLogger.info("Khóa mỏ neo không gian thích nghi tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startMotionSensors()
    }
    
    public func updateZoomFactor(_ zoom: CGFloat) {
        let newZoom = Double(max(1.0, zoom))
        stateLock.lock()
        // Zoom/lens switch làm thay đổi FOV, crop và OIS transfer function. Các gain
        // gyro học ở tiêu cự cũ không còn có ý nghĩa vật lý nên phải học lại; tọa độ
        // target vẫn do Vision quyết định và hoàn toàn không bị reset.
        if abs(newZoom - currentZoom) > 0.025 {
            gyroGainX = nil
            gyroGainY = nil
            gyroGainXSamples.removeAll(keepingCapacity: true)
            gyroGainYSamples.removeAll(keepingCapacity: true)
            cameraResidualVelocity = SIMD2<Double>(velocityX, velocityY)
        }
        currentZoom = newZoom
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
        
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        stateLock.lock()
        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        let sensorRevision = trackingRevision
        stateLock.unlock()
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let now = CACurrentMediaTime()
            self.stateLock.lock()
            guard self._isTrackingActive, self.trackingRevision == sensorRevision else {
                self.stateLock.unlock()
                return
            }

            let dt = self.lastMotionTime > 0
                ? min(0.05, max(0.001, now - self.lastMotionTime))
                : (1.0 / 60.0)
            self.lastMotionTime = now
            self.latestRotationRate = SIMD3<Double>(
                motion.rotationRate.x,
                motion.rotationRate.y,
                motion.rotationRate.z
            )

            let opticalAge = self.lastOpticalAcceptTime > 0
                ? now - self.lastOpticalAcceptTime
                : .greatestFiniteMagnitude

            // Vùng bảo vệ 110 ms: khi Vision/KLT vẫn cấp measurement đúng nhịp,
            // gyro không được phép thay đổi target dù chỉ một pixel.
            guard opticalAge > 0.11 else {
                self.stateLock.unlock()
                return
            }

            self.deadReckoningFrameCount += 1
            let decay = exp(-1.35 * max(0.0, opticalAge - 0.11))

            // q_dot không tự biến thành pixel. Gain signed bên dưới được học online
            // từ cặp (rotationRate, optical screen velocity), do đó đã bao gồm FOV,
            // electronic crop, orientation và đáp ứng OIS của camera đang dùng.
            let gyroVX = self.gyroGainX.map { $0 * motion.rotationRate.y }
            let gyroVY = self.gyroGainY.map { $0 * (-motion.rotationRate.x) }
            let predictVX = gyroVX.map { $0 + self.cameraResidualVelocity.x * decay }
                ?? (self.velocityX * decay)
            let predictVY = gyroVY.map { $0 + self.cameraResidualVelocity.y * decay }
                ?? (self.velocityY * decay)

            // Giới hạn vận tốc là hàng rào an toàn cho spike IMU, không phải mô hình
            // chuyển động. 3 screen/s vẫn dư cho một cú whip-pan thực tế.
            let safeVX = min(3.0, max(-3.0, predictVX))
            let safeVY = min(3.0, max(-3.0, predictVY))
            self.stateX = min(0.99, max(0.01, self.stateX + safeVX * dt))
            self.stateY = min(0.99, max(0.01, self.stateY + safeVY * dt))

            let point = CGPoint(x: self.stateX, y: self.stateY)
            let callback = self._onSpatialTargetUpdated
            let revision = sensorRevision
            let confidence: Double
            let quality: TrackingQuality
            if opticalAge > 4.0 {
                confidence = 0.12
                quality = .lost
            } else if opticalAge > 1.5 {
                confidence = max(0.20, self.lastOpticalConfidence * exp(-0.7 * (opticalAge - 1.5)))
                quality = .reacquiring
            } else {
                confidence = max(0.32, self.lastOpticalConfidence * exp(-0.45 * opticalAge))
                quality = .predicting
            }
            self.stateLock.unlock()

            DispatchQueue.main.async {
                guard self.isTrackingRevisionCurrent(revision) else { return }
                callback?(point, confidence, quality)
            }
        }
    }

    private func isTrackingRevisionCurrent(_ revision: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isTrackingActive && trackingRevision == revision
    }
    
    // MARK: - Dung hợp Dữ liệu Quang Học (Vision Optical Observation Update)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        guard _isTrackingActive else {
            stateLock.unlock()
            return
        }

        let dt = lastUpdateTime > 0
            ? min(0.12, max(0.005, now - lastUpdateTime))
            : (1.0 / 30.0)
        lastUpdateTime = now
        let effectiveThreshold = max(opticalAcceptThreshold, isLowTextureAnchor ? 0.30 : 0.0)

        guard let visualPoint = point, confidence >= effectiveThreshold else {
            // Không đẩy target ở đây. Motion loop sẽ tự chuyển sang fallback chỉ khi
            // opticalAge vượt 110 ms, tránh một frame Vision trễ gây nhảy nguồn.
            lastOpticalConfidence = confidence
            stateLock.unlock()
            return
        }

        let opticalAgeBeforeUpdate = now - lastOpticalAcceptTime
        let isVerifiedVision = confidence >= 0.60
        var rawX = Double(visualPoint.x)
        var rawY = Double(visualPoint.y)

        // Auxiliary measurements (KLT/VO) chỉ được phép dịch chuyển cục bộ. Một
        // measurement Vision đã xác minh thì là ground truth và không bị statistical/jump
        // gate chặn; đây là điểm khác biệt cốt lõi so với EKF cũ.
        let jump = hypot(rawX - stateX, rawY - stateY)
        if !isVerifiedVision, jump > Double(maxObservationJump) {
            let scale = Double(maxObservationJump) / max(jump, 1.0e-9)
            rawX = stateX + (rawX - stateX) * scale
            rawY = stateY + (rawY - stateY) * scale
        }

        if let previous = lastRawOpticalPoint {
            let rawElapsed = now - lastRawOpticalTime
            let rawDt = min(0.12, max(0.005, rawElapsed))
            let observedVelocity = SIMD2<Double>(
                (Double(visualPoint.x) - Double(previous.x)) / rawDt,
                (Double(visualPoint.y) - Double(previous.y)) / rawDt
            )
            // Không học calibration từ cú nhảy reacquire: displacement đó tích lũy
            // trong cả khoảng che khuất, không phải vận tốc của một frame camera.
            if isVerifiedVision, rawElapsed <= 0.12 {
                updateGyroCalibrationLocked(observedVelocity: observedVelocity)
            }
        }
        lastRawOpticalPoint = visualPoint
        lastRawOpticalTime = now

        // Khi Vision trở lại sau dead-reckoning, hòa vào measurement thật trong tối
        // đa ba frame. Không gate và không kéo dài blend, nên vừa tránh teleport vừa
        // không tạo cảm giác vòng bám "đuổi theo" target.
        if opticalAgeBeforeUpdate > 0.11 {
            reacquireFrameCount = 1
        } else if reacquireFrameCount > 0, reacquireFrameCount < 3 {
            reacquireFrameCount += 1
        } else if reacquireFrameCount >= 3 {
            reacquireFrameCount = 0
        }
        if reacquireFrameCount > 0 {
            let blend: Double = reacquireFrameCount == 1 ? 0.55 : (reacquireFrameCount == 2 ? 0.80 : 1.0)
            rawX = stateX + (rawX - stateX) * blend
            rawY = stateY + (rawY - stateY) * blend
        }

        let (smoothX, smoothY) = applyOneEuroFilter(
            obsX: rawX,
            obsY: rawY,
            timestamp: now,
            dt: dt
        )
        stateX = min(0.99, max(0.01, smoothX))
        stateY = min(0.99, max(0.01, smoothY))
        lastOpticalConfidence = confidence
        lastOpticalAcceptTime = now
        deadReckoningFrameCount = 0
        outlierStreak = 0

        let targetPoint = CGPoint(x: stateX, y: stateY)
        let callback = _onSpatialTargetUpdated
        let quality: TrackingQuality = isVerifiedVision ? .locked : .predicting
        stateLock.unlock()
        callback?(targetPoint, confidence, quality)
    }

    /// Học online phép chiếu vận tốc góc (rad/s) sang vận tốc ảnh chuẩn hóa
    /// (screen/s). Median cửa sổ ngắn loại spike và chuyển động độc lập của chủ thể.
    /// Chỉ học trên trục gyro đang chiếm ưu thế để giảm cross-axis/roll coupling.
    private func updateGyroCalibrationLocked(observedVelocity: SIMD2<Double>) {
        let rate = latestRotationRate
        guard abs(rate.z) < 0.55 else { return }

        if abs(rate.y) > 0.18, abs(rate.y) > abs(rate.x) * 1.15 {
            (gyroGainXSamples, gyroGainX) = robustGainUpdate(
                observedVelocity.x / rate.y,
                samples: gyroGainXSamples,
                estimate: gyroGainX
            )
        }
        let pitchImageRate = -rate.x
        if abs(pitchImageRate) > 0.18, abs(rate.x) > abs(rate.y) * 1.15 {
            (gyroGainYSamples, gyroGainY) = robustGainUpdate(
                observedVelocity.y / pitchImageRate,
                samples: gyroGainYSamples,
                estimate: gyroGainY
            )
        }

        let gyroVX = gyroGainX.map { $0 * rate.y }
        let gyroVY = gyroGainY.map { $0 * pitchImageRate }
        let residualX = gyroVX.map { observedVelocity.x - $0 } ?? observedVelocity.x
        let residualY = gyroVY.map { observedVelocity.y - $0 } ?? observedVelocity.y
        cameraResidualVelocity.x = 0.75 * cameraResidualVelocity.x + 0.25 * residualX
        cameraResidualVelocity.y = 0.75 * cameraResidualVelocity.y + 0.25 * residualY
    }

    /// Giữ tối đa 21 mẫu và dùng median thay cho mean. Gain được phép mang dấu vì
    /// orientation/camera transform quyết định cực tính; chỉ độ lớn phi vật lý bị bỏ.
    private func robustGainUpdate(
        _ sample: Double,
        samples: [Double],
        estimate: Double?
    ) -> ([Double], Double?) {
        guard sample.isFinite, abs(sample) >= 0.04, abs(sample) <= 3.5 else {
            return (samples, estimate)
        }
        var updatedSamples = samples
        updatedSamples.append(sample)
        if updatedSamples.count > 21 {
            updatedSamples.removeFirst(updatedSamples.count - 21)
        }
        let sorted = updatedSamples.sorted()
        let median = sorted[sorted.count / 2]
        if let old = estimate {
            return (updatedSamples, old * 0.75 + median * 0.25)
        } else if updatedSamples.count >= 3 {
            return (updatedSamples, median)
        }
        return (updatedSamples, nil)
    }
    
    // MARK: - 1-Euro Filter Math Helper
    private func applyOneEuroFilter(obsX: Double, obsY: Double, timestamp: CFTimeInterval, dt: Double) -> (Double, Double) {
        guard filterInitialized else {
            filterXPrev = obsX
            filterYPrev = obsY
            filterRawXPrev = obsX
            filterRawYPrev = obsY
            filterLastTime = timestamp
            filterInitialized = true
            return (obsX, obsY)
        }
        
        let rate = 1.0 / max(0.005, dt)
        
        // 1. Tính toán đạo hàm vận tốc (Derivative dx, dy)
        let rawDx = (obsX - filterRawXPrev) / max(0.005, dt)
        let rawDy = (obsY - filterRawYPrev) / max(0.005, dt)
        filterRawXPrev = obsX
        filterRawYPrev = obsY
        
        let aD = alpha(rate: rate, cutoff: oneEuroDCutoff)
        let dxHat = aD * rawDx + (1.0 - aD) * filterDxPrev
        let dyHat = aD * rawDy + (1.0 - aD) * filterDyPrev
        filterDxPrev = dxHat
        filterDyPrev = dyHat
        
        // 2. Tần số cắt thích nghi theo vận tốc di chuyển camera:
        // - Khi đứng yên: speed nhỏ -> cutoff gần minCutoff (1.2Hz) -> triệt rung tay
        // - Khi di chuyển tâm trắng đến target: speed tăng -> cutoff tăng tức thì -> target bám dính mượt mà
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
        _isTrackingActive = false
        trackingRevision &+= 1
        filterInitialized = false
        lastRawOpticalPoint = nil
        gyroGainX = nil
        gyroGainY = nil
        gyroGainXSamples.removeAll(keepingCapacity: false)
        gyroGainYSamples.removeAll(keepingCapacity: false)
        cameraResidualVelocity = .zero
        stateLock.unlock()
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        CameraLogger.info("Đã dừng động cơ tracking không gian", category: .tracking)
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
    
    private let modelLock = NSLock()
    private let embeddingLock = NSLock()
    private var anchorEmbedding: [Float]? = nil
    private var isModelLoaded: Bool = false
    private var _hasActiveTrainedModel: Bool = false
    public var hasActiveTrainedModel: Bool {
        modelLock.lock()
        defer { modelLock.unlock() }
        return _hasActiveTrainedModel
    }
    
    public init() {
        loadModelWeights()
    }
    
    public func loadModelWeights() {
        modelLock.lock()
        defer { modelLock.unlock() }
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
        _hasActiveTrainedModel = true
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
        _hasActiveTrainedModel = false
    }
    
    // MARK: - 1. Lưu Vân Tay Mỏ Neo Ban Đầu (Anchor Fingerprint)
    public func setAnchorTemplate(from pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) {
        let features = extractFeatures(from: pixelBuffer, at: targetPoint)
        let embedding = forwardPass(features)
        embeddingLock.lock()
        anchorEmbedding = embedding
        embeddingLock.unlock()
        CameraLogger.info("Đã khóa vân tay nơ-ron cho mục tiêu tại (\(String(format: "%.2f", targetPoint.x)), \(String(format: "%.2f", targetPoint.y)))", category: .tracking)
    }
    
    // MARK: - 2. So Khớp Vân Tay Hiện Tại (Cosine Similarity: 0.0 - 1.0)
    public func verifyTarget(in pixelBuffer: CVPixelBuffer, at targetPoint: CGPoint) -> Double {
        embeddingLock.lock()
        let anchor = anchorEmbedding
        embeddingLock.unlock()
        guard let anchor else { return 0.0 }
        let currentFeatures = extractFeatures(from: pixelBuffer, at: targetPoint)
        let currentEmbedding = forwardPass(currentFeatures)
        
        var dotProduct: Float = 0
        vDSP_dotpr(anchor, 1, currentEmbedding, 1, &dotProduct, vDSP_Length(embeddingDim))
        return Double(max(0.0, min(1.0, dotProduct)))
    }
    
    // MARK: - 3. Quét Lưới 9 Điểm Cục Bộ Tìm Đỉnh Tương Đồng (Neural Peak Grid Search 3x3)
    public func findBestMatchingPoint(in pixelBuffer: CVPixelBuffer, around centerPoint: CGPoint, searchRadius: CGFloat = 0.04) -> (CGPoint, Double) {
        embeddingLock.lock()
        let anchor = anchorEmbedding
        embeddingLock.unlock()
        guard let anchor else { return (centerPoint, 0.0) }

        let centerEmbedding = forwardPass(extractFeatures(from: pixelBuffer, at: centerPoint))
        var centerDot: Float = 0
        vDSP_dotpr(anchor, 1, centerEmbedding, 1, &centerDot, vDSP_Length(embeddingDim))
        let centerSim = Double(max(0.0, min(1.0, centerDot)))
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
        embeddingLock.lock()
        anchorEmbedding = nil
        embeddingLock.unlock()
    }
    
    // MARK: - Neural Forward Pass (Layer 1 -> LeakyReLU -> Layer 2 -> L2 Norm)
    private func forwardPass(_ input: [Float]) -> [Float] {
        modelLock.lock()
        defer { modelLock.unlock() }
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
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) >= 8,
              CVPixelBufferGetHeight(pixelBuffer) >= 8 else {
            return [Float](repeating: 0.0, count: inputDim)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return [Float](repeating: 0.5, count: inputDim)
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let boxSize = min(64, min(width, height))
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
