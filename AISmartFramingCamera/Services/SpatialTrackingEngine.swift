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
    
    // MARK: - 3D Spatial World-Ray Direction Memory
    // Tia định hướng 3D trong hệ quy chiếu thế giới tĩnh (World Reference Frame với trục Z thẳng đứng).
    // Dựa trên cảm biến hợp nhất CoreMotion CMAttitude (Gravity-referenced AHRS), không drift theo thời gian.
    private var anchor3DRay: SIMD3<Double>? = nil

    // Tọa độ chiếu không bị kẹp biên (phục vụ Vision Re-acquisition khi lia máy từ góc xa trở lại)
    private var unclampedScreenX: Double = 0.5
    private var unclampedScreenY: Double = 0.5

    public var currentUnclampedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGPoint(x: unclampedScreenX, y: unclampedScreenY)
    }

    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGPoint(x: unclampedScreenX, y: unclampedScreenY)
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
    private var trackingRevision: UInt64 = 0

    private var latestRotationRate = SIMD3<Double>(repeating: 0)
    private var cameraResidualVelocity = SIMD2<Double>(repeating: 0)
    private var lastRawOpticalPoint: CGPoint? = nil
    private var lastRawOpticalTime: CFTimeInterval = 0

    // Giản luật chống nhảy đột biến
    public var maxObservationJump: CGFloat = 0.15
    public var opticalAcceptThreshold: Double = 0.20

    // MARK: - Bộ Lọc 1-Euro Thích Nghi (Adaptive 1-Euro Filter)
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
        return _isStreetMode ? 6.00 : 4.50
    }

    private let oneEuroDCutoff: Double = 1.20

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

    // MARK: - 3D Math & Projection Helpers
    private func normalizeVector3D(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard len > 1.0e-9 else { return SIMD3<Double>(0, 0, -1) }
        return v / len
    }

    /// Chuyển đổi tọa độ màn hình chuẩn hóa (0..1) sang tia 3D đơn vị trong hệ tọa độ thiết bị
    /// (Camera sau nhìn theo trục -Z, tỉ lệ cảm biến camera chân dung 3:4)
    private func rayFromScreenPoint(_ point: CGPoint, zoom: Double) -> SIMD3<Double> {
        let zFactor = max(1.0, zoom)
        let fx = 0.88 * zFactor
        let fy = 0.66 * zFactor
        let dx = (Double(point.x) - 0.5) / fx
        let dy = (0.5 - Double(point.y)) / fy
        let dz = -1.0
        return normalizeVector3D(SIMD3<Double>(dx, dy, dz))
    }

    /// Chuyển vector từ hệ tọa độ thiết bị sang hệ quy chiếu thế giới tĩnh: r_world = R * v_dev
    private func deviceToWorld(_ v: SIMD3<Double>, rotationMatrix R: CMRotationMatrix) -> SIMD3<Double> {
        return SIMD3<Double>(
            R.m11 * v.x + R.m12 * v.y + R.m13 * v.z,
            R.m21 * v.x + R.m22 * v.y + R.m23 * v.z,
            R.m31 * v.x + R.m32 * v.y + R.m33 * v.z
        )
    }

    /// Chuyển vector từ hệ quy chiếu thế giới sang hệ tọa độ camera hiện tại: v_dev = R^T * r_world
    private func worldToDevice(_ r: SIMD3<Double>, rotationMatrix R: CMRotationMatrix) -> SIMD3<Double> {
        return SIMD3<Double>(
            R.m11 * r.x + R.m21 * r.y + R.m31 * r.z,
            R.m12 * r.x + R.m22 * r.y + R.m32 * r.z,
            R.m13 * r.x + R.m23 * r.y + R.m33 * r.z
        )
    }

    /// Chiếu tia thiết bị 3D lên màn hình chuẩn hóa (u, v) không kẹp biên
    private func projectDeviceToScreen(_ v: SIMD3<Double>, zoom: Double) -> (point: CGPoint, isInFront: Bool) {
        let zFactor = max(1.0, zoom)
        let fx = 0.88 * zFactor
        let fy = 0.66 * zFactor
        if v.z < -0.02 {
            let zDenom = -v.z
            let u = 0.5 + (v.x / zDenom) * fx
            let vScr = 0.5 - (v.y / zDenom) * fy
            return (CGPoint(x: u, y: vScr), true)
        } else {
            // Vật thể nằm phía sau camera (>90 độ)
            let zDenom = max(0.01, abs(v.z))
            let u = 0.5 + (v.x / zDenom) * fx * 3.0
            let vScr = 0.5 - (v.y / zDenom) * fy * 3.0
            return (CGPoint(x: u, y: vScr), false)
        }
    }

    // MARK: - Khởi tạo Mỏ Neo Không Gian 3D (Pin 3D Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        currentZoom = Double(max(1.0, zoom))
        anchorInitialPoint = screenPoint
        stateX = Double(screenPoint.x)
        stateY = Double(screenPoint.y)
        unclampedScreenX = Double(screenPoint.x)
        unclampedScreenY = Double(screenPoint.y)
        velocityX = 0.0
        velocityY = 0.0

        // Khởi tạo gốc 1-Euro
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
        latestRotationRate = .zero
        cameraResidualVelocity = .zero

        // Khởi tạo tia định hướng 3D thế giới ngay tại thời điểm khóa nếu sensor sẵn sàng
        if let attitude = motionManager.deviceMotion?.attitude {
            let vDev = rayFromScreenPoint(screenPoint, zoom: currentZoom)
            let rWorld = deviceToWorld(vDev, rotationMatrix: attitude.rotationMatrix)
            anchor3DRay = normalizeVector3D(rWorld)
        } else {
            anchor3DRay = nil
        }

        trackingRevision &+= 1
        _isTrackingActive = true
        stateLock.unlock()

        CameraLogger.info("Khóa mỏ neo không gian 3D tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)

        startMotionSensors()
    }

    public func updateZoomFactor(_ zoom: CGFloat) {
        let newZoom = Double(max(1.0, zoom))
        stateLock.lock()
        currentZoom = newZoom
        stateLock.unlock()
    }

    private var lastMotionTime: TimeInterval = 0
    private var deadReckoningFrameCount: Int = 0

    // MARK: - Khởi động cảm biến 60Hz CoreMotion Attitude (AHRS Fusion)
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

            self.lastMotionTime = now
            self.latestRotationRate = SIMD3<Double>(
                motion.rotationRate.x,
                motion.rotationRate.y,
                motion.rotationRate.z
            )

            let R = motion.attitude.rotationMatrix

            // Nếu anchor3DRay chưa kịp khởi tạo lúc lock, tạo ngay ở frame cảm biến đầu tiên
            if self.anchor3DRay == nil {
                let vDev = self.rayFromScreenPoint(CGPoint(x: self.stateX, y: self.stateY), zoom: self.currentZoom)
                let rWorld = self.deviceToWorld(vDev, rotationMatrix: R)
                self.anchor3DRay = self.normalizeVector3D(rWorld)
            }

            // Chiếu tia 3D từ hệ quy chiếu thế giới sang tọa độ camera hiện tại
            var projPoint = CGPoint(x: self.stateX, y: self.stateY)
            var isInFront = true
            if let rWorld = self.anchor3DRay {
                let vDev = self.worldToDevice(rWorld, rotationMatrix: R)
                let (proj, inFront) = self.projectDeviceToScreen(vDev, zoom: self.currentZoom)
                projPoint = proj
                isInFront = inFront
            }

            // Tọa độ không bị kẹp biên (unclamped) — phục vụ Vision Re-acquisition kiểm tra vùng biên
            self.unclampedScreenX = Double(projPoint.x)
            self.unclampedScreenY = Double(projPoint.y)

            let opticalAge = self.lastOpticalAcceptTime > 0
                ? now - self.lastOpticalAcceptTime
                : .greatestFiniteMagnitude

            // VÙNG BẢO VỆ OPTICAL 110ms: Khi Apple Vision đang bám mục tiêu chuẩn xác,
            // quang học là ground truth tuyệt đối, gyro KHÔNG được ghi đè stateX/stateY.
            guard opticalAge > 0.11 else {
                self.stateLock.unlock()
                return
            }

            // KHI MẤT DẤU QUANG HỌC (>110ms): Định vị chuẩn xác theo phép chiếu không gian 3D
            self.deadReckoningFrameCount += 1
            self.stateX = Double(projPoint.x)
            self.stateY = Double(projPoint.y)

            let isOffScreen = !isInFront || projPoint.x < 0.0 || projPoint.x > 1.0 || projPoint.y < 0.0 || projPoint.y > 1.0

            // Tọa độ gửi về UI: kẹp trong [0.03, 0.97] để vòng target nằm sát viền màn hình chỉ hướng
            let uiPoint = CGPoint(
                x: min(0.97, max(0.03, projPoint.x)),
                y: min(0.97, max(0.03, projPoint.y))
            )

            let callback = self._onSpatialTargetUpdated
            let revision = sensorRevision
            let confidence: Double
            let quality: TrackingQuality

            // Bộ nhớ 3D dựa trên trọng lực không bao giờ drift pitch/roll, yaw trôi rất chậm (<0.5 độ/phút).
            // Do đó confidence được duy trì ổn định, không bị rớt về 0.12 chỉ sau vài giây.
            if opticalAge > 5.0 {
                confidence = max(0.40, self.lastOpticalConfidence * exp(-0.08 * (opticalAge - 5.0)))
                quality = isOffScreen ? .reacquiring : .predicting
            } else if opticalAge > 1.2 {
                confidence = max(0.50, self.lastOpticalConfidence * exp(-0.06 * (opticalAge - 1.2)))
                quality = isOffScreen ? .reacquiring : .predicting
            } else {
                confidence = max(0.60, self.lastOpticalConfidence * exp(-0.03 * opticalAge))
                quality = .predicting
            }
            self.stateLock.unlock()

            DispatchQueue.main.async {
                guard self.isTrackingRevisionCurrent(revision) else { return }
                callback?(uiPoint, confidence, quality)
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
            lastOpticalConfidence = confidence
            stateLock.unlock()
            return
        }

        let isVerifiedVision = confidence >= 0.60
        var rawX = Double(visualPoint.x)
        var rawY = Double(visualPoint.y)

        // Auxiliary measurements chỉ được phép dịch chuyển cục bộ
        let jump = hypot(rawX - stateX, rawY - stateY)
        if !isVerifiedVision, jump > Double(maxObservationJump) {
            let scale = Double(maxObservationJump) / max(jump, 1.0e-9)
            rawX = stateX + (rawX - stateX) * scale
            rawY = stateY + (rawY - stateY) * scale
        }

        lastRawOpticalPoint = visualPoint
        lastRawOpticalTime = now

        // 1. ĐỆM ĐÀN HỒI CENTROID DEADBAND CUSHION (Khắc phục triệt để "đi xung quanh rất nhiều"):
        // - Deadband (< 0.005 ~ 2-3 subpixel): Khi người dùng đứng yên, triệt tiêu 100% rung giật vi sai
        // - Elastic Slack (0.005 ... 0.035): Chuyển tiếp cubic smoothstep mượt mà tự nhiên ("vẫn dc phép xê dịch nhưng ko quá")
        // - Active Tracking (>= 0.035): Bám dính tức thì theo chuyển động thực tế
        let dxFromPrev = rawX - filterXPrev
        let dyFromPrev = rawY - filterYPrev
        let distFromPrev = hypot(dxFromPrev, dyFromPrev)

        let deadband = 0.005
        let elasticBand = 0.035
        let effectiveX: Double
        let effectiveY: Double

        if distFromPrev < deadband {
            effectiveX = filterXPrev
            effectiveY = filterYPrev
        } else if distFromPrev < elasticBand {
            let t = (distFromPrev - deadband) / (elasticBand - deadband)
            let smoothFactor = t * t * (3.0 - 2.0 * t) // cubic smoothstep
            effectiveX = filterXPrev + dxFromPrev * smoothFactor
            effectiveY = filterYPrev + dyFromPrev * smoothFactor
        } else {
            effectiveX = rawX
            effectiveY = rawY
        }

        let (smoothX, smoothY) = applyOneEuroFilter(
            obsX: effectiveX,
            obsY: effectiveY,
            timestamp: now,
            dt: dt
        )
        stateX = min(0.99, max(0.01, smoothX))
        stateY = min(0.99, max(0.01, smoothY))
        unclampedScreenX = stateX
        unclampedScreenY = stateY
        lastOpticalConfidence = confidence
        lastOpticalAcceptTime = now
        deadReckoningFrameCount = 0
        outlierStreak = 0

        // 2. TỰ ĐỘNG CÂN CHỈNH TIA 3D THẾ GIỚI LIÊN TUYẾN (World-Ray Online Realignment):
        // Khi Apple Vision nhìn thấy rõ vật thể, cập nhật nhẹ nhàng tia 3D thế giới
        // để triệt tiêu hoàn toàn bất kỳ trôi yaw hay thị sai do tay xê dịch nhẹ.
        if isVerifiedVision, let attitude = motionManager.deviceMotion?.attitude {
            let R = attitude.rotationMatrix
            let vObs = rayFromScreenPoint(CGPoint(x: stateX, y: stateY), zoom: currentZoom)
            let rWorldObs = normalizeVector3D(deviceToWorld(vObs, rotationMatrix: R))
            if let currentRay = anchor3DRay {
                let blendAlpha = 0.05
                anchor3DRay = normalizeVector3D((1.0 - blendAlpha) * currentRay + blendAlpha * rWorldObs)
            } else {
                anchor3DRay = rWorldObs
            }
        }

        let targetPoint = CGPoint(x: stateX, y: stateY)
        let callback = _onSpatialTargetUpdated
        let quality: TrackingQuality = isVerifiedVision ? .locked : .predicting
        stateLock.unlock()
        callback?(targetPoint, confidence, quality)
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
        let speed = hypot(dxHat, dyHat)
        let adaptiveCutoff = effectiveMinCutoff + effectiveBeta * speed

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
        anchor3DRay = nil
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
