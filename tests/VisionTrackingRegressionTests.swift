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

    func testThreeConsecutiveFailuresRetireTracker() {
        var policy = VisionContinuityPolicy()
        XCTAssertFalse(policy.reject())
        XCTAssertFalse(policy.reject())
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
}
