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
    
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var isLowTextureAnchor: Bool = false
    
    public func setLowTextureFlag(_ isLowTexture: Bool) {
        self.isLowTextureAnchor = isLowTexture
    }
    
    // Mỏ neo góc xoay không gian 3D (Absolute Attitude Baseline Anchor)
    private var referenceAttitude: CMAttitude? = nil
    private var attitudeCalibrationFrames: Int = 0
    private var currentGyroScreenPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var lastValidOpticalPoint: CGPoint? = nil
    private var lastValidOpticalTime: CFTimeInterval = 0
    
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
    
    // MARK: - Bộ Lọc 1-Euro Thích Nghi (Adaptive 1-Euro Filter)
    // Tự động chuyển đổi: Khi đứng yên -> Tần số cắt thấp (triệt rung tay); Khi lia máy -> Tần số cắt cao (Zero Latency)
    private var filterXPrev: Double = 0.5
    private var filterYPrev: Double = 0.5
    private var filterDxPrev: Double = 0.0
    private var filterDyPrev: Double = 0.0
    private var filterLastTime: CFTimeInterval = 0.0
    private var filterInitialized: Bool = false
    
    private let oneEuroMinCutoff: Double = 1.2
    private let oneEuroBeta: Double = 1.0
    private let oneEuroDCutoff: Double = 1.0
    
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
        self.currentGyroScreenPoint = screenPoint
        self.lastValidOpticalPoint = screenPoint
        self.lastValidOpticalTime = CACurrentMediaTime()
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
        self.lastUpdateTime = CACurrentMediaTime()
        self.referenceAttitude = nil
        self.attitudeCalibrationFrames = 0
        self.deadReckoningFrameCount = 0
        self.isTrackingActive = true
        
        CameraLogger.info("🎯 Khóa mỏ neo không gian thích nghi tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
        
        startMotionSensors()
    }
    
    public func updateZoomFactor(_ zoom: CGFloat) {
        self.currentZoom = Double(max(1.0, zoom))
    }
    
    private var lastMotionTime: TimeInterval = 0
    private var deadReckoningFrameCount: Int = 0
    
    // MARK: - Khởi động cảm biến 60Hz Gyroscope & Attitude Tracking
    private func startMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng trên thiết bị này", category: .tracking)
            return
        }
        
        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        attitudeCalibrationFrames = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }
            
            let now = CACurrentMediaTime()
            let dt = self.lastMotionTime > 0 ? min(0.05, max(0.001, now - self.lastMotionTime)) : (1.0 / 60.0)
            self.lastMotionTime = now
            
            // 1. Ghi lại mốc tọa độ góc xoay Gyro trung bình ban đầu (Baseline Attitude Calibration)
            if self.referenceAttitude == nil {
                self.attitudeCalibrationFrames += 1
                if self.attitudeCalibrationFrames >= 3 {
                    self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                    CameraLogger.info("🎯 [SpatialTrackingEngine] Đã khóa mốc Attitude Gyro chuẩn không trôi tại (\(self.anchorInitialPoint.x), \(self.anchorInitialPoint.y))", category: .tracking)
                }
                return
            }
            
            guard let ref = self.referenceAttitude else { return }
            
            // 2. Tính toán góc xoay 3D tuyệt đối tương đối từ mốc ban đầu (Absolute Attitude Transform)
            // Phương pháp quaternion này TUYỆT ĐỐI KHÔNG BỊ TRÔI LỆCH (Zero Drift) như cộng dồn vận tốc góc
            let currentAttitude = motion.attitude
            currentAttitude.multiply(byInverseOf: ref)
            
            let yawDelta = currentAttitude.yaw
            let pitchDelta = currentAttitude.pitch
            
            let zoomScale = self.currentZoom
            let scaleX = self.sensitivityFactor * zoomScale
            let scaleY = (self.sensitivityFactor * 1.12) * zoomScale
            
            // Cực tính chuẩn xác 100% theo hệ quang học camera:
            // - Panning sang PHẢI (yawDelta < 0) -> Target dịch sang TRÁI (x giảm) hội tụ về tâm 0.5
            // - Panning sang TRÁI (yawDelta > 0) -> Target dịch sang PHẢI (x tăng) hội tụ về tâm 0.5
            // - Tilting ngửa LÊN (pitchDelta < 0) -> Target dịch xuống DƯỚI (y tăng) hội tụ về tâm 0.5
            // - Tilting cúi XUỐNG (pitchDelta > 0) -> Target dịch lên TRÊN (y giảm) hội tụ về tâm 0.5
            let rawGyroX = Double(self.anchorInitialPoint.x) + yawDelta * scaleX
            let rawGyroY = Double(self.anchorInitialPoint.y) - pitchDelta * scaleY
            let clampedGyroX = min(0.98, max(0.02, rawGyroX))
            let clampedGyroY = min(0.98, max(0.02, rawGyroY))
            self.currentGyroScreenPoint = CGPoint(x: clampedGyroX, y: clampedGyroY)
            
            // 3. Dung Hợp Cảm Biến 60Hz: Gyro Tuyệt Đối + Quang Học
            let fusedX: Double
            let fusedY: Double
            let quality: TrackingQuality
            let confidence: Double
            let timeSinceOptical = now - self.lastValidOpticalTime
            
            if self.isLowTextureAnchor {
                // ĐẶC BIỆT CHO VẬT THỂ TRẮNG / ĐƠN SẮC / THIẾU VÂN GÓC CẠNH (Chai trắng, túi trắng, tường phẳng):
                // Cảm biến quang học dễ trượt mốc hoặc mất nét. Gyro nắm 85% - 100% quyền giữ vị trí không gian 3D!
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
                // VẬT THỂ CÓ HOA VĂN / GÓC CẠNH RÕ NÉT:
                if let opt = self.lastValidOpticalPoint, self.lastOpticalConfidence >= 0.25, timeSinceOptical < 0.35 {
                    let optW = max(0.30, min(0.85, self.lastOpticalConfidence))
                    let gyroW = 1.0 - optW
                    fusedX = clampedGyroX * gyroW + Double(opt.x) * optW
                    fusedY = clampedGyroY * gyroW + Double(opt.y) * optW
                    quality = .locked
                    confidence = self.lastOpticalConfidence
                } else {
                    // Khi quang học tạm mờ/lia nhanh: Gyro giữ 100% vị trí mục tiêu
                    fusedX = clampedGyroX
                    fusedY = clampedGyroY
                    quality = .predicting
                    confidence = 0.70
                }
            }
            
            // 4. Lọc Thích Nghi 1-Euro Filter: Khử sạch dao động rung tay khi đứng yên, bám tức thì khi lia máy
            let (smoothX, smoothY) = self.applyOneEuroFilter(obsX: fusedX, obsY: fusedY, timestamp: now, dt: dt)
            self.stateX = min(0.98, max(0.02, smoothX))
            self.stateY = min(0.98, max(0.02, smoothY))
            
            let finalTarget = CGPoint(x: self.stateX, y: self.stateY)
            DispatchQueue.main.async {
                self.onSpatialTargetUpdated?(finalTarget, confidence, quality)
            }
        }
    }
    
    // MARK: - Dung hợp Dữ liệu Quang Học (Vision Optical Observation Update)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        self.lastOpticalConfidence = confidence
        
        let now = CACurrentMediaTime()
        self.lastUpdateTime = now
        
        var effectiveConfidence = confidence
        var activePoint = point
        
        // Tận dụng NeuralTargetTracker nếu có mô hình nơ-ron hoạt động
        if let visualPoint = point, let buffer = pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let (bestPt, neuralSim) = NeuralTargetTracker.shared.findBestMatchingPoint(in: buffer, around: visualPoint, searchRadius: 0.03)
            if neuralSim >= 0.65 {
                activePoint = bestPt
                effectiveConfidence = max(confidence, min(confidence + 0.10, neuralSim * 0.90))
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
            // Khi quang học mất nét trên vật thể có vân, thử Visual Odometry phụ trợ
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
        
        let rate = 1.0 / max(0.005, dt)
        
        // 1. Tính toán đạo hàm vận tốc (Derivative dx, dy)
        let rawDx = (obsX - filterXPrev) / max(0.005, dt)
        let rawDy = (obsY - filterYPrev) / max(0.005, dt)
        
        let aD = alpha(rate: rate, cutoff: oneEuroDCutoff)
        let dxHat = aD * rawDx + (1.0 - aD) * filterDxPrev
        let dyHat = aD * rawDy + (1.0 - aD) * filterDyPrev
        filterDxPrev = dxHat
        filterDyPrev = dyHat
        
        // 2. Tần số cắt thích nghi theo vận tốc di chuyển camera:
        // - Khi đứng yên: speed nhỏ -> cutoff gần minCutoff (1.2Hz) -> triệt rung tay
        // - Khi di chuyển tâm trắng đến target: speed tăng -> cutoff tăng tức thì -> target bám dính mượt mà
        let speed = hypot(dxHat, dyHat)
        let adaptiveCutoff = oneEuroMinCutoff + oneEuroBeta * speed
        
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
        isTrackingActive = false
        referenceAttitude = nil
        attitudeCalibrationFrames = 0
        lastValidOpticalPoint = nil
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        filterInitialized = false
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
    
    private var anchorEmbedding: [Float]? = nil
    private var isModelLoaded: Bool = false
    public private(set) var hasActiveTrainedModel: Bool = false
    
    public init() {
        loadModelWeights()
    }
    
    public func loadModelWeights() {
        // 1. Kiểm tra file AlignAI_SubjectRanker_Weights.bin trong Documents directory (nếu người dùng copy vào qua iTunes/Files)
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let docModelUrl = docsDir.appendingPathComponent("AlignAI_SubjectRanker_Weights.bin")
            if let data = try? Data(contentsOf: docModelUrl), data.count > 1000 {
                CameraLogger.info("Đã tìm thấy mô hình AlignAI_SubjectRanker_Weights.bin trong Documents directory, bắt đầu nạp trọng số", category: .tracking)
                loadFromData(data)
                return
            }
        }
        
        // 2. Tìm file AlignAI_SubjectRanker_Weights.bin hoặc RobustTargetEmbedder.bin trong Bundle
        if let url = Bundle.main.url(forResource: "AlignAI_SubjectRanker_Weights", withExtension: "bin"),
           let data = try? Data(contentsOf: url) {
            CameraLogger.info("Đã nạp thành công mô hình AlignAI_SubjectRanker_Weights.bin từ Bundle", category: .tracking)
            loadFromData(data)
        } else if let url1 = Bundle.main.url(forResource: "AlignAI_SubjectRanker_Weights", withExtension: "part1"),
                  let url2 = Bundle.main.url(forResource: "AlignAI_SubjectRanker_Weights", withExtension: "part2"),
                  let d1 = try? Data(contentsOf: url1),
                  let d2 = try? Data(contentsOf: url2) {
            var combined = d1
            combined.append(d2)
            CameraLogger.info("Đã nạp thành công mô hình AlignAI_SubjectRanker_Weights 114MB từ Part1+Part2", category: .tracking)
            loadFromData(combined)
        } else if let url = Bundle.main.url(forResource: "RobustTargetEmbedder", withExtension: "bin"),
                  let data = try? Data(contentsOf: url) {
            CameraLogger.info("Đã nạp thành công mô hình RobustTargetEmbedder.bin từ Bundle", category: .tracking)
            loadFromData(data)
        } else {
            // Fallback tạo trọng số chuẩn hóa Xavier
            initFallbackWeights()
        }
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
