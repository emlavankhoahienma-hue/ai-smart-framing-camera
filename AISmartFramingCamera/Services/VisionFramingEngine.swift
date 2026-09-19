import Foundation
import Vision
import CoreMedia
import CoreImage
import CoreGraphics
import QuartzCore
import Accelerate

public final class VisionFramingEngine: @unchecked Sendable {
    public static let shared = VisionFramingEngine()
    
    private let visionQueue = DispatchQueue(
        label: "com.aismartframing.visionQueue",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private let processingLock = NSLock()
    private var _captureNextFrameForGemini = false
    public var captureNextFrameForGemini: Bool {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _captureNextFrameForGemini }
        set { processingLock.lock(); _captureNextFrameForGemini = newValue; processingLock.unlock() }
    }

    private var _isLowTextureAnchor = false
    public var isLowTextureAnchor: Bool {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _isLowTextureAnchor }
        set { processingLock.lock(); _isLowTextureAnchor = newValue; processingLock.unlock() }
    }

    private var _currentSceneType: DetectedSceneType = .general
    public var currentSceneType: DetectedSceneType {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _currentSceneType }
        set { processingLock.lock(); _currentSceneType = newValue; processingLock.unlock() }
    }

    private var isProcessingFrame = false
    private var lastProcessTime: TimeInterval = 0
    private let frameThrottleInterval: TimeInterval = 0.033 // ~30 FPS for ultra-smooth optical tracking
    private var _isIdlePreviewMode: Bool = false
    public var isIdlePreviewMode: Bool {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _isIdlePreviewMode }
        set { processingLock.lock(); _isIdlePreviewMode = newValue; processingLock.unlock() }
    }
    private let idleThrottleInterval: TimeInterval = 0.2 // ~5 FPS lúc rảnh, vẫn đủ mượt cho preview mặt/scene
    
    // Callback references are copied under lock, then invoked after unlock.
    private var _onDetectionCompleted: ((SubjectDetectionResult) -> Void)?
    private var _onTargetTracked: ((CGPoint?, Double, CVPixelBuffer) -> Void)?
    private var _onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)?
    private var _onFrameCapturedForAI: ((CGImage) -> Void)?
    public var onDetectionCompleted: ((SubjectDetectionResult) -> Void)? {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _onDetectionCompleted }
        set { processingLock.lock(); _onDetectionCompleted = newValue; processingLock.unlock() }
    }
    public var onTargetTracked: ((CGPoint?, Double, CVPixelBuffer) -> Void)? {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _onTargetTracked }
        set { processingLock.lock(); _onTargetTracked = newValue; processingLock.unlock() }
    }
    public var onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)? {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _onSmartFocusPointCalculated }
        set { processingLock.lock(); _onSmartFocusPointCalculated = newValue; processingLock.unlock() }
    }
    
    // Gemini Frame Capture
    public var capturedGeminiFrame: CGImage? = nil
    public var onFrameCapturedForAI: ((CGImage) -> Void)? {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _onFrameCapturedForAI }
        set { processingLock.lock(); _onFrameCapturedForAI = newValue; processingLock.unlock() }
    }
    
    // Visual Feature Object Tracking (VNTrackObjectRequest + Deep FeaturePrint Re-ID + Color Histogram + KLT Point Cluster)
    private var _isTrackingTarget: Bool = false
    public private(set) var isTrackingTarget: Bool {
        get { processingLock.lock(); defer { processingLock.unlock() }; return _isTrackingTarget }
        set { processingLock.lock(); _isTrackingTarget = newValue; processingLock.unlock() }
    }
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTargetObservation: VNDetectedObjectObservation? = nil
    private var referenceFeaturePrint: VNFeaturePrintObservation? = nil
    private var referenceColorHistogram: [Float]? = nil
    private var consecutiveLostFrames: Int = 0
    
    // KLT pyramid (Shi-Tomasi seed + forward/backward validation + RANSAC)
    private var kltTrackedPoints: [CGPoint] = []
    private var kltPreviousBuffer: CVPixelBuffer? = nil
    private var kltPreviousPyramid: GrayPyramid? = nil
    private var kltTargetBox: CGRect = .zero
    private var kltTargetCenterUI: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // Xác minh danh tính vật thể liên tuyến (chống tracker trôi sang vật thể khác)
    private var lastVerifiedUIPoint: CGPoint? = nil
    private var identitySuspicionFrames: Int = 0
    private var histogramCheckCounter: Int = 0
    private var histogramMismatchStreak: Int = 0
    private var featurePrintCheckCounter: Int = 0
    private var detectionCorrectionCounter: Int = 0
    private var stableLockFrames: Int = 0
    private var voReferenceCounter: Int = 0
    private var anchorBoxSize: CGSize = CGSize(width: 0.14, height: 0.14)
    private var initialAnchorBoxSize: CGSize = CGSize(width: 0.14, height: 0.14)
    private var lastReIdAttemptTime: CFTimeInterval = 0
    private var shortTermFeaturePrint: VNFeaturePrintObservation? = nil
    private var shortTermColorHistogram: [Float]? = nil

    /// Một level ảnh xám liên tục trong RAM. Level 0 có cạnh dài tối đa 320 px;
    /// hai level sau giảm 2x bằng box filter, đủ bắt displacement 40-50 px ở ảnh
    /// camera gốc mà chỉ tiêu tốn một phần nhỏ bandwidth/CPU.
    private struct GrayLevel: Sendable {
        let width: Int
        let height: Int
        let pixels: [Float]

        @inline(__always)
        func sample(x: Double, y: Double) -> Float? {
            guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
            let x0 = Int(x)
            let y0 = Int(y)
            let fx = Float(x - Double(x0))
            let fy = Float(y - Double(y0))
            let i = y0 * width + x0
            let a = pixels[i] * (1 - fx) + pixels[i + 1] * fx
            let b = pixels[i + width] * (1 - fx) + pixels[i + width + 1] * fx
            return a * (1 - fy) + b * fy
        }
    }

    private struct GrayPyramid: Sendable {
        let levels: [GrayLevel]

        init?(pixelBuffer: CVPixelBuffer) {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

            let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
            let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
            let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let samplingStep = max(1, Int(ceil(Double(max(sourceWidth, sourceHeight)) / 320.0)))
            let width = max(16, sourceWidth / samplingStep)
            let height = max(16, sourceHeight / samplingStep)
            var basePixels = [Float](repeating: 0, count: width * height)

            for y in 0..<height {
                let sourceY = min(sourceHeight - 1, y * samplingStep)
                for x in 0..<width {
                    let sourceX = min(sourceWidth - 1, x * samplingStep)
                    let offset = sourceY * sourceStride + sourceX * 4
                    let b = Float(bytes[offset])
                    let g = Float(bytes[offset + 1])
                    let r = Float(bytes[offset + 2])
                    basePixels[y * width + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }

            var built = [GrayLevel(width: width, height: height, pixels: basePixels)]
            for _ in 1..<3 {
                guard let previous = built.last, previous.width >= 16, previous.height >= 16 else { break }
                let nextWidth = previous.width / 2
                let nextHeight = previous.height / 2
                var next = [Float](repeating: 0, count: nextWidth * nextHeight)
                for y in 0..<nextHeight {
                    for x in 0..<nextWidth {
                        let source = (y * 2) * previous.width + x * 2
                        next[y * nextWidth + x] = 0.25 * (
                            previous.pixels[source] + previous.pixels[source + 1]
                            + previous.pixels[source + previous.width]
                            + previous.pixels[source + previous.width + 1]
                        )
                    }
                }
                built.append(GrayLevel(width: nextWidth, height: nextHeight, pixels: next))
            }
            levels = built
        }
    }
    
    // Vision Detection Requests
    private lazy var faceDetectionRequest: VNDetectFaceRectanglesRequest = {
        let req = VNDetectFaceRectanglesRequest()
        req.revision = VNDetectFaceRectanglesRequestRevision3
        return req
    }()
    
    private lazy var faceLandmarksRequest: VNDetectFaceLandmarksRequest = {
        let req = VNDetectFaceLandmarksRequest()
        req.revision = VNDetectFaceLandmarksRequestRevision3
        return req
    }()
    
    private lazy var humanPoseRequest: VNDetectHumanBodyPoseRequest = {
        let req = VNDetectHumanBodyPoseRequest()
        req.revision = VNDetectHumanBodyPoseRequestRevision1
        return req
    }()
    
    private lazy var saliencyRequest: VNGenerateObjectnessBasedSaliencyImageRequest = {
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        req.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
        return req
    }()
    
    private lazy var sceneClassificationRequest: VNClassifyImageRequest = {
        let req = VNClassifyImageRequest()
        req.revision = VNClassifyImageRequestRevision1
        return req
    }()
    
    public init() {}
    
    // MARK: - Visual Object Tracking Control
    private var currentTrackRequest: VNTrackObjectRequest? = nil
    
    /// Tinh chỉnh Bounding Box mỏ neo ban đầu ôm khít chủ thể thật thay vì dùng box vuông cố định
    /// Sử dụng Objectness Saliency và Human Body Pose / Face detection
    public func refineAnchorBox(
        around tapUIPoint: CGPoint,
        in buffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> CGRect? {
        let tapVision = CGPoint(x: tapUIPoint.x, y: 1.0 - tapUIPoint.y)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        
        // 1. Ưu tiên kiểm tra Human Body Pose nếu điểm chạm thuộc về người
        let poseReq = VNDetectHumanBodyPoseRequest()
        poseReq.revision = VNDetectHumanBodyPoseRequestRevision1
        if (try? handler.perform([poseReq])) != nil,
           let observations = poseReq.results, !observations.isEmpty {
            for obs in observations {
                if let recognizedPoints = try? obs.recognizedPoints(.all) {
                    let validPoints = recognizedPoints.values.filter { $0.confidence > 0.25 }.map { $0.location }
                    guard !validPoints.isEmpty else { continue }
                    
                    let xs = validPoints.map { $0.x }
                    let ys = validPoints.map { $0.y }
                    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
                    
                    let bodyBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    let paddedBody = bodyBox.insetBy(dx: -max(0.04, bodyBox.width * 0.08), dy: -max(0.04, bodyBox.height * 0.08))
                    
                    if paddedBody.insetBy(dx: -0.04, dy: -0.04).contains(tapVision) {
                        let w = min(0.65, max(0.12, paddedBody.width))
                        let h = min(0.75, max(0.15, paddedBody.height))
                        return CGRect(
                            x: min(1.0 - w, max(0.01, paddedBody.midX - w / 2.0)),
                            y: min(1.0 - h, max(0.01, paddedBody.midY - h / 2.0)),
                            width: w,
                            height: h
                        )
                    }
                }
            }
        }
        
        // 2. Kiểm tra Face Detection nếu chạm vào mặt hoặc đầu
        let faceReq = VNDetectFaceRectanglesRequest()
        faceReq.revision = VNDetectFaceRectanglesRequestRevision3
        if (try? handler.perform([faceReq])) != nil,
           let faceResults = faceReq.results, !faceResults.isEmpty {
            for face in faceResults {
                if face.boundingBox.insetBy(dx: -0.04, dy: -0.04).contains(tapVision) {
                    let faceBox = face.boundingBox
                    let w = min(0.60, max(0.14, faceBox.width * 1.8))
                    let h = min(0.70, max(0.18, faceBox.height * 2.5))
                    return CGRect(
                        x: min(1.0 - w, max(0.01, faceBox.midX - w / 2.0)),
                        y: min(1.0 - h, max(0.01, faceBox.midY - h * 0.4)),
                        width: w,
                        height: h
                    )
                }
            }
        }
        
        // 3. Objectness-based Saliency (Đồ vật, thú cưng, chi tiết nổi bật)
        let salReq = VNGenerateObjectnessBasedSaliencyImageRequest()
        salReq.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
        if (try? handler.perform([salReq])) != nil,
           let result = salReq.results?.first as? VNSaliencyImageObservation,
           let objects = result.salientObjects, !objects.isEmpty {
            let candidates = objects.filter { $0.boundingBox.insetBy(dx: -0.03, dy: -0.03).contains(tapVision) }
            if let best = candidates.max(by: { $0.confidence < $1.confidence }) {
                let w = min(0.65, max(0.10, best.boundingBox.width * 1.15))
                let h = min(0.65, max(0.10, best.boundingBox.height * 1.15))
                return CGRect(
                    x: min(1.0 - w, max(0.01, best.boundingBox.midX - w / 2.0)),
                    y: min(1.0 - h, max(0.01, best.boundingBox.midY - h / 2.0)),
                    width: w,
                    height: h
                )
            }
        }
        
        return nil
    }
    
    /// Khởi động tracking bám dính vào vùng cảnh vật/vật thể/chữ tại toạ độ mục tiêu
    public func startTrackingObject(
        at normalizedPoint: CGPoint,
        size: CGSize = CGSize(width: 0.12, height: 0.12),
        refiningBuffer: CVPixelBuffer? = nil,
        orientation: CGImagePropertyOrientation = .up
    ) {
        var targetPoint = normalizedPoint
        var targetSize = size

        if let buffer = refiningBuffer,
           let refinedBox = refineAnchorBox(around: normalizedPoint, in: buffer, orientation: orientation) {
            let boxCenterUI = CGPoint(x: refinedBox.midX, y: 1.0 - refinedBox.midY)
            let dist = hypot(boxCenterUI.x - normalizedPoint.x, boxCenterUI.y - normalizedPoint.y)
            if dist < 0.15 {
                targetPoint = boxCenterUI
            }
            targetSize = CGSize(width: refinedBox.width, height: refinedBox.height)
            CameraLogger.info("🎯 [Vision] Đã tinh chỉnh Anchor Box ôm khít chủ thể: tâm=(\(String(format: "%.3f", targetPoint.x)), \(String(format: "%.3f", targetPoint.y))), size: \(targetSize)", category: .tracking)
        }
        
        // Convert UI coordinate (top-left origin) to Vision coordinate (bottom-left origin)
        // Kẹp TÂM box trong frame (thay vì kẹp origin) để box lớn gần mép không bị thò ra ngoài
        let halfW = targetSize.width / 2.0
        let halfH = targetSize.height / 2.0
        let centerX = min(1.0 - halfW - 0.005, max(halfW + 0.005, targetPoint.x))
        let centerYVision = min(1.0 - halfH - 0.005, max(halfH + 0.005, 1.0 - targetPoint.y))
        
        let clampedRect = CGRect(
            x: centerX - halfW,
            y: centerYVision - halfH,
            width: targetSize.width,
            height: targetSize.height
        )

        // Lấy immutable identity template từ đúng frame người dùng/AI pin. Nếu
        // chờ frame kế tiếp, một fast-pan ngay lập tức có thể lấy nhầm background.
        let seedFeaturePrint = refiningBuffer.flatMap {
            extractFeaturePrint(from: $0, regionOfInterest: clampedRect)
        }
        let seedHistogram = refiningBuffer.map {
            extractColorHistogram(from: $0, region: clampedRect)
        }
        let seedPyramid = refiningBuffer.flatMap { GrayPyramid(pixelBuffer: $0) }
        if let buffer = refiningBuffer {
            VisualOdometryEngine.shared.setReferenceFrame(buffer, atUIPoint: targetPoint)
        }
        
        visionQueue.sync {
        let initialObservation = VNDetectedObjectObservation(boundingBox: clampedRect)
        self.lastTargetObservation = initialObservation
        
        // Chuẩn Apple WWDC: Khởi tạo VNTrackObjectRequest ĐÚNG 1 LẦN DUY NHẤT để tích lũy bộ nhớ tracking
        let req = VNTrackObjectRequest(detectedObjectObservation: initialObservation)
        req.trackingLevel = .accurate
        self.currentTrackRequest = req
        
        self.referenceFeaturePrint = seedFeaturePrint
        self.referenceColorHistogram = seedHistogram
        self.shortTermFeaturePrint = seedFeaturePrint
        self.shortTermColorHistogram = seedHistogram
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.kltPreviousPyramid = seedPyramid
        self.kltTargetBox = clampedRect
        self.kltTargetCenterUI = targetPoint
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
        // Reset toàn bộ trạng thái xác minh danh tính & re-acquisition
        self.lastVerifiedUIPoint = targetPoint
        self.identitySuspicionFrames = 0
        self.histogramCheckCounter = 0
        self.histogramMismatchStreak = 0
        self.featurePrintCheckCounter = 0
        self.detectionCorrectionCounter = 0
        self.stableLockFrames = 0
        self.voReferenceCounter = 0
        self.anchorBoxSize = targetSize
        self.initialAnchorBoxSize = targetSize
        self.lastReIdAttemptTime = 0
        self.isTrackingTarget = true
        CameraLogger.info("🎯 [Vision] Khởi tạo VNTrackObjectRequest duy nhất tại: (\(String(format: "%.3f", targetPoint.x)), \(String(format: "%.3f", targetPoint.y))), size: \(targetSize)", category: .tracking)
        }
    }
    
    public func stopTrackingObject() {
        visionQueue.sync {
        self.isTrackingTarget = false
        self.currentTrackRequest?.isLastFrame = true
        self.currentTrackRequest = nil
        self.lastTargetObservation = nil
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.shortTermFeaturePrint = nil
        self.shortTermColorHistogram = nil
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.kltPreviousPyramid = nil
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
        self.lastVerifiedUIPoint = nil
        self.identitySuspicionFrames = 0
        self.histogramCheckCounter = 0
        self.histogramMismatchStreak = 0
        self.featurePrintCheckCounter = 0
        self.detectionCorrectionCounter = 0
        self.stableLockFrames = 0
        self.voReferenceCounter = 0
        self.lastReIdAttemptTime = 0
        VisualOdometryEngine.shared.clearReference()
        CameraLogger.info("🎯 [Vision] Đã dừng và giải phóng VNTrackObjectRequest", category: .tracking)
        }
    }
    
    // MARK: - Pyramidal Lucas-Kanade + forward/backward consistency

    private func uiRect(fromVisionRect rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1.0 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Shi-Tomasi: `lambdaMin(G)` đo texture theo hai hướng trong cửa sổ 5x5.
    /// Chỉ giữ local maxima cách nhau >= 6 px để ma trận LK không bị suy biến và
    /// tránh 30 điểm cùng nằm trên một cạnh thẳng của vật thể.
    private func extractKLTFeaturePoints(in visionROI: CGRect, pyramid: GrayPyramid) -> [CGPoint] {
        guard let level = pyramid.levels.first else { return [] }
        let roi = uiRect(fromVisionRect: visionROI)
        let minX = max(4, Int(roi.minX * CGFloat(level.width)))
        let maxX = min(level.width - 5, Int(roi.maxX * CGFloat(level.width)))
        let minY = max(4, Int(roi.minY * CGFloat(level.height)))
        let maxY = min(level.height - 5, Int(roi.maxY * CGFloat(level.height)))
        guard maxX - minX >= 8, maxY - minY >= 8 else { return [] }

        var candidates: [(CGPoint, Float)] = []
        let scanStep = max(2, min(maxX - minX, maxY - minY) / 18)
        for y in stride(from: minY, through: maxY, by: scanStep) {
            for x in stride(from: minX, through: maxX, by: scanStep) {
                var gxx: Float = 0
                var gxy: Float = 0
                var gyy: Float = 0
                for wy in -2...2 {
                    for wx in -2...2 {
                        guard let left = level.sample(x: Double(x + wx - 1), y: Double(y + wy)),
                              let right = level.sample(x: Double(x + wx + 1), y: Double(y + wy)),
                              let up = level.sample(x: Double(x + wx), y: Double(y + wy - 1)),
                              let down = level.sample(x: Double(x + wx), y: Double(y + wy + 1)) else { continue }
                        let gx = 0.5 * (right - left)
                        let gy = 0.5 * (down - up)
                        gxx += gx * gx
                        gxy += gx * gy
                        gyy += gy * gy
                    }
                }
                let trace = gxx + gyy
                let discriminant = sqrt(max(0, (gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy))
                let lambdaMin = 0.5 * (trace - discriminant)
                if lambdaMin > 120 {
                    let nx = CGFloat(x) / CGFloat(max(1, level.width - 1))
                    let ny = CGFloat(y) / CGFloat(max(1, level.height - 1))
                    let centerDistance = hypot(nx - roi.midX, ny - roi.midY)
                    let centerWeight = Float(max(0.35, 1.0 - centerDistance / max(0.03, max(roi.width, roi.height))))
                    candidates.append((CGPoint(x: nx, y: ny), lambdaMin * centerWeight))
                }
            }
        }

        candidates.sort { $0.1 > $1.1 }
        var selected: [CGPoint] = []
        let minDistance = CGFloat(6.0 / Double(max(level.width, level.height)))
        for candidate in candidates {
            if selected.allSatisfy({ hypot($0.x - candidate.0.x, $0.y - candidate.0.y) > minDistance }) {
                selected.append(candidate.0)
                if selected.count == 28 { break }
            }
        }
        return selected
    }

    /// Một pass coarse-to-fine LK. Với brightness constancy
    /// `I1(p) = I2(p+d)`, mỗi iteration giải normal equation
    /// `(J'J) delta = J'(I1-I2)` cho vector dịch 2-D.
    private func trackPoint(_ point: CGPoint, from source: GrayPyramid, to destination: GrayPyramid) -> CGPoint? {
        let levelCount = min(source.levels.count, destination.levels.count)
        guard levelCount > 0 else { return nil }
        var flowX = 0.0
        var flowY = 0.0

        for levelIndex in stride(from: levelCount - 1, through: 0, by: -1) {
            let a = source.levels[levelIndex]
            let b = destination.levels[levelIndex]
            if levelIndex < levelCount - 1 {
                flowX *= 2
                flowY *= 2
            }
            let px = Double(point.x) * Double(max(1, a.width - 1))
            let py = Double(point.y) * Double(max(1, a.height - 1))

            for _ in 0..<6 {
                var gxx = 0.0
                var gxy = 0.0
                var gyy = 0.0
                var bx = 0.0
                var by = 0.0
                var samples = 0

                for wy in -3...3 {
                    for wx in -3...3 {
                        let sx = px + Double(wx)
                        let sy = py + Double(wy)
                        let dx = sx + flowX
                        let dy = sy + flowY
                        guard let sourceValue = a.sample(x: sx, y: sy),
                              let destinationValue = b.sample(x: dx, y: dy),
                              let left = b.sample(x: dx - 1, y: dy),
                              let right = b.sample(x: dx + 1, y: dy),
                              let up = b.sample(x: dx, y: dy - 1),
                              let down = b.sample(x: dx, y: dy + 1) else { continue }
                        let gx = 0.5 * Double(right - left)
                        let gy = 0.5 * Double(down - up)
                        let error = Double(sourceValue - destinationValue)
                        gxx += gx * gx
                        gxy += gx * gy
                        gyy += gy * gy
                        bx += gx * error
                        by += gy * error
                        samples += 1
                    }
                }

                let determinant = gxx * gyy - gxy * gxy
                guard samples >= 25, determinant > 1.0e-3, gxx + gyy > 30 else { return nil }
                let deltaX = (gyy * bx - gxy * by) / determinant
                let deltaY = (-gxy * bx + gxx * by) / determinant
                guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) < 6, abs(deltaY) < 6 else { return nil }
                flowX += deltaX
                flowY += deltaY
                if deltaX * deltaX + deltaY * deltaY < 0.0025 { break }
            }
        }

        guard let base = destination.levels.first else { return nil }
        let outX = Double(point.x) * Double(max(1, base.width - 1)) + flowX
        let outY = Double(point.y) * Double(max(1, base.height - 1)) + flowY
        guard outX >= 3, outY >= 3, outX < Double(base.width - 4), outY < Double(base.height - 4) else { return nil }
        return CGPoint(
            x: CGFloat(outX / Double(max(1, base.width - 1))),
            y: CGFloat(outY / Double(max(1, base.height - 1)))
        )
    }

    private func trackKLTCluster(currentPyramid: GrayPyramid) -> (uiPoint: CGPoint, confidence: Double)? {
        guard !kltTrackedPoints.isEmpty, let previous = kltPreviousPyramid,
              let base = currentPyramid.levels.first else { return nil }

        var accepted: [(old: CGPoint, new: CGPoint, fb: Double)] = []
        for point in kltTrackedPoints {
            guard let forward = trackPoint(point, from: previous, to: currentPyramid),
                  let backward = trackPoint(forward, from: currentPyramid, to: previous) else { continue }
            let fbPixels = hypot(
                Double(backward.x - point.x) * Double(base.width),
                Double(backward.y - point.y) * Double(base.height)
            )
            if fbPixels <= 1.5 { accepted.append((point, forward, fbPixels)) }
        }
        guard accepted.count >= 5 else { return nil }

        let dxs = accepted.map { $0.new.x - $0.old.x }.sorted()
        let dys = accepted.map { $0.new.y - $0.old.y }.sorted()
        let medianDX = dxs[dxs.count / 2]
        let medianDY = dys[dys.count / 2]
        let ransacThreshold = max(0.006, 2.5 / CGFloat(max(base.width, base.height)))
        let inliers = accepted.filter {
            hypot(($0.new.x - $0.old.x) - medianDX, ($0.new.y - $0.old.y) - medianDY) <= ransacThreshold
        }
        guard inliers.count >= 4 else { return nil }

        let originalCount = kltTrackedPoints.count
        kltTrackedPoints = inliers.map { $0.new }
        kltTargetCenterUI = CGPoint(
            x: kltTargetCenterUI.x + medianDX,
            y: kltTargetCenterUI.y + medianDY
        )
        let inlierRatio = Double(inliers.count) / Double(max(1, originalCount))
        let meanFB = inliers.reduce(0.0) { $0 + $1.fb } / Double(inliers.count)
        let confidence = max(0.28, min(0.62, 0.30 + 0.38 * inlierRatio - 0.07 * meanFB))
        return (kltTargetCenterUI, confidence)
    }
    
    private func extractFeaturePrint(from buffer: CVPixelBuffer, regionOfInterest: CGRect) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        req.imageCropAndScaleOption = .scaleFit
        req.regionOfInterest = CGRect(
            x: max(0, min(0.9, regionOfInterest.origin.x)),
            y: max(0, min(0.9, regionOfInterest.origin.y)),
            width: max(0.05, min(1.0, regionOfInterest.size.width)),
            height: max(0.05, min(1.0, regionOfInterest.size.height))
        )
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([req])
            return req.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }
    
    private func extractColorHistogram(from buffer: CVPixelBuffer, region: CGRect) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return Array(repeating: 0, count: 24) }
        
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        var hist = Array(repeating: Float(0), count: 24)
        var totalPixels: Float = 0
        
        let minX = max(0, min(width - 1, Int(region.origin.x * CGFloat(width))))
        let minY = max(0, min(height - 1, Int((1.0 - region.origin.y - region.size.height) * CGFloat(height))))
        let maxX = max(minX + 1, min(width, Int((region.origin.x + region.size.width) * CGFloat(width))))
        let maxY = max(minY + 1, min(height, Int((1.0 - region.origin.y) * CGFloat(height))))
        
        let step = max(1, (maxX - minX) / 16)
        
        for y in stride(from: minY, to: maxY, by: max(1, step)) {
            for x in stride(from: minX, to: maxX, by: max(1, step)) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(data[offset])
                let g = Float(data[offset + 1])
                let r = Float(data[offset + 2])
                
                let rBin = min(7, Int(r / 32))
                let gBin = min(7, Int(g / 32)) + 8
                let bBin = min(7, Int(b / 32)) + 16
                
                hist[rBin] += 1
                hist[gBin] += 1
                hist[bBin] += 1
                totalPixels += 3
            }
        }
        
        if totalPixels > 0 {
            for i in 0..<24 {
                hist[i] /= totalPixels
            }
        }
        return hist
    }
    
    private func compareColorHistograms(_ h1: [Float], _ h2: [Float]) -> Float {
        guard h1.count == h2.count && !h1.isEmpty else { return 0 }
        var bhattacharyya: Float = 0
        for i in 0..<h1.count {
            bhattacharyya += sqrt(max(0, h1[i] * h2[i]))
        }
        return bhattacharyya
    }
    
    private func extractSaliencyCentroid(from buffer: CVPixelBuffer, near visionBox: CGRect) -> CGPoint? {
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do {
            try handler.perform([req])
            if let result = req.results?.first as? VNSaliencyImageObservation,
               let salientObjects = result.salientObjects {
                let boxCenter = CGPoint(x: visionBox.midX, y: visionBox.midY)
                var closestCentroid: CGPoint? = nil
                var minDistance: CGFloat = CGFloat.greatestFiniteMagnitude
                
                for obj in salientObjects {
                    let objCenter = CGPoint(x: obj.boundingBox.midX, y: obj.boundingBox.midY)
                    let d = hypot(objCenter.x - boxCenter.x, objCenter.y - boxCenter.y)
                    // Chỉ cho phép hút cực hẹp trong phạm vi chính vật thể đó (d < 0.08)
                    if d < minDistance && d < 0.08 {
                        minDistance = d
                        closestCentroid = objCenter
                    }
                }
                return closestCentroid
            }
        } catch {
            return nil
        }
        return nil
    }
    
    /// Tái chiếm target sau khi mất dấu — chỉ nhận khi ứng viên TỐT HƠN RÕ RỆT so với các ứng viên còn lại
    /// (margin chống mơ hồ) để tránh bám nhầm sang vật thể khác nằm gần đó (đặc biệt vật thể trắng/nền trắng).
    /// - searchCenter: tâm tìm kiếm (trung điểm giữa vị trí quang học cuối đã xác nhận và ước lượng không gian)
    /// - anchorSize: kích thước box gốc lúc pin (không dùng box cố định)
    private func attemptNeuralReIdentification(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, searchCenter: CGPoint, anchorSize: CGSize) -> (CGPoint, Double, CGRect)? {
        guard let longTermPrint = referenceFeaturePrint else { return nil }

        struct CheapCandidate {
            let box: CGRect
            let point: CGPoint
            let color: Double
            let prior: Double
        }
        struct VerifiedCandidate {
            let box: CGRect
            let point: CGPoint
            let distance: Float
            let color: Double
            let neural: Double
            let score: Double
        }

        let uncertainty = SpatialTrackingEngine.shared.currentUncertaintyRadius
        let lostExpansion = min(CGFloat(0.10), CGFloat(consecutiveLostFrames) * 0.0015)
        let radius = min(CGFloat(0.24), max(CGFloat(0.06), uncertainty * 1.25 + lostExpansion))
        let offsets: [CGFloat] = [-radius, -radius * 0.5, 0, radius * 0.5, radius]
        let zoomScale = min(CGFloat(3.0), max(CGFloat(0.5), SpatialTrackingEngine.shared.relativeZoomSinceAnchor))
        // Năm mức scale cục bộ bao phủ cả optical zoom lẫn chủ thể tiến/lùi; deep
        // FeaturePrint vẫn chỉ chạy trên 6 ROI tốt nhất nên không tăng peak cost.
        let scales: [CGFloat] = [0.55, 0.78, 1.0, 1.35, 1.75].map { $0 * zoomScale }
        let minimumColor = isLowTextureAnchor ? 0.60 : 0.52

        var cheap: [CheapCandidate] = []
        for scale in scales {
            let boxW = max(0.07, min(0.55, anchorSize.width * scale))
            let boxH = max(0.07, min(0.65, anchorSize.height * scale))
            for dy in offsets {
                for dx in offsets {
                    let uiPoint = CGPoint(
                        x: min(0.97, max(0.03, searchCenter.x + dx)),
                        y: min(0.97, max(0.03, searchCenter.y + dy))
                    )
                    let box = CGRect(
                        x: max(0.005, min(0.995 - boxW, uiPoint.x - boxW * 0.5)),
                        y: max(0.005, min(0.995 - boxH, (1.0 - uiPoint.y) - boxH * 0.5)),
                        width: boxW,
                        height: boxH
                    )
                    let histogram = extractColorHistogram(from: buffer, region: box)
                    let longColor = referenceColorHistogram.map {
                        Double(compareColorHistograms($0, histogram))
                    } ?? 1
                    let shortColor = shortTermColorHistogram.map {
                        Double(compareColorHistograms($0, histogram))
                    } ?? longColor
                    let color = max(longColor, shortColor)
                    guard color >= minimumColor else { continue }
                    let normalizedDistance = min(1.0, Double(hypot(dx, dy) / max(0.001, radius)))
                    let scalePenalty = abs(log(Double(scale))) * 0.08
                    cheap.append(CheapCandidate(
                        box: box,
                        point: uiPoint,
                        color: color,
                        prior: color - 0.10 * normalizedDistance - scalePenalty
                    ))
                }
            }
        }

        // FeaturePrint chỉ chạy cho tối đa 6 ROI đã qua cheap color/spatial gate.
        // Đây là chỗ giữ thermal budget ổn định khi re-ID mở rộng đến 0.24 frame.
        let shortlist = cheap.sorted { $0.prior > $1.prior }.prefix(6)
        let maximumDistance: Float = isLowTextureAnchor ? 0.38 : 0.46
        var verified: [VerifiedCandidate] = []
        for candidate in shortlist {
            guard let candidatePrint = extractFeaturePrint(from: buffer, regionOfInterest: candidate.box) else { continue }
            do {
                var longDistance: Float = .greatestFiniteMagnitude
                try longTermPrint.computeDistance(&longDistance, to: candidatePrint)
                var bestDistance = longDistance
                if let shortPrint = shortTermFeaturePrint {
                    var shortDistance: Float = .greatestFiniteMagnitude
                    try shortPrint.computeDistance(&shortDistance, to: candidatePrint)
                    bestDistance = min(bestDistance, shortDistance)
                }
                guard bestDistance < maximumDistance else { continue }

                let neuralSimilarity: Double
                if NeuralTargetTracker.shared.hasActiveTrainedModel {
                    neuralSimilarity = NeuralTargetTracker.shared.verifyTarget(in: buffer, at: candidate.point)
                    guard neuralSimilarity >= 0.45 else { continue }
                } else {
                    neuralSimilarity = 0.65
                }
                let featureScore = 1.0 - Double(bestDistance / maximumDistance)
                let score = 0.56 * featureScore + 0.26 * candidate.color + 0.18 * neuralSimilarity
                verified.append(VerifiedCandidate(
                    box: candidate.box,
                    point: candidate.point,
                    distance: bestDistance,
                    color: candidate.color,
                    neural: neuralSimilarity,
                    score: score
                ))
            } catch {
                continue
            }
        }

        guard let best = verified.max(by: { $0.score < $1.score }), best.score >= 0.61 else { return nil }
        // Chỉ so margin với một peak không chồng lấp. Các scale/ô lân cận cùng phủ
        // target là một mode duy nhất, không phải hai danh tính mơ hồ.
        let distinctRunnerUp = verified
            .filter { hypot($0.point.x - best.point.x, $0.point.y - best.point.y) > max(0.07, best.box.width * 0.45) }
            .max(by: { $0.score < $1.score })
        if let runner = distinctRunnerUp, best.score - runner.score < 0.075 {
            CameraLogger.info("🎯 [Vision] Re-ID bỏ qua — hai peak danh tính mơ hồ", category: .tracking)
            return nil
        }

        let confidence = min(0.96, max(0.78, 0.72 + best.score * 0.24))
        CameraLogger.info("🎯 [Vision] Re-ID thành công (dist: \(String(format: "%.3f", best.distance)), color: \(String(format: "%.2f", best.color)), neural: \(String(format: "%.2f", best.neural)))", category: .tracking)
        return (best.point, confidence, best.box)
    }
    
    /// Cầu nối KLT cho các frame mất dấu ngắn (lia máy nhanh / nhòe chuyển động):
    /// seed điểm từ buffer TRƯỚC (đã giữ nóng) theo box tracker cuối, rồi dò dịch chuyển sang frame hiện tại
    private func kltBridgePoint(currentPyramid: GrayPyramid) -> (CGPoint, Double)? {
        guard let lastObs = self.lastTargetObservation, self.kltPreviousPyramid != nil else { return nil }
        
        if self.kltTrackedPoints.isEmpty {
            guard let previous = self.kltPreviousPyramid else { return nil }
            self.kltTrackedPoints = self.extractKLTFeaturePoints(in: lastObs.boundingBox, pyramid: previous)
            self.kltTargetCenterUI = CGPoint(x: lastObs.boundingBox.midX, y: 1.0 - lastObs.boundingBox.midY)
            guard self.kltTrackedPoints.count >= 5 else { return nil }
        }
        
        guard let (pt, conf) = self.trackKLTCluster(currentPyramid: currentPyramid) else {
            self.kltTrackedPoints = [] // seed lại từ frame kế tiếp
            return nil
        }
        
        // Sanity: điểm KLT phải nằm gần vị trí cuối đã xác nhận (chống KLT bắt nhầm cụm điểm nền)
        let allowedRadius = max(0.12, SpatialTrackingEngine.shared.currentUncertaintyRadius * 1.5)
        if let verified = self.lastVerifiedUIPoint, hypot(pt.x - verified.x, pt.y - verified.y) >= allowedRadius {
            self.kltTrackedPoints = []
            return nil
        }
        
        return (pt, conf)
    }
    
    // MARK: - Process Incoming Video PixelBuffer
    public func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation = .up) {
        let currentTime = CACurrentMediaTime()
        let effectiveThrottle = isIdlePreviewMode ? idleThrottleInterval : frameThrottleInterval
        guard currentTime - lastProcessTime >= effectiveThrottle else { return }
        
        let shouldProcess: Bool = {
            processingLock.lock()
            defer { processingLock.unlock() }
            if isProcessingFrame { return false }
            isProcessingFrame = true
            return true
        }()
        guard shouldProcess else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            processingLock.lock()
            isProcessingFrame = false
            processingLock.unlock()
            return
        }
        
        lastProcessTime = currentTime
        
        // Capture frame for Gemini if requested
        let shouldCaptureForGemini = captureNextFrameForGemini
        if shouldCaptureForGemini {
            captureNextFrameForGemini = false
            let ciImg = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImg = self.sharedCIContext.createCGImage(ciImg, from: ciImg.extent) {
                DispatchQueue.main.async { [weak self] in
                    self?.capturedGeminiFrame = cgImg
                    self?.onFrameCapturedForAI?(cgImg)
                    self?.onFrameCapturedForAI = nil
                }
            }
        }
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.processingLock.lock()
                self.isProcessingFrame = false
                self.processingLock.unlock()
            }
            
            // 1. Nếu đang ở chế độ tracking mục tiêu (Target Placed)
            if self.isTrackingTarget, let trackRequest = self.currentTrackRequest {
                let currentPyramid = GrayPyramid(pixelBuffer: pixelBuffer)
                // Khởi tạo vân tay tham chiếu đúng 1 lần tại khung đầu
                if self.referenceFeaturePrint == nil, let obs = self.lastTargetObservation {
                    self.referenceFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: obs.boundingBox)
                    self.referenceColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: obs.boundingBox)
                    self.shortTermFeaturePrint = self.referenceFeaturePrint
                    self.shortTermColorHistogram = self.referenceColorHistogram
                }
                
                var trackedPoint: CGPoint? = nil
                var trackedConfidence: Double = 0.0
                var trackerIdentityLost = false
                
                do {
                    // Truyền lại request gốc vào sequenceHandler để Apple Vision tích lũy vector vận tốc và bộ lọc Kalman
                    try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)
                    if let results = trackRequest.results as? [VNDetectedObjectObservation], let newObs = results.first,
                       newObs.confidence > 0.20 {
                        
                        // ── XÁC MINH DANH TÍNH VẬT THỂ LIÊN TUYẾN (chống tracker trôi sang vật thể khác) ──
                        var identityOK = true
                        
                        // 1) Histogram màu 24-bin chỉ lấy ~256 mẫu, đủ rẻ để chạy
                        // mỗi visual frame. So với cả immutable long-term template
                        // và short-term template để chịu AE/AWB nhưng bắt occluder ngay.
                        let currentHistogram = self.extractColorHistogram(from: pixelBuffer, region: newObs.boundingBox)
                        let longSimilarity = self.referenceColorHistogram.map {
                            self.compareColorHistograms($0, currentHistogram)
                        } ?? 1
                        let shortSimilarity = self.shortTermColorHistogram.map {
                            self.compareColorHistograms($0, currentHistogram)
                        } ?? longSimilarity
                        let colorSimilarity = max(longSimilarity, shortSimilarity)
                        if colorSimilarity < 0.52 {
                            identityOK = false
                            self.histogramMismatchStreak += 2
                        } else if colorSimilarity < 0.66 {
                            self.histogramMismatchStreak += 1
                            if self.histogramMismatchStreak >= 2 { identityOK = false }
                        } else {
                            self.histogramMismatchStreak = 0
                        }

                        // 2) Deep Feature Print chạy định kỳ hoặc ngay khi màu đáng
                        // ngờ. Distance phải khớp ít nhất một template, nhưng template
                        // gốc không bao giờ bị ghi đè sau re-ID để tránh model drift.
                        if identityOK, let refPrint = self.referenceFeaturePrint {
                            self.featurePrintCheckCounter += 1
                            let cadence = self.isLowTextureAnchor ? 8 : 14
                            if self.featurePrintCheckCounter >= cadence || colorSimilarity < 0.72 {
                                self.featurePrintCheckCounter = 0
                                if let curPrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: newObs.boundingBox) {
                                    var longDistance: Float = .greatestFiniteMagnitude
                                    do {
                                        try refPrint.computeDistance(&longDistance, to: curPrint)
                                        var bestDistance = longDistance
                                        if let shortPrint = self.shortTermFeaturePrint {
                                            var shortDistance: Float = .greatestFiniteMagnitude
                                            try shortPrint.computeDistance(&shortDistance, to: curPrint)
                                            bestDistance = min(bestDistance, shortDistance)
                                        }
                                        let distanceLimit: Float = self.isLowTextureAnchor ? 0.52 : 0.60
                                        if bestDistance > distanceLimit {
                                            identityOK = false
                                            CameraLogger.info("🎯 [Vision] Mất khớp feature print (dist: \(String(format: "%.2f", bestDistance))) — nghi tracker trôi", category: .tracking)
                                        }
                                    } catch {
                                        // Lỗi tính distance: bỏ qua lần kiểm tra này
                                    }
                                }
                            }
                        }
                        
                        if identityOK {
                            // ── KHUNG HỢP LỆ: nối tiếp sequence, cập nhật mỏ neo & vị trí đã xác nhận ──
                            self.identitySuspicionFrames = 0
                            self.consecutiveLostFrames = 0
                            self.stableLockFrames += 1
                            trackRequest.inputObservation = newObs
                            self.lastTargetObservation = newObs
                            self.anchorBoxSize = CGSize(width: max(0.08, min(0.5, newObs.boundingBox.width)),
                                                        height: max(0.08, min(0.5, newObs.boundingBox.height)))
                            self.lastVerifiedUIPoint = CGPoint(x: newObs.boundingBox.midX, y: 1.0 - newObs.boundingBox.midY)
                            
                            // Chỉ short-term template thích nghi với AE/AWB/pose. Long-term
                            // template lúc pin là bất biến để occluder không thể "đầu độc" re-ID.
                            if self.stableLockFrames % 15 == 0,
                               let shortHistogram = self.shortTermColorHistogram,
                                shortHistogram.count == currentHistogram.count {
                                var blended = [Float](repeating: 0, count: shortHistogram.count)
                                for i in blended.indices {
                                    blended[i] = 0.88 * shortHistogram[i] + 0.12 * currentHistogram[i]
                                }
                                self.shortTermColorHistogram = blended
                            }
                            if self.stableLockFrames % 45 == 0 {
                                self.shortTermFeaturePrint = self.extractFeaturePrint(
                                    from: pixelBuffer,
                                    regionOfInterest: newObs.boundingBox
                                ) ?? self.shortTermFeaturePrint
                            }
                            
                            var uiX = newObs.boundingBox.midX
                            var uiY = 1.0 - newObs.boundingBox.midY
                            
                            // 3) Detection-based Periodic Correction (Nắn mỏ neo nhẹ nhàng mỗi 15 frame bằng Saliency Centroid với lực 0.08, chống rung giật)
                            self.detectionCorrectionCounter += 1
                            if self.detectionCorrectionCounter >= 15 {
                                self.detectionCorrectionCounter = 0
                                if let salientCentroid = self.extractSaliencyCentroid(from: pixelBuffer, near: newObs.boundingBox) {
                                    let centroidUIX = salientCentroid.x
                                    let centroidUIY = 1.0 - salientCentroid.y
                                    let box = newObs.boundingBox
                                    let boxUI = CGRect(x: box.minX, y: 1.0 - box.maxY, width: box.width, height: box.height)
                                    // Chỉ nắn khi centroid nằm trong hoặc rất sát box đang bám (tránh hút sang đối tượng ngoài)
                                    if boxUI.insetBy(dx: -0.02, dy: -0.02).contains(CGPoint(x: centroidUIX, y: centroidUIY)) {
                                        let drift = hypot(centroidUIX - uiX, centroidUIY - uiY)
                                        let maxOffset = min(box.width, box.height) * 0.45
                                        if drift > 0.02 && drift < maxOffset {
                                            uiX += (centroidUIX - uiX) * 0.08
                                            uiY += (centroidUIY - uiY) * 0.08
                                        }
                                    }
                                }
                            } else if self.currentSceneType.isDeformableNature,
                               let salientCentroid = self.extractSaliencyCentroid(from: pixelBuffer, near: newObs.boundingBox) {
                                let box = newObs.boundingBox
                                let boxUI = CGRect(x: box.minX, y: 1.0 - box.maxY, width: box.width, height: box.height)
                                let centroidUI = CGPoint(x: salientCentroid.x, y: 1.0 - salientCentroid.y)
                                if boxUI.contains(centroidUI) {
                                    let maxOffset = min(box.width, box.height) * 0.40
                                    var dx = centroidUI.x - uiX
                                    var dy = centroidUI.y - uiY
                                    dx = max(-maxOffset, min(maxOffset, dx))
                                    dy = max(-maxOffset, min(maxOffset, dy))
                                    uiX += dx * 0.5
                                    uiY += dy * 0.5
                                }
                            }
                            
                            trackedPoint = CGPoint(x: uiX, y: uiY)
                            trackedConfidence = Double(newObs.confidence)

                            self.kltTargetCenterUI = trackedPoint!
                            if let currentPyramid,
                               self.kltTrackedPoints.count < 8 || self.stableLockFrames % 15 == 0 {
                                self.kltTrackedPoints = self.extractKLTFeaturePoints(
                                    in: newObs.boundingBox,
                                    pyramid: currentPyramid
                                )
                            }

                            self.voReferenceCounter += 1
                            if self.voReferenceCounter >= 8 || !VisualOdometryEngine.shared.hasReference() {
                                self.voReferenceCounter = 0
                                VisualOdometryEngine.shared.setReferenceFrame(pixelBuffer, atUIPoint: trackedPoint!)
                            }
                        } else {
                            // ── NGHI TRICKER TRÔI: KHÔNG nối tiếp inputObservation (đông băng mỏ neo tại box cuối hợp lệ),
                            //    đếm frame mất để kích hoạt re-acquisition khi cần ──
                            trackerIdentityLost = true
                            self.identitySuspicionFrames += 1
                            self.stableLockFrames = 0
                            self.consecutiveLostFrames += 1
                        }
                    } else {
                        self.consecutiveLostFrames += 1
                    }
                } catch {
                    self.consecutiveLostFrames += 1
                }
                
                // 1A. Cầu nối KLT cho mất dấu NGẮN (1-10 frame: lia máy nhanh / nhòe chuyển động)
                if trackedPoint == nil, self.consecutiveLostFrames <= 15,
                   let currentPyramid,
                   let (kltPoint, kltConfidence) = self.kltBridgePoint(currentPyramid: currentPyramid) {
                    trackedPoint = kltPoint
                    trackedConfidence = kltConfidence
                }
                
                // 1B. Re-acquisition: chỉ khi mất dấu đủ lâu (>= 20 frame), HOẶC tracker bị nghi trôi
                // xa vị trí đã xác nhận; rate-limit 0.4s/lần để không nghẽn vision queue
                let forceReacquire: Bool = {
                    trackerIdentityLost && self.identitySuspicionFrames >= 2
                }()
                
                if trackedPoint == nil,
                   (self.consecutiveLostFrames >= 20 || forceReacquire),
                   self.consecutiveLostFrames <= 150,
                   CACurrentMediaTime() - self.lastReIdAttemptTime >= 0.35 {
                    self.lastReIdAttemptTime = CACurrentMediaTime()
                    
                    let spatialPoint = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
                    
                    // Tâm tìm kiếm = trung điểm giữa vị trí quang học CUỐI CÙNG ĐÃ XÁC NHẬN và ước lượng không gian (gyro)
                    let verified = self.lastVerifiedUIPoint
                    let searchCenter = CGPoint(
                        x: min(0.94, max(0.06, ((verified?.x ?? spatialPoint.x) + spatialPoint.x) / 2.0)),
                        y: min(0.94, max(0.06, ((verified?.y ?? spatialPoint.y) + spatialPoint.y) / 2.0))
                    )
                    
                    // Chỉ nạp lại mỏ neo khi Neural Re-ID xác nhận rõ ràng là vật thể ban đầu
                    if let (reIdPoint, reIdConfidence, reIdBox) = self.attemptNeuralReIdentification(in: pixelBuffer, orientation: orientation, searchCenter: searchCenter, anchorSize: self.initialAnchorBoxSize) {
                        trackedPoint = reIdPoint
                        trackedConfidence = reIdConfidence
                        self.consecutiveLostFrames = 0
                        self.identitySuspicionFrames = 0
                        self.stableLockFrames = 0
                        self.kltTrackedPoints = []
                        
                        let reObs = VNDetectedObjectObservation(boundingBox: reIdBox)
                        self.lastTargetObservation = reObs
                        self.anchorBoxSize = CGSize(width: max(0.08, min(0.5, reIdBox.width)),
                                                    height: max(0.08, min(0.5, reIdBox.height)))
                        self.lastVerifiedUIPoint = reIdPoint
                        let newReq = VNTrackObjectRequest(detectedObjectObservation: reObs)
                        newReq.trackingLevel = .accurate
                        self.currentTrackRequest = newReq
                        self.sequenceHandler = VNSequenceRequestHandler()

                        // Chỉ refresh short-term template; long-term identity lúc pin
                        // vẫn bất biến để chống gradual drift sau nhiều lần occlusion.
                        self.shortTermFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: reIdBox)
                        self.shortTermColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: reIdBox)
                        VisualOdometryEngine.shared.setReferenceFrame(pixelBuffer, atUIPoint: reIdPoint)
                    }
                }

                // Registration là measurement cuối cùng, variance cao. Nó chạy ở
                // visionQueue và không bao giờ chặn MainActor.
                if trackedPoint == nil, self.consecutiveLostFrames <= 45 {
                    let expected = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
                    if let vo = VisualOdometryEngine.shared.estimateMeasurement(
                        currentBuffer: pixelBuffer,
                        expectedUIPoint: expected
                    ) {
                        trackedPoint = vo.point
                        trackedConfidence = vo.confidence
                    }
                }

                // Giữ nóng buffer trước cho KLT (retain 1 frame; pool không ghi đè buffer đang giữ)
                self.kltPreviousBuffer = pixelBuffer
                self.kltPreviousPyramid = currentPyramid
                
                DispatchQueue.main.async {
                    self.onTargetTracked?(trackedPoint, trackedConfidence, pixelBuffer)
                }
                return
            }
            
            // 2. Chế độ phát hiện thông minh đa tầng bằng NeuralSubjectIntelligenceEngine (Apple Neural Engine ANE)
            let neuralOutput = NeuralSubjectIntelligenceEngine.shared.analyzeFrame(
                pixelBuffer: pixelBuffer,
                orientation: orientation
            )
            
            var result = SubjectDetectionResult()
            result.detectedScene = neuralOutput.detectedScene
            result.faceRectangles = neuralOutput.allFaceRects
            result.primaryEyePosition = neuralOutput.primaryEyePosition
            result.lookingDirection = neuralOutput.lookingDirection
            
            if let primary = neuralOutput.primaryCandidate {
                // Nếu chụp nhóm có nhiều khuôn mặt, ưu tiên khung bao nhóm (groupBoundingBox) để không ai bị mất góc
                if neuralOutput.allFaceRects.count > 1, let groupBox = neuralOutput.groupBoundingBox {
                    result.dominantSubjectRect = groupBox
                } else {
                    result.dominantSubjectRect = primary.boundingBox
                }
                result.confidence = primary.confidence
            }
            
            // Smart Focus Point
            let smartFocusPoint: CGPoint
            let smartFocusType: SmartFocusType
            if let eye = neuralOutput.primaryEyePosition {
                smartFocusPoint = eye
                smartFocusType = .face
            } else if let primary = neuralOutput.primaryCandidate {
                smartFocusPoint = primary.center
                smartFocusType = (primary.category == .face) ? .face : .salientObject
            } else {
                smartFocusPoint = CGPoint(x: 0.5, y: 0.5)
                smartFocusType = .center
            }
            
            let luma = Self.estimateLuminance(from: pixelBuffer)
            result.averageLuminance = luma.luminance
            result.estimatedColorTemp = luma.colorTemp
            
            DispatchQueue.main.async {
                self.onDetectionCompleted?(result)
                self.onSmartFocusPointCalculated?(smartFocusPoint, smartFocusType)
            }
        }
    }
    
    private static func estimateLuminance(from buffer: CVPixelBuffer) -> (luminance: Float, colorTemp: Float) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return (0.5, 5500)
        }
        
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleSize = 16
        let startX = (width / 2) - (sampleSize / 2)
        let startY = (height / 2) - (sampleSize / 2)
        
        var totalR: Float = 0; var totalG: Float = 0; var totalB: Float = 0
        var sampleCount: Float = 0
        
        for row in 0..<sampleSize {
            for col in 0..<sampleSize {
                let px = startX + col
                let py = startY + row
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let offset = py * bytesPerRow + px * 4
                let b = Float(data[offset]) / 255.0
                let g = Float(data[offset + 1]) / 255.0
                let r = Float(data[offset + 2]) / 255.0
                totalR += r; totalG += g; totalB += b
                sampleCount += 1
            }
        }
        
        guard sampleCount > 0 else { return (0.5, 5500) }
        let avgR = totalR / sampleCount
        let avgG = totalG / sampleCount
        let avgB = totalB / sampleCount
        let luma = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
        let rBRatio = avgR > 0 ? avgB / avgR : 1.0
        let estimatedK = max(2700, min(9000, 3500 + rBRatio * 3000))
        return (luma, estimatedK)
    }

    /// Chụp tức thì khung hình hiện tại cho AI Cloud phân tích
    public func captureImmediateFrame(completion: @escaping (CGImage?) -> Void) {
        let lastBuffer = visionQueue.sync { self.kltPreviousBuffer }
        if let lastBuf = lastBuffer {
            let ciImg = CIImage(cvPixelBuffer: lastBuf)
            if let cgImg = self.sharedCIContext.createCGImage(ciImg, from: ciImg.extent) {
                completion(cgImg)
                return
            }
        }
        self.onFrameCapturedForAI = { img in
            completion(img)
        }
        self.captureNextFrameForGemini = true
    }
}
