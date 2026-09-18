import Foundation
import Vision
import CoreMedia
import CoreImage
import CoreGraphics
import QuartzCore

public final class VisionFramingEngine: @unchecked Sendable {
    public static let shared = VisionFramingEngine()
    
    private let visionQueue = DispatchQueue(
        label: "com.aismartframing.visionQueue",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    private let visionQueueKey = DispatchSpecificKey<UInt8>()
    
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
    public var isIdlePreviewMode: Bool = false
    private let idleThrottleInterval: TimeInterval = 0.2 // ~5 FPS lúc rảnh, vẫn đủ mượt cho preview mặt/scene
    
    // Callbacks
    public var onDetectionCompleted: ((SubjectDetectionResult) -> Void)?
    public var onTargetTracked: ((TrackedTargetObservation?, CVPixelBuffer) -> Void)?
    public var onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)?
    
    // Gemini Frame Capture
    public var capturedGeminiFrame: CGImage? = nil
    public var onFrameCapturedForAI: ((CGImage) -> Void)?
    
    // Visual Feature Object Tracking (VNTrackObjectRequest + Deep FeaturePrint Re-ID + Color Histogram + KLT Point Cluster)
    public private(set) var isTrackingTarget: Bool = false
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTargetObservation: VNDetectedObjectObservation? = nil
    private var referenceFeaturePrint: VNFeaturePrintObservation? = nil
    private var referenceColorHistogram: [Float]? = nil
    private var consecutiveLostFrames: Int = 0
    
    // KLT (Lucas-Kanade) Feature Point Cluster Tracker + RANSAC
    private var kltTrackedPoints: [CGPoint] = []
    private var kltPreviousBuffer: CVPixelBuffer? = nil
    private var kltTargetBox: CGRect = .zero

    // Xác minh danh tính vật thể liên tuyến (chống tracker trôi sang vật thể khác)
    private var lastVerifiedUIPoint: CGPoint? = nil
    private var identitySuspicionFrames: Int = 0
    private var histogramCheckCounter: Int = 0
    private var histogramMismatchStreak: Int = 0
    private var featurePrintCheckCounter: Int = 0
    private var detectionCorrectionCounter: Int = 0
    private var stableLockFrames: Int = 0
    private var anchorBoxSize: CGSize = CGSize(width: 0.14, height: 0.14)
    private var lastReIdAttemptTime: CFTimeInterval = 0
    
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
    
    public init() {
        visionQueue.setSpecific(key: visionQueueKey, value: 1)
    }

    private func performOnVisionQueueSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: visionQueueKey) == 1 {
            work()
        } else {
            visionQueue.sync(execute: work)
        }
    }
    
    // MARK: - Visual Object Tracking Control
    private var currentTrackRequest: VNTrackObjectRequest? = nil
    
    /// Tinh chỉnh Bounding Box mỏ neo ban đầu ôm khít chủ thể thật thay vì dùng box vuông cố định
    /// Sử dụng Objectness Saliency và Human Body Pose / Face detection
    private func refineAnchorBox(
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
        performOnVisionQueueSync {
            startTrackingObjectOnQueue(
                at: normalizedPoint,
                size: size,
                refiningBuffer: refiningBuffer,
                orientation: orientation
            )
        }
    }

    private func startTrackingObjectOnQueue(
        at normalizedPoint: CGPoint,
        size: CGSize,
        refiningBuffer: CVPixelBuffer?,
        orientation: CGImagePropertyOrientation
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
        
        let initialObservation = VNDetectedObjectObservation(boundingBox: clampedRect)
        self.lastTargetObservation = initialObservation
        
        // Chuẩn Apple WWDC: Khởi tạo VNTrackObjectRequest ĐÚNG 1 LẦN DUY NHẤT để tích lũy bộ nhớ tracking
        let req = VNTrackObjectRequest(detectedObjectObservation: initialObservation)
        req.trackingLevel = .accurate
        self.currentTrackRequest = req
        
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.kltTargetBox = clampedRect
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
        self.anchorBoxSize = targetSize
        self.lastReIdAttemptTime = 0
        self.isTrackingTarget = true
        CameraLogger.info("🎯 [Vision] Khởi tạo VNTrackObjectRequest duy nhất tại: (\(String(format: "%.3f", targetPoint.x)), \(String(format: "%.3f", targetPoint.y))), size: \(targetSize)", category: .tracking)
    }
    
    public func stopTrackingObject() {
        performOnVisionQueueSync {
            stopTrackingObjectOnQueue()
        }
    }

    private func stopTrackingObjectOnQueue() {
        self.isTrackingTarget = false
        self.currentTrackRequest?.isLastFrame = true
        self.currentTrackRequest = nil
        self.lastTargetObservation = nil
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
        self.lastVerifiedUIPoint = nil
        self.identitySuspicionFrames = 0
        self.histogramCheckCounter = 0
        self.histogramMismatchStreak = 0
        self.featurePrintCheckCounter = 0
        self.detectionCorrectionCounter = 0
        self.stableLockFrames = 0
        self.lastReIdAttemptTime = 0
        CameraLogger.info("🎯 [Vision] Đã dừng và giải phóng VNTrackObjectRequest", category: .tracking)
    }
    
    // MARK: - Bám Chùm Điểm Hình Học KLT (Lucas-Kanade Feature Point Cluster + RANSAC)
    private func extractKLTFeaturePoints(in roi: CGRect, buffer: CVPixelBuffer) -> [CGPoint] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let minX = max(4, min(width - 5, Int(roi.origin.x * CGFloat(width))))
        let minY = max(4, min(height - 5, Int((1.0 - roi.origin.y - roi.size.height) * CGFloat(height))))
        let maxX = max(minX + 8, min(width - 5, Int((roi.origin.x + roi.size.width) * CGFloat(width))))
        let maxY = max(minY + 8, min(height - 5, Int((1.0 - roi.origin.y) * CGFloat(height))))
        
        var corners: [(point: CGPoint, score: Float)] = []
        let step = max(3, (maxX - minX) / 20)
        
        for y in stride(from: minY + 2, to: maxY - 2, by: step) {
            for x in stride(from: minX + 2, to: maxX - 2, by: step) {
                let offR = y * bytesPerRow + (x + 1) * 4
                let offL = y * bytesPerRow + (x - 1) * 4
                let offD = (y + 1) * bytesPerRow + x * 4
                let offU = (y - 1) * bytesPerRow + x * 4
                
                let lumR = Float(data[offR]) * 0.114 + Float(data[offR+1]) * 0.587 + Float(data[offR+2]) * 0.299
                let lumL = Float(data[offL]) * 0.114 + Float(data[offL+1]) * 0.587 + Float(data[offL+2]) * 0.299
                let lumD = Float(data[offD]) * 0.114 + Float(data[offD+1]) * 0.587 + Float(data[offD+2]) * 0.299
                let lumU = Float(data[offU]) * 0.114 + Float(data[offU+1]) * 0.587 + Float(data[offU+2]) * 0.299
                
                let ix = (lumR - lumL) * 0.5
                let iy = (lumD - lumU) * 0.5
                let score = ix * ix + iy * iy
                
                if score > 80.0 {
                    let normX = CGFloat(x) / CGFloat(width)
                    let normY = 1.0 - (CGFloat(y) / CGFloat(height))
                    corners.append((point: CGPoint(x: normX, y: normY), score: score))
                }
            }
        }
        
        // Trọng số tâm (Center-weighting): Ưu tiên các điểm đặc trưng nằm gần tâm box (chủ thể thật)
        // và giảm mạnh điểm của các điểm gần mép biên (thường là viền tường, mép bàn, hoa văn nền)
        let boxCenter = CGPoint(x: roi.midX, y: roi.midY)
        let maxDist = max(0.02, max(roi.width, roi.height) / 2.0)
        corners = corners.map { c in
            let d = hypot(c.point.x - boxCenter.x, c.point.y - boxCenter.y)
            let centerWeight = Float(max(0.20, 1.0 - (d / maxDist)))
            return (point: c.point, score: c.score * centerWeight)
        }
        
        corners.sort { $0.score > $1.score }
        let top = corners.prefix(30).map { $0.point }
        if top.count < 8 {
            var grid: [CGPoint] = top
            for r in 0..<3 {
                for c in 0..<3 {
                    // Tập trung lưới điểm vào 60% vùng trung tâm ROI thay vì mép ngoài
                    let gx = roi.origin.x + roi.size.width * (0.20 + 0.60 * (CGFloat(c) + 0.5) / 3.0)
                    let gy = roi.origin.y + roi.size.height * (0.20 + 0.60 * (CGFloat(r) + 0.5) / 3.0)
                    grid.append(CGPoint(x: gx, y: gy))
                }
            }
            return grid
        }
        return top
    }
    
    private func trackKLTCluster(in currentBuffer: CVPixelBuffer) -> (uiPoint: CGPoint, confidence: Double)? {
        guard !kltTrackedPoints.isEmpty, let prevBuffer = kltPreviousBuffer else {
            self.kltPreviousBuffer = currentBuffer
            return nil
        }
        defer { self.kltPreviousBuffer = currentBuffer }
        
        let width = CGFloat(CVPixelBufferGetWidth(currentBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(currentBuffer))
        
        CVPixelBufferLockBaseAddress(prevBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(currentBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(prevBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(currentBuffer, .readOnly)
        }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(currentBuffer)
        guard let prevData = CVPixelBufferGetBaseAddress(prevBuffer)?.assumingMemoryBound(to: UInt8.self),
              let currData = CVPixelBufferGetBaseAddress(currentBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        
        var displacedPoints: [CGPoint] = []
        var displacementVectors: [CGVector] = []
        let winR = 3
        let searchR = 6
        
        for pt in kltTrackedPoints {
            let px = Int(pt.x * width)
            let py = Int((1.0 - pt.y) * height)
            
            guard px >= winR + searchR, px < Int(width) - (winR + searchR),
                  py >= winR + searchR, py < Int(height) - (winR + searchR) else { continue }
            
            var bestDx = 0
            var bestDy = 0
            var minSAD = Float.greatestFiniteMagnitude
            
            for dy in -searchR...searchR {
                for dx in -searchR...searchR {
                    var sad: Float = 0
                    for wy in -winR...winR {
                        for wx in -winR...winR {
                            let pOff = (py + wy) * bytesPerRow + (px + wx) * 4
                            let cOff = (py + dy + wy) * bytesPerRow + (px + dx + wx) * 4
                            let pLum = Float(prevData[pOff]) * 0.114 + Float(prevData[pOff+1]) * 0.587 + Float(prevData[pOff+2]) * 0.299
                            let cLum = Float(currData[cOff]) * 0.114 + Float(currData[cOff+1]) * 0.587 + Float(currData[cOff+2]) * 0.299
                            sad += abs(pLum - cLum)
                        }
                    }
                    if sad < minSAD {
                        minSAD = sad
                        bestDx = dx
                        bestDy = dy
                    }
                }
            }
            
            let avgErr = minSAD / Float((winR * 2 + 1) * (winR * 2 + 1))
            if avgErr < 32.0 {
                let normDx = CGFloat(bestDx) / width
                let normDy = -CGFloat(bestDy) / height
                displacedPoints.append(CGPoint(x: pt.x + normDx, y: pt.y + normDy))
                displacementVectors.append(CGVector(dx: normDx, dy: normDy))
            }
        }
        
        guard displacementVectors.count >= 4 else { return nil }
        
        let sortedDx = displacementVectors.map { $0.dx }.sorted()
        let sortedDy = displacementVectors.map { $0.dy }.sorted()
        let medianDx = sortedDx[sortedDx.count / 2]
        let medianDy = sortedDy[sortedDy.count / 2]
        
        var inliers: [CGPoint] = []
        for (i, v) in displacementVectors.enumerated() {
            if hypot(v.dx - medianDx, v.dy - medianDy) < 0.035 {
                inliers.append(displacedPoints[i])
            }
        }
        
        guard !inliers.isEmpty else { return nil }

        let originalPointCount = self.kltTrackedPoints.count

        let avgX = inliers.map { $0.x }.reduce(0, +) / CGFloat(inliers.count)
        let avgY = inliers.map { $0.y }.reduce(0, +) / CGFloat(inliers.count)
        self.kltTrackedPoints = inliers

        let uiPoint = CGPoint(x: avgX, y: 1.0 - avgY)
        let inlierRatio = Double(inliers.count) / Double(max(1, originalPointCount))
        let confidence = max(0.70, min(0.95, 0.60 + inlierRatio * 0.35))
        return (uiPoint, confidence)
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
        guard let refPrint = self.referenceFeaturePrint else { return nil }
        
        let boxW = max(0.10, min(0.45, anchorSize.width))
        let boxH = max(0.10, min(0.45, anchorSize.height))
        // Vật thể low-texture (trắng/đơn sắc): feature print kém phân biệt hơn -> siết ngưỡng chặt hơn
        let minColorSim: Double = self.isLowTextureAnchor ? 0.80 : 0.70
        let maxDist: Float = self.isLowTextureAnchor ? 0.25 : 0.28
        
        var candidates: [(box: CGRect, dist: Float, colorSim: Double)] = []
        
        // CHỈ tìm kiếm trong phạm vi hẹp cục bộ quanh tâm tìm kiếm (bán kính <= 0.05), TUYỆT ĐỐI KHÔNG quét toàn màn hình
        let offsets: [CGFloat] = [-0.05, 0.0, 0.05]
        
        for dy in offsets {
            for dx in offsets {
                let testUix = min(0.94, max(0.06, searchCenter.x + dx))
                let testUiy = min(0.94, max(0.06, searchCenter.y + dy))
                let vx = max(0.01, min(1.0 - boxW - 0.01, testUix - boxW / 2))
                let vy = max(0.01, min(1.0 - boxH - 0.01, (1.0 - testUiy) - boxH / 2))
                let clampedBox = CGRect(x: vx, y: vy, width: boxW, height: boxH)
                
                let req = VNGenerateImageFeaturePrintRequest()
                req.imageCropAndScaleOption = .scaleFit
                req.regionOfInterest = clampedBox
                let h = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
                do {
                    try h.perform([req])
                    guard let candidatePrint = req.results?.first as? VNFeaturePrintObservation else { continue }
                    var dist: Float = 0
                    try refPrint.computeDistance(&dist, to: candidatePrint)
                    
                    let colorSim: Double
                    if let refHist = self.referenceColorHistogram {
                        let candHist = self.extractColorHistogram(from: buffer, region: clampedBox)
                        colorSim = Double(self.compareColorHistograms(refHist, candHist))
                    } else {
                        colorSim = 1.0
                    }
                    
                    if dist < maxDist && colorSim >= minColorSim {
                        candidates.append((clampedBox, dist, colorSim))
                    }
                } catch {
                    continue
                }
            }
        }
        
        guard !candidates.isEmpty else { return nil }
        
        let sorted = candidates.sorted { $0.dist < $1.dist }
        let best = sorted[0]
        
        // Loại kết quả MƠ HỒI: ứng viên thứ 2 gần ngang ứng viên tốt nhất -> không dám chắc là vật thể thật
        if sorted.count > 1, sorted[1].dist - best.dist < 0.04 {
            CameraLogger.info("🎯 [Vision] Re-ID bỏ qua — kết quả mơ hồ (best: \(String(format: "%.3f", best.dist)), runner-up: \(String(format: "%.3f", sorted[1].dist)))", category: .tracking)
            return nil
        }
        
        CameraLogger.info("🎯 [Vision] Re-ID thành công (Dist: \(String(format: "%.3f", best.dist)), Color: \(String(format: "%.2f", best.colorSim)), candidates: \(candidates.count))", category: .tracking)
        let uiX = best.box.midX
        let uiY = 1.0 - best.box.midY
        let confidence = max(0.70, Double(1.0 - (Double(best.dist) / Double(maxDist))) * 0.7 + best.colorSim * 0.3)
        return (CGPoint(x: uiX, y: uiY), confidence, best.box)
    }
    
    /// Cầu nối KLT cho các frame mất dấu ngắn (lia máy nhanh / nhòe chuyển động):
    /// seed điểm từ buffer TRƯỚC (đã giữ nóng) theo box tracker cuối, rồi dò dịch chuyển sang frame hiện tại
    private func kltBridgePoint(in currentBuffer: CVPixelBuffer) -> (CGPoint, Double)? {
        guard let lastObs = self.lastTargetObservation, let prevBuffer = self.kltPreviousBuffer else { return nil }
        
        if self.kltTrackedPoints.isEmpty {
            self.kltTrackedPoints = self.extractKLTFeaturePoints(in: lastObs.boundingBox, buffer: prevBuffer)
            guard self.kltTrackedPoints.count >= 4 else { return nil }
        }
        
        guard let (pt, conf) = self.trackKLTCluster(in: currentBuffer) else {
            self.kltTrackedPoints = [] // seed lại từ frame kế tiếp
            return nil
        }
        
        // Sanity: điểm KLT phải nằm gần vị trí cuối đã xác nhận (chống KLT bắt nhầm cụm điểm nền)
        if let verified = self.lastVerifiedUIPoint, hypot(pt.x - verified.x, pt.y - verified.y) >= 0.12 {
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
                // Khởi tạo vân tay tham chiếu đúng 1 lần tại khung đầu
                if self.referenceFeaturePrint == nil, let obs = self.lastTargetObservation {
                    self.referenceFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: obs.boundingBox)
                    self.referenceColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: obs.boundingBox)
                }
                
                var trackedPoint: CGPoint? = nil
                var trackedBoundingBox: CGRect? = nil
                var trackedConfidence: Double = 0.0
                var trackerIdentityLost = false
                
                do {
                    // Truyền lại request gốc vào sequenceHandler để Apple Vision tích lũy vector vận tốc và bộ lọc Kalman
                    try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)
                    if let results = trackRequest.results as? [VNDetectedObjectObservation], let newObs = results.first,
                       newObs.confidence > 0.20 {
                        
                        // ── XÁC MINH DANH TÍNH VẬT THỂ LIÊN TUYẾN (chống tracker trôi sang vật thể khác) ──
                        var identityOK = true
                        
                        // 1) Histogram màu 24-bin (rẻ): kiểm tra mỗi 3 frame
                        // Ngưỡng 0.68 kết hợp streak 3 lần liên tiếp: chống trôi sang nền/vật khác nhưng chịu được AE/AWB camera thực tế
                        self.histogramCheckCounter += 1
                        if self.histogramCheckCounter >= 3, let refHist = self.referenceColorHistogram {
                            self.histogramCheckCounter = 0
                            let curHist = self.extractColorHistogram(from: pixelBuffer, region: newObs.boundingBox)
                            let colorSim = self.compareColorHistograms(refHist, curHist)
                            if colorSim < 0.68 {
                                self.histogramMismatchStreak += 1
                                if self.histogramMismatchStreak >= 3 {
                                    identityOK = false
                                    CameraLogger.info("🎯 [Vision] Mất khớp histogram liên tiếp (\(String(format: "%.2f", colorSim))) — giữ mỏ neo", category: .tracking)
                                }
                            } else {
                                self.histogramMismatchStreak = 0
                            }
                        }
                        
                        // 2) Deep Feature Print (đắt): kiểm tra mỗi 20 frame
                        if identityOK, let refPrint = self.referenceFeaturePrint {
                            self.featurePrintCheckCounter += 1
                            if self.featurePrintCheckCounter >= 20 {
                                self.featurePrintCheckCounter = 0
                                if let curPrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: newObs.boundingBox) {
                                    var dist: Float = 0
                                    do {
                                        try refPrint.computeDistance(&dist, to: curPrint)
                                        if dist > 0.58 {
                                            identityOK = false
                                            CameraLogger.info("🎯 [Vision] Mất khớp feature print (dist: \(String(format: "%.2f", dist))) — nghi tracker trôi", category: .tracking)
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
                            
                            // Thích nghi chậm reference theo thay đổi phơi sáng (mỗi ~2s lock ổn định)
                            if self.stableLockFrames >= 60 {
                                self.stableLockFrames = 0
                                let curHist = self.extractColorHistogram(from: pixelBuffer, region: newObs.boundingBox)
                                if let refHist = self.referenceColorHistogram, refHist.count == curHist.count {
                                    var blended = [Float](repeating: 0, count: refHist.count)
                                    for i in 0..<refHist.count { blended[i] = refHist[i] * 0.85 + curHist[i] * 0.15 }
                                    self.referenceColorHistogram = blended
                                }
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
                            trackedBoundingBox = CGRect(
                                x: newObs.boundingBox.minX,
                                y: 1.0 - newObs.boundingBox.maxY,
                                width: newObs.boundingBox.width,
                                height: newObs.boundingBox.height
                            )
                            trackedConfidence = Double(newObs.confidence)
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
                if trackedPoint == nil, self.consecutiveLostFrames <= 10,
                   let (kltPoint, kltConfidence) = self.kltBridgePoint(in: pixelBuffer) {
                    trackedPoint = kltPoint
                    trackedBoundingBox = self.uiRect(centeredAt: kltPoint, size: self.anchorBoxSize)
                    // KLT là observation trung: đủ để engine tin (>= ngưỡng nhận) nhưng không reset VO reference
                    trackedConfidence = min(0.55, kltConfidence)
                    self.consecutiveLostFrames = min(self.consecutiveLostFrames, 4)
                }
                
                // 1B. Re-acquisition: chỉ khi mất dấu đủ lâu (>= 20 frame), HOẶC tracker bị nghi trôi
                // xa vị trí đã xác nhận; rate-limit 0.4s/lần để không nghẽn vision queue
                let forceReacquire: Bool = {
                    guard trackerIdentityLost, self.identitySuspicionFrames >= 5,
                          let verified = self.lastVerifiedUIPoint, let lastObs = self.lastTargetObservation else { return false }
                    let drifted = hypot(lastObs.boundingBox.midX - verified.x, (1.0 - lastObs.boundingBox.midY) - verified.y)
                    return drifted > 0.06
                }()
                
                if trackedPoint == nil,
                   (self.consecutiveLostFrames >= 20 || forceReacquire),
                   self.consecutiveLostFrames <= 150,
                   CACurrentMediaTime() - self.lastReIdAttemptTime >= 0.4 {
                    self.lastReIdAttemptTime = CACurrentMediaTime()
                    
                    let spatialPoint = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
                    
                    // Tâm tìm kiếm = trung điểm giữa vị trí quang học CUỐI CÙNG ĐÃ XÁC NHẬN và ước lượng không gian (gyro)
                    let verified = self.lastVerifiedUIPoint
                    let searchCenter = CGPoint(
                        x: min(0.94, max(0.06, ((verified?.x ?? spatialPoint.x) + spatialPoint.x) / 2.0)),
                        y: min(0.94, max(0.06, ((verified?.y ?? spatialPoint.y) + spatialPoint.y) / 2.0))
                    )
                    
                    // Chỉ nạp lại mỏ neo khi Neural Re-ID xác nhận rõ ràng là vật thể ban đầu
                    if let (reIdPoint, reIdConfidence, reIdBox) = self.attemptNeuralReIdentification(in: pixelBuffer, orientation: orientation, searchCenter: searchCenter, anchorSize: self.anchorBoxSize) {
                        trackedPoint = reIdPoint
                        trackedBoundingBox = CGRect(
                            x: reIdBox.minX,
                            y: 1.0 - reIdBox.maxY,
                            width: reIdBox.width,
                            height: reIdBox.height
                        )
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
                        
                        // QUAN TRỌNG: cập nhật lại vân tay tham chiếu từ box mới (reference cũ đã lạc hậu)
                        self.referenceFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: reIdBox)
                        self.referenceColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: reIdBox)
                    }
                }
                
                // Giữ nóng buffer trước cho KLT (retain 1 frame; pool không ghi đè buffer đang giữ)
                self.kltPreviousBuffer = pixelBuffer
                
                let observation: TrackedTargetObservation?
                if let trackedPoint, let trackedBoundingBox {
                    observation = TrackedTargetObservation(
                        center: trackedPoint,
                        boundingBox: trackedBoundingBox,
                        confidence: Float(trackedConfidence),
                        isPredicted: self.consecutiveLostFrames > 0
                    )
                } else {
                    observation = nil
                }

                DispatchQueue.main.async {
                    self.onTargetTracked?(observation, pixelBuffer)
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

    private func uiRect(centeredAt center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Chụp tức thì khung hình hiện tại cho AI Cloud phân tích
    public func captureImmediateFrame(completion: @escaping (CGImage?) -> Void) {
        if let lastBuf = self.kltPreviousBuffer {
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
