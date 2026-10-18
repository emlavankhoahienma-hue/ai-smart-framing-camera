import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore
import simd

/// 2x2 matrix helper for Kalman filter covariance, process noise, and gain operations.
struct Mat2: Sendable {
    var m00: Double
    var m01: Double
    var m10: Double
    var m11: Double

    static let zero = Mat2(m00: 0, m01: 0, m10: 0, m11: 0)
    static let identity = Mat2(m00: 1, m01: 0, m10: 0, m11: 1)

    static func diagonal(_ s: Double) -> Mat2 {
        Mat2(m00: s, m01: 0, m10: 0, m11: s)
    }

    var determinant: Double {
        m00 * m11 - m01 * m10
    }

    var inverse: Mat2? {
        let det = determinant
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        let inv = 1.0 / det
        return Mat2(
            m00: m11 * inv,
            m01: -m01 * inv,
            m10: -m10 * inv,
            m11: m00 * inv
        )
    }

    static func + (lhs: Mat2, rhs: Mat2) -> Mat2 {
        Mat2(m00: lhs.m00 + rhs.m00, m01: lhs.m01 + rhs.m01,
             m10: lhs.m10 + rhs.m10, m11: lhs.m11 + rhs.m11)
    }

    static func - (lhs: Mat2, rhs: Mat2) -> Mat2 {
        Mat2(m00: lhs.m00 - rhs.m00, m01: lhs.m01 - rhs.m01,
             m10: lhs.m10 - rhs.m10, m11: lhs.m11 - rhs.m11)
    }

    static func * (lhs: Mat2, rhs: Double) -> Mat2 {
        Mat2(m00: lhs.m00 * rhs, m01: lhs.m01 * rhs,
             m10: lhs.m10 * rhs, m11: lhs.m11 * rhs)
    }

    static func * (lhs: Mat2, rhs: Mat2) -> Mat2 {
        Mat2(
            m00: lhs.m00 * rhs.m00 + lhs.m01 * rhs.m10,
            m01: lhs.m00 * rhs.m01 + lhs.m01 * rhs.m11,
            m10: lhs.m10 * rhs.m00 + lhs.m11 * rhs.m10,
            m11: lhs.m10 * rhs.m01 + lhs.m11 * rhs.m11
        )
    }

    static func * (lhs: Mat2, rhs: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2<Double>(
            lhs.m00 * rhs.x + lhs.m01 * rhs.y,
            lhs.m10 * rhs.x + lhs.m11 * rhs.y
        )
    }

    var transposed: Mat2 {
        Mat2(m00: m00, m01: m10, m10: m01, m11: m11)
    }

    var symmetrized: Mat2 {
        let off = 0.5 * (m01 + m10)
        return Mat2(m00: m00, m01: off, m10: off, m11: m11)
    }
}

/// Unified probabilistic observation gate for spatial bearing tracking.
/// Uses Mahalanobis distance based on innovation covariance S = P + R (NSA Kalman)
/// instead of ad-hoc heuristic thresholds or artificial delay latches.
enum TrackingObservationGate {
    static func accepts(isInFront: Bool, residual: CGFloat,
                        maximumJump: CGFloat, evidence: TrackingOpticalEvidence) -> Bool {
        if evidence == .reidentified { return residual.isFinite }
        if evidence == .confirmedContinuation { return residual.isFinite }
        guard isInFront, residual.isFinite else { return false }
        let limit = max(0.30, maximumJump * 2)
        return residual <= limit
    }

    static func accepts(isInFront: Bool, residual: CGFloat,
                        mahalanobisSq: Double, gateThreshold: Double = 16.0,
                        evidence: TrackingOpticalEvidence) -> Bool {
        if evidence == .reidentified { return residual.isFinite }
        guard isInFront, residual.isFinite else { return false }
        if evidence == .confirmedContinuation {
            return mahalanobisSq <= max(gateThreshold, 100.0)
        }
        let effectiveGate = evidence == .verifiedContinuation ? max(gateThreshold, 25.0) : gateThreshold
        return mahalanobisSq <= effectiveGate
    }
}

/// Local tangent plane Error-State Kalman Filter (ESKF) on S^2 sphere.
/// Represents target world bearing r (||r|| = 1) and angular velocity omega (rad/s).
/// Uses NSA Kalman covariance scaling and unified Mahalanobis innovation gating.
final class SpatialTangentKalmanFilter: @unchecked Sendable {
    private(set) var bearing: SIMD3<Double>
    private(set) var tangentE1: SIMD3<Double>
    private(set) var tangentE2: SIMD3<Double>
    private(set) var angularVelocity: SIMD2<Double>

    private var pThetaTheta: Mat2
    private var pThetaOmega: Mat2
    private var pOmegaOmega: Mat2

    private(set) var lastTimestamp: TimeInterval
    private var lastVerifiedRay: SIMD3<Double>?
    private var lastVerifiedTimestamp: TimeInterval = -Double.infinity

    init(initialBearing: SIMD3<Double>, timestamp: TimeInterval) {
        let len = simd_length(initialBearing)
        let normalized = (initialBearing.x.isFinite && initialBearing.y.isFinite && initialBearing.z.isFinite && len.isFinite && len > 1e-6) ?
            simd_normalize(initialBearing) : SIMD3<Double>(0, 0, -1)
        self.bearing = normalized
        let basis = Self.constructTangentBasis(for: normalized)
        self.tangentE1 = basis.0
        self.tangentE2 = basis.1
        self.angularVelocity = .zero

        self.pThetaTheta = Mat2.diagonal(0.0004)
        self.pThetaOmega = Mat2.zero
        self.pOmegaOmega = Mat2.diagonal(0.25)
        self.lastTimestamp = timestamp.isFinite ? timestamp : 0
        self.lastVerifiedRay = normalized
        self.lastVerifiedTimestamp = self.lastTimestamp
    }

    static func constructTangentBasis(for ray: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let up = abs(ray.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let unnormalizedE1 = up - simd_dot(up, ray) * ray
        let lenE1 = simd_length(unnormalizedE1)
        let e1 = lenE1 > 1e-6 ? unnormalizedE1 / lenE1 : SIMD3<Double>(1, 0, 0)
        let e2 = simd_cross(ray, e1)
        return (e1, e2)
    }

    func predict(to timestamp: TimeInterval, isDynamicScene: Bool = false) {
        guard timestamp.isFinite, lastTimestamp.isFinite else { return }
        let rawDt = timestamp - lastTimestamp
        guard rawDt > 0 else { return }
        let dt = min(0.25, max(0.0005, rawDt))
        lastTimestamp = timestamp

        if rawDt > 0.5 {
            angularVelocity = .zero
            pThetaTheta = pThetaTheta + Mat2.diagonal(0.01)
            pOmegaOmega = Mat2.diagonal(1.0)
            return
        }

        // Damping on angular velocity prevents persistent angular momentum
        // when camera stops translating or panning
        let damping = exp(-1.5 * dt)
        angularVelocity *= damping

        let deltaTheta = angularVelocity * dt
        let angle = hypot(deltaTheta.x, deltaTheta.y)
        if angle > 1e-9 {
            let uTangent = (tangentE1 * deltaTheta.x + tangentE2 * deltaTheta.y) / angle
            let newBearing = simd_normalize(bearing * cos(angle) + uTangent * sin(angle))
            updateTangentFrame(newBearing: newBearing)
        }

        let qa = isDynamicScene ? 3.0 : 1.2
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let qTrans = 0.004 * dt
        let qThetaTheta = Mat2.diagonal(dt3 / 3.0 * qa + qTrans)
        let qThetaOmega = Mat2.diagonal(dt2 / 2.0 * qa)
        let qOmegaOmega = Mat2.diagonal(dt * qa)

        let pTT = pThetaTheta + (pThetaOmega + pThetaOmega.transposed) * dt + pOmegaOmega * dt2 + qThetaTheta
        let pTO = pThetaOmega + pOmegaOmega * dt + qThetaOmega
        let pOO = pOmegaOmega + qOmegaOmega

        pThetaTheta = pTT.symmetrized
        pThetaOmega = pTO
        pOmegaOmega = pOO.symmetrized
    }

    private func updateTangentFrame(newBearing: SIMD3<Double>) {
        let unnormalizedE1 = tangentE1 - simd_dot(tangentE1, newBearing) * newBearing
        let lenE1 = simd_length(unnormalizedE1)
        let newE1: SIMD3<Double>
        if lenE1 > 1e-6 {
            newE1 = unnormalizedE1 / lenE1
        } else {
            newE1 = Self.constructTangentBasis(for: newBearing).0
        }
        let newE2 = simd_cross(newBearing, newE1)

        let omega3D = tangentE1 * angularVelocity.x + tangentE2 * angularVelocity.y
        angularVelocity = SIMD2<Double>(simd_dot(omega3D, newE1), simd_dot(omega3D, newE2))

        bearing = newBearing
        tangentE1 = newE1
        tangentE2 = newE2
    }

    func evaluateInnovation(observedRay: SIMD3<Double>, confidence: Double, focalScale: Double) -> (Double, SIMD2<Double>, Mat2)? {
        let len = simd_length(observedRay)
        guard observedRay.x.isFinite, observedRay.y.isFinite, observedRay.z.isFinite, len.isFinite, len > 1e-6 else { return nil }
        let obsNorm = simd_normalize(observedRay)
        let dotProduct = simd_dot(bearing, obsNorm)
        guard dotProduct > -0.2 else { return nil }

        let crossProd = simd_cross(bearing, obsNorm)
        let angle = atan2(simd_length(crossProd), dotProduct)
        let tangentVec = obsNorm - dotProduct * bearing
        let lenTangent = simd_length(tangentVec)
        let innovation3D = lenTangent > 1e-9 ? tangentVec * (angle / lenTangent) : SIMD3<Double>.zero

        let y = SIMD2<Double>(simd_dot(innovation3D, tangentE1), simd_dot(innovation3D, tangentE2))

        let safeConf = min(1.0, max(0.20, confidence))
        let baseSigma = 0.008 / max(0.5, focalScale)
        let nsaSigma = baseSigma * (1.0 + 1.5 * (1.0 - safeConf))
        let rMat = Mat2.diagonal(nsaSigma * nsaSigma)

        let sMat = (pThetaTheta + rMat).symmetrized
        guard let sInv = sMat.inverse else { return nil }

        let sInvY = sInv * y
        let mahalanobisSq = y.x * sInvY.x + y.y * sInvY.y
        guard mahalanobisSq.isFinite, mahalanobisSq >= 0 else { return nil }
        return (mahalanobisSq, y, sInv)
    }

    func update(innovation y: SIMD2<Double>, sInv: Mat2) {
        let kTheta = pThetaTheta * sInv
        let kOmega = pThetaOmega.transposed * sInv

        let deltaThetaCorr = kTheta * y
        let deltaOmegaCorr = kOmega * y

        let corrAngle = hypot(deltaThetaCorr.x, deltaThetaCorr.y)
        if corrAngle > 1e-12 {
            let uCorr = (tangentE1 * deltaThetaCorr.x + tangentE2 * deltaThetaCorr.y) / corrAngle
            let newBearing = simd_normalize(bearing * cos(corrAngle) + uCorr * sin(corrAngle))
            updateTangentFrame(newBearing: newBearing)
        }

        angularVelocity += deltaOmegaCorr
        let speed = hypot(angularVelocity.x, angularVelocity.y)
        if speed > 6.0 {
            angularVelocity *= (6.0 / speed)
        }

        let i2 = Mat2.identity
        let pTT = (i2 - kTheta) * pThetaTheta
        let pTO = (i2 - kTheta) * pThetaOmega
        let pOO = pOmegaOmega - kOmega * pThetaOmega

        pThetaTheta = pTT.symmetrized
        pThetaOmega = pTO
        pOmegaOmega = pOO.symmetrized

        pThetaTheta.m00 = max(1e-8, pThetaTheta.m00)
        pThetaTheta.m11 = max(1e-8, pThetaTheta.m11)
        pOmegaOmega.m00 = max(1e-6, pOmegaOmega.m00)
        pOmegaOmega.m11 = max(1e-6, pOmegaOmega.m11)

        lastVerifiedRay = bearing
        lastVerifiedTimestamp = lastTimestamp
    }

    func reidentify(observedRay: SIMD3<Double>, timestamp: TimeInterval) {
        let obsNorm = simd_normalize(observedRay)
        let dtMiss = lastVerifiedTimestamp.isFinite ? timestamp - lastVerifiedTimestamp : 0

        var interpolatedVelocity = SIMD2<Double>.zero
        if dtMiss > 0.04 && dtMiss <= 1.5, let lastRef = lastVerifiedRay {
            let dotVal = simd_dot(lastRef, obsNorm)
            let crossLen = simd_length(simd_cross(lastRef, obsNorm))
            let gapAngle = atan2(crossLen, dotVal)
            let tangentDisp = obsNorm - dotVal * lastRef
            let tangentLen = simd_length(tangentDisp)
            if tangentLen > 1e-6 {
                let basis = Self.constructTangentBasis(for: obsNorm)
                let avgSpeed = min(3.5, gapAngle / dtMiss)
                let dir3D = tangentDisp / tangentLen
                interpolatedVelocity = SIMD2<Double>(
                    simd_dot(dir3D, basis.0) * avgSpeed,
                    simd_dot(dir3D, basis.1) * avgSpeed
                )
            }
        }

        bearing = obsNorm
        let basis = Self.constructTangentBasis(for: obsNorm)
        tangentE1 = basis.0
        tangentE2 = basis.1
        angularVelocity = interpolatedVelocity

        pThetaTheta = Mat2.diagonal(0.0004)
        pThetaOmega = Mat2.zero
        pOmegaOmega = Mat2.diagonal(0.25)

        lastTimestamp = timestamp
        lastVerifiedRay = obsNorm
        lastVerifiedTimestamp = timestamp
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
    private var kalmanFilter: SpatialTangentKalmanFilter?
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
    private var pendingOutput: (CGPoint, Double, TrackingQuality, UInt64, SIMD3<Double>?, TimeInterval)?
    private var deliveredPresentationBearing: (ray: SIMD3<Double>, timestamp: TimeInterval, generation: UInt64)?
    private var deliveryScheduled = false

    /// The exact smoothed world bearing delivered with the UI callback. Consumers
    /// can project it into a newer image without decoding an older image point
    /// with that newer image's intrinsics or pose. No tracking state is corrected.
    var presentationBearing: (ray: SIMD3<Double>, timestamp: TimeInterval)? {
        lock.withLock {
            guard active, let bearing = deliveredPresentationBearing,
                  bearing.generation == generation else { return nil }
            return (bearing.ray, bearing.timestamp)
        }
    }

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
                let normRay = simd_normalize(pinnedWorldRay)
                worldRay = normRay
                if let trackedSubjectRay {
                    let length = simd_length(trackedSubjectRay)
                    subjectWorldRay = length.isFinite && length > 1e-6 ?
                        simd_normalize(trackedSubjectRay) : nil
                    guideFromSubject = subjectWorldRay.map {
                        simd_quatd(from: $0, to: normRay)
                    }
                } else { subjectWorldRay = nil; guideFromSubject = nil }
                pendingPin = nil
                kalmanFilter = SpatialTangentKalmanFilter(initialBearing: subjectWorldRay ?? normRay, timestamp: timestamp)
            } else {
                worldRay = nil
                subjectWorldRay = nil
                guideFromSubject = nil
                kalmanFilter = nil
                pendingPin = (screenPoint, timestamp, pinCalibration ?? calibration)
            }
            // The yellow reticle represents the physical subject. The
            // composition guide may have a different bearing.
            displayWorldRay = subjectWorldRay ?? worldRay
            lastDisplayTime = -.infinity
            presentationIsRecovering = false
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
        let ray = pose.act(k.deviceRay(at: point))
        worldRay = ray
        displayWorldRay = ray
        kalmanFilter = SpatialTangentKalmanFilter(initialBearing: ray, timestamp: time)
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
                publish(); return
            }
            let observed = pose.act(frame.calibration.deviceRay(at: point))
            if let ray = subjectWorldRay ?? worldRay {
                let filter = kalmanFilter ?? {
                    let kf = SpatialTangentKalmanFilter(initialBearing: ray, timestamp: frame.timestamp)
                    kalmanFilter = kf
                    return kf
                }()
                filter.predict(to: frame.timestamp, isDynamicScene: street || scene.isDeformableNature)
                let predictedRay = filter.bearing
                let predicted = frame.calibration.project(deviceRay: pose.inverse.act(predictedRay))
                let residual = hypot(point.x - predicted.point.x, point.y - predicted.point.y)
                // Only a separately confirmed re-ID may move the bearing beyond
                // the ordinary continuation gate after parallax or a long absence.
                guard let (mahalanobisSq, innovation, sInv) = filter.evaluateInnovation(
                    observedRay: observed,
                    confidence: value,
                    focalScale: max(frame.calibration.fx, frame.calibration.fy)
                ) else { publish(); return }
                let gateLimit = (street || scene.isDeformableNature) ? 25.0 : 16.0
                guard TrackingObservationGate.accepts(
                    isInFront: predicted.isInFront,
                    residual: residual,
                    mahalanobisSq: mahalanobisSq,
                    gateThreshold: gateLimit,
                    evidence: evidence
                ) else { publish(); return }
                let corrected: SIMD3<Double>
                if evidence == .reidentified {
                    corrected = observed
                    filter.reidentify(observedRay: observed, timestamp: frame.timestamp)
                } else if evidence == .confirmedContinuation && residual > 0.20 {
                    corrected = observed
                    filter.reidentify(observedRay: observed, timestamp: frame.timestamp)
                } else {
                    filter.update(innovation: innovation, sInv: sInv)
                    let blended = filter.bearing
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
                if evidence == .reidentified || (evidence == .confirmedContinuation && residual > 0.20) {
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
                kalmanFilter = SpatialTangentKalmanFilter(initialBearing: observed, timestamp: frame.timestamp)
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
        var presentationBearing: SIMD3<Double>?
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
                presentationBearing = rendered
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
        pendingOutput = (estimated, outputConfidence, quality, generation, presentationBearing, now)
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let output = self.pendingOutput
            self.pendingOutput = nil; self.deliveryScheduled = false
            let callback = self.callback
            let valid = self.active && output?.3 == self.generation
            if valid, let output {
                self.deliveredPresentationBearing = output.4.map { ($0, output.5, output.3) }
            }
            self.lock.unlock()
            if valid, let output { callback?(output.0, output.1, output.2) }
        }
    }

    public func stopTracking() {
        lock.withLock {
            generation &+= 1; active = false; worldRay = nil; subjectWorldRay = nil
            guideFromSubject = nil
            displayWorldRay = nil; lastDisplayTime = -.infinity
            presentationIsRecovering = false
            kalmanFilter = nil
            pendingPin = nil; pendingOutput = nil
            deliveredPresentationBearing = nil
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
