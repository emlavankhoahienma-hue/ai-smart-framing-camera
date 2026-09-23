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
        return consecutiveFailures >= 8
    }
}

enum TrackingOpticalEvidence: Equatable {
    case verifiedContinuation
    case geometryContinuation
    case reidentified
}

struct TrackingOpticalMeasurement {
    let point: CGPoint
    let confidence: Double
    let pixelBuffer: CVPixelBuffer
    let frame: TrackingFrameContext
    let evidence: TrackingOpticalEvidence
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
    private var targetCallback: ((CGPoint?, Double, CVPixelBuffer) -> Void)?
    private var timedTargetCallback: ((CGPoint?, Double, CVPixelBuffer, TrackingFrameContext) -> Void)?
    private var measurementCallback: ((TrackingOpticalMeasurement) -> Void)?
    private var focusCallback: ((CGPoint, SmartFocusType) -> Void)?
    private var captureCallback: ((CGImage) -> Void)?
    private var targetDeliveryScheduled = false
    private var pendingTargetDelivery: (CGPoint?, Double, CVPixelBuffer, TrackingFrameContext?, TrackingOpticalEvidence?, UInt64)?

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
    private var lastVerified = -Double.infinity
    private var lastSearch = -Double.infinity
    private var searchCursor = 0
    private var previousTime = -Double.infinity
    private var latestBuffer: CVPixelBuffer?
    private var latestOrientation: CGImagePropertyOrientation = .up
    private var seedBuffer: CVPixelBuffer?
    private var seedOrientation: CGImagePropertyOrientation = .up
    private var seedPoint = CGPoint(x: 0.5, y: 0.5)
    private var seedSize = CGSize(width: 0.14, height: 0.14)
    private var seedSubjectRect: CGRect?
    private var pendingSeed = false
    private var pendingRecovery: (point: CGPoint, frame: TrackingFrameContext)?

    public init() {}

    /// Preserve the frozen target fingerprint while discarding a tracker whose
    /// image sequence belongs to the previous physical camera.
    func prepareForLensSwitch() {
        let epoch = ingressLock.withLock { () -> UInt64 in
            generation &+= 1
            pendingTargetDelivery = nil
            return generation
        }
        visionQueue.async { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            self.tracker = nil
            self.patchFlow.reset()
            self.continuity = VisionContinuityPolicy()
            self.pendingRecovery = nil
            self.misses = max(self.misses, 20)
            self.lastSearch = -.infinity
        }
    }

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
                                    orientation: CGImagePropertyOrientation = .up) {
        beginTracking(at: point, size: size, subjectRect: nil,
                      refiningBuffer: refiningBuffer, orientation: orientation)
    }

    func startTrackingObject(at point: CGPoint, subjectRect: CGRect,
                             refiningBuffer: CVPixelBuffer? = nil,
                             orientation: CGImagePropertyOrientation = .up) {
        guard subjectRect.width > 0, subjectRect.height > 0,
              subjectRect.contains(point) else { return }
        beginTracking(at: point, size: subjectRect.size, subjectRect: subjectRect,
                      refiningBuffer: refiningBuffer, orientation: orientation)
    }

    private func beginTracking(at point: CGPoint, size: CGSize, subjectRect: CGRect?,
                               refiningBuffer: CVPixelBuffer?, orientation: CGImagePropertyOrientation) {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y),
              size.width > 0, size.height > 0 else { return }
        let epoch = ingressLock.withLock { () -> UInt64 in
            generation &+= 1; active = true
            pendingTargetDelivery = nil
            return generation
        }
        visionQueue.async { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            self.resetTrackingState()
            self.seedPoint = point; self.seedSize = size
            self.seedSubjectRect = subjectRect
            self.seedBuffer = refiningBuffer; self.seedOrientation = orientation
            self.pendingSeed = true
        }
    }

    public func stopTrackingObject() {
        let epoch = ingressLock.withLock { () -> UInt64 in
            generation &+= 1; active = false
            pendingTargetDelivery = nil
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
        misses = 0; lastVerified = -.infinity; lastSearch = -.infinity
        searchCursor = 0; previousTime = -.infinity
        pendingRecovery = nil; seedBuffer = nil; seedSubjectRect = nil; pendingSeed = false
    }

    private func seed(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let source = seedBuffer ?? buffer
        let sourceOrientation = seedBuffer == nil ? orientation : seedOrientation
        let w = min(0.8, max(0.04, seedSize.width)), h = min(0.8, max(0.04, seedSize.height))
        let centered = seedSubjectRect.map {
            CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height)
        } ?? CGRect(x: seedPoint.x - w / 2, y: 1 - seedPoint.y - h / 2,
                    width: w, height: h)
        // A user pin must keep its selected image patch. Automatic saliency/face
        // expansion can include a stronger background target in the same ROI.
        let box = centered.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        // Keep the selected physical point's relative location, not the new box center.
        anchorUV = CGPoint(x: (seedPoint.x - box.minX) / box.width,
                           y: ((1 - seedPoint.y) - box.minY) / box.height)
        boxSize = box.size; lastBox = box
        referencePrint = featurePrint(source, box: box, orientation: sourceOrientation)
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
        tracker = newTracker; seedBuffer = nil; seedSubjectRect = nil; pendingSeed = false
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
            // Full local detection runs several Vision/CoreML requests. Limit
            // it independently from the 30 Hz object-tracking path.
            let interval = active ? 1 / 32.0 : (idle ? 0.6 : 0.15)
            guard !busy, now - lastAdmission >= interval else { return nil }
            busy = true; lastAdmission = now
            let capture = captureNext; captureNext = false
            return (generation, active, capture)
        }
        guard let (epoch, tracking, capture) = admission else { return }
        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.ingressLock.withLock { self.busy = false } }
            self.latestBuffer = buffer; self.latestOrientation = orientation
            self.deliverCaptures(buffer, orientation: orientation, requested: capture, epoch: epoch)
            guard self.isCurrent(epoch) else { return }
            if tracking {
                guard let frame else { self.deliver(nil, confidence: 0, buffer: buffer, frame: nil,
                                                    evidence: nil, epoch: epoch); return }
                if self.pendingSeed { self.seed(in: buffer, orientation: orientation) }
                let result = self.track(buffer, orientation: orientation, frame: frame)
                self.deliver(result?.0, confidence: result?.1 ?? 0, buffer: buffer, frame: frame,
                             evidence: result?.2, epoch: epoch)
            } else {
                self.detect(buffer, orientation: orientation, epoch: epoch)
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

    private func track(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                       frame: TrackingFrameContext) -> (CGPoint, Double, TrackingOpticalEvidence)? {
        let prediction = SpatialTrackingEngine.shared.projection(at: frame.timestamp, calibration: frame.calibration)
        // A bearing prediction alone must not kill a live optical tracker at a
        // noisy FOV boundary. Only stop feeding images when clearly behind or
        // well outside the image, allowing a 5% boundary margin.
        if let prediction, !prediction.isInFront ||
            !CGRect(x: -0.05, y: -0.05, width: 1.1, height: 1.1).contains(prediction.point) {
            tracker = nil; continuity = VisionContinuityPolicy()
            patchFlow.reset()
            misses += 1; pendingRecovery = nil
            return nil
        }
        let dt = previousTime.isFinite ? min(0.1, max(0.001, frame.timestamp - previousTime)) : 1 / 30.0
        previousTime = frame.timestamp
        if let tracker {
            do {
                if let observation = try tracker.advance(in: buffer, orientation: orientation),
                   observation.confidence >= 0.40 {
                    let rawBox = observation.boundingBox
                    let rawPoint = point(in: rawBox)
                    let flow = orientation == .up ? patchFlow.evaluate(buffer: buffer, box: rawBox,
                                                                       fallback: rawPoint) : nil
                    let measuredPoint = flow?.isReliable == true ? flow!.point : rawPoint
                    let residual = prediction.map { hypot($0.point.x - measuredPoint.x,
                                                           $0.point.y - measuredPoint.y) } ?? 0
                    let needsIdentity = frame.timestamp - lastVerified >= 0.35 || misses > 1
                    let appearance = needsIdentity ? verify(buffer, box: rawBox,
                                                            orientation: orientation, strict: false) : .match(0)
                    let evidence: TrackingOpticalEvidence
                    switch appearance {
                    case .match:
                        evidence = needsIdentity ? .verifiedContinuation : .geometryContinuation
                    case .unavailable:
                        // A missing FeaturePrint is not evidence that a new
                        // background patch is the selected object. Require an
                        // independent, consistent point-flow observation.
                        guard flow?.isReliable == true, observation.confidence >= 0.65 else {
                            misses += 1; pendingRecovery = nil
                            if continuity.reject() { self.tracker = nil; patchFlow.reset() }
                            return nil
                        }
                        evidence = .geometryContinuation
                    case .mismatch: misses += 1; pendingRecovery = nil
                        if continuity.reject() { self.tracker = nil; patchFlow.reset() }
                        return nil
                    }
                    if rawBox.width > 0.01, rawBox.height > 0.01,
                       rawBox.minX >= 0, rawBox.minY >= 0, rawBox.maxX <= 1, rawBox.maxY <= 1,
                       residual <= SpatialTrackingEngine.shared.maxObservationJump {
                        if needsIdentity, case .match = appearance { lastVerified = frame.timestamp }
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
                        if let flow { patchFlow.accept(flow, box: rawBox, point: measuredPoint) }
                        else { patchFlow.seed(buffer: buffer, box: rawBox, point: measuredPoint) }
                        continuity.accept()
                        misses = 0; pendingRecovery = nil
                        return (measuredPoint, Double(observation.confidence), evidence)
                    }
                }
            } catch { /* An invalid observation never updates the spatial anchor. */ }
            misses += 1
            pendingRecovery = nil
            // Withhold the optical correction on a suspect frame, but retain
            // Vision's identity through one or two bad frames instead of reseeding.
            guard continuity.reject() else { return nil }
            self.tracker = nil
            patchFlow.reset()
        } else {
            misses += 1
        }
        // Search near the bearing first, then sweep the visible image after a
        // longer miss. Two distinct captured frames must agree.
        guard frame.timestamp - lastSearch >= 0.18,
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
                    misses = 0; lastVerified = frame.timestamp; pendingRecovery = nil
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
        var proposals = [center, CGPoint(x: center.x - step, y: center.y),
                         CGPoint(x: center.x + step, y: center.y),
                         CGPoint(x: center.x, y: center.y - step),
                         CGPoint(x: center.x, y: center.y + step),
                         CGPoint(x: center.x - step, y: center.y - step),
                         CGPoint(x: center.x + step, y: center.y + step),
                         CGPoint(x: center.x - step, y: center.y + step),
                         CGPoint(x: center.x + step, y: center.y - step)]
        if misses >= 6 {
            let radius: CGFloat = 0.10
            for index in 0..<8 {
                let angle = Double(index) * Double.pi / 4
                proposals.append(CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                                         y: center.y + radius * CGFloat(sin(angle))))
            }
        }
        var expensiveChecks = 0
        for (index, p) in proposals.prefix(25).enumerated() {
            let budget = index < 9 ? (misses >= 20 ? 4 : 6) : (index < 17 ? 8 : 12)
            guard expensiveChecks < budget else { continue }
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
            expensiveChecks += 1
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
            pendingTargetDelivery = (point, confidence, buffer, frame, evidence, epoch)
            guard !targetDeliveryScheduled else { return false }
            targetDeliveryScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delivery = self.ingressLock.withLock { () -> (CGPoint?, Double, CVPixelBuffer,
                TrackingFrameContext?, TrackingOpticalEvidence?, UInt64)? in
                let delivery = self.pendingTargetDelivery
                self.pendingTargetDelivery = nil; self.targetDeliveryScheduled = false
                return delivery
            }
            guard let (point, confidence, buffer, frame, evidence, epoch) = delivery,
                  self.isCurrent(epoch) else { return }
            if let measured = self.onTargetMeasurement {
                if let point, let frame, let evidence {
                    measured(TrackingOpticalMeasurement(point: point, confidence: confidence,
                        pixelBuffer: buffer, frame: frame, evidence: evidence))
                }
            }
            if let timed = self.onTargetTrackedWithTimestamp {
                if let frame { timed(point, confidence, buffer, frame) }
            } else { self.onTargetTracked?(point, confidence, buffer) }
        }
    }

    private func detect(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, epoch: UInt64) {
        let output = NeuralSubjectIntelligenceEngine.shared.analyzeFrame(pixelBuffer: buffer, orientation: orientation)
        var result = SubjectDetectionResult()
        result.detectedScene = output.detectedScene
        result.faceRectangles = output.allFaceRects
        result.primaryEyePosition = output.primaryEyePosition
        result.lookingDirection = output.lookingDirection
        if let primary = output.primaryCandidate {
            result.dominantSubjectRect = output.allFaceRects.count > 1 ? (output.groupBoundingBox ?? primary.boundingBox) : primary.boundingBox
            result.dominantSubjectCategory = output.allFaceRects.count > 1 ? .human : primary.category
            result.confidence = primary.confidence
        }
        let focus: CGPoint
        let type: SmartFocusType
        if let eye = output.primaryEyePosition { focus = eye; type = .face }
        else if let primary = output.primaryCandidate {
            focus = primary.center; type = primary.category == .face ? .face : .salientObject
        } else { focus = CGPoint(x: 0.5, y: 0.5); type = .center }
        let luma = luminance(buffer)
        result.averageLuminance = luma.0; result.estimatedColorTemp = luma.1
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(epoch) else { return }
            self.onDetectionCompleted?(result)
            self.onSmartFocusPointCalculated?(focus, type)
        }
    }

    private func luminance(_ buffer: CVPixelBuffer) -> (Float, Float) {
        let image = CIImage(cvPixelBuffer: buffer)
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(avg, toBitmap: bytes.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let r = Float(rgba[0]) / 255, g = Float(rgba[1]) / 255, b = Float(rgba[2]) / 255
        return (0.2126 * r + 0.7152 * g + 0.0722 * b, max(2700, min(9000, 3500 + b / max(r, 0.01) * 3000)))
    }

    private func deliverCaptures(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                 requested: Bool, epoch: UInt64? = nil) {
        guard requested else { return }
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let cg = context.createCGImage(image, from: image.extent)
        DispatchQueue.main.async { [weak self] in
            guard let self, let cg, requested else { return }
            if let epoch, !self.isCurrent(epoch) { return }
            self.capturedGeminiFrame = cg
            let callback = self.ingressLock.withLock { () -> ((CGImage) -> Void)? in
                let callback = self.captureCallback; self.captureCallback = nil; return callback
            }
            callback?(cg)
        }
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
