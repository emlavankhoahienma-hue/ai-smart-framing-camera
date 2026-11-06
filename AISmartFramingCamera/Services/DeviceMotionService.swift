import Foundation
import CoreMotion
import CoreGraphics
import simd

/// One manager for legacy motion guidance and spatial tracking. The manager,
/// subscribers and legacy baseline are protected by the same recursive lock.
/// Callbacks run outside the lock. start/stop never waits for the main queue.
public final class DeviceMotionService: @unchecked Sendable {
    public static let shared = DeviceMotionService()
    private let manager = CMMotionManager()
    private let queue: OperationQueue
    private let lock = NSRecursiveLock()
    private var subscribers: [UUID: (TrackingMotionSample) -> Void] = [:]
    private var legacyActive = false
    private var legacyGeneration: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var reference: simd_quatd?
    private var motionCallback: ((CGFloat, CGFloat) -> Void)?

    // Horizon Lock 360° state (Velocity-Adaptive Circular EMA + Adaptive Dynamic Zoom)
    public private(set) var horizonRollAngle: Float = 0.0
    public private(set) var horizonAdaptiveZoom: Float = 1.02
    public private(set) var horizonShakeX: Float = 0.0
    public private(set) var horizonShakeY: Float = 0.0
    private var smoothedCosRoll: Float = 1.0
    private var smoothedSinRoll: Float = 0.0
    private var isHorizonTrackingActive: Bool = false

    public var onMotionUpdate: ((CGFloat, CGFloat) -> Void)? {
        get { lock.withLock { motionCallback } }
        set { lock.withLock { motionCallback = newValue } }
    }

    public init() {
        queue = OperationQueue()
        queue.name = "com.alignai.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func subscribe(_ callback: @escaping (TrackingMotionSample) -> Void) -> UUID {
        lock.withLock {
            let id = UUID()
            subscribers[id] = callback
            startIfNeeded()
            return id
        }
    }

    func unsubscribe(_ id: UUID) {
        lock.withLock {
            subscribers.removeValue(forKey: id)
            stopIfUnused()
        }
    }

    public func startTracking() {
        lock.withLock {
            legacyGeneration &+= 1; legacyActive = true; reference = nil
            startIfNeeded()
        }
    }

    public func resetReferenceAttitude() { lock.withLock { reference = nil } }

    public func recalibrateBaselines() {
        lock.withLock {
            reference = nil
            legacyGeneration &+= 1
            smoothedCosRoll = 1.0
            smoothedSinRoll = 0.0
            horizonRollAngle = 0.0
            horizonAdaptiveZoom = 1.02
            horizonShakeX = 0.0
            horizonShakeY = 0.0
        }
    }

    public func stopTracking() {
        lock.withLock {
            legacyGeneration &+= 1; legacyActive = false; reference = nil
            stopIfUnused()
        }
    }

    public func setHorizonTrackingActive(_ active: Bool) {
        lock.withLock {
            isHorizonTrackingActive = active
            if active {
                startIfNeeded()
            } else {
                stopIfUnused()
            }
        }
    }

    public func currentHorizonParams() -> (roll: Float, zoom: Float, shakeX: Float, shakeY: Float) {
        lock.withLock {
            (horizonRollAngle, horizonAdaptiveZoom, horizonShakeX, horizonShakeY)
        }
    }

    private func stopIfUnused() {
        if subscribers.isEmpty && !legacyActive && !isHorizonTrackingActive {
            streamGeneration &+= 1
            manager.stopDeviceMotionUpdates()
        }
    }

    private func startIfNeeded() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        streamGeneration &+= 1
        let epoch = streamGeneration
        manager.deviceMotionUpdateInterval = 1.0 / 200.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }

            let gx = Float(motion.gravity.x)
            let gy = Float(motion.gravity.y)
            let rawRoll = atan2(gx, -gy) // Góc trọng lực thực tế [-pi, +pi]
            let gyroSpeed = Float(abs(motion.rotationRate.z))
            let rateX = Float(motion.rotationRate.x)
            let rateY = Float(motion.rotationRate.y)

            let r = motion.attitude.rotationMatrix
            // CoreMotion DCM maps reference -> device. Invert to unproject an
            // image ray into the reference frame. No Euler angles or rate gains.
            let worldToDevice = simd_double3x3(columns: (
                SIMD3(r.m11, r.m21, r.m31), SIMD3(r.m12, r.m22, r.m32), SIMD3(r.m13, r.m23, r.m33)))
            let pose = simd_quatd(worldToDevice.transpose)
            let sample = TrackingMotionSample(timestamp: motion.timestamp, deviceToWorld: pose)
            self.lock.lock()
            // A queued callback from a stopped manager belongs to its old
            // reference frame and must not enter a newly subscribed session.
            guard self.streamGeneration == epoch else { self.lock.unlock(); return }

            // 1. Velocity-Adaptive Circular EMA (Làm mượt trên sin/cos để vượt qua +-180 độ mượt tuyệt đối)
            let currentAngle = atan2(self.smoothedSinRoll, self.smoothedCosRoll)
            let angleDelta = abs(atan2(sin(rawRoll - currentAngle), cos(rawRoll - currentAngle)))
            let adaptiveAlpha = min(max(0.06 + gyroSpeed * 0.12 + angleDelta * 0.45, 0.06), 0.55)

            self.smoothedCosRoll = self.smoothedCosRoll * (1.0 - adaptiveAlpha) + cos(rawRoll) * adaptiveAlpha
            self.smoothedSinRoll = self.smoothedSinRoll * (1.0 - adaptiveAlpha) + sin(rawRoll) * adaptiveAlpha
            let calculatedRoll = atan2(self.smoothedSinRoll, self.smoothedCosRoll)
            self.horizonRollAngle = calculatedRoll

            // 2. Adaptive Dynamic Zoom (Cầm thẳng 0 độ chỉ zoom nhẹ 1.02x; nghiêng tới đâu tự tăng zoom giấu 4 góc đen)
            let sin2Theta = abs(sin(2.0 * calculatedRoll))
            let neededScale = Float(1.02 + 0.24 * sin2Theta)
            self.horizonAdaptiveZoom = self.horizonAdaptiveZoom * 0.85 + neededScale * 0.15

            // 3. Bù rung tay vi mô ngang/dọc (+-3%)
            self.horizonShakeX = (self.horizonShakeX * 0.85) + min(max(rateY * 0.006, -0.03), 0.03)
            self.horizonShakeY = (self.horizonShakeY * 0.85) + min(max(rateX * 0.006, -0.03), 0.03)

            let handlers = Array(self.subscribers.values)
            let generation = self.legacyGeneration
            var delta: CGPoint?
            if self.legacyActive {
                if self.reference == nil { self.reference = pose }
                if let reference = self.reference {
                    let ray = pose.inverse.act(reference.act(SIMD3(0, 0, -1)))
                    let projected = TrackingCalibration.fallback().project(deviceRay: ray)
                    delta = CGPoint(x: projected.point.x - 0.5, y: projected.point.y - 0.5)
                }
            }
            self.lock.unlock()
            handlers.forEach { $0(sample) }
            if let delta {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let callback = self.lock.withLock {
                        self.legacyActive && self.legacyGeneration == generation ? self.motionCallback : nil
                    }
                    callback?(delta.x, delta.y)
                }
            }
        }
    }
}
