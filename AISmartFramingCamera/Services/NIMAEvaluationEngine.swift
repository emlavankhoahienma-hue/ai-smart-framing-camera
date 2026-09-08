//
//  NIMAEvaluationEngine.swift
//  AISmartFramingCamera
//
//  Created for Build 125 - Google NIMA (Neural Image Assessment) Deep Aesthetic Scoring
//

import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import Vision
import CoreML

public final class NIMAEvaluationEngine: @unchecked Sendable {
    public static let shared = NIMAEvaluationEngine()
    
    public var isEnabled: Bool = false
    public private(set) var isAvailable: Bool = false
    
    private let inferenceQueue = DispatchQueue(
        label: "com.aismartframing.nima.inference",
        qos: .userInitiated
    )
    
    private var visionModel: VNCoreMLModel?
    private var mlModel: MLModel?
    
    private init() {
        loadModelAsync()
    }
    
    // MARK: - Asynchronous Model Loading & Warm-Up
    private func loadModelAsync() {
        inferenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Locate NIMAAestheticScorer in App Bundle
            let modelURLs = [
                Bundle.main.url(forResource: "NIMAAestheticScorer", withExtension: "mlmodelc"),
                Bundle.main.url(forResource: "NIMAAestheticScorer", withExtension: "mlpackage")
            ].compactMap { $0 }
            
            guard let modelURL = modelURLs.first else {
                CameraLogger.warning("NIMAAestheticScorer model not found in app bundle. Fallback to heuristic scoring.", category: .ai)
                self.isAvailable = false
                return
            }
            
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all // Target Apple Neural Engine (ANE)
                let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
                let vModel = try VNCoreMLModel(for: loadedModel)
                
                self.mlModel = loadedModel
                self.visionModel = vModel
                self.isAvailable = true
                CameraLogger.info("✅ NIMAAestheticScorer loaded successfully on Apple Neural Engine!", category: .ai)
                
                // Warm up with dummy prediction
                self.warmUpModel()
            } catch {
                CameraLogger.error("Lỗi nạp NIMAAestheticScorer CoreML", error: error, category: .ai)
                self.isAvailable = false
            }
        }
    }
    
    private func warmUpModel() {
        guard let vModel = self.visionModel else { return }
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return }
        
        let request = VNCoreMLRequest(model: vModel)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        try? handler.perform([request])
        CameraLogger.info("NIMAAestheticScorer warm-up complete.", category: .ai)
    }
    
    // MARK: - Candidate Framing Generator
    /// Sinh 4-5 khung hình ứng viên quanh vùng saliency/face hiện có
    public func generateCandidates(
        saliencyRect: CGRect,
        faceRect: CGRect?,
        frameAspect: CGFloat = 4.0 / 3.0
    ) -> [CGRect] {
        let baseRect = faceRect ?? saliencyRect
        var candidates: [CGRect] = []
        
        let centerX = baseRect.midX
        let centerY = baseRect.midY
        let w = max(0.40, min(0.85, baseRect.width * 1.8))
        let h = max(0.40, min(0.85, baseRect.height * 1.8))
        
        // 1. Original Centered Framing
        candidates.append(clampRect(CGRect(x: centerX - w / 2.0, y: centerY - h / 2.0, width: w, height: h)))
        
        // 2. Shifted Left (Providing open leading room to the right)
        candidates.append(clampRect(CGRect(x: centerX - w * 0.65, y: centerY - h / 2.0, width: w, height: h)))
        
        // 3. Shifted Right (Providing open leading room to the left)
        candidates.append(clampRect(CGRect(x: centerX - w * 0.35, y: centerY - h / 2.0, width: w, height: h)))
        
        // 4. Shifted Down (Providing headroom on top for portraits)
        candidates.append(clampRect(CGRect(x: centerX - w / 2.0, y: centerY - h * 0.35, width: w, height: h)))
        
        // 5. Tighter Framing (Zoom ~1.2x candidate)
        let tightW = w * 0.82
        let tightH = h * 0.82
        candidates.append(clampRect(CGRect(x: centerX - tightW / 2.0, y: centerY - tightH / 2.0, width: tightW, height: tightH)))
        
        return candidates
    }
    
    private func clampRect(_ rect: CGRect) -> CGRect {
        let x = max(0.0, min(1.0 - rect.width, rect.origin.x))
        let y = max(0.0, min(1.0 - rect.height, rect.origin.y))
        let w = max(0.20, min(1.0 - x, rect.width))
        let h = max(0.20, min(1.0 - y, rect.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    // MARK: - Candidate Scoring
    /// Chấm điểm 1 candidate bằng NIMA, trả về mean score μ = Σ i·P(i)
    public func scoreCandidate(pixelBuffer: CVPixelBuffer, cropRect: CGRect) -> Double? {
        guard let vModel = self.visionModel else { return nil }
        
        // Convert UI coordinate (Top-Left 0,0) to Vision coordinate (Bottom-Left 0,0)
        let visionROI = CGRect(
            x: max(0.0, min(1.0, cropRect.origin.x)),
            y: max(0.0, min(1.0, 1.0 - cropRect.origin.y - cropRect.height)),
            width: max(0.05, min(1.0, cropRect.width)),
            height: max(0.05, min(1.0, cropRect.height))
        )
        
        var predictedScore: Double?
        
        let request = VNCoreMLRequest(model: vModel) { req, error in
            guard error == nil,
                  let observations = req.results as? [VNCoreMLFeatureValueObservation],
                  let firstObs = observations.first,
                  let multiArray = firstObs.featureValue.multiArrayValue else {
                return
            }
            
            let count = multiArray.count
            guard count >= 10 else { return }
            
            var mean: Double = 0.0
            var sumProbs: Double = 0.0
            
            for i in 0..<10 {
                let p = multiArray[i].doubleValue
                let rating = Double(i + 1)
                mean += rating * p
                sumProbs += p
            }
            
            if sumProbs > 0.5 {
                predictedScore = mean / sumProbs
            } else {
                predictedScore = mean
            }
        }
        
        request.imageCropAndScaleOption = .scaleFill
        request.regionOfInterest = visionROI
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        
        return predictedScore
    }
    
    // MARK: - Async Best Candidate Selection
    public func pickBestCandidate(
        from pixelBuffer: CVPixelBuffer,
        candidates: [CGRect],
        completion: @escaping (CGRect, Double) -> Void
    ) {
        guard !candidates.isEmpty else {
            completion(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), 8.0)
            return
        }
        
        inferenceQueue.async { [weak self] in
            guard let self = self else { return }
            
            var bestCrop = candidates[0]
            var bestScore: Double = 0.0
            
            for candidate in candidates {
                if let score = self.scoreCandidate(pixelBuffer: pixelBuffer, cropRect: candidate) {
                    if score > bestScore {
                        bestScore = score
                        bestCrop = candidate
                    }
                }
            }
            
            if bestScore <= 0.0 {
                bestScore = 8.0
            }
            
            DispatchQueue.main.async {
                completion(bestCrop, (bestScore * 10.0).rounded() / 10.0)
            }
        }
    }
    
    // MARK: - Score Blending
    public static func blendScores(nimaScore: Double, heuristicScore: Double) -> Double {
        let blended = 0.6 * nimaScore + 0.4 * heuristicScore
        return (blended * 10.0).rounded() / 10.0
    }
}
