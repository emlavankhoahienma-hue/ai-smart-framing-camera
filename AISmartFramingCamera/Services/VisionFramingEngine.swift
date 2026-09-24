import Foundation
import Vision
import CoreMedia
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
import QuartzCore

/// A synthetic observation is used exactly once, to create this object. Every
/// continuation must preserve the observation returned by Apple's tracker.
/// A caller-defined replacement starts a NEW tracker (VNTrackingRequest contract).
final class VisionObjectSequence {
    private let sequence = VNSequenceRequestHandler()
    private let request: VNTrackObjectRequest
    private var lastBuffer: CVPixelBuffer?
    private(set) var lastObservation: VNDetectedObjectObservation?

    init(box: CGRect) {
        request = VNTrackObjectRequest(detectedObjectObservation:
            VNDetectedObjectObservation(boundingBox: box))
        request.trackingLevel = .accurate
    }

    func advance(in buffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation) throws -> VNDetectedObjectObservation? {
        // The selected image can also be the next admitted image. Do not tell
        // Vision that the exact same retained camera frame is a new time step.
        if let lastBuffer, lastBuffer === buffer { return lastObservation }
        try sequence.perform([request], on: buffer, orientation: orientation)
        let observation = request.results?.first as? VNDetectedObjectObservation
        if let observation {
            request.inputObservation = observation
        }
        lastObservation = observation
        lastBuffer = buffer
        return observation
    }
}

/// Hysteresis for transient blur/appearance failure. Re-ID is allowed only
/// after retiring the active sequence; never in parallel with a live tracker.
struct VisionContinuityPolicy {
    private(set) var consecutiveFailures = 0
    mutating func accept() { consecutiveFailures = 0 }
    mutating func reject() -> Bool {
        consecutiveFailures += 1
        // A short pan or exposure transition can spoil several consecutive
        // camera frames. Withhold those measurements, but keep Vision's
        // sequence long enough to resume the same object without a re-ID scan.
        return consecutiveFailures >= 6
    }
}

enum TrackingOpticalEvidence: Equatable {
    case verifiedContinuation
    case geometryContinuation
    case confirmedContinuation
    case reidentified
}

struct TrackingOpticalMeasurement {
    let point: CGPoint
    let confidence: Double
    let pixelBuffer: CVPixelBuffer
    let frame: TrackingFrameContext
    let evidence: TrackingOpticalEvidence
    let subjectBox: CGRect?
}

private enum AppearanceResult {
    case match(Double)
    case mismatch
    case unavailable
}

/// Mutable Vision requests and templates belong exclusively to visionQueue.
/// ingressLock protects settings, callbacks, admission and session generation.
/// No synchronous dispatch to the main queue and at most one admitted frame.
public final class VisionFramingEngine: @unchecked Sendable {
    public static let shared = VisionFramingEngine()
    private let visionQueue = DispatchQueue(label: "com.alignai.vision", qos: .userInitiated,
                                            autoreleaseFrequency: .workItem)
    private let ingressLock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var busy = false
    private var generation: UInt64 = 0
    private var active = false
    private var idle = false
    private var lowTexture = false
    private var scene: DetectedSceneType = .general
    private var captureNext = false
    private var captured: CGImage?
    private var lastAdmission = -Double.infinity
    private var detectionCallback: ((SubjectDetectionResult) -> Void)?
    private var detectionSourceCallback: ((SubjectDetectionResult, CVPixelBuffer, TrackingFrameContext?) -> Void)?
    private var targetCallback: ((CGPoint?, Double, CVPixelBuffer) -> Void)?
    private var timedTargetCallback: ((CGPoint?, Double, CVPixelBuffer, TrackingFrameContext) -> Void)?
    private var measurementCallback: ((TrackingOpticalMeasurement) -> Void)?
    private var focusCallback: ((CGPoint, SmartFocusType) -> Void)?
    private var captureCallback: ((CGImage) -> Void)?
    private var captureSourceCallback: ((CGImage, CVPixelBuffer?, TrackingFrameContext?) -> Void)?
    private var targetDeliveryScheduled = false
    private var pendingTargetDelivery: (CGPoint?, Double, CVPixelBuffer, TrackingFrameContext?, TrackingOpticalEvidence?, CGRect?, UInt64)?
    private var detectionDeliveryScheduled = false
    private var pendingDetectionDelivery: (SubjectDetectionResult, CVPixelBuffer, TrackingFrameContext?, CGPoint, SmartFocusType, UInt64)?

    public var isTrackingTarget: Bool { ingressLock.withLock { active } }
    public var isIdlePreviewMode: Bool {
        get { ingressLock.withLock { idle } }
        set { ingressLock.withLock { idle = newValue } }
    }
    public var isLowTextureAnchor: Bool {
        get { ingressLock.withLock { lowTexture } }
        set { ingressLock.withLock { lowTexture = newValue } }
    }
    public var currentSceneType: DetectedSceneType {
        get { ingressLock.withLock { scene } }
        set { ingressLock.withLock { scene = newValue } }
    }
    public var captureNextFrameForGemini: Bool {
        get { ingressLock.withLock { captureNext } }
        set { ingressLock.withLock { captureNext = newValue } }
    }
    public var capturedGeminiFrame: CGImage? {
        get { ingressLock.withLock { captured } }
        set { ingressLock.withLock { captured = newValue } }
    }
    public var onDetectionCompleted: ((SubjectDetectionResult) -> Void)? {
        get { ingressLock.withLock { detectionCallback } }
        set { ingressLock.withLock { detectionCallback = newValue } }
    }
    var onDetectionWithSource: ((SubjectDetectionResult, CVPixelBuffer, TrackingFrameContext?) -> Void)? {
        get { ingressLock.withLock { detectionSourceCallback } }
        set { ingressLock.withLock { detectionSourceCallback = newValue } }
    }
    public var onTargetTracked: ((CGPoint?, Double, CVPixelBuffer) -> Void)? {
        get { ingressLock.withLock { targetCallback } }
        set { ingressLock.withLock { targetCallback = newValue } }
    }
    /// Preferred public callback. If installed, it replaces the legacy public
    /// callback; the app's internal evidence callback remains independent.
    public var onTargetTrackedWithTimestamp: ((CGPoint?, Double, CVPixelBuffer, TrackingFrameContext) -> Void)? {
        get { ingressLock.withLock { timedTargetCallback } }
        set { ingressLock.withLock { timedTargetCallback = newValue } }
    }
    var onTargetMeasurement: ((TrackingOpticalMeasurement) -> Void)? {
        get { ingressLock.withLock { measurementCallback } }
        set { ingressLock.withLock { measurementCallback = newValue } }
    }
    public var onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)? {
        get { ingressLock.withLock { focusCallback } }
        set { ingressLock.withLock { focusCallback = newValue } }
    }
    public var onFrameCapturedForAI: ((CGImage) -> Void)? {
        get { ingressLock.withLock { captureCallback } }
        set { ingressLock.withLock { captureCallback = newValue } }
    }
    var onFrameCapturedForAIWithSource: ((CGImage, CVPixelBuffer?, TrackingFrameContext?) -> Void)? {
        get { ingressLock.withLock { captureSourceCallback } }
        set { ingressLock.withLock { captureSourceCallback = newValue } }
    }

    // Queue-confined state. Frozen identity is only replaced by an explicit pin.
    private var tracker: VisionObjectSequence?
    private var continuity = VisionContinuityPolicy()
    private let patchFlow = TargetPatchFlow()
    private var referencePrint: VNFeaturePrintObservation?
    private var referenceHistogram: [Float]?
    private var anchorUV = CGPoint(x: 0.5, y: 0.5)
    private var boxSize = CGSize(width: 0.14, height: 0.14)
    private var lastBox: CGRect?
    private var misses = 0
    private var lastAppearanceCheck = -Double.infinity
    private var lastSearch = -Double.infinity
    private var searchCursor = 0
    private var previousTime = -Double.infinity
    private var seedTimestamp = -Double.infinity
    private var hasLiveObservation = false
    private var latestBuffer: CVPixelBuffer?
    private var latestOrientation: CGImagePropertyOrientation = .up
    private var seedBuffer: CVPixelBuffer?
    private var seedOrientation: CGImagePropertyOrientation = .up
    private var seedPoint = CGPoint(x: 0.5, y: 0.5)
    private var seedSize = CGSize(width: 0.14, height: 0.14)
    private var pendingSeed = false
    private var pendingRecovery: (point: CGPoint, frame: TrackingFrameContext)?
    private var pendingLargeInnovation: (offset: CGPoint, timestamp: TimeInterval)?

    public init() {}

    public func refineAnchorBox(around point: CGPoint, in buffer: CVPixelBuffer,
                                orientation: CGImagePropertyOrientation = .up) -> CGRect? {
        let face = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        guard (try? handler.perform([face, saliency])) != nil else { return nil }
        let visionPoint = CGPoint(x: point.x, y: 1 - point.y)
        let boxes = (face.results ?? []).map(\.boundingBox) +
            (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        return boxes.filter { $0.contains(visionPoint) && $0.width > 0.03 && $0.height > 0.03 }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    public func startTrackingObject(at point: CGPoint, size: CGSize = CGSize(width: 0.12, height: 0.12),
                                    refiningBuffer: CVPixelBuffer? = nil,
                                    orientation: CGImagePropertyOrientation = .up,
                                    sourceTimestamp: TimeInterval? = nil) {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y),
              size.width > 0, size.height > 0 else { return }
        let epoch = ingressLock.withLock { () -> UInt64 in
            generation &+= 1; active = true
            pendingTargetDelivery = nil
            pendingDetectionDelivery = nil
            return generation
        }
        visionQueue.async { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            self.resetTrackingState()
            self.seedPoint = point; self.seedSize = size
            self.seedBuffer = refiningBuffer; self.seedOrientation = orientation
            self.pendingSeed = true
            if let refiningBuffer {
                // Build the appearance template immediately so the camera-pool
                // buffer is released even if the next video frame never arrives.
                self.seed(in: refiningBuffer, orientation: orientation,
                          timestamp: sourceTimestamp ?? CACurrentMediaTime())
            }
        }
    }

    public func stopTrackingObject() {
        let epoch = ingressLock.withLock { () -> UInt64 in
            generation &+= 1; active = false
            pendingTargetDelivery = nil
            pendingDetectionDelivery = nil
            return generation
        }
        visionQueue.async { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            self.resetTrackingState()
        }
    }

    private func isCurrent(_ epoch: UInt64) -> Bool { ingressLock.withLock { generation == epoch } }

    private func resetTrackingState() {
        NeuralTargetTracker.shared.clearAnchor()
        tracker = nil; continuity = VisionContinuityPolicy()
        patchFlow.reset()
        referencePrint = nil; referenceHistogram = nil; lastBox = nil
        misses = 0; lastAppearanceCheck = -.infinity
        lastSearch = -.infinity
        searchCursor = 0; previousTime = -.infinity
        seedTimestamp = -.infinity; hasLiveObservation = false
        pendingRecovery = nil; seedBuffer = nil; pendingSeed = false
        pendingLargeInnovation = nil
        latestBuffer = nil
    }

    private func seed(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                      timestamp: TimeInterval) {
        seedTimestamp = timestamp
        let source = seedBuffer ?? buffer
        let sourceOrientation = seedBuffer == nil ? orientation : seedOrientation
        let w = min(0.8, max(0.04, seedSize.width)), h = min(0.8, max(0.04, seedSize.height))
        let centered = CGRect(x: seedPoint.x - w / 2, y: 1 - seedPoint.y - h / 2, width: w, height: h)
        // A user pin must keep its selected image patch. Automatic saliency/face
        // expansion can include a stronger background target in the same ROI.
        let box = centered.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        // Keep the selected physical point's relative location, not the new box center.
        anchorUV = CGPoint(x: (seedPoint.x - box.minX) / box.width,
                           y: ((1 - seedPoint.y) - box.minY) / box.height)
        boxSize = box.size; lastBox = box
        referencePrint = featurePrint(source, box: box, orientation: sourceOrientation)
        if referencePrint != nil {
            lastAppearanceCheck = timestamp
        }
        referenceHistogram = histogram(source, box: box, orientation: sourceOrientation)
        if sourceOrientation == .up {
            NeuralTargetTracker.shared.setAnchorTemplate(from: source, at: seedPoint)
            patchFlow.seed(buffer: source, box: box, point: seedPoint)
        }
        let newTracker = VisionObjectSequence(box: box)
        if seedBuffer != nil {
            // Establish the template on the actual selected image, not on a later
            // frame captured after the user's hand has moved.
            _ = try? newTracker.advance(in: source, orientation: sourceOrientation)
        }
        tracker = newTracker; seedBuffer = nil; pendingSeed = false
    }

    public func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                         orientation: CGImagePropertyOrientation = .up) {
        let frame = orientation == .up ? TrackingFrameContext.read(sampleBuffer,
            zoom: SpatialTrackingEngine.shared.currentDisplayZoom) : nil
        processVideoSampleBuffer(sampleBuffer, orientation: orientation, frameContext: frame)
    }

    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                  orientation: CGImagePropertyOrientation,
                                  frameContext: TrackingFrameContext?) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let spatial = SpatialTrackingEngine.shared
        let matchesSize = frameContext.map {
            $0.imageSize == .zero ||
            (Int($0.imageSize.width) == CVPixelBufferGetWidth(buffer) &&
             Int($0.imageSize.height) == CVPixelBufferGetHeight(buffer))
        } ?? false
        let frame = orientation == .up && frameContext?.orientation == .up && matchesSize ? frameContext : nil
        if let frame { spatial.registerFrame(frame) }
        let now = CACurrentMediaTime()
        let admission = ingressLock.withLock { () -> (UInt64, Bool, Bool)? in
            // Full scene analysis runs once on the detached AI capture. Preview
            // needs only a lightweight face pass; tracking retains its own FPS.
            guard !busy, now - lastAdmission >= (active ? 1 / 32.0 : 0.2) else { return nil }
            busy = true; lastAdmission = now
            let capture = captureNext; captureNext = false
            return (generation, active, capture)
        }
        guard let (epoch, tracking, capture) = admission else { return }
        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.ingressLock.withLock { self.busy = false } }
            self.latestBuffer = buffer; self.latestOrientation = orientation
            self.deliverCaptures(buffer, orientation: orientation, frame: frame,
                                 requested: capture, epoch: epoch)
            guard self.isCurrent(epoch) else { return }
            if tracking {
                guard let frame else { self.deliver(nil, confidence: 0, buffer: buffer, frame: nil,
                                                    evidence: nil, epoch: epoch); return }
                if self.pendingSeed { self.seed(in: buffer, orientation: orientation,
                                                timestamp: frame.timestamp) }
                let result = self.track(buffer, orientation: orientation, frame: frame)
                self.deliver(result?.0, confidence: result?.1 ?? 0, buffer: buffer, frame: frame,
                             evidence: result?.2, epoch: epoch)
            } else {
                self.detect(buffer, orientation: orientation, frame: frame, epoch: epoch)
            }
        }
    }

    private func point(in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + anchorUV.x * box.width, y: 1 - (box.minY + anchorUV.y * box.height))
    }

    private func box(at point: CGPoint, size: CGSize) -> CGRect? {
        let b = CGRect(x: point.x - anchorUV.x * size.width,
                       y: 1 - point.y - anchorUV.y * size.height, width: size.width, height: size.height)
        // Never slide/clamp a candidate onto the image edge: that changes identity.
        guard b.minX >= 0, b.minY >= 0, b.maxX <= 1, b.maxY <= 1 else { return nil }
        return b
    }

    private func shouldRetireSequence(afterFailureAt timestamp: TimeInterval) -> Bool {
        let ordinaryRetirement = continuity.reject()
        // The image used for an AI decision may be seconds old. If its VN
        // sequence never obtains a single live observation, move promptly to
        // appearance-verified recovery around the current world projection.
        let staleSource = !hasLiveObservation && seedTimestamp.isFinite &&
            timestamp - seedTimestamp > 0.8
        return ordinaryRetirement || (staleSource && continuity.consecutiveFailures >= 2)
    }

    private func track(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                       frame: TrackingFrameContext) -> (CGPoint, Double, TrackingOpticalEvidence)? {
        let prediction = SpatialTrackingEngine.shared.projection(at: frame.timestamp, calibration: frame.calibration)
        // A stale bearing cannot retire a live optical sequence. After a longer
        // miss, permit the bounded image sweep even if the bearing is offscreen.
        if tracker == nil, let prediction,
           (!prediction.isInFront ||
            !CGRect(x: -0.15, y: -0.15, width: 1.3, height: 1.3).contains(prediction.point)),
           misses < 20 {
            tracker = nil; continuity = VisionContinuityPolicy()
            patchFlow.reset()
            misses += 1; pendingRecovery = nil; pendingLargeInnovation = nil
            return nil
        }
        let dt = previousTime.isFinite ? min(0.1, max(0.001, frame.timestamp - previousTime)) : 1 / 30.0
        previousTime = frame.timestamp
        if let tracker {
            do {
                if let observation = try tracker.advance(in: buffer, orientation: orientation),
                   observation.confidence >= 0.40 {
                    let rawBox = observation.boundingBox
                    guard rawBox.minX.isFinite, rawBox.minY.isFinite,
                          rawBox.width.isFinite, rawBox.height.isFinite,
                          rawBox.width > 0.01, rawBox.height > 0.01,
                          rawBox.minX >= 0, rawBox.minY >= 0,
                          rawBox.maxX <= 1, rawBox.maxY <= 1 else {
                        misses += 1; pendingRecovery = nil; pendingLargeInnovation = nil
                        if shouldRetireSequence(afterFailureAt: frame.timestamp) {
                            self.tracker = nil; patchFlow.reset()
                        }
                        return nil
                    }
                    let rawPoint = point(in: rawBox)
                    let flow = orientation == .up ? patchFlow.evaluate(buffer: buffer, box: rawBox,
                                                                       fallback: rawPoint) : nil
                    let measuredPoint = (flow?.isReliable == true ? flow?.point : nil) ?? rawPoint
                    let residual = prediction.map { hypot($0.point.x - measuredPoint.x,
                                                           $0.point.y - measuredPoint.y) } ?? 0
                    // Run the expensive fingerprint only when continuity looks
                    // doubtful. A healthy Vision sequence should not hitch the
                    // viewfinder with a recurring neural request.
                    let needsIdentity = referencePrint != nil &&
                        (misses > 0 || (residual > 0.24 && flow?.isReliable != true)) &&
                        frame.timestamp - lastAppearanceCheck >= 0.35
                    let appearance: AppearanceResult
                    if needsIdentity {
                        lastAppearanceCheck = frame.timestamp
                        appearance = verify(buffer, box: rawBox,
                                            orientation: orientation, strict: false)
                    } else {
                        appearance = .unavailable
                    }
                    var evidence: TrackingOpticalEvidence
                    let ordinaryLimit = max(0.30, SpatialTrackingEngine.shared.maxObservationJump * 2)
                    switch appearance {
                    case .match: evidence = .verifiedContinuation
                    case .unavailable:
                        // Follow the live VN sequence with patch-flow support;
                        // a very confident nearby VN point can bridge weak texture.
                        let supported = (flow?.isReliable == true && observation.confidence >= 0.55) ||
                            (observation.confidence >= 0.70 && residual <= ordinaryLimit)
                        guard supported else {
                            misses += 1; pendingRecovery = nil; pendingLargeInnovation = nil
                            if shouldRetireSequence(afterFailureAt: frame.timestamp) {
                                self.tracker = nil; patchFlow.reset()
                            }
                            return nil
                        }
                        evidence = .geometryContinuation
                    case .mismatch:
                        // Lighting can change the frozen appearance template.
                        // Keep a nearby, independently consistent flow track.
                        guard flow?.isReliable == true, (flow?.inliers ?? 0) >= 7,
                              observation.confidence >= 0.65,
                              residual <= max(0.22,
                                  SpatialTrackingEngine.shared.maxObservationJump * 1.5) else {
                            misses += 1; pendingRecovery = nil; pendingLargeInnovation = nil
                            if shouldRetireSequence(afterFailureAt: frame.timestamp) {
                                self.tracker = nil; patchFlow.reset()
                            }
                            return nil
                        }
                        evidence = .geometryContinuation
                    }
                    if rawBox.width > 0.01, rawBox.height > 0.01,
                       rawBox.minX >= 0, rawBox.minY >= 0, rawBox.maxX <= 1, rawBox.maxY <= 1 {
                        let isLarge = prediction.map { !$0.isInFront || residual > ordinaryLimit } ?? false
                        if isLarge {
                            // Two consecutive, flow-supported offsets let a live
                            // tracker correct a badly drifted bearing without
                            // treating one background jump as a new anchor.
                            guard let flow, flow.isReliable, flow.inliers >= 7,
                                  observation.confidence >= 0.70, let prediction else {
                                pendingLargeInnovation = nil
                                misses += 1; pendingRecovery = nil
                                if shouldRetireSequence(afterFailureAt: frame.timestamp) {
                                    self.tracker = nil; patchFlow.reset()
                                }
                                return nil
                            }
                            let offset = CGPoint(x: measuredPoint.x - prediction.point.x,
                                                 y: measuredPoint.y - prediction.point.y)
                            let consistent = pendingLargeInnovation.map {
                                frame.timestamp > $0.timestamp &&
                                frame.timestamp - $0.timestamp < 0.25 &&
                                hypot(offset.x - $0.offset.x, offset.y - $0.offset.y) < 0.08
                            } ?? false
                            if consistent {
                                evidence = .confirmedContinuation
                                pendingLargeInnovation = nil
                            } else {
                                pendingLargeInnovation = (offset, frame.timestamp)
                                lastBox = rawBox
                                patchFlow.accept(flow, box: rawBox, point: measuredPoint)
                                continuity.accept()
                                misses = 0
                                return nil
                            }
                        } else {
                            pendingLargeInnovation = nil
                        }
                        // A bounded log-size step suppresses scale breathing. The
                        // actual tracked point stays fixed while the ROI resizes.
                        let gain = 1 - exp(-2 * Double.pi * 1.5 * dt)
                        func smooth(_ old: CGFloat, _ new: CGFloat) -> CGFloat {
                            let delta = min(0.12, max(-0.12, log(Double(new / old))))
                            return old * CGFloat(exp(gain * delta))
                        }
                        boxSize = CGSize(width: smooth(boxSize.width, rawBox.width),
                                         height: smooth(boxSize.height, rawBox.height))
                        // Smoothed size belongs to the recovery search only.
                        // NEVER feed a synthesized box back to the live sequence.
                        lastBox = rawBox
                        // Rebase the box fallback to the point actually followed by
                        // texture. Otherwise a flow dropout jumps to the old box UV.
                        let selectedUV = CGPoint(x: (measuredPoint.x - rawBox.minX) / rawBox.width,
                            y: (1 - measuredPoint.y - rawBox.minY) / rawBox.height)
                        if flow?.isReliable == true,
                           (0...1).contains(selectedUV.x), (0...1).contains(selectedUV.y) {
                            anchorUV = selectedUV
                        }
                        if let flow { patchFlow.accept(flow, box: rawBox, point: measuredPoint) }
                        else { patchFlow.seed(buffer: buffer, box: rawBox, point: measuredPoint) }
                        continuity.accept()
                        misses = 0; pendingRecovery = nil
                        hasLiveObservation = true
                        return (measuredPoint, Double(observation.confidence), evidence)
                    }
                }
            } catch { /* An invalid observation never updates the spatial anchor. */ }
            misses += 1
            pendingRecovery = nil; pendingLargeInnovation = nil
            // Withhold the optical correction on a suspect frame, but retain
            // Vision's identity through a short burst of blur instead of reseeding.
            guard shouldRetireSequence(afterFailureAt: frame.timestamp) else { return nil }
            self.tracker = nil
            patchFlow.reset()
        } else {
            misses += 1
        }
        // Search near the bearing first, then sweep the visible image after a
        // longer miss. Two distinct captured frames must agree.
        guard frame.timestamp - lastSearch >= 0.30,
              referencePrint != nil else { return nil }
        lastSearch = frame.timestamp
        let center = prediction?.point ?? lastBox.map({ point(in: $0) }) ?? seedPoint
        var searchCenter = center
        if let previous = pendingRecovery,
           let oldProjection = SpatialTrackingEngine.shared.projection(
               at: previous.frame.timestamp, calibration: previous.frame.calibration) {
            searchCenter = CGPoint(x: center.x + previous.point.x - oldProjection.point.x,
                                   y: center.y + previous.point.y - oldProjection.point.y)
        }
        if let recovered = search(buffer, center: searchCenter, orientation: orientation) {
            if let previous = pendingRecovery, frame.timestamp > previous.frame.timestamp,
               frame.timestamp - previous.frame.timestamp < 0.5 {
                // Each candidate uses its own capture calibration. Reusing the
                // current zoom for an older frame can reject a real match.
                let previousPrediction = SpatialTrackingEngine.shared.projection(
                    at: previous.frame.timestamp, calibration: previous.frame.calibration)
                let oldError = CGPoint(x: previous.point.x - (previousPrediction?.point.x ?? center.x),
                                       y: previous.point.y - (previousPrediction?.point.y ?? center.y))
                let newError = CGPoint(x: recovered.0.x - center.x, y: recovered.0.y - center.y)
                if hypot(newError.x - oldError.x, newError.y - oldError.y) < 0.025 {
                    let recoveredTracker = VisionObjectSequence(box: recovered.2)
                    // A failed Vision seed is not a successful reacquisition.
                    guard let observation = try? recoveredTracker.advance(in: buffer, orientation: orientation),
                          observation.confidence >= 0.40 else { pendingRecovery = nil; return nil }
                    let confirmedPoint = point(in: observation.boundingBox)
                    guard hypot(confirmedPoint.x - recovered.0.x, confirmedPoint.y - recovered.0.y) < 0.025 else {
                        pendingRecovery = nil; return nil
                    }
                    tracker = recoveredTracker
                    lastBox = observation.boundingBox; boxSize = recovered.2.size
                    patchFlow.seed(buffer: buffer, box: observation.boundingBox, point: confirmedPoint)
                    continuity.accept()
                    misses = 0; lastAppearanceCheck = frame.timestamp
                    hasLiveObservation = true
                    pendingRecovery = nil; pendingLargeInnovation = nil
                    return (confirmedPoint, min(recovered.1, Double(observation.confidence)), .reidentified)
                }
            }
            pendingRecovery = (recovered.0, frame)
        } else { pendingRecovery = nil }
        return nil
    }

    private func crop(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let bounds = image.extent
        let roi = CGRect(x: bounds.minX + box.minX * bounds.width,
                         y: bounds.minY + box.minY * bounds.height,
                         width: box.width * bounds.width, height: box.height * bounds.height).intersection(bounds)
        guard !roi.isNull, roi.width >= 8, roi.height >= 8 else { return nil }
        return context.createCGImage(image, from: roi)
    }

    private func featurePrint(_ buffer: CVPixelBuffer, box: CGRect,
                              orientation: CGImagePropertyOrientation) -> VNFeaturePrintObservation? {
        guard let image = crop(buffer, box: box, orientation: orientation) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        if #available(iOS 17.0, *) {
            req.revision = VNGenerateImageFeaturePrintRequestRevision2
        } else {
            req.revision = VNGenerateImageFeaturePrintRequestRevision1
        }
        req.imageCropAndScaleOption = .scaleFit
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])) != nil else { return nil }
        return req.results?.first as? VNFeaturePrintObservation
    }

    private func histogram(_ buffer: CVPixelBuffer, box: CGRect,
                           orientation: CGImagePropertyOrientation) -> [Float]? {
        if orientation == .up, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, height > 0 else { return nil }
            var bins = [Float](repeating: 0, count: 64)
            var count: Float = 0
            for y in 0..<24 {
                let imageY = min(height - 1, max(0, Int((Double(1 - box.maxY) +
                    (Double(y) + 0.5) * Double(box.height) / 24) * Double(height))))
                for x in 0..<24 {
                    let imageX = min(width - 1, max(0, Int((Double(box.minX) +
                        (Double(x) + 0.5) * Double(box.width) / 24) * Double(width))))
                    let offset = imageY * rowBytes + imageX * 4
                    let b = Float(bytes[offset]), g = Float(bytes[offset + 1])
                    let r = Float(bytes[offset + 2]), total = r + g + b
                    guard total > 24 else { continue }
                    bins[min(7, Int(8 * r / total)) * 8 + min(7, Int(8 * g / total))] += 1
                    count += 1
                }
            }
            return count > 0 ? bins.map { $0 / count } : nil
        }
        guard let image = crop(buffer, box: box, orientation: orientation) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 24 * 24 * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 24, height: 24,
                                      bitsPerComponent: 8, bytesPerRow: 96,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24)); return true
        }
        guard drawn else { return nil }
        var bins = [Float](repeating: 0, count: 64)
        var count: Float = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let r = Float(rgba[i]), g = Float(rgba[i + 1]), b = Float(rgba[i + 2])
            let total = r + g + b
            guard total > 24 else { continue }
            bins[min(7, Int(8 * r / total)) * 8 + min(7, Int(8 * g / total))] += 1
            count += 1
        }
        guard count > 0 else { return nil }
        return bins.map { $0 / count }
    }

    private func verify(_ buffer: CVPixelBuffer, box: CGRect, orientation: CGImagePropertyOrientation,
                        strict: Bool) -> AppearanceResult {
        guard let referencePrint, let current = featurePrint(buffer, box: box, orientation: orientation)
            else { return .unavailable }
        var distance: Float = 0
        guard (try? referencePrint.computeDistance(&distance, to: current)) != nil, distance.isFinite
            else { return .unavailable }
        let config = ingressLock.withLock { (lowTexture, scene.isDeformableNature) }
        // Starting thresholds for revision 2, not probabilities or trained claims.
        let maximum: Float = strict ? (config.0 ? 0.32 : 0.42) : (config.1 ? 0.65 : 0.60)
        guard distance <= maximum else { return .mismatch }
        if strict, orientation == .up, NeuralTargetTracker.shared.hasActiveTrainedModel {
            let p = point(in: box)
            // The optional CNN uses a fixed 0.16 image crop; at the image edge,
            // only the box-based feature print remains available.
            if (0.08...0.92).contains(p.x), (0.08...0.92).contains(p.y),
               NeuralTargetTracker.shared.verifyTarget(in: buffer, at: p) < 0.75 { return .mismatch }
        }
        if let referenceHistogram, let currentHistogram = histogram(buffer, box: box, orientation: orientation) {
            let similarity = zip(referenceHistogram, currentHistogram).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }
            guard similarity >= (strict ? 0.72 : 0.45) else { return .mismatch }
        }
        return .match(Double(distance))
    }

    private func search(_ buffer: CVPixelBuffer, center: CGPoint,
                        orientation: CGImagePropertyOrientation) -> (CGPoint, Double, CGRect)? {
        let step = max(0.02, min(0.06, min(boxSize.width, boxSize.height) * 0.3))
        var candidates: [(CGPoint, Double, CGRect)] = []
        let neighbors = [CGPoint(x: center.x - step, y: center.y),
                         CGPoint(x: center.x + step, y: center.y),
                         CGPoint(x: center.x, y: center.y - step),
                         CGPoint(x: center.x, y: center.y + step),
                         CGPoint(x: center.x - step, y: center.y - step),
                         CGPoint(x: center.x + step, y: center.y + step),
                         CGPoint(x: center.x - step, y: center.y + step),
                         CGPoint(x: center.x + step, y: center.y - step)]
        var proposals = [center]
        for offset in 0..<neighbors.count {
            proposals.append(neighbors[(searchCursor + offset) % neighbors.count])
        }
        searchCursor = (searchCursor + 2) % 25
        if misses >= 6 {
            let radius: CGFloat = misses < 20 ? 0.12 : 0.26
            for index in 0..<8 {
                let angle = Double((index + searchCursor) % 8) * Double.pi / 4
                proposals.append(CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                                         y: center.y + radius * CGFloat(sin(angle))))
            }
        }
        if misses >= 20 {
            // Sweep a 5x5 image grid over successive searches. The fixed
            // budget avoids blocking 30 Hz tracking with a full-frame scan.
            for index in 0..<8 {
                let cell = (searchCursor + index) % 25
                proposals.append(CGPoint(x: (CGFloat(cell % 5) + 0.5) / 5,
                                         y: (CGFloat(cell / 5) + 0.5) / 5))
            }
            searchCursor = (searchCursor + 8) % 25
        }
        // Spread the neural checks over time so recovery cannot monopolize the
        // same queue that feeds the live camera preview.
        var checksByRegion = [0, 0, 0]
        let budgets = misses >= 20 ? [1, 0, 1] : (misses >= 6 ? [1, 1, 0] : [2, 0, 0])
        for (index, p) in proposals.prefix(25).enumerated() {
            let region = index < 9 ? 0 : (index < 17 ? 1 : 2)
            guard checksByRegion[region] < budgets[region] else { continue }
            let scale: CGFloat = index >= 17 ? [0.75, 1.0, 1.35][(searchCursor + index) % 3] : 1
            let candidateSize = CGSize(width: boxSize.width * scale, height: boxSize.height * scale)
            guard let roi = box(at: p, size: candidateSize) else { continue }
            // Cheap color evidence runs before the heavier FeaturePrint.
            if let referenceHistogram, let current = histogram(buffer, box: roi, orientation: orientation) {
                let similarity = zip(referenceHistogram, current).reduce(Float(0)) {
                    $0 + sqrt($1.0 * $1.1)
                }
                guard similarity >= 0.62 else { continue }
            }
            checksByRegion[region] += 1
            if case let .match(distance) = verify(buffer, box: roi, orientation: orientation, strict: true) {
                candidates.append((p, distance, roi))
            }
        }
        candidates.sort { $0.1 < $1.1 }
        guard let best = candidates.first else { return nil }
        // Nearby overlapping crops are one hypothesis. Only compare distinct ROIs.
        if let rival = candidates.dropFirst().first(where: {
            hypot($0.0.x - best.0.x, $0.0.y - best.0.y) > step * 1.5
        }), rival.1 - best.1 < 0.04 { return nil }
        return (best.0, 0.80, best.2)
    }

    private func deliver(_ point: CGPoint?, confidence: Double, buffer: CVPixelBuffer,
                         frame: TrackingFrameContext?, evidence: TrackingOpticalEvidence?, epoch: UInt64) {
        let schedule = ingressLock.withLock { () -> Bool in
            guard generation == epoch else { return false }
            // The large, verified bearing correction must reach Spatial before
            // a newer ordinary frame can replace it in the Main coalescer.
            if pendingTargetDelivery?.4 == .reidentified && evidence != .reidentified { return false }
            if pendingTargetDelivery?.4 == .confirmedContinuation &&
                evidence != .confirmedContinuation && evidence != .reidentified { return false }
            let box = lastBox.map {
                CGRect(x: $0.minX, y: 1 - $0.maxY,
                       width: $0.width, height: $0.height)
            }
            pendingTargetDelivery = (point, confidence, buffer, frame, evidence, box, epoch)
            guard !targetDeliveryScheduled else { return false }
            targetDeliveryScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delivery = self.ingressLock.withLock { () -> (CGPoint?, Double, CVPixelBuffer,
                TrackingFrameContext?, TrackingOpticalEvidence?, CGRect?, UInt64)? in
                let delivery = self.pendingTargetDelivery
                self.pendingTargetDelivery = nil; self.targetDeliveryScheduled = false
                return delivery
            }
            guard let (point, confidence, buffer, frame, evidence, box, epoch) = delivery,
                  self.isCurrent(epoch) else { return }
            if let measured = self.onTargetMeasurement {
                if let point, let frame, let evidence {
                    measured(TrackingOpticalMeasurement(point: point, confidence: confidence,
                        pixelBuffer: buffer, frame: frame, evidence: evidence,
                        subjectBox: box))
                }
            }
            if let timed = self.onTargetTrackedWithTimestamp {
                if let frame { timed(point, confidence, buffer, frame) }
            } else { self.onTargetTracked?(point, confidence, buffer) }
        }
    }

    private func detect(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                        frame: TrackingFrameContext?, epoch: UInt64) {
        var result = SubjectDetectionResult()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        if (try? handler.perform([faceRequest])) != nil {
            result.faceRectangles = (faceRequest.results ?? []).filter { $0.confidence >= 0.45 }.map {
                CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY,
                       width: $0.boundingBox.width, height: $0.boundingBox.height)
            }
            result.dominantSubjectRect = result.faceRectangles.first
            result.confidence = faceRequest.results?.first?.confidence ?? 0
        }
        let focus: CGPoint
        let type: SmartFocusType
        if let face = result.faceRectangles.first {
            focus = CGPoint(x: face.midX, y: face.midY); type = .face
        } else { focus = CGPoint(x: 0.5, y: 0.5); type = .center }
        let luma = luminance(buffer)
        result.averageLuminance = luma.0; result.estimatedColorTemp = luma.1
        // Keep only the newest undelivered detection. A blocked main queue
        // must never accumulate camera-pool buffers at the analysis frame rate.
        let schedule = ingressLock.withLock { () -> Bool in
            guard generation == epoch else { return false }
            pendingDetectionDelivery = (result, buffer, frame, focus, type, epoch)
            guard !detectionDeliveryScheduled else { return false }
            detectionDeliveryScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delivery = self.ingressLock.withLock { () ->
                (SubjectDetectionResult, CVPixelBuffer, TrackingFrameContext?, CGPoint, SmartFocusType, UInt64)? in
                let delivery = self.pendingDetectionDelivery
                self.pendingDetectionDelivery = nil
                self.detectionDeliveryScheduled = false
                return delivery
            }
            guard let (result, buffer, frame, focus, type, epoch) = delivery,
                  self.isCurrent(epoch) else { return }
            self.onDetectionWithSource?(result, buffer, frame)
            self.onDetectionCompleted?(result)
            self.onSmartFocusPointCalculated?(focus, type)
        }
    }

    private func luminance(_ buffer: CVPixelBuffer) -> (Float, Float) {
        let image = CIImage(cvPixelBuffer: buffer)
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            context.render(avg, toBitmap: baseAddress, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let r = Float(rgba[0]) / 255, g = Float(rgba[1]) / 255, b = Float(rgba[2]) / 255
        return (0.2126 * r + 0.7152 * g + 0.0722 * b, max(2700, min(9000, 3500 + b / max(r, 0.01) * 3000)))
    }

    private func deliverCaptures(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                 frame: TrackingFrameContext?, requested: Bool, epoch: UInt64? = nil) {
        guard requested else { return }
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let cg = context.createCGImage(image, from: image.extent)
        // Gemini may take seconds. Never hand its callback an AVCapture pool buffer.
        let needsSource = ingressLock.withLock { captureSourceCallback != nil }
        let detachedBuffer = needsSource ? detachedTrackingBuffer(from: buffer) : nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let cg, requested else { return }
            if let epoch, !self.isCurrent(epoch) { return }
            self.capturedGeminiFrame = cg
            let callbacks = self.ingressLock.withLock {
                let callbacks = (self.captureCallback, self.captureSourceCallback)
                self.captureCallback = nil; self.captureSourceCallback = nil
                return callbacks
            }
            callbacks.1?(cg, detachedBuffer, frame)
            callbacks.0?(cg)
        }
    }

    private func detachedTrackingBuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess,
              let output else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let outputBase = CVPixelBufferGetBaseAddress(output) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let bytesPerRow = width * 4
        guard sourceStride >= bytesPerRow, outputStride >= bytesPerRow else { return nil }
        for row in 0..<height {
            memcpy(outputBase.advanced(by: row * outputStride),
                   sourceBase.advanced(by: row * sourceStride), bytesPerRow)
        }
        return output
    }

    public func captureImmediateFrame(completion: @escaping (CGImage?) -> Void) {
        visionQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            if let buffer = self.latestBuffer {
                let image = CIImage(cvPixelBuffer: buffer).oriented(self.latestOrientation)
                let cg = self.context.createCGImage(image, from: image.extent)
                DispatchQueue.main.async { completion(cg) }
            } else {
                // No image available: report failure rather than retaining an
                // unbounded callback until an unknown future camera session.
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
