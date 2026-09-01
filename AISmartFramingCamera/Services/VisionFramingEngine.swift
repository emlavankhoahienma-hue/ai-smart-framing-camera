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
    
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private var isProcessingFrame = false
    private var lastProcessTime: TimeInterval = 0
    private let frameThrottleInterval: TimeInterval = 0.033 // ~30 FPS for ultra-smooth optical tracking
    public var isIdlePreviewMode: Bool = false
    private let idleThrottleInterval: TimeInterval = 0.2 // ~5 FPS lúc rảnh, vẫn đủ mượt cho preview mặt/scene
    
    // Callbacks
    public var onDetectionCompleted: ((SubjectDetectionResult) -> Void)?
    public var onTargetTracked: ((CGPoint?, Double, CVPixelBuffer) -> Void)?
    public var onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)?
    
    // Gemini Frame Capture
    public var captureNextFrameForGemini: Bool = false
    public var capturedGeminiFrame: CGImage? = nil
    
    // Visual Feature Object Tracking (VNTrackObjectRequest + Deep FeaturePrint Re-ID + Color Histogram + KLT Point Cluster)
    public private(set) var isTrackingTarget: Bool = false
    public var currentSceneType: DetectedSceneType = .general
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTargetObservation: VNDetectedObjectObservation? = nil
    private var referenceFeaturePrint: VNFeaturePrintObservation? = nil
    private var referenceColorHistogram: [Float]? = nil
    private var consecutiveLostFrames: Int = 0
    
    // KLT (Lucas-Kanade) Feature Point Cluster Tracker + RANSAC
    private var kltTrackedPoints: [CGPoint] = []
    private var kltPreviousBuffer: CVPixelBuffer? = nil
    private var kltTargetBox: CGRect = .zero
    
    // Vision Detection Requests
    private var faceDetectionRequest: VNDetectFaceRectanglesRequest!
    private var faceLandmarksRequest: VNDetectFaceLandmarksRequest!
    private var humanPoseRequest: VNDetectHumanBodyPoseRequest!
    private var saliencyRequest: VNGenerateObjectnessBasedSaliencyImageRequest!
    private var sceneClassificationRequest: VNClassifyImageRequest!
    
    public init() {
        setupVisionRequests()
    }
    
    private func setupVisionRequests() {
        // 1. Face Rectangle Detection
        faceDetectionRequest = VNDetectFaceRectanglesRequest()
        faceDetectionRequest.revision = VNDetectFaceRectanglesRequestRevision3
        
        // 2. Face Landmarks (Eyes, Nose, Chin)
        faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        faceLandmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        
        // 3. Human Body Pose Detection
        humanPoseRequest = VNDetectHumanBodyPoseRequest()
        humanPoseRequest.revision = VNDetectHumanBodyPoseRequestRevision1
        
        // 4. Objectness Saliency
        saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        saliencyRequest.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
        
        // 5. Scene Classification
        sceneClassificationRequest = VNClassifyImageRequest()
        sceneClassificationRequest.revision = VNClassifyImageRequestRevision1
    }
    
    // MARK: - Visual Object Tracking Control
    
    /// Khởi động tracking bám dính vào vùng cảnh vật/vật thể/chữ tại toạ độ mục tiêu
    public func startTrackingObject(at normalizedPoint: CGPoint, size: CGSize = CGSize(width: 0.12, height: 0.12)) {
        // Convert UI coordinate (top-left origin) to Vision coordinate (bottom-left origin)
        let visionY = 1.0 - normalizedPoint.y - (size.height / 2.0)
        let visionX = normalizedPoint.x - (size.width / 2.0)
        
        let clampedRect = CGRect(
            x: max(0.01, min(0.80, visionX)),
            y: max(0.01, min(0.80, visionY)),
            width: size.width,
            height: size.height
        )
        
        let initialObservation = VNDetectedObjectObservation(boundingBox: clampedRect)
        self.lastTargetObservation = initialObservation
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.kltTargetBox = clampedRect
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
        self.isTrackingTarget = true
    }
    
    public func stopTrackingObject() {
        self.isTrackingTarget = false
        self.lastTargetObservation = nil
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.kltTrackedPoints = []
        self.kltPreviousBuffer = nil
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
    }
    
    // MARK: - Cân Bằng Sáng Cục Bộ Thích Nghi (Adaptive ROI Dynamic Range & Local CLAHE)
    private func enhanceROIContrast(in buffer: CVPixelBuffer, roi: CGRect) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        
        let data = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let minX = max(0, min(width - 1, Int(roi.origin.x * CGFloat(width))))
        let minY = max(0, min(height - 1, Int((1.0 - roi.origin.y - roi.size.height) * CGFloat(height))))
        let maxX = max(minX + 1, min(width, Int((roi.origin.x + roi.size.width) * CGFloat(width))))
        let maxY = max(minY + 1, min(height, Int((1.0 - roi.origin.y) * CGFloat(height))))
        
        var minLum: Float = 255.0
        var maxLum: Float = 0.0
        let step = max(1, (maxX - minX) / 24)
        
        for y in stride(from: minY, to: maxY, by: max(1, step)) {
            for x in stride(from: minX, to: maxX, by: max(1, step)) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(data[offset])
                let g = Float(data[offset + 1])
                let r = Float(data[offset + 2])
                let lum = r * 0.299 + g * 0.587 + b * 0.114
                if lum < minLum { minLum = lum }
                if lum > maxLum { maxLum = lum }
            }
        }
        
        let range = maxLum - minLum
        guard range > 12.0 && range < 185.0 else { return }
        
        let scale = 220.0 / range
        let stretchStep = max(1, (maxX - minX) / 80)
        
        for y in stride(from: minY, to: maxY, by: max(1, stretchStep)) {
            for x in stride(from: minX, to: maxX, by: max(1, stretchStep)) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(data[offset])
                let g = Float(data[offset + 1])
                let r = Float(data[offset + 2])
                
                let newB = max(0, min(255, (b - minLum) * scale + 15))
                let newG = max(0, min(255, (g - minLum) * scale + 15))
                let newR = max(0, min(255, (r - minLum) * scale + 15))
                
                data[offset] = UInt8(b * 0.40 + newB * 0.60)
                data[offset + 1] = UInt8(g * 0.40 + newG * 0.60)
                data[offset + 2] = UInt8(r * 0.40 + newR * 0.60)
            }
        }
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
        
        corners.sort { $0.score > $1.score }
        let top = corners.prefix(30).map { $0.point }
        if top.count < 8 {
            var grid: [CGPoint] = top
            for r in 0..<3 {
                for c in 0..<3 {
                    let gx = roi.origin.x + roi.size.width * (CGFloat(c) + 0.5) / 3.0
                    let gy = roi.origin.y + roi.size.height * (CGFloat(r) + 0.5) / 3.0
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
        
        let avgX = inliers.map { $0.x }.reduce(0, +) / CGFloat(inliers.count)
        let avgY = inliers.map { $0.y }.reduce(0, +) / CGFloat(inliers.count)
        self.kltTrackedPoints = inliers
        
        let uiPoint = CGPoint(x: avgX, y: 1.0 - avgY)
        let inlierRatio = Double(inliers.count) / Double(max(1, kltTrackedPoints.count))
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
    
    private func attemptNeuralReIdentification(in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, fallbackPoint: CGPoint?) -> (CGPoint, Double)? {
        guard let refPrint = self.referenceFeaturePrint, let fb = fallbackPoint else { return nil }
        
        var candidateBoxes: [CGRect] = []
        let boxSize: CGFloat = 0.14
        
        // CHỈ tìm kiếm trong phạm vi hẹp cục bộ quanh vị trí vật thể thực tế (bán kính <= 0.06), TUYỆT ĐỐI KHÔNG quét toàn màn hình để tránh nhảy vào bầu trời, cửa, nước
        let offsets: [CGFloat] = [-0.05, 0.0, 0.05]
        for dy in offsets {
            for dx in offsets {
                let testUix = fb.x + dx
                let testUiy = fb.y + dy
                let vx = testUix - boxSize / 2
                let vy = 1.0 - testUiy - boxSize / 2
                let clampedBox = CGRect(x: max(0.01, min(1.0 - boxSize - 0.01, vx)),
                                        y: max(0.01, min(1.0 - boxSize - 0.01, vy)),
                                        width: boxSize,
                                        height: boxSize)
                candidateBoxes.append(clampedBox)
            }
        }
        
        var bestBox: CGRect? = nil
        var minDistance: Float = Float.greatestFiniteMagnitude
        var bestColorSim: Double = 0.0
        
        for box in candidateBoxes {
            let req = VNGenerateImageFeaturePrintRequest()
            req.imageCropAndScaleOption = .scaleFit
            req.regionOfInterest = box
            let h = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
            do {
                try h.perform([req])
                if let candidatePrint = req.results?.first as? VNFeaturePrintObservation {
                    var dist: Float = 0
                    try refPrint.computeDistance(&dist, to: candidatePrint)
                    
                    var colorSim: Double = 1.0
                    if let refHist = self.referenceColorHistogram {
                        let candHist = self.extractColorHistogram(from: buffer, region: box)
                        colorSim = Double(self.compareColorHistograms(refHist, candHist))
                    }
                    
                    // Siết chặt điều kiện: distance < 0.32 và colorSim >= 0.70 (chỉ nhận đúng vật thể ban đầu)
                    if dist < minDistance && dist < 0.32 && colorSim >= 0.70 {
                        minDistance = dist
                        bestBox = box
                        bestColorSim = colorSim
                    }
                }
            } catch {
                continue
            }
        }
        
        if let matchedBox = bestBox, minDistance < 0.32 {
            CameraLogger.info("🎯 Local Neural Re-ID thành công quanh vật thể (Dist: \(String(format: "%.3f", minDistance)), Color: \(String(format: "%.2f", bestColorSim)))", category: .tracking)
            let newObs = VNDetectedObjectObservation(boundingBox: matchedBox)
            self.lastTargetObservation = newObs
            self.sequenceHandler = VNSequenceRequestHandler()
            let uiX = matchedBox.midX
            let uiY = 1.0 - matchedBox.midY
            let confidence = max(0.70, Double(1.0 - (minDistance / 0.32)) * 0.7 + bestColorSim * 0.3)
            return (CGPoint(x: uiX, y: uiY), confidence)
        }
        
        return nil
    }
    
    // MARK: - Process Incoming Video PixelBuffer
    public func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation = .up) {
        let currentTime = CACurrentMediaTime()
        let effectiveThrottle = isIdlePreviewMode ? idleThrottleInterval : frameThrottleInterval
        guard currentTime - lastProcessTime >= effectiveThrottle else { return }
        guard !isProcessingFrame else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        isProcessingFrame = true
        lastProcessTime = currentTime
        
        // Capture frame for Gemini if requested
        let shouldCaptureForGemini = captureNextFrameForGemini
        if shouldCaptureForGemini {
            captureNextFrameForGemini = false
            let ciImg = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImg = self.sharedCIContext.createCGImage(ciImg, from: ciImg.extent) {
                DispatchQueue.main.async { [weak self] in
                    self?.capturedGeminiFrame = cgImg
                }
            }
        }
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isProcessingFrame = false }
            
            // 1. Nếu đang ở chế độ tracking mục tiêu (Target Placed)
            if self.isTrackingTarget, let prevObs = self.lastTargetObservation {
                // Không mutate pixelBuffer in-place để tránh tạo cạnh giả trên nền frame trước
                if self.referenceFeaturePrint == nil {
                    self.referenceFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: prevObs.boundingBox)
                    self.referenceColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: prevObs.boundingBox)
                }
                
                // 1A. Tracking quang học phần cứng trực tiếp (Apple VNTrackObjectRequest)
                let trackRequest = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                trackRequest.trackingLevel = .accurate
                
                var trackedPoint: CGPoint? = nil
                var trackedConfidence: Double = 0.0
                
                do {
                    try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)
                    if let results = trackRequest.results as? [VNDetectedObjectObservation], let newObs = results.first {
                        if newObs.confidence > 0.20 {
                            self.lastTargetObservation = newObs
                            self.consecutiveLostFrames = 0
                            var uiX = newObs.boundingBox.midX
                            var uiY = 1.0 - newObs.boundingBox.midY
                            
                            // Xử lý cụm lá cây / mặt nước biến đổi liên tục (Deformable Nature)
                            if self.currentSceneType.isDeformableNature {
                                if let salientCentroid = self.extractSaliencyCentroid(from: pixelBuffer, near: newObs.boundingBox) {
                                    uiX = uiX * 0.4 + salientCentroid.x * 0.6
                                    uiY = uiY * 0.4 + (1.0 - salientCentroid.y) * 0.6
                                }
                            }
                            
                            trackedPoint = CGPoint(x: uiX, y: uiY)
                            trackedConfidence = Double(newObs.confidence)
                        } else {
                            self.consecutiveLostFrames += 1
                        }
                    }
                } catch {
                    self.consecutiveLostFrames += 1
                }
                
                // 1B. Khi mất dấu quang học tạm thời (lia máy nhanh): Tự động tái lập mỏ neo quang học chính xác tại toạ độ không gian
                if trackedPoint == nil && (self.consecutiveLostFrames >= 2) {
                    let spatialPoint = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
                    
                    if let (reIdPoint, reIdConfidence) = self.attemptNeuralReIdentification(in: pixelBuffer, orientation: orientation, fallbackPoint: spatialPoint) {
                        trackedPoint = reIdPoint
                        trackedConfidence = reIdConfidence
                        self.consecutiveLostFrames = 0
                    } else {
                        // Tự động tái lập mỏ neo VNTrackObjectRequest ngay tại vị trí không gian con quay hồi chuyển đang giữ
                        let boxSize: CGFloat = 0.14
                        let vx = max(0.01, min(1.0 - boxSize - 0.01, spatialPoint.x - boxSize / 2.0))
                        let vy = max(0.01, min(1.0 - boxSize - 0.01, (1.0 - spatialPoint.y) - boxSize / 2.0))
                        let reAnchorObs = VNDetectedObjectObservation(boundingBox: CGRect(x: vx, y: vy, width: boxSize, height: boxSize))
                        self.lastTargetObservation = reAnchorObs
                        self.sequenceHandler = VNSequenceRequestHandler()
                        trackedPoint = spatialPoint
                        trackedConfidence = 0.65
                        self.consecutiveLostFrames = 0
                    }
                }
                
                DispatchQueue.main.async {
                    self.onTargetTracked?(trackedPoint, trackedConfidence, pixelBuffer)
                }
                return
            }
            
            // 2. Chế độ phát hiện thông minh đa tầng bằng NeuralSubjectIntelligenceEngine (Apple Neural Engine ANE)
            let (primaryCandidate, allCandidates, detectedScene) = NeuralSubjectIntelligenceEngine.shared.analyzeFrame(
                pixelBuffer: pixelBuffer,
                orientation: orientation
            )
            
            var result = SubjectDetectionResult()
            result.detectedScene = detectedScene
            
            if let primary = primaryCandidate {
                result.dominantSubjectRect = primary.boundingBox
                result.confidence = primary.confidence
                if primary.category == .face {
                    result.faceRectangles = [primary.boundingBox]
                }
            }
            
            // Smart Focus Point
            let smartFocusPoint: CGPoint
            let smartFocusType: SmartFocusType
            if let primary = primaryCandidate {
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
}
