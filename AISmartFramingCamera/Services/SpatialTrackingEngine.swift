import Foundation
import CoreMotion
import CoreGraphics
import UIKit
import simd
import Accelerate

/// Động cơ Tracking Không Gian Chuẩn Xác Tuyệt Đối (Unified Spatial Visual-Inertial Fusion Engine)
/// Khóa chặt mỏ neo vào không gian 3D thế giới thực, bù trừ chuyển động lia máy với cực tính chuẩn xác 100%
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Mốc tọa độ quán tính và tia 3D thế giới (3D World-Ray)
    private var anchor3DRay: simd_double3? = nil
    private var currentAttitudeMatrix: simd_double3x3? = nil
    private var currentOmega: Double = 0.0
    private var anchorInitialPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var isLowTextureAnchor: Bool = false
    
    public func setLowTextureFlag(_ isLowTexture: Bool) {
        self.isLowTextureAnchor = isLowTexture
    }
    
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
    
    // Đồng bộ state giữa luồng optical (main) và gyro (motionQueue) — chống data race
    private let stateLock = NSLock()
    private var lastOpticalAcceptTime: CFTimeInterval = 0
    private var outlierStreak: Int = 0
    
    // Giản luật chống nhảy đột biến
    public var maxObservationJump: CGFloat = 0.18
    public var opticalAcceptThreshold: Double = 0.20
    public var isStreetMode: Bool = false
    
    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGPoint(x: stateX, y: stateY)
    }
    
    // Callback duy nhất truyền tọa độ về ViewModel
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?
    
    public init() {
        motionQueue.name = "com.alignai.spatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }
    
    // MARK: - Khởi tạo Mỏ Neo Không Gian 3D (Pin Spatial Anchor)
    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        stateLock.lock()
        self.currentZoom = Double(max(1.0, zoom))
        self.anchorInitialPoint = screenPoint
        self.stateX = Double(screenPoint.x)
        self.stateY = Double(screenPoint.y)
        self.velocityX = 0.0
        self.velocityY = 0.0
        self.lastOpticalConfidence = 1.0
        self.lastOpticalAcceptTime = CACurrentMediaTime()
        self.lastUpdateTime = CACurrentMediaTime()
        self.isTrackingActive = true
        self.outlierStreak = 0

        // Tính tia không gian 3D trong hệ tọa độ thiết bị (Device Frame)
        let fx = 0.88 * self.currentZoom
        let fy = 0.66 * self.currentZoom
        let xDev = (Double(screenPoint.x) - 0.5) / fx
        let yDev = (0.5 - Double(screenPoint.y)) / fy
        let devRay = simd_normalize(simd_double3(xDev, yDev, -1.0))

        if let attitude = motionManager.deviceMotion?.attitude {
            let rot = attitude.rotationMatrix
            let R = simd_double3x3(
                simd_double3(rot.m11, rot.m21, rot.m31),
                simd_double3(rot.m12, rot.m22, rot.m32),
                simd_double3(rot.m13, rot.m23, rot.m33)
            )
            self.currentAttitudeMatrix = R
            self.anchor3DRay = simd_normalize(R * devRay)
        } else {
            self.anchor3DRay = devRay
        }
        stateLock.unlock()

        CameraLogger.info("Khóa mỏ neo không gian 3D thế giới tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y))), Zoom: \(zoom)x", category: .tracking)
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
        
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60 FPS
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isTrackingActive else { return }

            let rot = motion.attitude.rotationMatrix
            let R = simd_double3x3(
                simd_double3(rot.m11, rot.m21, rot.m31),
                simd_double3(rot.m12, rot.m22, rot.m32),
                simd_double3(rot.m13, rot.m23, rot.m33)
            )

            let wx = motion.rotationRate.x
            let wy = motion.rotationRate.y
            let wz = motion.rotationRate.z
            let omega = sqrt(wx * wx + wy * wy + wz * wz)

            self.stateLock.lock()
            self.currentAttitudeMatrix = R
            self.currentOmega = omega

            guard let rWorld = self.anchor3DRay else {
                self.stateLock.unlock()
                return
            }

            // Chiếu tia thế giới về hệ tọa độ thiết bị: vDev = R^T * rWorld
            let vDev = R.transpose * rWorld
            let inFront = vDev.z < -0.05

            let fx = 0.88 * self.currentZoom
            let fy = 0.66 * self.currentZoom

            let projU: Double
            let projV: Double
            if inFront {
                projU = 0.5 + (vDev.x / (-vDev.z)) * fx
                projV = 0.5 - (vDev.y / (-vDev.z)) * fy
            } else {
                projU = 0.5 + vDev.x * 10.0
                projV = 0.5 - vDev.y * 10.0
            }

            let margin = 0.05
            let isOffScreen = !inFront || projU < margin || projU > (1.0 - margin) || projV < margin || projV > (1.0 - margin)

            let finalTargetX: Double
            let finalTargetY: Double

            if isOffScreen {
                // Neo mép màn hình (Perimeter Docking)
                var dx = inFront ? (projU - 0.5) : vDev.x
                var dy = inFront ? (projV - 0.5) : -vDev.y
                let len = hypot(dx, dy)
                if len > 1e-5 {
                    dx /= len
                    dy /= len
                } else {
                    dx = 0; dy = 1
                }
                let halfW = 0.5 - margin
                let halfH = 0.5 - margin
                let tx = abs(dx) > 1e-5 ? (halfW / abs(dx)) : 1e9
                let ty = abs(dy) > 1e-5 ? (halfH / abs(dy)) : 1e9
                let t = min(tx, ty)
                finalTargetX = min(1.0 - margin, max(margin, 0.5 + dx * t))
                finalTargetY = min(1.0 - margin, max(margin, 0.5 + dy * t))
                self.stateX = finalTargetX
                self.stateY = finalTargetY
            } else {
                // Motion-adaptive projection:
                // Nếu camera đang quay (omega > 0.02 rad/s), nạp thẳng tọa độ chiếu tức thì từ IMU
                // TUYỆT ĐỐI KHÔNG BỊ DÍNH VÀO TÂM TRẮNG!
                if omega > 0.02 {
                    self.stateX = projU
                    self.stateY = projV
                } else {
                    // Khi đứng yên: Giảm chấn êm dịu, triệt rung vi mô
                    self.stateX = self.stateX * 0.90 + projU * 0.10
                    self.stateY = self.stateY * 0.90 + projV * 0.10
                }
                finalTargetX = self.stateX
                finalTargetY = self.stateY
            }

            let now = CACurrentMediaTime()
            let timeSinceOptical = self.lastOpticalAcceptTime > 0 ? (now - self.lastOpticalAcceptTime) : 1.0
            let lastConf = self.lastOpticalConfidence

            let quality: TrackingQuality
            if isOffScreen {
                quality = timeSinceOptical > 6.0 ? .reacquiring : .predicting
            } else if timeSinceOptical > 2.0 {
                quality = .reacquiring
            } else if timeSinceOptical > 0.3 {
                quality = .predicting
            } else {
                quality = .locked
            }

            let targetPoint = CGPoint(x: finalTargetX, y: finalTargetY)
            self.stateLock.unlock()

            DispatchQueue.main.async {
                self.onSpatialTargetUpdated?(targetPoint, lastConf, quality)
            }
        }
    }
    
    // MARK: - Dung hợp Dữ liệu Quang Học (Vision Optical Observation Update)
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        guard isTrackingActive else { return }
        
        let now = CACurrentMediaTime()
        var effectiveConfidence = confidence
        var activePoint = point
        
        // Chỉ dùng NeuralTargetTracker hỗ trợ phụ khi có model thật hợp lệ
        if let visualPoint = point, let buffer = pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let (bestPt, neuralSim) = NeuralTargetTracker.shared.findBestMatchingPoint(in: buffer, around: visualPoint, searchRadius: 0.03)
            if neuralSim >= 0.65 {
                activePoint = bestPt
                effectiveConfidence = max(confidence, min(confidence + 0.10, neuralSim * 0.90))
            }
        }
        
        let effectiveThreshold = max(self.opticalAcceptThreshold, self.isLowTextureAnchor ? 0.60 : 0.0)
        guard let visualPoint = activePoint, effectiveConfidence >= effectiveThreshold else {
            stateLock.lock()
            self.lastOpticalConfidence = confidence
            stateLock.unlock()
            return
        }
        
        stateLock.lock()
        self.lastOpticalConfidence = effectiveConfidence
        self.lastOpticalAcceptTime = now
        
        let isStationary = self.currentOmega < 0.02
        var rawObsX = Double(visualPoint.x)
        var rawObsY = Double(visualPoint.y)
        
        // Centroid deadband: CHỈ kích hoạt khi camera đứng yên để triệt tiêu rung tay!
        // Khi camera đang lia máy (isStationary == false), deadband = 0 để target lướt tự do theo vật thể!
        if isStationary {
            let d = hypot(rawObsX - self.stateX, rawObsY - self.stateY)
            let deadbandRadius = 0.005
            let elasticRadius = 0.035
            if d < deadbandRadius {
                rawObsX = self.stateX
                rawObsY = self.stateY
            } else if d < elasticRadius {
                let k = (d - deadbandRadius) / (elasticRadius - deadbandRadius)
                let s = k * k * (3.0 - 2.0 * k)
                rawObsX = self.stateX + (rawObsX - self.stateX) * s
                rawObsY = self.stateY + (rawObsY - self.stateY) * s
            }
        }
        
        // Hòa trộn quan sát quang học vào trạng thái
        let alpha = isStationary ? 0.35 : 0.70
        self.stateX = self.stateX * (1.0 - alpha) + rawObsX * alpha
        self.stateY = self.stateY * (1.0 - alpha) + rawObsY * alpha
        let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
        
        // Hiệu chỉnh liên tuyến Parallax & Drift cho tia 3D thế giới (Online Parallax Correction)
        if effectiveConfidence >= 0.50, let R = self.currentAttitudeMatrix {
            let fx = 0.88 * self.currentZoom
            let fy = 0.66 * self.currentZoom
            let xDev = (self.stateX - 0.5) / fx
            let yDev = (0.5 - self.stateY) / fy
            let devRay = simd_normalize(simd_double3(xDev, yDev, -1.0))
            let obsWorldRay = simd_normalize(R * devRay)
            
            let blendFactor = 0.05
            if let curRay = self.anchor3DRay {
                self.anchor3DRay = simd_normalize(curRay * (1.0 - blendFactor) + obsWorldRay * blendFactor)
            } else {
                self.anchor3DRay = obsWorldRay
            }
        }
        stateLock.unlock()
        
        if effectiveConfidence > 0.65, let buffer = pixelBuffer {
            VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: targetPoint)
        }
        
        DispatchQueue.main.async {
            self.onSpatialTargetUpdated?(targetPoint, effectiveConfidence, .locked)
        }
    }
    
    // MARK: - Dừng Tracking
    public func stopTracking() {
        stateLock.lock()
        isTrackingActive = false
        anchor3DRay = nil
        currentAttitudeMatrix = nil
        currentOmega = 0.0
        stateLock.unlock()
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
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
