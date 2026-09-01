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
    
    // Visual Feature Object Tracking (VNTrackObjectRequest + Deep FeaturePrint Re-ID + Color Histogram)
    public private(set) var isTrackingTarget: Bool = false
    public var currentSceneType: DetectedSceneType = .general
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTargetObservation: VNDetectedObjectObservation? = nil
    private var referenceFeaturePrint: VNFeaturePrintObservation? = nil
    private var referenceColorHistogram: [Float]? = nil
    private var consecutiveLostFrames: Int = 0
    
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
    public func startTrackingObject(at normalizedPoint: CGPoint, size: CGSize = CGSize(width: 0.18, height: 0.18)) {
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
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
        self.isTrackingTarget = true
    }
    
    public func stopTrackingObject() {
        self.isTrackingTarget = false
        self.lastTargetObservation = nil
        self.referenceFeaturePrint = nil
        self.referenceColorHistogram = nil
        self.consecutiveLostFrames = 0
        self.sequenceHandler = VNSequenceRequestHandler()
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
                    if d < minDistance && d < 0.35 {
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
        guard let refPrint = self.referenceFeaturePrint else { return nil }
        
        var candidateBoxes: [CGRect] = []
        if let fb = fallbackPoint {
            let fbVisionY = 1.0 - fb.y - 0.10
            let fbVisionX = fb.x - 0.10
            candidateBoxes.append(CGRect(x: max(0, min(0.8, fbVisionX)), y: max(0, min(0.8, fbVisionY)), width: 0.20, height: 0.20))
        }
        
        let searchPoints: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.35, y: 0.35),
            CGPoint(x: 0.65, y: 0.35),
            CGPoint(x: 0.35, y: 0.65),
            CGPoint(x: 0.65, y: 0.65)
        ]
        for p in searchPoints {
            let vy = 1.0 - p.y - 0.10
            let vx = p.x - 0.10
            candidateBoxes.append(CGRect(x: max(0, min(0.8, vx)), y: max(0, min(0.8, vy)), width: 0.20, height: 0.20))
        }
        
        var bestBox: CGRect? = nil
        var minDistance: Float = Float.greatestFiniteMagnitude
        
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
                    if dist < minDistance {
                        minDistance = dist
                        bestBox = box
                    }
                }
            } catch {
                continue
            }
        }
        
        if let matchedBox = bestBox, minDistance < 0.48 {
            CameraLogger.info("🎯 Deep Neural Re-ID thành công! Tìm lại được mục tiêu (Distance: \(String(format: "%.3f", minDistance)))", category: .tracking)
            let newObs = VNDetectedObjectObservation(boundingBox: matchedBox)
            self.lastTargetObservation = newObs
            self.sequenceHandler = VNSequenceRequestHandler()
            let uiX = matchedBox.midX
            let uiY = 1.0 - matchedBox.midY
            let confidence = max(0.65, Double(1.0 - (minDistance / 0.50)))
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
                // Dynamic EKF: Bầu trời / Đám mây -> bỏ qua optical jitter, nhường 100% cho 3D Gyro
                if self.currentSceneType.isSkyOrInfiniteHorizon {
                    DispatchQueue.main.async {
                        self.onTargetTracked?(nil, 0.95, pixelBuffer)
                    }
                    return
                }
                
                if self.referenceFeaturePrint == nil {
                    self.referenceFeaturePrint = self.extractFeaturePrint(from: pixelBuffer, regionOfInterest: prevObs.boundingBox)
                    self.referenceColorHistogram = self.extractColorHistogram(from: pixelBuffer, region: prevObs.boundingBox)
                }
                
                let trackRequest = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                trackRequest.trackingLevel = .accurate
                
                var trackedPoint: CGPoint? = nil
                var trackedConfidence: Double = 0.0
                
                do {
                    try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)
                    if let results = trackRequest.results as? [VNDetectedObjectObservation], let newObs = results.first {
                        if newObs.confidence > 0.25 {
                            self.lastTargetObservation = newObs
                            self.consecutiveLostFrames = 0
                            var uiX = newObs.boundingBox.midX
                            var uiY = 1.0 - newObs.boundingBox.midY
                            
                            // Xử lý cụm lá cây / mặt nước biến đổi liên tục (Deformable Nature)
                            if self.currentSceneType.isDeformableNature {
                                if let salientCentroid = self.extractSaliencyCentroid(from: pixelBuffer, near: newObs.boundingBox) {
                                    // Chuyển dịch tâm về trọng tâm toàn bộ tán cây/cụm cảnh
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
                
                // Khi mất dấu quang học: Thử Color Histogram Match + Deep Neural Re-ID
                if trackedPoint == nil && (self.consecutiveLostFrames >= 2) {
                    let spatialPoint = SpatialTrackingEngine.shared.currentEstimatedScreenPoint
                    
                    if let refHist = self.referenceColorHistogram, self.currentSceneType.isDeformableNature {
                        let testBox = CGRect(x: max(0, min(0.8, spatialPoint.x - 0.1)), y: max(0, min(0.8, (1.0 - spatialPoint.y) - 0.1)), width: 0.20, height: 0.20)
                        let currentHist = self.extractColorHistogram(from: pixelBuffer, region: testBox)
                        let colorSim = self.compareColorHistograms(refHist, currentHist)
                        if colorSim > 0.68 {
                            trackedPoint = spatialPoint
                            trackedConfidence = Double(colorSim)
                            self.consecutiveLostFrames = 0
                        }
                    }
                    
                    if trackedPoint == nil, let (reIdPoint, reIdConfidence) = self.attemptNeuralReIdentification(in: pixelBuffer, orientation: orientation, fallbackPoint: spatialPoint) {
                        trackedPoint = reIdPoint
                        trackedConfidence = reIdConfidence
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
