import Foundation
import CoreGraphics
import simd

/// Cac phep tinh toan hoc thuan tuy (Pure Functions) cho he thong bo cuc AI va bám bắt mục tiêu.
/// Tat ca ham deu doc lap, khong phu thuoc phan cung camera/UI, hoan toan deterministic va co the kiem thu voi XCTest.
public enum CompositionPureCalculations {

    // MARK: - 1. YOLO Box Decoding & Validation
    /// Tinh bounding box nguyen ban tu toa do tam (cx, cy) va kich thuoc (w, h) ma KHONG clamp toa do goc
    public static func decodeYOLORawBox(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        let x = cx - w / 2.0
        let y = cy - h / 2.0
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Tinh ty le dien tich cua rawRect nam ben trong khung hinh don vi [0, 0, 1, 1]
    public static func computeInsideUnitRatio(rawRect: CGRect) -> Double {
        guard rawRect.width > 0, rawRect.height > 0,
              rawRect.minX.isFinite, rawRect.minY.isFinite,
              rawRect.width.isFinite, rawRect.height.isFinite else { return 0.0 }
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = rawRect.intersection(unitRect)
        guard !visible.isNull, !visible.isEmpty else { return 0.0 }
        let visibleArea = Double(visible.width * visible.height)
        let totalArea = Double(rawRect.width * rawRect.height)
        return totalArea > 0 ? (visibleArea / totalArea) : 0.0
    }

    /// Kiem tra tinh hop le va cat phan hien thi cua box trong khung don vi
    public static func validateAndClipBox(
        rawRect: CGRect,
        minDimension: CGFloat = CompositionTuning.minBoxDimension,
        maxDimension: CGFloat = CompositionTuning.maxBoxDimension,
        minAspect: CGFloat = CompositionTuning.minAspectRatio,
        maxAspect: CGFloat = CompositionTuning.maxAspectRatio,
        minVisibleFraction: CGFloat = CompositionTuning.minVisibleAreaFraction
    ) -> CGRect? {
        guard rawRect.minX.isFinite, rawRect.minY.isFinite,
              rawRect.width.isFinite, rawRect.height.isFinite,
              rawRect.width > 0, rawRect.height > 0 else { return nil }
        
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = rawRect.intersection(unitRect)
        guard !visible.isNull, !visible.isEmpty else { return nil }

        let insideRatio = Double(visible.width * visible.height) / Double(rawRect.width * rawRect.height)
        guard insideRatio >= Double(minVisibleFraction) else { return nil }

        guard visible.width >= minDimension, visible.height >= minDimension,
              visible.width <= maxDimension, visible.height <= maxDimension else { return nil }

        let aspect = visible.width / max(0.001, visible.height)
        guard aspect >= minAspect && aspect <= maxAspect else { return nil }

        return visible
    }

    // MARK: - 2. Coordinate System Normalization
    /// Chuyen doi bounding box tu he toa do Vision (goc duoi-trai, y huong len) sang he toa do Upright (goc tren-trai, y huong xuong)
    public static func visionToUprightRect(_ visionRect: CGRect) -> CGRect {
        return CGRect(
            x: visionRect.minX,
            y: 1.0 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    /// Chuyen doi nguoc tu he toa do Upright ve Vision
    public static func uprightToVisionRect(_ uprightRect: CGRect) -> CGRect {
        return CGRect(
            x: uprightRect.minX,
            y: 1.0 - uprightRect.maxY,
            width: uprightRect.width,
            height: uprightRect.height
        )
    }

    /// Chuyen doi tu toa do metadata cua Apple (AVCaptureMetadataOutput cam sau anh doc) sang Upright
    public static func appleMetadataToUprightRect(_ metadataBounds: CGRect) -> CGRect {
        return CGRect(
            x: metadataBounds.origin.y,
            y: 1.0 - metadataBounds.origin.x - metadataBounds.size.width,
            width: metadataBounds.size.height,
            height: metadataBounds.size.width
        )
    }

    /// Chuyen doi bounding box tu toa do Upright sang metadataOutputRect cua AVCaptureVideoPreviewLayer
    public static func uprightToMetadataOutputRect(_ uprightRect: CGRect) -> CGRect {
        guard !uprightRect.isEmpty, !uprightRect.isNull else { return .zero }
        let metaX = max(0.0, min(1.0, uprightRect.minY))
        let metaY = max(0.0, min(1.0, 1.0 - uprightRect.maxX))
        let metaW = max(0.0, min(1.0 - metaX, uprightRect.height))
        let metaH = max(0.0, min(1.0 - metaY, uprightRect.width))
        return CGRect(x: metaX, y: metaY, width: metaW, height: metaH)
    }

    /// Chuyen doi diem Upright sang toa do captureDevicePoint cua AVCaptureVideoPreviewLayer
    public static func uprightToCaptureDevicePoint(_ uprightPoint: CGPoint) -> CGPoint {
        return CGPoint(x: uprightPoint.y, y: 1.0 - uprightPoint.x)
    }

    // MARK: - 3. Letterbox Coordinates Unpadding (Vision .scaleFit)
    /// Hoan nguyen toa do chuan hoa bi them vien den khi tien xu ly .scaleFit
    /// - sourceAspect: Ty le anh goc (vi du 3.0 / 4.0 = 0.75 cho anh doc)
    /// - modelAspect: Ty le input cua model (vi du 1.0 cho 640x640)
    public static func unpadLetterbox(
        normalizedRect: CGRect,
        sourceWidth: Double,
        sourceHeight: Double,
        modelSize: Double = 640.0
    ) -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0, modelSize > 0 else { return normalizedRect }
        let scale = min(modelSize / sourceWidth, modelSize / sourceHeight)
        let validW = sourceWidth * scale
        let validH = sourceHeight * scale
        let padX = (modelSize - validW) / 2.0
        let padY = (modelSize - validH) / 2.0

        let pixelX = Double(normalizedRect.minX) * modelSize
        let pixelY = Double(normalizedRect.minY) * modelSize
        let pixelW = Double(normalizedRect.width) * modelSize
        let pixelH = Double(normalizedRect.height) * modelSize

        let unpaddedX = (pixelX - padX) / validW
        let unpaddedY = (pixelY - padY) / validH
        let unpaddedW = pixelW / validW
        let unpaddedH = pixelH / validH

        return CGRect(
            x: max(0.0, min(1.0, unpaddedX)),
            y: max(0.0, min(1.0, unpaddedY)),
            width: max(0.0, min(1.0, unpaddedW)),
            height: max(0.0, min(1.0, unpaddedH))
        )
    }

    // MARK: - 3. Camera Intrinsics Calculation
    /// Tinh toan tieu cu chuan hoa (fx, fy) tu goc nhin thuc te cua camera
    /// - fovLongDegrees: Goc nhin canh dai (videoFieldOfView cua cam sau) theo do
    /// - aspect: Ty le chieu rong / chieu cao cua buffer anh doc (vi du 3.0 / 4.0 = 0.75)
    public static func calculateIntrinsics(
        fovLongDegrees: Double,
        aspect: Double = CompositionTuning.fallbackBufferAspectRatio,
        zoom: Double = 1.0
    ) -> (fx: Double, fy: Double, cx: Double, cy: Double) {
        let fovRad = fovLongDegrees * .pi / 180.0
        let effectiveZoom = max(0.1, zoom)
        // fy tinh theo canh doc dai (height), fx tinh theo canh ngang ngan (width)
        let fy = (0.5 / tan(fovRad / 2.0)) * effectiveZoom
        let fx = fy / max(0.001, aspect)
        return (fx: fx, fy: fy, cx: 0.5, cy: 0.5)
    }

    // MARK: - 4. Continuous Ideal Zoom Calculation with Edge Constraints
    /// Tinh muc zoom ly tuong dua tren dien tich mong muon va rang buoc mep an toan
    public static func calculateContinuousIdealZoom(
        currentZoom: Double,
        currentArea: Double,
        desiredArea: Double,
        maxZoom: Double,
        targetPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        boxWidth: Double = 0.2,
        boxHeight: Double = 0.3,
        safetyMargin: Double = CompositionTuning.edgeSafetyMargin
    ) -> Double {
        guard currentArea > 0.0001, desiredArea > 0, currentZoom > 0 else { return currentZoom }
        
        // 1. Tinh ty le zoom ly tuong tu dien tich (dien tich tang k^2 nen zoom tang k = sqrt(ratio))
        let idealRatio = sqrt(desiredArea / currentArea)
        var zoomCandidate = currentZoom * idealRatio

        // 2. Rang buoc mep an toan: khong duoc zoom vuot qua gioi han lam box bi chém cut khoi man hinh
        if boxWidth > 0 && boxHeight > 0 {
            let maxRatioX = (2.0 * min(Double(targetPoint.x) - safetyMargin, 1.0 - safetyMargin - Double(targetPoint.x))) / boxWidth
            let maxRatioY = (2.0 * min(Double(targetPoint.y) - safetyMargin, 1.0 - safetyMargin - Double(targetPoint.y))) / boxHeight
            let maxAllowedRatio = max(1.0, min(maxRatioX, maxRatioY))
            zoomCandidate = min(zoomCandidate, currentZoom * maxAllowedRatio)
        }

        // 3. Clamp vao khoang hop le
        return max(currentZoom, min(maxZoom, zoomCandidate))
    }

    // MARK: - 5. 3D Ray Projection & Unprojection
    /// Chuyen doi diem anh chuan hoa [0...1] thanh tia don vi 3D trong he toa do thiet bi
    public static func pointToDeviceRay(point: CGPoint, fx: Double, fy: Double, cx: Double = 0.5, cy: Double = 0.5) -> SIMD3<Double> {
        let rx = (Double(point.x) - cx) / fx
        let ry = -(Double(point.y) - cy) / fy
        let rz = -1.0
        let len = sqrt(rx * rx + ry * ry + rz * rz)
        guard len > 1e-6 else { return SIMD3<Double>(0, 0, -1) }
        return SIMD3<Double>(rx / len, ry / len, rz / len)
    }

    /// Chieu tia 3D nguoc ve mat phang anh man hinh [0...1]
    public static func deviceRayToScreenPoint(ray: SIMD3<Double>, fx: Double, fy: Double, cx: Double = 0.5, cy: Double = 0.5) -> (point: CGPoint, isInFront: Bool) {
        let forward = -ray.z
        if forward > 1e-6 {
            let px = cx + fx * ray.x / forward
            let py = cy - fy * ray.y / forward
            return (point: CGPoint(x: px, y: py), isInFront: true)
        }
        var dx = atan2(ray.x, forward)
        let dy = -atan2(ray.y, hypot(ray.x, forward))
        if abs(dx) + abs(dy) < 1e-8 { dx = .pi }
        let scale = 2.0 / max(abs(dx), abs(dy), 1e-8)
        return (point: CGPoint(x: 0.5 + dx * scale, y: 0.5 + dy * scale), isInFront: false)
    }

    /// Chieu tia the gioi ve man hinh hien tai qua phep quay quaternion
    public static func projectWorldRayToScreen(
        worldRay: SIMD3<Double>,
        devicePose: simd_quatd,
        fx: Double,
        fy: Double,
        cx: Double = 0.5,
        cy: Double = 0.5
    ) -> (point: CGPoint, isInFront: Bool) {
        let normWorldRay = simd_normalize(worldRay)
        let deviceRay = devicePose.inverse.act(normWorldRay)
        return deviceRayToScreenPoint(ray: deviceRay, fx: fx, fy: fy, cx: cx, cy: cy)
    }

    // MARK: - 6. Quaternion Slerp & Pose Interpolation
    /// Noi suy phep quay giua 2 pose theo thuat toan slerp voi kiem tra an toan mau so
    public static func slerpPose(q0: simd_quatd, q1: simd_quatd, t: Double) -> simd_quatd {
        let clampedT = max(0.0, min(1.0, t))
        let norm0 = simd_normalize(q0)
        let norm1 = simd_normalize(q1)
        return simd_slerp(norm0, norm1, clampedT)
    }

    /// Noi suy pose tai thoi diem time tu lich su cac mau TrackingMotionSample
    public static func interpolateHistoricalPose(
        at time: TimeInterval,
        samples: [TrackingMotionSample],
        margin: Double = CompositionTuning.motionInterpolationMargin,
        minDt: Double = CompositionTuning.motionInterpolationMinDt,
        maxDt: Double = CompositionTuning.motionInterpolationMaxDt
    ) -> simd_quatd? {
        guard let first = samples.first, let last = samples.last,
              time >= first.timestamp - margin, time <= last.timestamp + margin else { return nil }
        if time <= first.timestamp { return first.deviceToWorld }
        if time >= last.timestamp { return last.deviceToWorld }
        for i in 1..<samples.count where samples[i].timestamp >= time {
            let a = samples[i - 1], b = samples[i]
            let dt = b.timestamp - a.timestamp
            guard dt > minDt, dt < maxDt else {
                if abs(time - a.timestamp) <= minDt { return a.deviceToWorld }
                return nil
            }
            let t = (time - a.timestamp) / dt
            return slerpPose(q0: a.deviceToWorld, q1: b.deviceToWorld, t: t)
        }
        return nil
    }
}
