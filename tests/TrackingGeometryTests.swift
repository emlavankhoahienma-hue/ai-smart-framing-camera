import XCTest
import simd
import CoreVideo
@testable import AISmartFramingCamera

/// Add this file to the app's XCTest target. These tests exercise the real Swift
/// geometry. They were supplied but cannot run on the Windows authoring host.
final class TrackingGeometryTests: XCTestCase {
    private let k = TrackingCalibration.fallback()

    func testRightPanAndUpTiltSigns() {
        let anchor = k.deviceRay(at: CGPoint(x: 0.5, y: 0.5))
        let right = simd_quatd(angle: -20 * .pi / 180, axis: SIMD3(0, 1, 0))
        let up = simd_quatd(angle: 20 * .pi / 180, axis: SIMD3(1, 0, 0))
        XCTAssertLessThan(k.project(deviceRay: right.inverse.act(anchor)).point.x, 0.5)
        XCTAssertGreaterThan(k.project(deviceRay: up.inverse.act(anchor)).point.y, 0.5)
    }

    func testNoClampAcrossFullRotation() {
        let pin = CGPoint(x: 0.7, y: 0.3)
        let anchor = k.deviceRay(at: pin)
        var sawOffscreen = false
        for degrees in 0...360 {
            let pose = simd_quatd(angle: Double(degrees) * .pi / 180, axis: SIMD3(0, 1, 0))
            let p = k.project(deviceRay: pose.inverse.act(anchor))
            XCTAssertTrue(p.point.x.isFinite && p.point.y.isFinite)
            if !p.isInsideImage { sawOffscreen = true }
        }
        XCTAssertTrue(sawOffscreen)
        let back = k.project(deviceRay: anchor).point
        XCTAssertEqual(back.x, pin.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, pin.y, accuracy: 1e-12)
    }

    func testHistoricalPoseUsesSlerpAndRejectsUnavailableTime() {
        let samples = [
            TrackingMotionSample(timestamp: 1, deviceToWorld: simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))),
            TrackingMotionSample(timestamp: 1.02, deviceToWorld: simd_quatd(angle: 0.02, axis: SIMD3(0, 1, 0)))
        ]
        let interpolated = TrackingGeometry.pose(at: 1.01, in: samples)
        XCTAssertNotNil(interpolated)
        XCTAssertEqual(interpolated?.angle ?? 0, 0.01, accuracy: 1e-9)
        XCTAssertNil(TrackingGeometry.pose(at: 0.5, in: samples))
        XCTAssertNil(TrackingGeometry.pose(at: 2, in: samples))
    }

    func testAspectFillAndDocking() {
        let size = CGSize(width: 390, height: 844)
        let original = CGPoint(x: -2, y: 1.5)
        let p = TrackingGeometry.screenPoint(original, size: size, aspect: 0.75)
        let roundTrip = TrackingGeometry.bufferPoint(p, size: size, aspect: 0.75)
        XCTAssertEqual(roundTrip.x, original.x, accuracy: 1e-12)
        XCTAssertEqual(roundTrip.y, original.y, accuracy: 1e-12)
        let dock = TrackingGeometry.dock(p, size: size)
        XCTAssertEqual(dock.x, 30, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(dock.y, 30)
        XCTAssertLessThanOrEqual(dock.y, 814)
    }

    func testDelayedObservationPreservesWorldRay() {
        let capturePose = simd_quatd(angle: -0.2, axis: SIMD3(0, 1, 0))
        let currentPose = simd_quatd(angle: -0.4, axis: SIMD3(0, 1, 0))
        let world = k.deviceRay(at: CGPoint(x: 0.5, y: 0.5))
        let observation = k.project(deviceRay: capturePose.inverse.act(world)).point
        let reconstructed = capturePose.act(k.deviceRay(at: observation))
        let correctedNow = k.project(deviceRay: currentPose.inverse.act(reconstructed)).point
        let truthNow = k.project(deviceRay: currentPose.inverse.act(world)).point
        XCTAssertEqual(correctedNow.x, truthNow.x, accuracy: 1e-12)
        XCTAssertEqual(correctedNow.y, truthNow.y, accuracy: 1e-12)
    }

    func testHomographyPixelUnitsAndDirectionOnAppleVision() throws {
        func buffer(dx: Int, dy: Int) throws -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 256, 256,
                                              kCVPixelFormatType_32BGRA, nil, &result)
            XCTAssertEqual(status, kCVReturnSuccess)
            let image = try XCTUnwrap(result)
            CVPixelBufferLockBaseAddress(image, [])
            defer { CVPixelBufferUnlockBaseAddress(image, []) }
            let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(image)
            for y in 0..<256 {
                for x in 0..<256 {
                    let sx = x - dx, sy = y - dy
                    let cell = (sx / 8 + 1) * 73 + (sy / 8 + 1) * 193
                    let valid = sx >= 0 && sx < 256 && sy >= 0 && sy < 256
                    let offset = y * stride + x * 4
                    pixels[offset] = valid ? UInt8(truncatingIfNeeded: cell * 17) : 0
                    pixels[offset + 1] = valid ? UInt8(truncatingIfNeeded: cell * 29) : 0
                    pixels[offset + 2] = valid ? UInt8(truncatingIfNeeded: cell * 41) : 0
                    pixels[offset + 3] = 255
                }
            }
            return image
        }
        let reference = try buffer(dx: 0, dy: 0)
        let shifted = try buffer(dx: 16, dy: 8)
        let engine = VisualOdometryEngine.shared
        defer { engine.clearReference() }
        engine.setReferenceFrame(reference, atUIPoint: CGPoint(x: 0.5, y: 0.5))
        let estimate = try XCTUnwrap(engine.estimateCurrentUIPoint(currentBuffer: shifted))
        XCTAssertEqual(estimate.x, 0.5 + 16.0 / 256, accuracy: 0.015)
        XCTAssertEqual(estimate.y, 0.5 + 8.0 / 256, accuracy: 0.015)
    }
}
