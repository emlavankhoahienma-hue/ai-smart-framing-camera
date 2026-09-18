import CoreGraphics
import XCTest
@testable import AISmartFramingCameraCore

final class CameraGeometryAndTrackingTests: XCTestCase {
    func testPreviewGeometryRoundTripsAcrossCaptureRatiosAndPhones() throws {
        let sourceRatios: [CGFloat] = [3.0 / 4.0, 9.0 / 16.0]
        let phoneSizes = [
            CGSize(width: 320, height: 568),
            CGSize(width: 390, height: 844),
            CGSize(width: 430, height: 932)
        ]
        let points = [CGPoint(x: 0.03, y: 0.06), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.94, y: 0.91)]

        for ratio in sourceRatios {
            let geometry = CameraPreviewGeometry(sourceAspectRatio: ratio)
            for size in phoneSizes {
                for point in points {
                    let screen = try XCTUnwrap(geometry.screenPoint(fromNormalized: point, in: size))
                    let roundTrip = try XCTUnwrap(geometry.normalizedPoint(fromScreen: screen, in: size))
                    XCTAssertEqual(roundTrip.x, point.x, accuracy: 0.000_01)
                    XCTAssertEqual(roundTrip.y, point.y, accuracy: 0.000_01)
                }

                let rect = CGRect(x: 0.22, y: 0.18, width: 0.31, height: 0.27)
                let screenRect = try XCTUnwrap(geometry.screenRect(fromNormalized: rect, in: size))
                let roundTripRect = try XCTUnwrap(geometry.normalizedRect(fromScreen: screenRect, in: size))
                XCTAssertEqual(roundTripRect.minX, rect.minX, accuracy: 0.000_01)
                XCTAssertEqual(roundTripRect.minY, rect.minY, accuracy: 0.000_01)
                XCTAssertEqual(roundTripRect.width, rect.width, accuracy: 0.000_01)
                XCTAssertEqual(roundTripRect.height, rect.height, accuracy: 0.000_01)
            }
        }
    }

    func testGeometryRejectsNonFiniteInput() {
        let geometry = CameraPreviewGeometry(sourceAspectRatio: 3.0 / 4.0)
        XCTAssertNil(geometry.screenPoint(fromNormalized: CGPoint(x: CGFloat.nan, y: 0.5), in: CGSize(width: 390, height: 520)))
        XCTAssertNil(geometry.normalizedPoint(fromScreen: CGPoint(x: CGFloat.infinity, y: 10), in: CGSize(width: 390, height: 520)))
        XCTAssertEqual(geometry.fittedSize(in: CGSize(width: CGFloat.nan, height: 100)), .zero)
    }

    func testStabilizerReducesRMSJitter() throws {
        var stabilizer = DetectionRectStabilizer()
        let noise: [CGFloat] = [-0.010, 0.008, -0.006, 0.011, -0.009, 0.005, -0.004, 0.007, -0.008, 0.004]
        var rawErrors: [CGFloat] = []
        var filteredErrors: [CGFloat] = []

        for delta in noise {
            let raw = CGRect(x: 0.4 + delta, y: 0.35 - delta, width: 0.20, height: 0.24)
            let filtered = try XCTUnwrap(stabilizer.update(with: [raw]).first)
            rawErrors.append(hypot(raw.midX - 0.5, raw.midY - 0.47))
            filteredErrors.append(hypot(filtered.midX - 0.5, filtered.midY - 0.47))
        }

        XCTAssertLessThan(rms(filteredErrors), rms(rawErrors) * 0.78)
    }

    func testStabilizerTracksLinearMotionWithBoundedLag() throws {
        var stabilizer = DetectionRectStabilizer()
        var lastFiltered = CGRect.zero
        for frame in 0..<20 {
            let x = 0.15 + CGFloat(frame) * 0.018
            lastFiltered = try XCTUnwrap(stabilizer.update(with: [CGRect(x: x, y: 0.35, width: 0.16, height: 0.20)]).first)
        }
        let expectedMidX = 0.15 + CGFloat(19) * 0.018 + 0.08
        XCTAssertLessThan(abs(lastFiltered.midX - expectedMidX), 0.045)
    }

    func testOutlierOcclusionAndReacquisitionPreserveTargetIdentity() throws {
        var stabilizer = DetectionRectStabilizer(maximumMissedFrames: 6)
        let anchor = CGRect(x: 0.20, y: 0.30, width: 0.18, height: 0.22)
        _ = stabilizer.update(with: [anchor])
        _ = stabilizer.update(with: [anchor.offsetBy(dx: 0.01, dy: 0)])

        let afterOutlier = try XCTUnwrap(stabilizer.update(with: [CGRect(x: 0.75, y: 0.05, width: 0.10, height: 0.10)]).first)
        XCTAssertLessThan(afterOutlier.midX, 0.45)

        for _ in 0..<4 {
            XCTAssertFalse(stabilizer.update(with: []).isEmpty)
        }

        let reacquired = try XCTUnwrap(stabilizer.update(with: [anchor.offsetBy(dx: 0.025, dy: 0.01)]).first)
        XCTAssertLessThan(abs(reacquired.midX - (anchor.midX + 0.025)), 0.08)
        XCTAssertLessThan(reacquired.midX, 0.50)
    }

    func testAFMappingIsFiniteBoundedAndHonorsLocks() {
        let inputs = [CGPoint(x: -2, y: 4), CGPoint(x: CGFloat.nan, y: CGFloat.infinity), CGPoint(x: 0.22, y: 0.83)]
        for input in inputs {
            let device = CameraCoordinateMapper.uiToDevice(input)
            XCTAssertTrue(device.x.isFinite && device.y.isFinite)
            XCTAssertTrue((0.01...0.99).contains(device.x))
            XCTAssertTrue((0.01...0.99).contains(device.y))
            let ui = CameraCoordinateMapper.deviceToUI(device)
            XCTAssertTrue(ui.x.isFinite && ui.y.isFinite)
            XCTAssertTrue((0.01...0.99).contains(ui.x))
            XCTAssertTrue((0.01...0.99).contains(ui.y))
        }

        let point = CGPoint(x: 0.8, y: 0.8)
        XCTAssertFalse(AutofocusUpdatePolicy.shouldIssueUpdate(
            point: point, previousPoint: CGPoint(x: 0.5, y: 0.5), now: 10, previousUpdateTime: 0,
            isAEAFLocked: true, isManualFocus: false, force: false
        ))
        XCTAssertFalse(AutofocusUpdatePolicy.shouldIssueUpdate(
            point: point, previousPoint: CGPoint(x: 0.5, y: 0.5), now: 10, previousUpdateTime: 0,
            isAEAFLocked: false, isManualFocus: true, force: false
        ))
        XCTAssertTrue(AutofocusUpdatePolicy.shouldIssueUpdate(
            point: point, previousPoint: CGPoint(x: 0.5, y: 0.5), now: 10, previousUpdateTime: 0,
            isAEAFLocked: false, isManualFocus: false, force: false
        ))
    }

    private func rms(_ values: [CGFloat]) -> CGFloat {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / CGFloat(values.count))
    }
}
