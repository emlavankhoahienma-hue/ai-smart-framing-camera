import XCTest
@testable import AISmartFramingCamera

/// Add to the app's XCTest target and run on a Mac with an iOS SDK.
final class CameraPipelineRegressionTests: XCTestCase {
    func testPredictedTargetNeverTriggersAutomaticCapture() {
        for quality in [TrackingQuality.predicting, .reacquiring, .lost] {
            XCTAssertFalse(TrackingCapturePolicy.canCapture(distance: 0.01,
                tolerance: 0.038, quality: quality, isZooming: false))
        }
        XCTAssertTrue(TrackingCapturePolicy.canCapture(distance: 0.01,
            tolerance: 0.038, quality: .locked, isZooming: false))
        XCTAssertFalse(TrackingCapturePolicy.canCapture(distance: 0.01,
            tolerance: 0.038, quality: .locked, isZooming: true))
    }

    func testAutoZoomKeepsSubjectInsideFramingMargin() {
        let subject = CGRect(x: 0.78, y: 0.38, width: 0.12, height: 0.18)
        XCTAssertEqual(CompositionCalculator.shared.computeOptimalZoom(
            subjectRect: subject, currentZoom: 1, category: .foregroundObject), 1)
    }

    func testTinyCenteredObjectCanRequestTelephoto() {
        let subject = CGRect(x: 0.46, y: 0.42, width: 0.08, height: 0.12)
        XCTAssertEqual(CompositionCalculator.shared.computeOptimalZoom(
            subjectRect: subject, currentZoom: 1, category: .foregroundObject), 3)
    }

    func testWindowedFocalLengthDoesNotApplyASecondCrop() {
        let wide = WindowedZoomAspectRatio.ratio3_4.windowFractions(focalLength: 24)
        let tele = WindowedZoomAspectRatio.ratio3_4.windowFractions(focalLength: 85)
        XCTAssertEqual(wide.widthFraction, tele.widthFraction)
        XCTAssertEqual(wide.heightFraction, tele.heightFraction)
    }
}
