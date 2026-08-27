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
    private let frameThrottleInterval: TimeInterval = 0.05 // ~20 FPS for optimal battery and Neural Engine throughput
    
    // Callbacks
    public var onDetectionCompleted: ((SubjectDetectionResult) -> Void)?
    
    // Vision Requests
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
    
    // MARK: - Process Incoming Video PixelBuffer
    public func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation = .right) {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessTime >= frameThrottleInterval else { return }
        guard !isProcessingFrame else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        isProcessingFrame = true
        lastProcessTime = currentTime
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isProcessingFrame = false }
            
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
                
                // 1. Parse Faces
                if let faces = self.faceDetectionRequest.results as? [VNFaceObservation], !faces.isEmpty {
                    result.faceRectangles = faces.map { face in
                        // Convert Vision normalized coordinates (bottom-left origin) to UI coordinates (top-left origin)
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
                        
                        // Parse Face Landmarks for Looking Direction
                        if let landmarks = primaryFace.landmarks,
                           let leftEye = landmarks.leftEye,
                           let rightEye = landmarks.rightEye,
                           let nose = landmarks.nose {
                            
                            let leftEyeNorm = leftEye.normalizedPoints.first ?? .zero
                            let rightEyeNorm = rightEye.normalizedPoints.first ?? .zero
                            let noseNorm = nose.normalizedPoints.first ?? .zero
                            
                            // Approximate gaze vector
                            let eyeMidX = (leftEyeNorm.x + rightEyeNorm.x) / 2.0
                            let gazeDx = noseNorm.x - eyeMidX
                            result.lookingDirection = CGVector(dx: gazeDx * 5.0, dy: 0)
                            
                            let primaryEyeY = uiBounding.origin.y + (1.0 - leftEyeNorm.y) * uiBounding.height
                            result.primaryEyePosition = CGPoint(x: uiBounding.midX, y: primaryEyeY)
                        }
                    }
                }
                
                // 2. Parse Human Body Pose
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
                
                // 3. Parse Saliency if no face or body was found
                if result.dominantSubjectRect == nil,
                   let saliency = self.saliencyRequest.results?.first as? VNSaliencyImageObservation,
                   let salientObjects = saliency.salientObjects, !salientObjects.isEmpty {
                    
                    let dominant = salientObjects[0]
                    let salientRect = CGRect(
                        x: dominant.boundingBox.origin.x,
                        y: 1.0 - dominant.boundingBox.origin.y - dominant.boundingBox.height,
                        width: dominant.boundingBox.width,
                        height: dominant.boundingBox.height
                    )
                    result.dominantSubjectRect = salientRect
                    result.saliencyPoints = salientObjects.map { obj in
                        CGPoint(x: obj.boundingBox.midX, y: 1.0 - obj.boundingBox.midY)
                    }
                }
                
                // 4. Parse Scene Classification
                if let classifications = self.sceneClassificationRequest.results as? [VNClassificationObservation], !classifications.isEmpty {
                    let topLabels = classifications.prefix(5)
                    for item in topLabels {
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
                
            } catch {
                // Fallback graceful degradation
                result.detectedScene = .general
                result.confidence = 0.5
            }
            
            DispatchQueue.main.async {
                self.onDetectionCompleted?(result)
            }
        }
    }
}
