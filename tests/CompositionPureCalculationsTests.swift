import XCTest
import CoreGraphics
import simd
@testable import AISmartFramingCamera

/// Kiem thu don vi thuan tuy (Deterministic Unit Tests) cho cac phep tinh bo cuc AI va chieu hinh hoc 3D.
/// Khong phu thuoc phan cung camera, khong can sensor that.
final class CompositionPureCalculationsTests: XCTestCase {

    // MARK: - Test #1: Decode YOLO box khong clamp sớm
    func testYOLORawBoxDecodingWithoutClamp() {
        let cx: CGFloat = 0.05
        let cy: CGFloat = 0.5
        let w: CGFloat = 0.2
        let h: CGFloat = 0.3

        let raw = CompositionPureCalculations.decodeYOLORawBox(cx: cx, cy: cy, w: w, h: h)
        XCTAssertEqual(raw.minX, -0.05, accuracy: 1e-6)
        XCTAssertEqual(raw.minY, 0.35, accuracy: 1e-6)
        XCTAssertEqual(raw.width, 0.2, accuracy: 1e-6)
        XCTAssertEqual(raw.height, 0.3, accuracy: 1e-6)

        let insideRatio = CompositionPureCalculations.computeInsideUnitRatio(rawRect: raw)
        XCTAssertEqual(insideRatio, 0.75, accuracy: 1e-6)

        let clipped = CompositionPureCalculations.validateAndClipBox(
            rawRect: raw,
            minDimension: 0.04,
            maxDimension: 0.95,
            minAspect: 0.15,
            maxAspect: 6.5,
            minVisibleFraction: 0.75
        )
        XCTAssertNotNil(clipped)
        guard let validBox = clipped else { return }
        XCTAssertEqual(validBox.minX, 0.0, accuracy: 1e-6)
        XCTAssertEqual(validBox.minY, 0.35, accuracy: 1e-6)
        XCTAssertEqual(validBox.width, 0.15, accuracy: 1e-6)
        XCTAssertEqual(validBox.height, 0.3, accuracy: 1e-6)
    }

    // MARK: - Test #3: Hoan nguyen toa do Letterbox (.scaleFit)
    func testLetterboxUnpadding() {
        let sourceW = 3000.0
        let sourceH = 4000.0 // Ty le 3:4 anh doc
        let modelSize = 640.0

        // Mot box nam chinh giua model 640x640: minX=80, minY=0, width=480, height=640
        // Toa do chuan hoa trong model: (80/640, 0, 480/640, 640/640) = (0.125, 0.0, 0.75, 1.0)
        let normalizedInModel = CGRect(x: 0.125, y: 0.0, width: 0.75, height: 1.0)
        let unpadded = CompositionPureCalculations.unpadLetterbox(
            normalizedRect: normalizedInModel,
            sourceWidth: sourceW,
            sourceHeight: sourceH,
            modelSize: modelSize
        )

        // Phai hoan nguyen ve toan bo khung hinh goc (0, 0, 1, 1)
        XCTAssertEqual(unpadded.minX, 0.0, accuracy: 1e-6)
        XCTAssertEqual(unpadded.minY, 0.0, accuracy: 1e-6)
        XCTAssertEqual(unpadded.width, 1.0, accuracy: 1e-6)
        XCTAssertEqual(unpadded.height, 1.0, accuracy: 1e-6)
    }

    // MARK: - Test #4: Dong nhat he toa do giua cac nguon (YOLO, Vision, Apple Metadata)
    func testCoordinateUnificationAcrossSources() {
        let expectedUpright = CGRect(x: 0.20, y: 0.30, width: 0.40, height: 0.50)

        // 1. YOLO decode (cx = 0.40, cy = 0.55, w = 0.40, h = 0.50)
        let yoloBox = CompositionPureCalculations.decodeYOLORawBox(cx: 0.40, cy: 0.55, w: 0.40, h: 0.50)

        // 2. Vision observation (goc duoi-trai, y=0.20)
        let visionObservation = CGRect(x: 0.20, y: 0.20, width: 0.40, height: 0.50)
        let visionBox = CompositionPureCalculations.visionToUprightRect(visionObservation)

        // 3. Apple AVCaptureMetadataOutput sensor space (landscape sensor)
        let appleMetadataBounds = CGRect(x: 0.20, y: 0.20, width: 0.50, height: 0.40)
        let appleBox = CompositionPureCalculations.appleMetadataToUprightRect(appleMetadataBounds)

        // Tat ca nguon phai tra ve cung mot box upright giong nhau voi sai so < 1e-6
        for box in [yoloBox, visionBox, appleBox] {
            XCTAssertEqual(box.minX, expectedUpright.minX, accuracy: 1e-6)
            XCTAssertEqual(box.minY, expectedUpright.minY, accuracy: 1e-6)
            XCTAssertEqual(box.width, expectedUpright.width, accuracy: 1e-6)
            XCTAssertEqual(box.height, expectedUpright.height, accuracy: 1e-6)
        }

        // Round-trip Vision <-> Upright
        let roundTrip = CompositionPureCalculations.visionToUprightRect(
            CompositionPureCalculations.uprightToVisionRect(expectedUpright)
        )
        XCTAssertEqual(roundTrip.minX, expectedUpright.minX, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.minY, expectedUpright.minY, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.width, expectedUpright.width, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.height, expectedUpright.height, accuracy: 1e-6)
    }

    // MARK: - Test #5: Upright sang metadataOutputRect va captureDevicePoint
    func testUprightToMetadataOutputRect() {
        // Spec Test: rect (x:0.1, y:0.2, w:0.3, h:0.4) -> metadataRect (x:0.2, y:0.6, w:0.4, h:0.3)
        let upright = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let meta = CompositionPureCalculations.uprightToMetadataOutputRect(upright)
        XCTAssertEqual(meta.minX, 0.2, accuracy: 1e-6)
        XCTAssertEqual(meta.minY, 0.6, accuracy: 1e-6)
        XCTAssertEqual(meta.width, 0.4, accuracy: 1e-6)
        XCTAssertEqual(meta.height, 0.3, accuracy: 1e-6)

        // Capture device point round trip
        let pt = CGPoint(x: 0.35, y: 0.65)
        let devPt = CompositionPureCalculations.uprightToCaptureDevicePoint(pt)
        XCTAssertEqual(devPt.x, 0.65, accuracy: 1e-6)
        XCTAssertEqual(devPt.y, 0.65, accuracy: 1e-6) // 1.0 - 0.35 = 0.65
    }

    // MARK: - Test #6: Tieu cu Intrinsics tu fovLong
    func testCameraIntrinsicsCalculation() {
        let fovLong = 69.0 // do
        let aspect = 0.75   // 3:4 portrait
        let intr = CompositionPureCalculations.calculateIntrinsics(fovLongDegrees: fovLong, aspect: aspect, zoom: 1.0)

        // fy = 0.5 / tan(34.5 deg) ≈ 0.7275
        // fx = fy / 0.75 ≈ 0.9700
        XCTAssertEqual(intr.fy, 0.7275, accuracy: 0.001)
        XCTAssertEqual(intr.fx, 0.9700, accuracy: 0.001)
        XCTAssertEqual(intr.cx, 0.5, accuracy: 1e-9)
        XCTAssertEqual(intr.cy, 0.5, accuracy: 1e-9)
    }

    // MARK: - Test #7: Quay may sang phai 10 do -> vat the dich sang trai
    func testPanRightProjectionShiftAndRoundTrip() {
        let fx = 1.15
        let fy = 0.8625
        let cx = 0.5
        let cy = 0.5

        // Pose quay may sang phai 10 do quanh truc +y thiet bi (goc quay am)
        let angleRad = -10.0 * .pi / 180.0
        let poseRight = simd_quatd(angle: angleRad, axis: SIMD3<Double>(0, 1, 0))

        // Tia the gioi ban dau nhin thang ve phia truoc (0, 0, -1)
        let worldRay = SIMD3<Double>(0, 0, -1)
        let projected = CompositionPureCalculations.projectWorldRayToScreen(
            worldRay: worldRay,
            devicePose: poseRight,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy
        )

        XCTAssertTrue(projected.isInFront)
        // Khi quay may sang phai, vat the tren man hinh phai dich sang trai: x = 0.5 - fx * tan(10 deg)
        let expectedX = 0.5 - fx * tan(10.0 * .pi / 180.0) // ≈ 0.2972
        XCTAssertEqual(projected.point.x, expectedX, accuracy: 1e-4)

        // Round-trip test: point -> ray -> point voi pose don vi
        let testPt = CGPoint(x: 0.35, y: 0.65)
        let ray = CompositionPureCalculations.pointToDeviceRay(point: testPt, fx: fx, fy: fy, cx: cx, cy: cy)
        let back = CompositionPureCalculations.deviceRayToScreenPoint(ray: ray, fx: fx, fy: fy, cx: cx, cy: cy)
        XCTAssertTrue(back.isInFront)
        XCTAssertEqual(Double(back.point.x), Double(testPt.x), accuracy: 1e-9)
        XCTAssertEqual(Double(back.point.y), Double(testPt.y), accuracy: 1e-9)
    }

    // MARK: - Test #9: Tinh toan zoom ly tuong co can bac hai va gioi han mep
    func testContinuousIdealZoomCalculation() {
        let A0 = 0.05
        let desired = 0.34
        let currentZoom = 1.0
        let maxZoom = 5.0

        let idealZoom = CompositionPureCalculations.calculateContinuousIdealZoom(
            currentZoom: currentZoom,
            currentArea: A0,
            desiredArea: desired,
            maxZoom: maxZoom,
            targetPoint: CGPoint(x: 0.5, y: 0.5),
            boxWidth: 0.2,
            boxHeight: 0.25,
            safetyMargin: 0.06
        )

        // k = sqrt(0.34 / 0.05) = sqrt(6.8) ≈ 2.60768
        XCTAssertEqual(idealZoom, 2.6077, accuracy: 0.001)
    }
}
