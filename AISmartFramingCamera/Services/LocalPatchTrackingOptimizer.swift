import Foundation
import CoreGraphics
import CoreMedia
import QuartzCore

/// Bộ lọc Kalman 2D cho Bounding Box [x, y, w, h, vx, vy, vw, vh]
public final class BoundingBoxKalmanFilter2D: @unchecked Sendable {
    private var state: [Double] = [0, 0, 0, 0, 0, 0, 0, 0] // x, y, w, h, vx, vy, vw, vh
    private var isInitialized = false
    private var lastTimestamp: CFTimeInterval = 0
    
    // Nhiễu quá trình và nhiễu đo đạc
    private let processNoise: Double = 1e-3
    private let measurementNoise: Double = 1e-2
    private var covariance: [Double] = [1, 1, 1, 1, 1, 1, 1, 1]
    
    public init() {}
    
    public func reset(with rect: CGRect, timestamp: CFTimeInterval) {
        state = [
            Double(rect.origin.x), Double(rect.origin.y),
            Double(rect.size.width), Double(rect.size.height),
            0.0, 0.0, 0.0, 0.0
        ]
        covariance = [0.1, 0.1, 0.1, 0.1, 0.5, 0.5, 0.5, 0.5]
        lastTimestamp = timestamp
        isInitialized = true
    }
    
    public func update(measurement: CGRect?, timestamp: CFTimeInterval) -> CGRect {
        guard isInitialized else {
            if let m = measurement {
                reset(with: m, timestamp: timestamp)
                return m
            }
            return .zero
        }
        
        let dt = max(0.001, min(0.1, timestamp - lastTimestamp))
        lastTimestamp = timestamp
        
        // 1. Dự đoán (Prediction)
        for i in 0..<4 {
            state[i] += state[i + 4] * dt
            covariance[i] += covariance[i + 4] * dt + processNoise
            covariance[i + 4] += processNoise * 2.0
        }
        
        // 2. Cập nhật đo đạc (Update) nếu có
        if let m = measurement {
            let z = [Double(m.origin.x), Double(m.origin.y), Double(m.size.width), Double(m.size.height)]
            for i in 0..<4 {
                let kalmanGain = covariance[i] / (covariance[i] + measurementNoise)
                let residual = z[i] - state[i]
                state[i] += kalmanGain * residual
                covariance[i] *= (1.0 - kalmanGain)
                
                // Cập nhật vận tốc
                state[i + 4] = residual / dt
            }
        }
        
        return CGRect(
            x: max(0.0, min(1.0, state[0])),
            y: max(0.0, min(1.0, state[1])),
            width: max(0.01, min(1.0, state[2])),
            height: max(0.01, min(1.0, state[3]))
        )
    }
}

/// Bộ tối ưu hóa bám mục tiêu cục bộ siêu tốc (Lấy cảm hứng từ Doka Camera)
public final class LocalPatchTrackingOptimizer: @unchecked Sendable {
    public static let shared = LocalPatchTrackingOptimizer()
    
    public let localSearchMargin: CGFloat = 0.20 // Mở rộng 20% quanh toạ độ cũ
    public let maxProcessingWidth: CGFloat = 384.0 // Giới hạn downscale 384px cho OpenCV / Vision
    
    private let kalmanFilter = BoundingBoxKalmanFilter2D()
    private var consecutiveFailures: Int = 0
    private let maxAllowedFailures: Int = 6 // ~100ms ở 60 FPS
    private var isTrackingStable: Bool = false
    private var lastSmoothedRect: CGRect = .zero
    
    private init() {}
    
    /// Bắt đầu phiên bám đuổi với Seed Rect
    public func startTracking(with seedRect: CGRect, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        kalmanFilter.reset(with: seedRect, timestamp: timestamp)
        lastSmoothedRect = seedRect
        consecutiveFailures = 0
        isTrackingStable = true
    }
    
    /// Tính toán Vùng tìm kiếm cục bộ (Local Search Inset ROI)
    /// Tránh quét cả khung hình 4K/1080p ở mọi frame!
    public func computeLocalSearchROI(previousRect: CGRect) -> CGRect {
        let marginW = previousRect.width * localSearchMargin
        let marginH = previousRect.height * localSearchMargin
        
        let minX = max(0.0, previousRect.minX - marginW)
        let minY = max(0.0, previousRect.minY - marginH)
        let maxX = min(1.0, previousRect.maxX + marginW)
        let maxY = min(1.0, previousRect.maxY + marginH)
        
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    /// Cập nhật toạ độ qua bộ lọc Kalman 2D
    public func updateTrackingCoordinates(
        measuredRect: CGRect?,
        timestamp: CFTimeInterval = CACurrentMediaTime()
    ) -> (smoothedRect: CGRect, isStable: Bool) {
        if measuredRect != nil {
            consecutiveFailures = 0
            isTrackingStable = true
        } else {
            consecutiveFailures += 1
            if consecutiveFailures > maxAllowedFailures {
                isTrackingStable = false
            }
        }
        
        lastSmoothedRect = kalmanFilter.update(measurement: measuredRect, timestamp: timestamp)
        return (lastSmoothedRect, isTrackingStable)
    }
    
    /// Reset bộ tối ưu
    public func stopTracking() {
        consecutiveFailures = 0
        isTrackingStable = false
        lastSmoothedRect = .zero
    }
}
