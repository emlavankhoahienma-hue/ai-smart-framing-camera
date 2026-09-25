import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore
import simd

enum TrackingObservationGate {
    static func accepts(isInFront: Bool, residual: CGFloat,
                        maximumJump: CGFloat, evidence: TrackingOpticalEvidence) -> Bool {
        if evidence == .reidentified { return residual.isFinite }
        if evidence == .confirmedContinuation { return residual.isFinite }
        guard isInFront, residual.isFinite else { return false }
        // A world bearing can disagree with a continuing optical track after
        // translation or a calibration change. Keep a broad sanity bound, then
        // reduce the correction gain instead of discarding small/medium errors.
        let limit = max(0.30, maximumJump * 2)
        return residual <= limit
    }
}

/// Reject isolated optical innovations in world coordinates, where camera pans
/// cancel out. A sustained translation may pass after three distinct images;
/// a single bad box must never move the anchor, even with high VN confidence.
struct TrackingInnovationPolicy {
    private var candidate: SIMD3<Double>?
    private var timestamp = -Double.infinity
    private var count = 0

    mutating func reset() { candidate = nil; timestamp = -.infinity; count = 0 }

    mutating func accepts(observed: SIMD3<Double>, predicted: SIMD3<Double>,
                         timestamp time: TimeInterval, focalScale: Double,
                         evidence: TrackingOpticalEvidence) -> Bool {
        let angle = atan2(simd_length(simd_cross(predicted, observed)),
                          simd_dot(predicted, observed))
        let immediate = (evidence == .geometryContinuation ? 0.012 : 0.020) / focalScale
        if evidence == .reidentified || angle <= immediate {
            reset()
            return true
        }
        let consistent = candidate.map {
            let difference = atan2(simd_length(simd_cross($0, observed)), simd_dot($0, observed))
            return time > timestamp && time - timestamp <= 0.20 && difference <= 0.035 / focalScale
        } ?? false
        count = consistent ? count + 1 : 1
        candidate = observed
        timestamp = time
        return count >= 3
    }
}

/// Limits ONLY changes to the world bearing. Device rotation is applied later,
/// unfiltered, so the reticle cannot trail the optical centre during a pan.
enum TrackingBearingSlew {
    static func advance(from: SIMD3<Double>, to: SIMD3<Double>,
                        maxAngle: Double) -> SIMD3<Double> {
        let delta = simd_quatd(from: from, to: to)
        let angle = abs(delta.angle)
        guard angle > maxAngle, angle > 1e-9 else { return to }
        let fraction = max(0, maxAngle) / angle
        let identity = simd_quatd(angle: 0, axis: SIMD3<Double>(0, 1, 0))
        return simd_normalize(simd_slerp(identity, delta, fraction).act(from))
    }
}

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
    private var displayWorldRay: SIMD3<Double>?
    private var lastDisplayTime = -Double.infinity
    private var presentationIsRecovering = false
    private var innovation = TrackingInnovationPolicy()
    private var subjectWorldRay: SIMD3<Double>?
    private var guideFromSubject: simd_quatd?
    private var pendingPin: (CGPoint, TimeInterval, TrackingCalibration)?
    private var calibration = TrackingCalibration.fallback()
    private var lastFrameTime = -Double.infinity
    private var zoom = 1.0
    private var active = false
    private var generation: UInt64 = 0
    private var lastAccepted = -Double.infinity
    private var lastVerified = -Double.infinity
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
    // Internal acknowledgement: UI/capture must not treat a rejected frame as a lock.
    var lastAcceptedOpticalTimestamp: TimeInterval { lock.withLock { lastAccepted } }

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
                           calibration pinCalibration: TrackingCalibration? = nil,
                           pinnedWorldRay: SIMD3<Double>? = nil,
                           trackedSubjectRay: SIMD3<Double>? = nil) {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite, timestamp.isFinite else { return }
        if let pinnedWorldRay {
            let length = simd_length(pinnedWorldRay)
            guard pinnedWorldRay.x.isFinite, pinnedWorldRay.y.isFinite,
                  pinnedWorldRay.z.isFinite, length.isFinite, length > 1e-6 else { return }
        }
        prepare()
        lock.withLock {
            generation &+= 1; active = true
            updateZoomFactor(zoom)
            pinTime = timestamp
            if let pinnedWorldRay {
                worldRay = simd_normalize(pinnedWorldRay)
                if let trackedSubjectRay {
                    let length = simd_length(trackedSubjectRay)
                    subjectWorldRay = length.isFinite && length > 1e-6 ?
                        simd_normalize(trackedSubjectRay) : nil
                    guideFromSubject = subjectWorldRay.map {
                        simd_quatd(from: $0, to: simd_normalize(pinnedWorldRay))
                    }
                } else { subjectWorldRay = nil; guideFromSubject = nil }
                pendingPin = nil
            } else {
                worldRay = nil
                subjectWorldRay = nil
                guideFromSubject = nil
                pendingPin = (screenPoint, timestamp, pinCalibration ?? calibration)
            }
            // The yellow reticle represents the physical subject. The
            // composition guide may have a different bearing.
            displayWorldRay = subjectWorldRay ?? worldRay
            lastDisplayTime = -.infinity
            presentationIsRecovering = false
            innovation.reset()
            lastAccepted = -Double.infinity; lastVerified = -.infinity
            lastProcessed = -Double.infinity
            confidence = 0; estimated = screenPoint; pendingOutput = nil
            resolvePin()
            publish()
        }
    }

    public func updateZoomFactor(_ value: CGFloat) {
        guard value.isFinite, value > 0 else { return }
        lock.withLock {
            zoom = Double(value)
            // KVO precedes the image exposed at that zoom. Keep the last image
            // calibration until registerFrame delivers its matching geometry.
            if !lastFrameTime.isFinite {
                calibration = .fallback(zoom: zoom, aspect: calibration.aspect)
            }
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
            guard active, let ray = subjectWorldRay ?? worldRay,
                  let pose = TrackingGeometry.pose(at: timestamp, in: history) else { return nil }
            return k.project(deviceRay: pose.inverse.act(ray))
        }
    }

    /// Snapshot the pose while the capture frame is still in the short motion
    /// history. Cloud analysis can return long after that history has expired.
    func pose(at timestamp: TimeInterval) -> simd_quatd? {
        lock.withLock { TrackingGeometry.pose(at: timestamp, in: history) }
    }

    /// Use a fresh motion sample when the exact camera timestamp falls just
    /// outside the interpolation window during camera start or lens switching.
    func latestPose(maxAge: TimeInterval = 0.25) -> simd_quatd? {
        lock.withLock {
            guard maxAge.isFinite, maxAge > 0, let sample = history.last else { return nil }
            let age = CACurrentMediaTime() - sample.timestamp
            guard age >= -0.05, age <= maxAge else { return nil }
            return sample.deviceToWorld
        }
    }

    private func resolvePin() {
        guard let (point, time, k) = pendingPin else { return }
        // A tap can precede the first CoreMotion callback. Once that callback
        // arrives, its pose is a bounded startup approximation; otherwise the
        // pending pin would remain unresolved and the ring would stay glued to
        // its original screen coordinate until Vision happened to succeed.
        let pose = TrackingGeometry.pose(at: time, in: history) ?? history.first.flatMap {
            $0.timestamp >= time && $0.timestamp - time <= 0.25 ? $0.deviceToWorld : nil
        }
        guard let pose else { return }
        worldRay = pose.act(k.deviceRay(at: point))
        displayWorldRay = worldRay
        pendingPin = nil
    }

    private func receive(_ sample: TrackingMotionSample, epoch: UInt64) {
        lock.withLock {
            guard epoch == motionEpoch else { return }
            let q = sample.deviceToWorld.vector
            let qLength = simd_length(q)
            guard sample.timestamp.isFinite, q.x.isFinite, q.y.isFinite,
                  q.z.isFinite, q.w.isFinite, qLength.isFinite,
                  qLength > 1e-9 else { return }
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
        updateWithOpticalDetection(point: point, confidence: value, frame: frame,
                                   evidence: .verifiedContinuation)
    }

    func updateWithOpticalDetection(point: CGPoint?, confidence value: Double,
                                    frame: TrackingFrameContext, evidence: TrackingOpticalEvidence) {
        lock.withLock {
            let age = CACurrentMediaTime() - frame.timestamp
            guard active, frame.timestamp.isFinite, (-0.05...0.75).contains(age),
                  frame.timestamp >= pinTime,
                  frame.timestamp > lastProcessed, frame.calibration.isValid else { return }
            lastProcessed = frame.timestamp
            guard let point, point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y), value.isFinite,
                  value >= max(threshold,
                               lowTexture && evidence == .geometryContinuation ? 0.50 : 0.35),
                  let pose = TrackingGeometry.pose(at: frame.timestamp, in: history) else {
                innovation.reset()
                publish(); return
            }
            let observed = pose.act(frame.calibration.deviceRay(at: point))
            if let ray = subjectWorldRay ?? worldRay {
                let predicted = frame.calibration.project(deviceRay: pose.inverse.act(ray))
                let residual = hypot(point.x - predicted.point.x, point.y - predicted.point.y)
                // Only a separately confirmed re-ID may move the bearing beyond
                // the ordinary continuation gate after parallax or a long absence.
                guard TrackingObservationGate.accepts(isInFront: predicted.isInFront,
                    residual: residual, maximumJump: jump, evidence: evidence) else { publish(); return }
                guard innovation.accepts(observed: observed, predicted: ray,
                    timestamp: frame.timestamp,
                    focalScale: max(frame.calibration.fx, frame.calibration.fy),
                    evidence: evidence) else { publish(); return }
                let dt = lastAccepted.isFinite ? min(0.05, frame.timestamp - lastAccepted) : 1 / 30.0
                // Filter ONLY world-bearing innovation. Camera rotation bypasses
                // this filter completely. A larger residual gets a useful but
                // bounded correction rather than an abrupt snap or a hard reject.
                let cutoff = (street || scene.isDeformableNature ? 2.0 : 0.7) + min(6, Double(residual) * 40)
                let ordinaryGain = (1 - exp(-2 * .pi * cutoff * dt)) * min(1, max(0, value))
                let residualWeight = max(0.45, 1 / (1 + pow(Double(residual) / 0.20, 2)))
                let evidenceWeight = evidence == .geometryContinuation ? 0.70 : 1.0
                // Once the innovation gate has seen the same displacement on
                // distinct images, follow real subject motion promptly. Small
                // static jitter still takes the quieter ordinary filter path.
                let motionFraction = min(1, max(0, (Double(residual) - 0.02) / 0.08))
                let motionGain = motionFraction * motionFraction * (3 - 2 * motionFraction) *
                    (evidence == .geometryContinuation ? 0.50 : 0.65)
                let nominalGain = max(ordinaryGain * residualWeight * evidenceWeight,
                                      motionGain)
                // Rate is per second, not per delivered frame (Vision FPS varies).
                let speed = evidence == .geometryContinuation ? 1.1 : 1.6
                let maxSafeGain = residual > 1e-5 ?
                    min(1.0, min(speed * dt, 0.035) / Double(residual)) : 1.0
                let gain = min(nominalGain, maxSafeGain)
                let corrected: SIMD3<Double>
                if evidence == .reidentified {
                    corrected = observed
                } else {
                    let blended = ray * (1 - gain) + observed * gain
                    let length = simd_length(blended)
                    guard length.isFinite, length > 1e-9 else { publish(); return }
                    corrected = blended / length
                }
                if subjectWorldRay != nil, let guideFromSubject {
                    // Keep the source-frame angular offset exactly. Incremental
                    // corrections would slowly rotate the guide around the subject.
                    worldRay = guideFromSubject.act(corrected)
                    subjectWorldRay = corrected
                } else {
                    worldRay = corrected
                }
                if evidence == .reidentified {
                    presentationIsRecovering = true
                } else if !presentationIsRecovering {
                    // Accepted live optical motion is already rate limited.
                    // Do not filter it a second time or the reticle trails a
                    // moving subject while the image continues to move.
                    displayWorldRay = subjectWorldRay ?? worldRay
                }
            } else {
                // The first timestamped visual fix can initialize if pinning
                // happened before the first CoreMotion sample.
                worldRay = observed; displayWorldRay = observed; pendingPin = nil
            }
            lastAccepted = frame.timestamp
            if evidence != .geometryContinuation { lastVerified = frame.timestamp }
            confidence = min(1, value)
            publish()
        }
    }

    private func publish() {
        guard active else { return }
        let now = CACurrentMediaTime()
        var quality: TrackingQuality = .reacquiring
        var outputConfidence = 0.0
        if let reticleRay = subjectWorldRay ?? worldRay, let sample = history.last,
           (-0.05...0.45).contains(now - sample.timestamp) {
            let dt = lastDisplayTime.isFinite ? min(0.05, max(0, now - lastDisplayTime)) : 0
            let rendered = presentationIsRecovering ? (displayWorldRay.map {
                TrackingBearingSlew.advance(from: $0, to: reticleRay,
                    maxAngle: 0.90 * dt / max(calibration.fx, calibration.fy))
            } ?? reticleRay) : reticleRay
            displayWorldRay = rendered
            lastDisplayTime = now
            let settlingAngle = atan2(simd_length(simd_cross(rendered, reticleRay)),
                                      simd_dot(rendered, reticleRay))
            let settled = settlingAngle * max(calibration.fx, calibration.fy) < 0.008
            if settled { presentationIsRecovering = false }
            // Paint onto the latest camera image, using its pose and intrinsics
            // together. Projecting an older image with the newest IMU pose makes
            // the ring lead the subject and oscillate during a handheld pan.
            let imagePose = (now - lastFrameTime <= 0.20 ?
                TrackingGeometry.pose(at: lastFrameTime, in: history) : nil) ?? sample.deviceToWorld
            let projected = calibration.project(deviceRay: imagePose.inverse.act(rendered))
            if projected.point.x.isFinite, projected.point.y.isFinite {
                estimated = projected.point
                let age = now - lastAccepted
                let motionIsCurrent = now - sample.timestamp <= 0.10
                let isVerified = now - lastVerified < 1.0 || age < 0.35
                if projected.isInsideImage && motionIsCurrent && isVerified && age < 0.45 && settled {
                    quality = .locked
                } else {
                    // Optical absence never expires a valid world bearing.
                    // Keep the yellow guide and recover identity in the background.
                    quality = .predicting
                }
                outputConfidence = age < 1.20 ? confidence : min(0.45, confidence * exp(-max(0, age) / 5))
            }
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
            generation &+= 1; active = false; worldRay = nil; subjectWorldRay = nil
            guideFromSubject = nil
            displayWorldRay = nil; lastDisplayTime = -.infinity
            presentationIsRecovering = false; innovation.reset()
            pendingPin = nil; pendingOutput = nil
        }
        // Keep the shared pose stream warm for the next selected camera image.
        // suspend() releases it when the camera screen leaves the foreground.
        VisualOdometryEngine.shared.clearReference()
        // Vision owns appearance lifetime on its serial queue. Clearing it here
        // can race the seed of a new session while stopTracking is returning.
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
