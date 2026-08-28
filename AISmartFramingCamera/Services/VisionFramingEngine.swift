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
    
    private var isProcessingFrame = false
    private var lastProcessTime: TimeInterval = 0
    private let frameThrottleInterval: TimeInterval = 0.033 // ~30 FPS for ultra-smooth optical tracking
    
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
    private var saliencyRequest: VNGenerateAttentionBasedSaliencyImageRequest!
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
        
        // 4. Attention Saliency
        saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        saliencyRequest.revision = VNGenerateAttentionBasedSaliencyImageRequestRevision1
        
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
        guard currentTime - lastProcessTime >= frameThrottleInterval else { return }
        guard !isProcessingFrame else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        isProcessingFrame = true
        lastProcessTime = currentTime
        
        // Capture frame for Gemini if requested
        let shouldCaptureForGemini = captureNextFrameForGemini
        if shouldCaptureForGemini {
            captureNextFrameForGemini = false
            let ciImg = CIImage(cvPixelBuffer: pixelBuffer)
            let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
            if let cgImg = ciCtx.createCGImage(ciImg, from: ciImg.extent) {
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
            
            // 2. Chế độ phát hiện thông thường (Analyzing / Idle)
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            var result = SubjectDetectionResult()
            
            do {
                try handler.perform([
                    self.faceDetectionRequest,
                    self.faceLandmarksRequest,
                    self.humanPoseRequest,
                    self.saliencyRequest,
                    self.sceneClassificationRequest
                ])
                
                // Parse Faces
                if let faces = self.faceDetectionRequest.results as? [VNFaceObservation], !faces.isEmpty {
                    result.faceRectangles = faces.map { face in
                        CGRect(
                            x: face.boundingBox.origin.x,
                            y: 1.0 - face.boundingBox.origin.y - face.boundingBox.height,
                            width: face.boundingBox.width,
                            height: face.boundingBox.height
                        )
                    }
                    
                    if let primaryFace = faces.first {
                        let uiBounding = CGRect(
                            x: primaryFace.boundingBox.origin.x,
                            y: 1.0 - primaryFace.boundingBox.origin.y - primaryFace.boundingBox.height,
                            width: primaryFace.boundingBox.width,
                            height: primaryFace.boundingBox.height
                        )
                        result.dominantSubjectRect = uiBounding
                        result.detectedScene = .portrait
                        
                        if let landmarks = primaryFace.landmarks,
                           let leftEye = landmarks.leftEye,
                           let rightEye = landmarks.rightEye,
                           let nose = landmarks.nose {
                            let leftEyeNorm = leftEye.normalizedPoints.first ?? .zero
                            let rightEyeNorm = rightEye.normalizedPoints.first ?? .zero
                            let noseNorm = nose.normalizedPoints.first ?? .zero
                            let eyeMidX = (leftEyeNorm.x + rightEyeNorm.x) / 2.0
                            let gazeDx = noseNorm.x - eyeMidX
                            result.lookingDirection = CGVector(dx: gazeDx * 5.0, dy: 0)
                            let primaryEyeY = uiBounding.origin.y + (1.0 - leftEyeNorm.y) * uiBounding.height
                            result.primaryEyePosition = CGPoint(x: uiBounding.midX, y: primaryEyeY)
                        }
                    }
                }
                
                // Parse Body Pose
                if let poses = self.humanPoseRequest.results as? [VNHumanBodyPoseObservation], !poses.isEmpty {
                    for pose in poses {
                        if let recognizedPoints = try? pose.recognizedPoints(.all) {
                            for (_, point) in recognizedPoints where point.confidence > 0.4 {
                                result.humanBodyPoses.append(CGPoint(x: point.location.x, y: 1.0 - point.location.y))
                            }
                        }
                    }
                    if result.dominantSubjectRect == nil, let firstPose = poses.first {
                        if let neck = try? firstPose.recognizedPoint(.neck), neck.confidence > 0.3 {
                            let center = CGPoint(x: neck.location.x, y: 1.0 - neck.location.y)
                            result.dominantSubjectRect = CGRect(x: center.x - 0.15, y: center.y - 0.2, width: 0.3, height: 0.4)
                            result.detectedScene = .portrait
                        }
                    }
                }
                
                // Parse Saliency
                if result.dominantSubjectRect == nil,
                   let saliency = self.saliencyRequest.results?.first as? VNSaliencyImageObservation,
                   let salientObjects = saliency.salientObjects, !salientObjects.isEmpty {
                    let dominant = salientObjects[0]
                    result.dominantSubjectRect = CGRect(
                        x: dominant.boundingBox.origin.x,
                        y: 1.0 - dominant.boundingBox.origin.y - dominant.boundingBox.height,
                        width: dominant.boundingBox.width,
                        height: dominant.boundingBox.height
                    )
                    result.saliencyPoints = salientObjects.map { obj in
                        CGPoint(x: obj.boundingBox.midX, y: 1.0 - obj.boundingBox.midY)
                    }
                }
                
                // Parse Scene Classification
                if let classifications = self.sceneClassificationRequest.results as? [VNClassificationObservation], !classifications.isEmpty {
                    for item in classifications.prefix(5) {
                        let id = item.identifier.lowercased()
                        if id.contains("sunset") || id.contains("sunrise") || id.contains("golden hour") || id.contains("twilight") {
                            result.detectedScene = .sunset
                            break
                        } else if id.contains("mountain") || id.contains("ocean") || id.contains("valley") || id.contains("landscape") || id.contains("forest") {
                            result.detectedScene = .landscape
                            break
                        } else if id.contains("building") || id.contains("skyscraper") || id.contains("architecture") || id.contains("bridge") {
                            result.detectedScene = .architecture
                            break
                        } else if id.contains("food") || id.contains("meal") || id.contains("dish") || id.contains("plate") {
                            result.detectedScene = .food
                            break
                        } else if id.contains("night") || id.contains("dark") || id.contains("city light") {
                            result.detectedScene = .night
                            break
                        } else if id.contains("street") || id.contains("pedestrian") || id.contains("vehicle") {
                            result.detectedScene = .street
                            break
                        }
                    }
                }
                
                result.confidence = 0.92
                
                // 3. Smart Autofocus Point Calculation (Face Priority > Saliency Object > Center)
                var smartFocusPoint = CGPoint(x: 0.5, y: 0.5)
                var smartFocusType: SmartFocusType = .center
                
                if let faces = self.faceDetectionRequest.results as? [VNFaceObservation], !faces.isEmpty {
                    // Face Priority: chọn khuôn mặt có diện tích lớn nhất (chủ thể gần camera nhất)
                    if let primaryFace = faces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }) {
                        smartFocusPoint = CGPoint(x: primaryFace.boundingBox.midX, y: 1.0 - primaryFace.boundingBox.midY)
                        smartFocusType = .face
                    }
                } else if let saliency = self.saliencyRequest.results?.first as? VNSaliencyImageObservation,
                          let salientObjects = saliency.salientObjects, let dominant = salientObjects.first {
                    // Saliency Object Priority
                    smartFocusPoint = CGPoint(x: dominant.boundingBox.midX, y: 1.0 - dominant.boundingBox.midY)
                    smartFocusType = .salientObject
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
