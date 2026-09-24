import XCTest
import simd
@testable import AISmartFramingCamera

/// Real production policies. Add to the app's XCTest target and run on an
/// Apple SDK; the Windows verification report must not claim these ran.
final class TrackingStabilityRegressionTests: XCTestCase {
    private let k = TrackingCalibration.fallback()
    private let centre = SIMD3<Double>(0, 0, -1)

    func testIsolatedHighConfidenceBoxCannotMoveWorldBearing() {
        var policy = TrackingInnovationPolicy()
        let wrong = k.deviceRay(at: CGPoint(x: 0.72, y: 0.48))
        let evidences: [TrackingOpticalEvidence] = [.geometryContinuation, .verifiedContinuation, .confirmedContinuation]
        for evidence in evidences {
            policy.reset()
            XCTAssertFalse(policy.accepts(observed: wrong, predicted: centre,
                timestamp: 1, focalScale: k.fx, evidence: evidence))
            XCTAssertTrue(policy.accepts(observed: centre, predicted: centre,
                timestamp: 1.033, focalScale: k.fx, evidence: evidence))
            XCTAssertFalse(policy.accepts(observed: wrong, predicted: centre,
                timestamp: 1.067, focalScale: k.fx, evidence: evidence))
        }
    }

    func testConsistentTranslationRecoversWithoutRepinning() {
        var policy = TrackingInnovationPolicy()
        let shifted = k.deviceRay(at: CGPoint(x: 0.70, y: 0.5))
        XCTAssertFalse(policy.accepts(observed: shifted, predicted: centre,
            timestamp: 1, focalScale: k.fx, evidence: .geometryContinuation))
        XCTAssertFalse(policy.accepts(observed: shifted, predicted: centre,
            timestamp: 1.033, focalScale: k.fx, evidence: .geometryContinuation))
        XCTAssertTrue(policy.accepts(observed: shifted, predicted: centre,
            timestamp: 1.067, focalScale: k.fx, evidence: .geometryContinuation))
    }

    func testDuplicateFramesAndLongGapsDoNotConfirmAnInnovation() {
        var policy = TrackingInnovationPolicy()
        let wrong = k.deviceRay(at: CGPoint(x: 0.75, y: 0.5))
        for time in [1.0, 1.0, 1.0, 2.0, 3.0] {
            XCTAssertFalse(policy.accepts(observed: wrong, predicted: centre,
                timestamp: time, focalScale: k.fx, evidence: .verifiedContinuation))
        }
    }

    func testCameraRotationCancelsBeforeOpticalGate() {
        var policy = TrackingInnovationPolicy()
        let world = k.deviceRay(at: CGPoint(x: 0.57, y: 0.43))
        for i in 0..<300 {
            let pose = simd_quatd(angle: sin(Double(i) / 30) * 0.5,
                                  axis: SIMD3<Double>(0, 1, 0))
            let image = k.project(deviceRay: pose.inverse.act(world))
            let reconstructed = pose.act(k.deviceRay(at: image.point))
            XCTAssertTrue(policy.accepts(observed: reconstructed, predicted: world,
                timestamp: Double(i) / 60, focalScale: k.fx, evidence: .geometryContinuation))
        }
    }

    func testConfirmedReidentificationStillHasBoundedDisplayMotion() {
        var policy = TrackingInnovationPolicy()
        let found = k.deviceRay(at: CGPoint(x: 0.90, y: 0.1))
        XCTAssertTrue(policy.accepts(observed: found, predicted: centre,
            timestamp: 1, focalScale: k.fx, evidence: .reidentified))
        let step = 0.60 / 60 / k.fx
        let rendered = TrackingBearingSlew.advance(from: centre, to: found, maxAngle: step)
        XCTAssertLessThanOrEqual(acos(min(1, simd_dot(rendered, centre))), step + 1e-9)
        XCTAssertGreaterThan(simd_length(rendered - found), 0.1)
        var current = centre
        for _ in 0..<180 { current = TrackingBearingSlew.advance(from: current, to: found, maxAngle: step) }
        XCTAssertLessThan(simd_length(current - found), 1e-8)
    }

    func testSlewDoesNotFilterAPanOrForgetAnOffscreenBearing() {
        let world = k.deviceRay(at: CGPoint(x: 0.65, y: 0.35))
        let rendered = TrackingBearingSlew.advance(from: world, to: world, maxAngle: 0.01)
        for degrees in stride(from: 0, through: 360, by: 4) {
            let pose = simd_quatd(angle: -Double(degrees) * .pi / 180, axis: SIMD3<Double>(0, 1, 0))
            let expected = k.project(deviceRay: pose.inverse.act(world))
            let actual = k.project(deviceRay: pose.inverse.act(rendered))
            XCTAssertEqual(actual.point.x, expected.point.x, accuracy: 1e-9)
            XCTAssertEqual(actual.point.y, expected.point.y, accuracy: 1e-9)
        }
    }

    func testSmallCentredSubjectGetsUsefulZoomAndLargeSubjectDoesNotClip() {
        let frame = TrackingFrameContext(timestamp: 1, calibration: k)
        let small = LocalFramingGeometry.centeredZoom(
            subject: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10),
            aim: CGPoint(x: 0.5, y: 0.5), companions: [], scene: .general,
            frame: frame, currentZoom: 1, allowedZooms: [1, 2, 3])
        XCTAssertEqual(small, 3)
        let large = LocalFramingGeometry.centeredZoom(
            subject: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.70),
            aim: CGPoint(x: 0.5, y: 0.5), companions: [], scene: .general,
            frame: frame, currentZoom: 1, allowedZooms: [1, 2, 3])
        XCTAssertEqual(large, 1)
    }

    func testCompanionAtEdgePreventsUnsafeZoom() {
        let frame = TrackingFrameContext(timestamp: 1, calibration: k)
        let zoom = LocalFramingGeometry.centeredZoom(
            subject: CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10),
            aim: CGPoint(x: 0.5, y: 0.5),
            companions: [CGRect(x: 0.85, y: 0.4, width: 0.10, height: 0.10)],
            scene: .general, frame: frame, currentZoom: 1, allowedZooms: [1, 2, 3])
        XCTAssertEqual(zoom, 1)
    }
}
