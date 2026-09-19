import Foundation
import CoreMotion
import CoreGraphics
import CoreVideo
import UIKit

/// Dedicated street/commute tracker restored from the Build 142 behavior.
/// The state lock is intentionally retained to keep the original math race-free.
public final class StreetSpatialTrackingEngine: @unchecked Sendable {
    public static let shared = StreetSpatialTrackingEngine()

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let stateLock = NSLock()

    private var stateX: Double = 0.5
    private var stateY: Double = 0.5
    private var filterXPrev: Double = 0.5
    private var filterYPrev: Double = 0.5
    private var filterDxPrev: Double = 0
    private var filterDyPrev: Double = 0
    private var filterLastTime: CFTimeInterval = 0
    private var filterInitialized = false

    private let minCutoff: Double = 1.2
    private let beta: Double = 0.90
    private let dCutoff: Double = 1.2

    private var lastRawGyroX: Double = 0
    private var lastRawGyroY: Double = 0
    private var smoothedRotationX: Double = 0
    private var smoothedRotationY: Double = 0
    private var currentZoom: Double = 1
    private var lastOpticalConfidence: Double = 1
    private var lastUpdateTime: CFTimeInterval = 0
    private var lastMotionTime: CFTimeInterval = 0
    private var deadReckoningFrameCount = 0
    private var isLowTextureAnchor = false
    private var lastOpticalAcceptTime: CFTimeInterval = 0
    private var outlierStreak = 0
    private var trackingActive = false
    private var observationJumpLimit: CGFloat = 0.12
    private var acceptThreshold: Double = 0.20

    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)?

    public var isTrackingActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return trackingActive
    }

    public var currentEstimatedScreenPoint: CGPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CGPoint(x: stateX, y: stateY)
    }

    public var maxObservationJump: CGFloat {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return observationJumpLimit
        }
        set {
            stateLock.lock()
            observationJumpLimit = newValue
            stateLock.unlock()
        }
    }

    public var opticalAcceptThreshold: Double {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return acceptThreshold
        }
        set {
            stateLock.lock()
            acceptThreshold = newValue
            stateLock.unlock()
        }
    }

    public init() {
        motionQueue.name = "com.alignai.streetSpatialTrackingQueue"
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .userInteractive
    }

    public func setLowTextureFlag(_ isLowTexture: Bool) {
        stateLock.lock()
        isLowTextureAnchor = isLowTexture
        stateLock.unlock()
    }

    public func updateZoomFactor(_ zoom: CGFloat) {
        guard zoom.isFinite else { return }
        stateLock.lock()
        currentZoom = Double(max(1, zoom))
        stateLock.unlock()
    }

    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1) {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite, zoom.isFinite else { return }
        stateLock.lock()
        currentZoom = Double(max(1, zoom))
        stateX = Double(screenPoint.x)
        stateY = Double(screenPoint.y)
        filterXPrev = stateX
        filterYPrev = stateY
        filterDxPrev = 0
        filterDyPrev = 0
        filterLastTime = CACurrentMediaTime()
        filterInitialized = true
        lastOpticalConfidence = 1
        lastOpticalAcceptTime = CACurrentMediaTime()
        outlierStreak = 0
        deadReckoningFrameCount = 0
        lastUpdateTime = CACurrentMediaTime()
        lastRawGyroX = 0
        lastRawGyroY = 0
        smoothedRotationX = 0
        smoothedRotationY = 0
        trackingActive = true
        stateLock.unlock()

        CameraLogger.info("Street tracker đã khóa target tại (\(String(format: "%.3f", screenPoint.x)), \(String(format: "%.3f", screenPoint.y)))", category: .tracking)
        startStreetMotionSensors()
    }

    private func startStreetMotionSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            CameraLogger.warning("Cảm biến DeviceMotion không khả dụng", category: .tracking)
            return
        }

        lastMotionTime = CACurrentMediaTime()
        deadReckoningFrameCount = 0
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            self.stateLock.lock()
            let isActive = self.trackingActive
            let zoom = self.currentZoom
            self.stateLock.unlock()
            guard isActive else { return }

            let now = CACurrentMediaTime()
            let dt = self.lastMotionTime > 0 ? min(0.04, max(0.005, now - self.lastMotionTime)) : 1.0 / 60.0
            self.lastMotionTime = now

            let rawRateY = motion.rotationRate.y
            let rawRateX = motion.rotationRate.x
            let jerkY = abs(rawRateY - self.lastRawGyroY) / dt
            let jerkX = abs(rawRateX - self.lastRawGyroX) / dt
            self.lastRawGyroY = rawRateY
            self.lastRawGyroX = rawRateX

            let damping = (jerkY > 22 || jerkX > 22) ? 0.06 : 0.40
            self.smoothedRotationY = self.smoothedRotationY * (1 - damping) + rawRateY * damping
            self.smoothedRotationX = self.smoothedRotationX * (1 - damping) + rawRateX * damping

            let rateY = abs(self.smoothedRotationY) < 0.035 ? 0 : self.smoothedRotationY
            let rateX = abs(self.smoothedRotationX) < 0.035 ? 0 : self.smoothedRotationX
            let dx = rateY * dt * 0.85 * zoom
            let dy = -rateX * dt * 0.95 * zoom

            self.stateLock.lock()
            let sinceOptical = self.lastOpticalAcceptTime > 0 ? now - self.lastOpticalAcceptTime : 1
            guard sinceOptical > 0.12 else {
                self.stateLock.unlock()
                return
            }

            self.deadReckoningFrameCount += 1
            self.stateX = min(0.98, max(0.02, self.stateX + dx))
            self.stateY = min(0.98, max(0.02, self.stateY + dy))
            self.filterXPrev = self.stateX
            self.filterYPrev = self.stateY
            let count = self.deadReckoningFrameCount
            let point = CGPoint(x: self.stateX, y: self.stateY)
            self.stateLock.unlock()

            let quality: TrackingQuality = count > 90 ? .lost : (count > 30 ? .predicting : .reacquiring)
            let confidence = max(0.25, 0.45 * pow(0.98, Double(max(0, count - 30))))
            DispatchQueue.main.async {
                self.onSpatialTargetUpdated?(point, confidence, quality)
            }
        }
    }

    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        let now = CACurrentMediaTime()
        stateLock.lock()
        guard trackingActive else {
            stateLock.unlock()
            return
        }
        let dt = lastUpdateTime > 0 ? min(0.1, max(0.005, now - lastUpdateTime)) : 1.0 / 30.0
        lastUpdateTime = now
        let threshold = max(acceptThreshold, isLowTextureAnchor ? 0.60 : 0)
        let jumpLimit = observationJumpLimit
        let lowTexture = isLowTextureAnchor
        stateLock.unlock()

        var effectiveConfidence = confidence
        var activePoint = point
        if let point, let pixelBuffer, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let result = NeuralTargetTracker.shared.findBestMatchingPoint(in: pixelBuffer, around: point, searchRadius: 0.035)
            if result.1 >= 0.60 {
                activePoint = result.0
                effectiveConfidence = max(confidence, result.1 * 0.95)
            }
        }

        if let point = activePoint, effectiveConfidence >= threshold {
            stateLock.lock()
            lastOpticalConfidence = effectiveConfidence
            lastOpticalAcceptTime = now
            deadReckoningFrameCount = 0
            var rawX = Double(point.x)
            var rawY = Double(point.y)
            let jump = hypot(rawX - stateX, rawY - stateY)
            if jump > Double(jumpLimit) {
                outlierStreak += 1
                if outlierStreak >= 6 {
                    outlierStreak = 0
                    filterInitialized = false
                } else {
                    let scale = Double(jumpLimit) / jump
                    rawX = stateX + (rawX - stateX) * scale
                    rawY = stateY + (rawY - stateY) * scale
                }
            } else {
                outlierStreak = 0
            }

            let filtered = applyOneEuroFilter(obsX: rawX, obsY: rawY, timestamp: now, dt: dt)
            stateX = min(0.98, max(0.02, filtered.x))
            stateY = min(0.98, max(0.02, filtered.y))
            let trackedPoint = CGPoint(x: stateX, y: stateY)
            stateLock.unlock()

            if effectiveConfidence > 0.65, let pixelBuffer {
                VisualOdometryEngine.shared.setReferenceFrame(pixelBuffer, atUIPoint: trackedPoint)
            }
            onSpatialTargetUpdated?(trackedPoint, effectiveConfidence, .locked)
            return
        }

        stateLock.lock()
        lastOpticalConfidence = confidence
        stateLock.unlock()

        if !lowTexture, let pixelBuffer,
           let odometryPoint = VisualOdometryEngine.shared.estimateCurrentUIPoint(currentBuffer: pixelBuffer) {
            stateLock.lock()
            let distance = hypot(Double(odometryPoint.x) - stateX, Double(odometryPoint.y) - stateY)
            if distance < 0.15 {
                let blend = 0.35
                stateX = stateX * (1 - blend) + Double(odometryPoint.x) * blend
                stateY = stateY * (1 - blend) + Double(odometryPoint.y) * blend
                filterXPrev = stateX
                filterYPrev = stateY
                let trackedPoint = CGPoint(x: stateX, y: stateY)
                stateLock.unlock()
                onSpatialTargetUpdated?(trackedPoint, 0.70, .locked)
            } else {
                stateLock.unlock()
            }
        }
    }

    private func applyOneEuroFilter(obsX: Double, obsY: Double, timestamp: CFTimeInterval, dt: Double) -> (x: Double, y: Double) {
        guard filterInitialized else {
            filterXPrev = obsX
            filterYPrev = obsY
            filterLastTime = timestamp
            filterInitialized = true
            return (obsX, obsY)
        }

        let rate = 1.0 / dt
        let rawDx = (obsX - filterXPrev) / dt
        let rawDy = (obsY - filterYPrev) / dt
        let derivativeAlpha = alpha(rate: rate, cutoff: dCutoff)
        let dx = derivativeAlpha * rawDx + (1 - derivativeAlpha) * filterDxPrev
        let dy = derivativeAlpha * rawDy + (1 - derivativeAlpha) * filterDyPrev
        filterDxPrev = dx
        filterDyPrev = dy

        let positionAlpha = alpha(rate: rate, cutoff: minCutoff + beta * hypot(dx, dy))
        let x = positionAlpha * obsX + (1 - positionAlpha) * filterXPrev
        let y = positionAlpha * obsY + (1 - positionAlpha) * filterYPrev
        filterXPrev = x
        filterYPrev = y
        return (x, y)
    }

    private func alpha(rate: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / (1.0 / rate))
    }

    public func stopTracking() {
        stateLock.lock()
        trackingActive = false
        filterInitialized = false
        stateLock.unlock()
        motionManager.stopDeviceMotionUpdates()
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
        CameraLogger.info("Street tracker đã dừng", category: .tracking)
    }
}
