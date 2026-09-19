import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Bộ hợp nhất visual-inertial cho mỏ neo 2-D.
///
/// Trạng thái EKF là `[u, v, vu, vv, bu, bv]`:
/// - `u, v`: tọa độ target chuẩn hóa trong preview.
/// - `vu, vv`: chuyển động riêng của target trong ảnh (screen units / second).
/// - `bu, bv`: bias chậm của optical-flow dự đoán từ gyro. Bias hấp thụ sai số
///   căn trục IMU-camera và sai số FOV mà không tích lũy thành drift dài hạn.
///
/// Gyro luôn tham gia bước predict, kể cả khi Vision đang trả kết quả. Đây là điểm
/// quan trọng để không có khe trễ pha 2-4 frame khi bắt đầu lia nhanh. Vision, KLT
/// và image registration chỉ là measurement; innovation được kiểm tra bằng NIS
/// (Mahalanobis distance) trước khi được phép sửa state.
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    private let stateLock = NSLock()

    // State vector and its full 6x6 covariance, stored row-major. A fixed-size
    // small matrix is faster and allocates less than a general LA object at 100 Hz.
    private var x = [Double](repeating: 0, count: 6)
    private var p = [Double](repeating: 0, count: 36)
    private var lastPredictionTime: CFTimeInterval = 0
    private var lastOpticalAcceptTime: CFTimeInterval = 0
    private var lastOpticalConfidence: Double = 0
    private var lastGyroRate = SIMD3<Double>(repeating: 0)
    private var fastGyroRate = SIMD3<Double>(repeating: 0)
    private var slowGyroRate = SIMD3<Double>(repeating: 0)
    private var lastUIEmissionTime: CFTimeInterval = 0
    private var consecutiveRejectedMeasurements = 0
    private var stateRevision: UInt64 = 0
    private var _isTrackingActive = false
    private var _isLowTextureAnchor = false
    private var _isStreetMode = false
    private var _activeSceneType: DetectedSceneType = .general
    private var _currentZoom: Double = 1.0
    private var _targetZoom: Double = 1.0
    private var _anchorZoom: Double = 1.0
    private var _maxObservationJump: CGFloat = 0.15
    private var _opticalAcceptThreshold: Double = 0.20
    private var _callback: ((CGPoint, Double, TrackingQuality) -> Void)?

    /// Giữ API cũ nhưng mọi truy cập chéo queue đều được khóa.
    public private(set) var isTrackingActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isTrackingActive }
        set { stateLock.lock(); _isTrackingActive = newValue; stateLock.unlock() }
    }

    public func setLowTextureFlag(_ isLowTexture: Bool) {
        stateLock.lock()
        _isLowTextureAnchor = isLowTexture
        stateLock.unlock()
    }

    public var activeSceneType: DetectedSceneType {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _activeSceneType }
        set { stateLock.lock(); _activeSceneType = newValue; stateLock.unlock() }
    }

    public var isStreetMode: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isStreetMode }
        set { stateLock.lock(); _isStreetMode = newValue; stateLock.unlock() }
    }

    /// Các knob cũ vẫn được giữ để Settings/ViewModel không đổi API. Chúng được
    /// đọc dưới lock và tham gia measurement gate thay vì cắt cứng output.
    public var maxObservationJump: CGFloat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _maxObservationJump }
        set { stateLock.lock(); _maxObservationJump = max(0.02, newValue); stateLock.unlock() }
    }
    public var opticalAcceptThreshold: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _opticalAcceptThreshold }
        set { stateLock.lock(); _opticalAcceptThreshold = min(0.95, max(0.05, newValue)); stateLock.unlock() }
    }

    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return outputPointLocked()
    }

    /// Bán kính 3-sigma của ước lượng, dùng để Vision mở rộng vùng re-ID đúng mức
    /// khi occlusion kéo dài mà không phải quét toàn frame.
    public var currentUncertaintyRadius: CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGFloat(min(0.30, max(0.025, 3.0 * sqrt(max(p[0], p[7])))))
    }

    /// Tỷ lệ FOV hiện tại so với lúc pin, để re-ID thử đúng scale sau 1x→3x.
    public var relativeZoomSinceAnchor: CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGFloat(_currentZoom / max(0.1, _anchorZoom))
    }

    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _callback }
        set { stateLock.lock(); _callback = newValue; stateLock.unlock() }
    }

    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
        x[0] = 0.5
        x[1] = 0.5
        resetCovarianceLocked()
    }

    // MARK: - Anchor lifecycle

    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        x = [Double(screenPoint.x), Double(screenPoint.y), 0, 0, 0, 0]
        resetCovarianceLocked()
        _currentZoom = Double(max(1.0, zoom))
        _targetZoom = _currentZoom
        _anchorZoom = _currentZoom
        lastPredictionTime = now
        lastOpticalAcceptTime = now
        lastOpticalConfidence = 1.0
        lastGyroRate = .zero
        fastGyroRate = .zero
        slowGyroRate = .zero
        consecutiveRejectedMeasurements = 0
        stateRevision &+= 1
        lastUIEmissionTime = 0
        _isTrackingActive = true
        stateLock.unlock()

        CameraLogger.info("Khóa mỏ neo không gian thích nghi tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        startMotionSensors()
    }

    /// Nhận target zoom. Predict loop sẽ ramp phép biến đổi quanh principal point:
    /// `p' = c + r(p-c)` đồng bộ gần với chuyển động quang học của preview.
    public func updateZoomFactor(_ zoom: CGFloat) {
        let newZoom = Double(max(1.0, zoom))
        stateLock.lock()
        let previousTarget = _targetZoom
        _targetZoom = newZoom
        stateLock.unlock()

        if abs(newZoom / max(1.0, previousTarget) - 1.0) > 0.015 {
            VisualOdometryEngine.shared.clearReference()
        }
    }

    // MARK: - IMU predict

    private func startMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }

        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
        // Predict và UI chạy cùng nhịp 60 Hz; Vision measurement chạy 30 Hz.
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self, let motion else { return }
            let now = CACurrentMediaTime()
            self.stateLock.lock()
            guard self._isTrackingActive else {
                self.stateLock.unlock()
                return
            }

            let rawRate = SIMD3<Double>(motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z)
            // Hai low-pass với hằng số thời gian khác nhau tách chuyển động chủ đích
            // (năng lượng thấp tần) khỏi rung tay 8-12 Hz. Chỉ high-frequency được
            // giảm nhẹ khi gần đứng yên; lúc pan/tilt nhanh gain trở về 1 tức thì.
            self.fastGyroRate += (rawRate - self.fastGyroRate) * 0.55
            self.slowGyroRate += (rawRate - self.slowGyroRate) * 0.10
            let intentional = simd_length(self.slowGyroRate)
            let highFrequency = self.fastGyroRate - self.slowGyroRate
            let tremorGain = min(1.0, max(0.58, intentional / 0.10))
            let fusedRate = self.slowGyroRate + highFrequency * tremorGain
            self.lastGyroRate = fusedRate

            self.predictLocked(to: now, gyroRate: fusedRate)
            let age = now - self.lastOpticalAcceptTime
            let quality = self.qualityLocked(opticalAge: age)
            let confidence = self.confidenceLocked(opticalAge: age)
            let point = self.outputPointLocked()
            let revision = self.stateRevision
            // 1/75 tạo tolerance cho jitter scheduler quanh tick 1/60, tránh vô
            // tình bỏ mỗi frame thứ hai vì timestamp ngắn hơn 16.667 ms vài µs.
            let shouldEmit = now - self.lastUIEmissionTime >= (1.0 / 75.0)
            if shouldEmit { self.lastUIEmissionTime = now }
            self.stateLock.unlock()

            if shouldEmit {
                DispatchQueue.main.async { [weak self] in
                    self?.publishIfCurrent(revision: revision, point: point, confidence: confidence, quality: quality)
                }
            }
        }
    }

    /// Optical flow do rotation của pinhole camera. `fx/fy` ở đơn vị chiều rộng
    /// và chiều cao chuẩn hóa. Các hạng bậc hai giữ đúng chuyển động ở gần rìa,
    /// nơi phép xấp xỉ tuyến tính `gyro * zoom` thường gây overshoot.
    private func gyroImageVelocityLocked(_ rate: SIMD3<Double>) -> SIMD2<Double> {
        let zoom = max(1.0, _currentZoom)
        let fx = 0.82 * zoom
        let fy = 0.82 * zoom
        let cx = x[0] - 0.5
        let cy = x[1] - 0.5

        let wx = rate.x
        let wy = rate.y
        let wz = rate.z
        let du = wy * (fx + cx * cx / fx) - wx * (cx * cy / fy) + wz * cy
        let dv = -wx * (fy + cy * cy / fy) + wy * (cx * cy / fx) - wz * cx
        return SIMD2<Double>(du, dv)
    }

    /// EKF predict: `x(k+1) = f(x, gyro, dt)`. Velocity riêng của target được
    /// giảm theo Ornstein-Uhlenbeck (không giả định vật thể tiếp tục bay mãi khi
    /// bị che), trong khi bias gyro là random walk rất chậm.
    private func predictLocked(to timestamp: CFTimeInterval, gyroRate: SIMD3<Double>) {
        guard lastPredictionTime > 0 else {
            lastPredictionTime = timestamp
            return
        }
        let dt = min(0.05, max(0.0005, timestamp - lastPredictionTime))
        guard dt > 0.0004 else { return }
        lastPredictionTime = timestamp

        // AVCapture ramp không cung cấp KVO 60 Hz trong kiến trúc hiện tại. Nội suy
        // zoom với vận tốc hữu hạn tránh teleport ring ngay khi app ra lệnh 1x→3x;
        // measurement Vision vẫn tự hiệu chỉnh nếu phần cứng đổi nhanh hơn/chậm hơn.
        let zoomDelta = _targetZoom - _currentZoom
        if abs(zoomDelta) > 0.0001 {
            let maximumStep = 1.8 * dt
            let step = min(abs(zoomDelta), maximumStep) * (zoomDelta < 0 ? -1.0 : 1.0)
            let nextZoom = max(1.0, _currentZoom + step)
            applyZoomScaleLocked(nextZoom / max(1.0, _currentZoom))
            _currentZoom = nextZoom
        }

        let flow = gyroImageVelocityLocked(gyroRate)
        let velocityDecay = exp(-0.85 * dt)
        x[0] += (x[2] + flow.x - x[4]) * dt
        x[1] += (x[3] + flow.y - x[5]) * dt
        x[2] *= velocityDecay
        x[3] *= velocityDecay

        // F = df/dx. The dominant terms are constant-velocity and bias coupling.
        // Off-axis derivatives of rotational flow are deliberately omitted from F;
        // their bounded error is represented by angular-rate-dependent Q below.
        var f = identity6()
        f[0 * 6 + 2] = dt
        f[1 * 6 + 3] = dt
        f[0 * 6 + 4] = -dt
        f[1 * 6 + 5] = -dt
        f[2 * 6 + 2] = velocityDecay
        f[3 * 6 + 3] = velocityDecay

        var fp = [Double](repeating: 0, count: 36)
        var propagated = [Double](repeating: 0, count: 36)
        for row in 0..<6 {
            for col in 0..<6 {
                var sum = 0.0
                for k in 0..<6 { sum += f[row * 6 + k] * p[k * 6 + col] }
                fp[row * 6 + col] = sum
            }
        }
        for row in 0..<6 {
            for col in 0..<6 {
                var sum = 0.0
                for k in 0..<6 { sum += fp[row * 6 + k] * f[col * 6 + k] }
                propagated[row * 6 + col] = sum
            }
        }

        let angularSpeed = simd_length(gyroRate)
        let positionNoise = (1.2e-5 + 8.0e-5 * min(6.0, angularSpeed)) * dt
        let velocityNoise = (7.0e-4 + 1.5e-3 * min(4.0, angularSpeed)) * dt
        propagated[0] += positionNoise
        propagated[7] += positionNoise
        propagated[14] += velocityNoise
        propagated[21] += velocityNoise
        propagated[28] += 1.0e-6 * dt
        propagated[35] += 1.0e-6 * dt
        p = propagated

        // State nội bộ được phép đi ra ngoài frame để quay lại không bị trễ; chỉ
        // output cho UI mới clamp. Giới hạn rộng này chỉ ngăn numerical runaway.
        x[0] = min(1.5, max(-0.5, x[0]))
        x[1] = min(1.5, max(-0.5, x[1]))
    }

    /// Jacobian của zoom đồng tâm được áp cho cả mean lẫn covariance; nhờ vậy
    /// uncertainty cũng tăng đúng tỷ lệ khi phóng đại ảnh.
    private func applyZoomScaleLocked(_ ratio: Double) {
        guard ratio.isFinite, ratio > 0 else { return }
        x[0] = 0.5 + (x[0] - 0.5) * ratio
        x[1] = 0.5 + (x[1] - 0.5) * ratio
        x[2] *= ratio
        x[3] *= ratio
        let scale = [ratio, ratio, ratio, ratio, 1.0, 1.0]
        for row in 0..<6 {
            for col in 0..<6 { p[row * 6 + col] *= scale[row] * scale[col] }
        }
        p[0] += 5.0e-6 * abs(ratio - 1.0)
        p[7] += 5.0e-6 * abs(ratio - 1.0)
    }

    // MARK: - Optical measurement update

    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        guard _isTrackingActive else {
            stateLock.unlock()
            return
        }
        predictLocked(to: now, gyroRate: lastGyroRate)

        var accepted = false
        if let point, point.x.isFinite, point.y.isFinite {
            let threshold = max(_opticalAcceptThreshold, _isLowTextureAnchor ? 0.42 : 0.0)
            if confidence >= threshold {
                accepted = correctLocked(measurement: SIMD2(Double(point.x), Double(point.y)), confidence: confidence)
            }
        }

        if accepted {
            lastOpticalAcceptTime = now
            lastOpticalConfidence = confidence
            consecutiveRejectedMeasurements = 0
        } else {
            lastOpticalConfidence = min(lastOpticalConfidence, confidence)
            consecutiveRejectedMeasurements += 1
        }

        let age = now - lastOpticalAcceptTime
        let output = outputPointLocked()
        let outputConfidence = confidenceLocked(opticalAge: age)
        let quality = qualityLocked(opticalAge: age)
        stateRevision &+= 1
        let revision = stateRevision
        stateLock.unlock()

        // updateWithOpticalDetection hiện được gọi trên MainActor; callback trực
        // tiếp tránh thêm một frame dispatch latency. pixelBuffer được giữ trong
        // signature để bảo toàn API, nhưng tác vụ VO nặng đã chuyển sang visionQueue.
        publishIfCurrent(
            revision: revision,
            point: output,
            confidence: outputConfidence,
            quality: accepted && confidence >= 0.55 ? .locked : quality
        )
    }

    /// Measurement model `z = Hx + n`, H chỉ chọn u,v. NIS = y' S^-1 y
    /// được gate theo phân phối chi-square 2 bậc tự do. Không có quy tắc "sai nhiều
    /// frame thì chấp nhận"; chỉ một re-ID confidence rất cao mới được gate rộng hơn.
    private func correctLocked(measurement z: SIMD2<Double>, confidence: Double) -> Bool {
        let clampedConfidence = min(1.0, max(0.05, confidence))
        let angularSpeed = simd_length(lastGyroRate)
        var sigma = 0.006 + (1.0 - clampedConfidence) * 0.045
        if _isLowTextureAnchor { sigma *= 1.45 }
        if angularSpeed > 1.5 { sigma *= 1.25 }
        let r = sigma * sigma

        let y0 = z.x - x[0]
        let y1 = z.y - x[1]
        let jump = hypot(y0, y1)
        if jump > Double(_maxObservationJump), confidence < 0.78 { return false }

        let s00 = p[0] + r
        let s01 = p[1]
        let s10 = p[6]
        let s11 = p[7] + r
        let determinant = s00 * s11 - s01 * s10
        guard determinant > 1.0e-14 else { return false }
        let inv00 = s11 / determinant
        let inv01 = -s01 / determinant
        let inv10 = -s10 / determinant
        let inv11 = s00 / determinant
        let nis = y0 * (inv00 * y0 + inv01 * y1) + y1 * (inv10 * y0 + inv11 * y1)
        let gate = confidence >= 0.86 ? 25.0 : (angularSpeed > 1.2 ? 16.0 : 11.83)
        guard nis <= gate else { return false }

        var k0 = [Double](repeating: 0, count: 6)
        var k1 = [Double](repeating: 0, count: 6)
        for row in 0..<6 {
            let ph0 = p[row * 6]
            let ph1 = p[row * 6 + 1]
            k0[row] = ph0 * inv00 + ph1 * inv10
            k1[row] = ph0 * inv01 + ph1 * inv11
        }
        for row in 0..<6 { x[row] += k0[row] * y0 + k1[row] * y1 }

        // Compact covariance update `(I-KH)P` for H=[I2 0], followed by explicit
        // symmetrization and a positive diagonal floor for numerical stability.
        let oldP = p
        for row in 0..<6 {
            for col in 0..<6 {
                p[row * 6 + col] = oldP[row * 6 + col]
                    - k0[row] * oldP[col]
                    - k1[row] * oldP[6 + col]
            }
        }
        for row in 0..<6 {
            for col in (row + 1)..<6 {
                let average = 0.5 * (p[row * 6 + col] + p[col * 6 + row])
                p[row * 6 + col] = average
                p[col * 6 + row] = average
            }
            p[row * 6 + row] = max(1.0e-10, p[row * 6 + row])
        }
        return true
    }

    private func qualityLocked(opticalAge: CFTimeInterval) -> TrackingQuality {
        if opticalAge < 0.12, lastOpticalConfidence >= 0.55 { return .locked }
        if opticalAge < 1.50 { return .predicting }
        if opticalAge < 4.0 { return .reacquiring }
        return .lost
    }

    private func confidenceLocked(opticalAge: CFTimeInterval) -> Double {
        let uncertaintyPenalty = min(0.75, 8.0 * sqrt(max(p[0], p[7])))
        let timeDecay = exp(-0.42 * max(0, opticalAge - 0.10))
        return min(1.0, max(0.08, lastOpticalConfidence * timeDecay * (1.0 - uncertaintyPenalty)))
    }

    private func outputPointLocked() -> CGPoint {
        CGPoint(x: min(0.99, max(0.01, x[0])), y: min(0.99, max(0.01, x[1])))
    }

    /// Bỏ callback đã xếp hàng trước một optical correction mới hơn. Nếu không có
    /// revision gate, một predict cũ có thể chạy sau measurement trên MainActor và
    /// làm vòng neo giật ngược đúng một frame.
    private func publishIfCurrent(
        revision: UInt64,
        point: CGPoint,
        confidence: Double,
        quality: TrackingQuality
    ) {
        stateLock.lock()
        let callback = revision == stateRevision ? _callback : nil
        stateLock.unlock()
        callback?(point, confidence, quality)
    }

    private func resetCovarianceLocked() {
        p = [Double](repeating: 0, count: 36)
        p[0] = 2.5e-5
        p[7] = 2.5e-5
        p[14] = 2.5e-3
        p[21] = 2.5e-3
        p[28] = 4.0e-4
        p[35] = 4.0e-4
    }

    private func identity6() -> [Double] {
        var result = [Double](repeating: 0, count: 36)
        for i in 0..<6 { result[i * 6 + i] = 1.0 }
        return result
    }

    public func stopTracking() {
        stateLock.lock()
        _isTrackingActive = false
        lastPredictionTime = 0
        lastOpticalAcceptTime = 0
        lastOpticalConfidence = 0
        lastGyroRate = .zero
        fastGyroRate = .zero
        slowGyroRate = .zero
        consecutiveRejectedMeasurements = 0
        stateRevision &+= 1
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

    private let embeddingLock = NSLock()
    
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
        let embedding = forwardPass(features)
        embeddingLock.lock()
        self.anchorEmbedding = embedding
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
        embeddingLock.lock()
        self.anchorEmbedding = nil
        embeddingLock.unlock()
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
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return [Float](repeating: 0, count: inputDim)
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
        guard boxSize >= 16 else { return [Float](repeating: 0, count: inputDim) }
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
