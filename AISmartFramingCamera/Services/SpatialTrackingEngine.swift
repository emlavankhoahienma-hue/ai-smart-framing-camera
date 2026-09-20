import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore
import simd

/// A persistent world bearing, NOT a metric 3D position. Pure rotation is
/// observable from CoreMotion; translation is corrected while Vision sees the
/// target. Off-screen translation requires a separate 6DoF/depth provider.
public final class SpatialTrackingEngine: @unchecked Sendable {
    public static let shared = SpatialTrackingEngine()
    private let lock = NSRecursiveLock()
    private var subscription: UUID?
    private var motionEpoch: UInt64 = 0
    private var watchdog: DispatchSourceTimer?
    private var history: [TrackingMotionSample] = []
    private var worldRay: SIMD3<Double>?
    private var pendingPin: (CGPoint, TimeInterval, TrackingCalibration)?
    private var calibration = TrackingCalibration.fallback()
    private var lastFrameTime = -Double.infinity
    private var zoom = 1.0
    private var active = false
    private var generation: UInt64 = 0
    private var lastAccepted = -Double.infinity
    private var lastProcessed = -Double.infinity
    private var pinTime = -Double.infinity
    private var confidence = 0.0
    private var lowTexture = false
    private var scene: DetectedSceneType = .general
    private var street = false
    private var jump: CGFloat = 0.15
    private var threshold = 0.20
    private var estimated = CGPoint(x: 0.5, y: 0.5)
    private var callback: ((CGPoint, Double, TrackingQuality) -> Void)?
    private var pendingOutput: (CGPoint, Double, TrackingQuality, UInt64)?
    private var deliveryScheduled = false

    public init() {}
    deinit {
        watchdog?.cancel()
        if let subscription { DeviceMotionService.shared.unsubscribe(subscription) }
    }

    public var isTrackingActive: Bool { lock.withLock { active } }
    public var activeSceneType: DetectedSceneType {
        get { lock.withLock { scene } }
        set { lock.withLock { scene = newValue } }
    }
    public var isStreetMode: Bool {
        get { lock.withLock { street } }
        set { lock.withLock { street = newValue } }
    }
    public var maxObservationJump: CGFloat {
        get { lock.withLock { jump } }
        set { lock.withLock { if newValue.isFinite { jump = max(0.01, newValue) } } }
    }
    public var opticalAcceptThreshold: Double {
        get { lock.withLock { threshold } }
        set { lock.withLock { if newValue.isFinite { threshold = min(1, max(0, newValue)) } } }
    }
    public var onSpatialTargetUpdated: ((CGPoint, Double, TrackingQuality) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    public var currentEstimatedScreenPoint: CGPoint { lock.withLock { estimated } }
    public var currentBufferAspect: CGFloat { lock.withLock { CGFloat(calibration.aspect) } }
    public var currentDisplayZoom: Double { lock.withLock { zoom } }

    public func setLowTextureFlag(_ value: Bool) { lock.withLock { lowTexture = value } }

    /// Warm up before pinning so the pose at the selected image PTS exists.
    public func prepare() {
        lock.withLock {
            guard subscription == nil else { return }
            motionEpoch &+= 1
            let epoch = motionEpoch
            subscription = DeviceMotionService.shared.subscribe { [weak self] sample in self?.receive(sample, epoch: epoch) }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.publish() }
            }
            watchdog = timer
            timer.resume()
        }
    }

    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat = 1.0) {
        lockAnchor(at: screenPoint, zoom: zoom, timestamp: CACurrentMediaTime())
    }

    public func lockAnchor(at screenPoint: CGPoint, zoom: CGFloat, timestamp: TimeInterval,
                           calibration pinCalibration: TrackingCalibration? = nil) {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite, timestamp.isFinite else { return }
        prepare()
        lock.withLock {
            generation &+= 1; active = true; worldRay = nil
            updateZoomFactor(zoom)
            pinTime = timestamp; pendingPin = (screenPoint, timestamp, pinCalibration ?? calibration)
            lastAccepted = -Double.infinity; lastProcessed = -Double.infinity
            confidence = 0; estimated = screenPoint; pendingOutput = nil
            resolvePin()
            publish()
        }
    }

    public func updateZoomFactor(_ value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        lock.withLock {
            zoom = Double(value)
            if !calibration.isMeasured { calibration = .fallback(zoom: zoom, aspect: calibration.aspect) }
        }
    }

    public func registerFrame(_ frame: TrackingFrameContext) {
        guard frame.calibration.isValid, frame.timestamp.isFinite else { return }
        lock.withLock {
            guard frame.timestamp >= lastFrameTime else { return }
            calibration = frame.calibration; lastFrameTime = frame.timestamp
        }
    }

    public func projection(at timestamp: TimeInterval, calibration k: TrackingCalibration) -> TrackingProjection? {
        lock.withLock {
            guard active, let worldRay, let pose = TrackingGeometry.pose(at: timestamp, in: history) else { return nil }
            return k.project(deviceRay: pose.inverse.act(worldRay))
        }
    }

    private func resolvePin() {
        guard let (point, time, k) = pendingPin,
              let pose = TrackingGeometry.pose(at: time, in: history) else { return }
        worldRay = pose.act(k.deviceRay(at: point))
        pendingPin = nil
    }

    private func receive(_ sample: TrackingMotionSample, epoch: UInt64) {
        lock.withLock {
            guard epoch == motionEpoch else { return }
            guard sample.timestamp > (history.last?.timestamp ?? -Double.infinity) else { return }
            history.append(sample)
            history.removeAll { $0.timestamp < sample.timestamp - 3 }
            guard active else { return }
            resolvePin()
            publish()
        }
    }

    /// Compatibility entry point. Callers with camera buffers must use the
    /// timestamped overload; an arrival-time observation cannot be de-lagged.
    public func updateWithOpticalDetection(point: CGPoint?, confidence: Double, pixelBuffer: CVPixelBuffer? = nil) {
        let k = lock.withLock { calibration }
        updateWithOpticalDetection(point: point, confidence: confidence,
            frame: TrackingFrameContext(timestamp: CACurrentMediaTime(), calibration: k))
    }

    public func updateWithOpticalDetection(point: CGPoint?, confidence value: Double, frame: TrackingFrameContext) {
        lock.withLock {
            guard active, frame.timestamp >= pinTime,
                  frame.timestamp > lastProcessed, frame.calibration.isValid else { return }
            lastProcessed = frame.timestamp
            guard let point, point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y), value.isFinite,
                  value >= max(threshold, lowTexture ? 0.65 : 0.35),
                  let pose = TrackingGeometry.pose(at: frame.timestamp, in: history) else {
                publish(); return
            }
            let observed = pose.act(frame.calibration.deviceRay(at: point))
            if let ray = worldRay {
                let predicted = frame.calibration.project(deviceRay: pose.inverse.act(ray))
                guard predicted.isInFront else { publish(); return }
                let residual = hypot(point.x - predicted.point.x, point.y - predicted.point.y)
                // Reject a jump. Never turn repeated rejected detections into a
                // forced reset, and never refresh confidence on rejected input.
                guard residual <= jump else { publish(); return }
                let dt = lastAccepted.isFinite ? min(0.1, frame.timestamp - lastAccepted) : 1 / 30.0
                // Filter ONLY world-bearing innovation. Camera rotation bypasses
                // this filter completely. Higher cutoff follows real translation.
                let cutoff = (street || scene.isDeformableNature ? 2.0 : 0.7) + min(10, Double(residual) * 100)
                let gain = (1 - exp(-2 * .pi * cutoff * dt)) * min(1, max(0, value))
                worldRay = simd_normalize(ray * (1 - gain) + observed * gain)
            } else {
                // The first timestamped visual fix can initialize if pinning
                // happened before the first CoreMotion sample.
                worldRay = observed; pendingPin = nil
            }
            lastAccepted = frame.timestamp; confidence = min(1, value)
            publish()
        }
    }

    private func publish() {
        guard active else { return }
        let now = CACurrentMediaTime()
        var quality: TrackingQuality = .reacquiring
        var outputConfidence = 0.0
        if let worldRay, let sample = history.last, now - sample.timestamp < 0.15 {
            let projected = calibration.project(deviceRay: sample.deviceToWorld.inverse.act(worldRay))
            estimated = projected.point
            let age = now - lastAccepted
            quality = projected.isInsideImage && age < 0.15 ? .locked :
                (projected.isInsideImage ? .reacquiring : .predicting)
            outputConfidence = age < 0.15 ? confidence : min(0.45, confidence * exp(-max(0, age) / 5))
        }
        // No timeout deletes worldRay or appearance. Only explicit stop/re-pin.
        pendingOutput = (estimated, outputConfidence, quality, generation)
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let output = self.pendingOutput
            self.pendingOutput = nil; self.deliveryScheduled = false
            let callback = self.callback
            let valid = self.active && output?.3 == self.generation
            self.lock.unlock()
            if valid, let output { callback?(output.0, output.1, output.2) }
        }
    }

    public func stopTracking() {
        lock.withLock {
            generation &+= 1; active = false; worldRay = nil; pendingPin = nil; pendingOutput = nil
        }
        // Keep the shared pose stream warm for the next selected camera image.
        // suspend() releases it when the camera screen leaves the foreground.
        VisualOdometryEngine.shared.clearReference()
        NeuralTargetTracker.shared.clearAnchor()
    }

    public func suspend() {
        stopTracking()
        let id = lock.withLock { () -> UUID? in
            motionEpoch &+= 1
            watchdog?.cancel(); watchdog = nil
            let id = subscription; subscription = nil; history.removeAll(); return id
        }
        if let id { DeviceMotionService.shared.unsubscribe(id) }
    }
}
