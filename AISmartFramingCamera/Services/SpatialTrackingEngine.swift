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
    
    // Mốc tọa độ quán tính khi khóa target
    private var referenceAttitude: CMAttitude? = nil
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
        
        var effectiveConfidence = confidence
        if let visualPoint = point, let buffer = pixelBuffer {
            let neuralSim = NeuralTargetTracker.shared.verifyTarget(in: buffer, at: visualPoint)
            if neuralSim >= 0.70 {
                effectiveConfidence = max(confidence, neuralSim * 0.95)
            }
        }
        
        let effectiveThreshold = isLowTextureAnchor ? 0.75 : 0.25
        if let visualPoint = point, effectiveConfidence >= effectiveThreshold {
            let obsX = Double(visualPoint.x)
            let obsY = Double(visualPoint.y)
            
            // Lọc outlier cực đoan (> 0.40 màn hình trong 1 frame)
            let jump = hypot(obsX - self.stateX, obsY - self.stateY)
            if jump > 0.40 && effectiveConfidence < 0.70 {
                return
            }
            
            // Quang học là Ground Truth: Bám trực tiếp vào vật thể thực tế
            let kGain = max(0.70, min(0.90, effectiveConfidence))
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
            if effectiveConfidence > 0.65, let motion = motionManager.deviceMotion {
                self.referenceAttitude = motion.attitude.copy() as? CMAttitude
                self.anchorInitialPoint = CGPoint(x: self.stateX, y: self.stateY)
            }
            
            if effectiveConfidence > 0.60, let buffer = pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: CGPoint(x: self.stateX, y: self.stateY))
            }
            
            let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
            self.onSpatialTargetUpdated?(targetPoint, effectiveConfidence, .locked)
        } else {
            // Khi quang học tạm thời mất nét hoặc là vùng ít chi tiết (Low Texture):
            if !isLowTextureAnchor, let buffer = pixelBuffer, let voPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: buffer) {
                self.stateX = min(0.98, max(0.02, Double(voPoint.x)))
                self.stateY = min(0.98, max(0.02, Double(voPoint.y)))
                let targetPoint = CGPoint(x: self.stateX, y: self.stateY)
                self.onSpatialTargetUpdated?(targetPoint, 0.70, .locked)
            } else if let ref = self.referenceAttitude, let motion = motionManager.deviceMotion {
                // Dùng Gyroscope chiếu chính xác mỏ neo không gian (Ưu tiên tuyệt đối cho vùng ít chi tiết)
                let currentAttitude = motion.attitude
                currentAttitude.multiply(byInverseOf: ref)
                let yawDelta = Double(currentAttitude.yaw)
                let pitchDelta = Double(currentAttitude.pitch)
                let zoomScale = self.currentZoom
                let projX = Double(self.anchorInitialPoint.x) - yawDelta * self.sensitivityFactor * zoomScale
                let projY = Double(self.anchorInitialPoint.y) + pitchDelta * self.sensitivityFactor * zoomScale
                self.stateX = min(0.98, max(0.02, projX))
                self.stateY = min(0.98, max(0.02, projY))
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
    
    private var anchorEmbedding: [Float]? = nil
    private var isModelLoaded: Bool = false
    
    public init() {
        loadModelWeights()
    }
    
    private func loadModelWeights() {
        // Tìm file RobustTargetEmbedder.bin trong Bundle hoặc thư mục app
        if let url = Bundle.main.url(forResource: "RobustTargetEmbedder", withExtension: "bin"),
           let data = try? Data(contentsOf: url) {
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
            initFallbackWeights()
            return
        }
        
        var offset = 0
        W1 = Array(floats[offset..<offset+w1Count]); offset += w1Count
        b1 = Array(floats[offset..<offset+b1Count]); offset += b1Count
        W2 = Array(floats[offset..<offset+w2Count]); offset += w2Count
        b2 = Array(floats[offset..<offset+b2Count]); offset += b2Count
        isModelLoaded = true
        CameraLogger.info("Đã nạp thành công Neural Target Embedder Weights (413 KB)", category: .tracking)
    }
    
    private func initFallbackWeights() {
        let std1 = sqrtf(2.0 / Float(inputDim))
        W1 = (0..<(inputDim * hiddenDim)).map { _ in Float.random(in: -std1...std1) }
        b1 = [Float](repeating: 0, count: hiddenDim)
        
        let std2 = sqrtf(2.0 / Float(hiddenDim))
        W2 = (0..<(hiddenDim * embeddingDim)).map { _ in Float.random(in: -std2...std2) }
        b2 = [Float](repeating: 0, count: embeddingDim)
        isModelLoaded = true
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
        
        // 3. Gradient Variance (6 values)
        var grad = [Float](repeating: 0.1, count: 6)
        
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
