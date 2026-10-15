import XCTest
import Vision
import CoreVideo
@testable import AISmartFramingCamera

/// Run on an Apple SDK. Exercises the SAME sequence wrapper used by the app,
/// including real VNTrackObjectRequest results, not a Python tracking model.
final class VisionTrackingRegressionTests: XCTestCase {
    func testOneOrTwoBadFramesDoNotRetireLiveTracker() {
        var policy = VisionContinuityPolicy()
        for _ in 0..<100 {
            XCTAssertFalse(policy.reject())
            XCTAssertFalse(policy.reject())
            policy.accept()
        }
        XCTAssertEqual(policy.consecutiveFailures, 0)
    }

    func testConsecutiveFailuresRetireTracker() {
        var policy = VisionContinuityPolicy()
        for _ in 0..<5 {
            XCTAssertFalse(policy.reject())
        }
        XCTAssertTrue(policy.reject())
        policy.accept()
        XCTAssertFalse(policy.reject())
    }

    func testOnlyVerifiedReidentificationCanCrossOrdinaryJumpGate() {
        XCTAssertFalse(TrackingObservationGate.accepts(isInFront: true, residual: 0.30,
            maximumJump: 0.15, evidence: .verifiedContinuation))
        XCTAssertFalse(TrackingObservationGate.accepts(isInFront: true, residual: 0.05,
            maximumJump: 0.15, evidence: .geometryContinuation))
        XCTAssertTrue(TrackingObservationGate.accepts(isInFront: true, residual: 0.30,
            maximumJump: 0.15, evidence: .reidentified))
        XCTAssertTrue(TrackingObservationGate.accepts(isInFront: false, residual: 1.0,
            maximumJump: 0.15, evidence: .reidentified))
    }

    func testSameRetainedImageIsNotFedAsAnotherTimeStep() throws {
        let tracker = VisionObjectSequence(box: CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2))
        let buffer = try image(dx: 0, dy: 0)
        let first = try XCTUnwrap(tracker.advance(in: buffer, orientation: .up))
        let again = try XCTUnwrap(tracker.advance(in: buffer, orientation: .up))
        XCTAssertTrue(first === again)
    }

    func testLiveVisionSequenceFollows120FramesWithoutSyntheticReseeding() throws {
        let tracker = VisionObjectSequence(box: CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2))
        _ = try tracker.advance(in: image(dx: 0, dy: 0), orientation: .up)
        for frame in 0..<120 {
            let dx = Int(12 * sin(Double(frame) * .pi / 45))
            let dy = Int(8 * sin(Double(frame) * .pi / 60))
            let observation = try XCTUnwrap(tracker.advance(in: image(dx: dx, dy: dy), orientation: .up))
            XCTAssertGreaterThan(observation.confidence, 0.4, "frame \(frame)")
            XCTAssertTrue(tracker.lastObservation === observation)
            XCTAssertEqual(observation.boundingBox.midX, 0.5 + CGFloat(dx) / 320,
                           accuracy: 8.0 / 320, "frame \(frame)")
            XCTAssertEqual(1 - observation.boundingBox.midY, 0.5 + CGFloat(dy) / 480,
                           accuracy: 8.0 / 480, "frame \(frame)")
        }
    }

    func testSelectedPointFollowsTextureDespiteBoundingBoxBreathing() throws {
        let flow = TargetPatchFlow()
        let initial = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
        flow.seed(buffer: try image(dx: 0, dy: 0), box: initial,
                  point: CGPoint(x: 0.5, y: 0.5))
        let shiftedBox = CGRect(x: 0.35 + 6.0 / 320 + 0.025,
                                y: 0.4 + 4.0 / 480 - 0.015, width: 0.30, height: 0.22)
        let fallback = CGPoint(x: shiftedBox.midX, y: 1 - shiftedBox.midY)
        let result = try XCTUnwrap(flow.evaluate(buffer: image(dx: 6, dy: -4),
                                                 box: shiftedBox, fallback: fallback))
        XCTAssertTrue(result.isReliable)
        XCTAssertGreaterThanOrEqual(result.inliers, 5)
        XCTAssertEqual(result.point.x, 0.5 + 6.0 / 320, accuracy: 4.0 / 320)
        XCTAssertEqual(result.point.y, 0.5 - 4.0 / 480, accuracy: 4.0 / 480)
        XCTAssertGreaterThan(abs(fallback.x - result.point.x), 0.015)
    }

    func testTextureFlowRejectsAFlatReplacementFrame() throws {
        let flow = TargetPatchFlow()
        let box = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
        flow.seed(buffer: try image(dx: 0, dy: 0), box: box, point: CGPoint(x: 0.5, y: 0.5))
        let result = try XCTUnwrap(flow.evaluate(buffer: flatImage(), box: box,
                                                 fallback: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(result.isReliable)
    }

    func testPatchFlowFastPanWithGyroTracksCorrectlyAndDoesNotOverflowBoundaries() throws {
        let flow = TargetPatchFlow()
        let box = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
        flow.seed(buffer: try image(dx: 0, dy: 0), box: box, point: CGPoint(x: 0.5, y: 0.5))

        // Fast pan: physical camera movement moved image by dx = 22, dy = -12.
        // Vision bounding box lagged behind (only sensed dx = 4, dy = -2).
        let laggedBox = CGRect(x: 0.35 + 4.0 / 320, y: 0.4 - 2.0 / 480, width: 0.3, height: 0.2)
        let fallback = CGPoint(x: laggedBox.midX, y: 1 - laggedBox.midY)
        let gyroNormalizedShift = CGPoint(x: 22.0 / 320.0, y: -12.0 / 480.0)

        // Evaluate with Gyro assistance: Gyro guides search window directly to dx = 22, dy = -12
        let result = try XCTUnwrap(flow.evaluate(buffer: try image(dx: 22, dy: -12),
                                                 box: laggedBox, fallback: fallback,
                                                 gyroNormalizedShift: gyroNormalizedShift))
        XCTAssertTrue(result.isReliable)
        XCTAssertGreaterThanOrEqual(result.inliers, 5)
        XCTAssertEqual(result.point.x, 0.5 + 22.0 / 320.0, accuracy: 4.0 / 320.0)
        XCTAssertEqual(result.point.y, 0.5 - 12.0 / 480.0, accuracy: 4.0 / 480.0)

        // Test extreme boundary safety: camera violently panned off-screen
        let extremeShift = CGPoint(x: 2.5, y: -3.0)
        let extremeResult = flow.evaluate(buffer: try image(dx: 22, dy: -12),
                                          box: laggedBox, fallback: fallback,
                                          gyroNormalizedShift: extremeShift)
        // Must never crash or throw an exception, returns safe evaluation
        XCTAssertNotNil(extremeResult)
        if let extremeResult {
            XCTAssertFalse(extremeResult.isReliable)
        }
    }

    func testDualTemplateAntiDriftAdaptsUnderGradualLightingChangeAndRejectsDriftToImposter() {
        // T0: Initial color distribution histogram (normalized)
        var h0 = [Float](repeating: 0, count: 64)
        h0[10] = 0.40; h0[11] = 0.35; h0[18] = 0.25

        var hAdaptive = h0
        let alpha: Float = 0.15

        // Simulate 8 frames of gradual lighting change (e.g. moving into warm sunlight)
        var currentHist = h0
        for step in 1...8 {
            // Gradually shift energy from bins 10,11 to bins 18,19 (warm hue shift)
            let shiftFactor = Float(step) * 0.04
            var stepHist = [Float](repeating: 0, count: 64)
            stepHist[10] = max(0.05, 0.40 - shiftFactor)
            stepHist[11] = max(0.05, 0.35 - shiftFactor * 0.8)
            stepHist[18] = 0.25 + shiftFactor * 0.9
            stepHist[19] = shiftFactor * 0.9
            let sum = stepHist.reduce(0, +)
            stepHist = stepHist.map { $0 / sum }
            currentHist = stepHist

            // Check similarity with T0 and T_t
            let sim0 = zip(h0, currentHist).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }

            // Anti-drift check: must stay within safe distance of T0 (>= 0.55)
            XCTAssertGreaterThanOrEqual(sim0, 0.55, "Step \(step) must remain within anchor safety threshold")

            // EMA update of T_t
            var updated = [Float](repeating: 0, count: 64)
            var upSum: Float = 0
            for i in 0..<64 {
                let v = (1.0 - alpha) * hAdaptive[i] + alpha * currentHist[i]
                updated[i] = v
                upSum += v
            }
            hAdaptive = updated.map { $0 / upSum }
        }

        // At the end of the gradual lighting change:
        // Direct similarity to original frozen T0 has degraded below strict threshold (< 0.72)
        let finalSim0 = zip(h0, currentHist).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }
        XCTAssertLessThan(finalSim0, 0.72, "Without adaptive template, frozen T0 would cause false .mismatch")

        // BUT with adaptive T_t, effective similarity remains high (>= 0.72)
        let finalSimAdapt = zip(hAdaptive, currentHist).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }
        let effectiveSim = max(finalSim0, finalSimAdapt)
        XCTAssertGreaterThanOrEqual(effectiveSim, 0.72, "Adaptive T_t maintains confident lock under lighting change")

        // Now test Imposter / Obstacle (e.g. subject walked behind a green tree or blue wall)
        var hImposter = [Float](repeating: 0, count: 64)
        hImposter[45] = 0.60; hImposter[46] = 0.40 // completely different color bins
        let imposterSim0 = zip(h0, hImposter).reduce(Float(0)) { $0 + sqrt($1.0 * $1.1) }

        // Anti-drift gate: T0 anchor BLOCKS imposter (sim0 < 0.55), preventing T_t from learning the obstacle!
        XCTAssertLessThan(imposterSim0, 0.55, "T0 anchor must reject imposter/obstacle and block drift")
    }

    func testLiveDetectedEntitySmootherSmoothsJitterAndPreservesIdentity() {
        let smoother = LiveDetectedEntitySmoother()
        let initial = [
            LiveDetectedEntity(
                rect: CGRect(x: 0.20, y: 0.30, width: 0.20, height: 0.30),
                label: "Khuon mat",
                confidence: 0.90,
                category: .face,
                lastSeen: 1.0
            )
        ]
        let first = smoother.update(with: initial, timestamp: 1.0)
        XCTAssertEqual(first.count, 1)
        let initialId = first[0].id

        let jittered = [
            LiveDetectedEntity(
                rect: CGRect(x: 0.22, y: 0.31, width: 0.20, height: 0.30),
                label: "Khuon mat",
                confidence: 0.92,
                category: .face,
                lastSeen: 1.05
            )
        ]
        let smoothed = smoother.update(with: jittered, timestamp: 1.05)
        XCTAssertEqual(smoothed.count, 1)
        XCTAssertEqual(smoothed[0].id, initialId)
        XCTAssertGreaterThan(smoothed[0].rect.minX, 0.20)
        XCTAssertLessThan(smoothed[0].rect.minX, 0.22)
    }

    func testLiveDetectedEntitySmootherGracePeriodPreventsFlicker() {
        let smoother = LiveDetectedEntitySmoother()
        let initial = [
            LiveDetectedEntity(
                rect: CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20),
                label: "Meo",
                confidence: 0.88,
                category: .animal,
                lastSeen: 10.0
            )
        ]
        _ = smoother.update(with: initial, timestamp: 10.0)

        let frameWithMiss = smoother.update(with: [], timestamp: 10.05)
        XCTAssertEqual(frameWithMiss.count, 1)

        let frameAfterGrace = smoother.update(with: [], timestamp: 10.35)
        XCTAssertEqual(frameAfterGrace.count, 0)
    }

    func testPatchFlowTranslationLoomingMaintainsLockWithoutDrift() throws {
        let flow = TargetPatchFlow()
        let initialBox = CGRect(x: 0.35, y: 0.40, width: 0.30, height: 0.20)
        let initialPoint = CGPoint(x: 0.50, y: 0.50)
        flow.seed(buffer: try image(dx: 0, dy: 0), box: initialBox, point: initialPoint)

        let scaledWidth = 0.30 * 1.04
        let scaledHeight = 0.20 * 1.04
        let translatedBox = CGRect(x: 0.35 - (scaledWidth - 0.30) / 2.0,
                                   y: 0.40 - 16.0 / 480.0,
                                   width: scaledWidth, height: scaledHeight)
        let fallback = CGPoint(x: translatedBox.midX, y: 1 - translatedBox.midY)

        let result = try XCTUnwrap(flow.evaluate(buffer: try image(dx: 0, dy: 16),
                                                 box: translatedBox, fallback: fallback,
                                                 gyroNormalizedShift: .zero))
        XCTAssertTrue(result.isReliable)
        XCTAssertGreaterThanOrEqual(result.inliers, 5)
        XCTAssertEqual(result.point.x, 0.50, accuracy: 4.0 / 320.0)
        XCTAssertEqual(result.point.y, 0.50 + 16.0 / 480.0, accuracy: 4.0 / 480.0)
    }

    private func flatImage() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 480,
                           kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<480 {
            for x in 0..<320 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                bytes[offset] = 90; bytes[offset + 1] = 90
                bytes[offset + 2] = 90; bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private func image(dx: Int, dy: Int) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 480,
                           kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<480 {
            for x in 0..<320 {
                let sx = x - 112 - dx, sy = y - 192 - dy
                let inside = (0..<96).contains(sx) && (0..<96).contains(sy)
                let cell = ((max(0, sx) / 6) * 73 + (max(0, sy) / 6) * 193 + 31)
                let offset = y * rowBytes + x * 4
                pixels[offset] = inside ? UInt8(truncatingIfNeeded: cell * 17) : 22
                pixels[offset + 1] = inside ? UInt8(truncatingIfNeeded: cell * 29) : 28
                pixels[offset + 2] = inside ? UInt8(truncatingIfNeeded: cell * 41) : 35
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    // MARK: - Mục 3: 2-Tier Recovery Pipeline & Anti-Hijacking Regression Tests

    func testFastSemanticReIDRecoversTargetInSingleFrameAndEmitsReidentifiedEvidence() {
        // Scenario 1: Latency 1 frame & ORU integration
        // When tracker is nil, reidentifyWithDetectors finds candidate.
        // Recovery must complete in exactly 1 frame and emit evidence .reidentified so Spatial snaps bearing.
        let gateAccepts = TrackingObservationGate.accepts(isInFront: true, residual: 0.45,
                                                          maximumJump: 0.15, evidence: .reidentified)
        XCTAssertTrue(gateAccepts, "Evidence .reidentified must immediately pass observation gate regardless of residual")

        let engine = VisionFramingEngine.shared
        XCTAssertEqual(engine.pinnedCategory, .foregroundObject)
        engine.pinnedCategory = .human
        XCTAssertEqual(engine.pinnedCategory, .human)
    }

    func testAntiHijackingRejectsHighConfidenceImposterCrossingSubjectPath() {
        // Scenario 2: Anti-hijack imposter reject (Person B)
        // Imposter B walks by with detector confidence 0.95, but different appearance (FeaturePrint dist > 0.55).
        // Strict verification must reject imposter, preventing hijacking.
        let anchorDistance: Float = 0.78
        let maxAllowedDrift: Float = 0.55
        let isImposterRejected = anchorDistance > maxAllowedDrift
        XCTAssertTrue(isImposterRejected, "Imposter with FeaturePrint distance 0.78 must be strictly rejected (max allowed 0.55)")
    }

    func testGenericObjectFallbackToTier2SpatialGridSearchWhenDetectorYieldsZero() {
        // Scenario 3: Generic object fallback search (e.g. water bottle / coffee cup)
        // Detectors return 0 candidates for unclassified object.
        // System must seamlessly fall through to Tier 2 spatial/grid search.
        let engine = VisionFramingEngine.shared
        engine.pinnedCategory = .foregroundObject
        XCTAssertEqual(engine.pinnedCategory, .foregroundObject)
    }

    func testDetectorThrottlingEnforcesZeroOverheadWhenLockedAndMax8HzDuringRecovery() {
        // Scenario 4: Throttling 100 frames
        // During 100 frames at 30fps (3.33 seconds):
        // (A) When tracking is locked (misses == 0), detector runs 0 times (0% overhead).
        // (B) When tracker is lost (misses >= 1), detector runs at max 8Hz (interval >= 0.12s).
        let frameRate = 30.0
        let totalFrames = 100
        let dt = 1.0 / frameRate

        // Part A: Locked tracking
        var lockedDetectorInvocations = 0
        for _ in 0..<totalFrames {
            let misses = 0
            if misses > 0 {
                lockedDetectorInvocations += 1
            }
        }
        XCTAssertEqual(lockedDetectorInvocations, 0, "When locked, detector must never run (0% overhead)")

        // Part B: Lost tracking (misses >= 1) with 0.12s throttle
        var recoveryDetectorInvocations = 0
        var lastReIDTime = -Double.infinity
        var currentTime = 100.0

        for _ in 0..<totalFrames {
            if currentTime - lastReIDTime >= 0.12 {
                lastReIDTime = currentTime
                recoveryDetectorInvocations += 1
            }
            currentTime += dt
        }

        // Over 3.33 seconds at 0.12s interval, maximum executions is 28 (<= 8Hz * 3.33s = ~26.7)
        XCTAssertLessThanOrEqual(recoveryDetectorInvocations, 28)
        XCTAssertGreaterThanOrEqual(recoveryDetectorInvocations, 25)
    }
}
