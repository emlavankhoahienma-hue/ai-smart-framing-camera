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
    public var onTargetTracked: ((CGPoint?, Double) -> Void)?
    public var onSmartFocusPointCalculated: ((CGPoint, SmartFocusType) -> Void)?
    
    // Gemini Frame Capture
    public var captureNextFrameForGemini: Bool = false
    public var capturedGeminiFrame: CGImage? = nil
    
    // Visual Feature Object Tracking (VNTrackObjectRequest)
    public private(set) var isTrackingTarget: Bool = false
    private var sequenceHandler = VNSequenceRequestHandler()
    private var lastTargetObservation: VNDetectedObjectObservation? = nil
    
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
        self.sequenceHandler = VNSequenceRequestHandler()
        self.isTrackingTarget = true
    }
    
    public func stopTrackingObject() {
        self.isTrackingTarget = false
        self.lastTargetObservation = nil
        self.sequenceHandler = VNSequenceRequestHandler()
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
            
            // 1. Nếu đang ở chế độ tracking mục tiêu (Target Placed) -> Chạy VNTrackObjectRequest bám vật thể
            if self.isTrackingTarget, let prevObs = self.lastTargetObservation {
                let trackRequest = VNTrackObjectRequest(detectedObjectObservation: prevObs)
                trackRequest.trackingLevel = .accurate // Optical flow + deep visual template matching
                
                do {
                    try self.sequenceHandler.perform([trackRequest], on: pixelBuffer, orientation: orientation)
                    if let results = trackRequest.results as? [VNDetectedObjectObservation], let newObs = results.first {
                        if newObs.confidence > 0.25 {
                            self.lastTargetObservation = newObs
                            // Convert from Vision (bottom-left) to UI (top-left)
                            let uiX = newObs.boundingBox.midX
                            let uiY = 1.0 - newObs.boundingBox.midY
                            let trackedPoint = CGPoint(x: uiX, y: uiY)
                            
                            DispatchQueue.main.async {
                                self.onTargetTracked?(trackedPoint, Double(newObs.confidence))
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.onTargetTracked?(nil, Double(newObs.confidence))
                            }
                        }
                    }
                } catch {
                    print("Visual tracking frame error: \(error)")
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
            } catch {
                result.detectedScene = .general
                result.confidence = 0.5
                DispatchQueue.main.async {
                    self.onDetectionCompleted?(result)
                    self.onSmartFocusPointCalculated?(CGPoint(x: 0.5, y: 0.5), .center)
                }
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
