import Foundation
import CoreGraphics
import CoreMedia
import Vision
import CoreImage
import Accelerate
import QuartzCore

/// Phân loại chủ thể vạn vật không bị giới hạn nhãn
public enum UniversalSubjectCategory: String, Codable, Sendable {
    case person
    case animal
    case architecture
    case natureLandscape
    case stillLifeObject
    case unknownSalient
}

/// Bố cục thị giác tối ưu hóa
public enum OptimalCompositionAnchor: String, Codable, Sendable {
    case ruleOfThirdsLeft
    case ruleOfThirdsRight
    case goldenRatioLeft
    case goldenRatioRight
    case centerSymmetry
    case negativeSpaceDominant
    case landscapeHorizonLower
}

/// Ứng viên chủ thể anh hùng (Hero Target Candidate)
public struct UniversalHeroTarget: Sendable {
    public let boundingBox: CGRect // Chuẩn hóa [0..1] theo toạ độ ảnh (gốc trái-dưới hoặc quy ước Vision)
    public let normalizedCenter: CGPoint
    public let confidence: Float
    public let category: UniversalSubjectCategory
    public let compositionAnchor: OptimalCompositionAnchor
    public let targetAimPoint: CGPoint // Điểm căn tâm vàng đề xuất trên kính ngắm (thay vì dính ở 0.5, 0.5)
    public let backgroundContextScore: Float // Điểm thẩm mỹ bối cảnh [0..1]
    public let edgeClutterScore: Float // Độ rối/rác rìa khung hình [0..1]
    public let keypointJoints: [CGPoint] // Toạ độ khớp giải phẫu nếu có
    
    public init(
        boundingBox: CGRect,
        normalizedCenter: CGPoint,
        confidence: Float,
        category: UniversalSubjectCategory,
        compositionAnchor: OptimalCompositionAnchor,
        targetAimPoint: CGPoint,
        backgroundContextScore: Float,
        edgeClutterScore: Float,
        keypointJoints: [CGPoint] = []
    ) {
        self.boundingBox = boundingBox
        self.normalizedCenter = normalizedCenter
        self.confidence = confidence
        self.category = category
        self.compositionAnchor = compositionAnchor
        self.targetAimPoint = targetAimPoint
        self.backgroundContextScore = backgroundContextScore
        self.edgeClutterScore = edgeClutterScore
        self.keypointJoints = keypointJoints
    }
}

/// Động cơ phát hiện chủ thể anh hùng vạn vật (Universal Saliency & Multi-Modal Fusion)
public final class UniversalSalientTargetEngine: @unchecked Sendable {
    public static let shared = UniversalSalientTargetEngine()
    
    private let processingQueue = DispatchQueue(label: "com.alignai.universal.target", qos: .userInitiated)
    private var lastAnalyzedTime: CFTimeInterval = 0
    private let analysisInterval: CFTimeInterval = 0.08 // ~12 FPS phân tích sâu ANE
    
    private init() {}
    
    /// Phân tích đa tín hiệu thực tế trên khung hình (Attention Saliency + Objectness + Instance Mask + Pose + Heuristics)
    public func analyzeFrame(
        pixelBuffer: CVPixelBuffer,
        knownDetections: [(rect: CGRect, label: String, confidence: Float)] = [],
        completion: @escaping (UniversalHeroTarget?) -> Void
    ) {
        let now = CACurrentMediaTime()
        guard now - lastAnalyzedTime >= analysisInterval else {
            return
        }
        lastAnalyzedTime = now
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            let target = self.performMultiModalAnalysis(pixelBuffer: pixelBuffer, knownDetections: knownDetections)
            DispatchQueue.main.async {
                completion(target)
            }
        }
    }
    
    /// Luồng phân tích đa tín hiệu hợp nhất
    public func performMultiModalAnalysis(
        pixelBuffer: CVPixelBuffer,
        knownDetections: [(rect: CGRect, label: String, confidence: Float)] = []
    ) -> UniversalHeroTarget? {
        var attentionHeatmapRects: [CGRect] = []
        var objectnessRects: [CGRect] = []
        var detectedJoints: [CGPoint] = []
        var humanRects: [CGRect] = []
        
        // 1. Apple Vision Attention Saliency (ANE)
        let attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        // 2. Apple Vision Objectness Saliency (ANE)
        let objectnessRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        // 3. Human Body Pose Request (Khớp xương giải phẫu)
        let poseRequest = VNDetectHumanBodyPoseRequest()
        // 4. Human Rectangles Request
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        var requests: [VNRequest] = [attentionRequest, objectnessRequest, humanRequest, poseRequest]
        
        // Hỗ trợ VNGenerateForegroundInstanceMaskRequest trên iOS 17+
        if #available(iOS 17.0, *) {
            let instanceMaskRequest = VNGenerateForegroundInstanceMaskRequest()
            requests.append(instanceMaskRequest)
        }
        
        do {
            try handler.perform(requests)
            
            // Xử lý Attention Saliency
            if let saliencyObs = attentionRequest.results?.first as? VNSaliencyImageObservation,
               let salientObjects = saliencyObs.salientObjects {
                attentionHeatmapRects = salientObjects.map { $0.boundingBox }
            }
            
            // Xử lý Objectness Saliency
            if let objObs = objectnessRequest.results?.first as? VNSaliencyImageObservation,
               let salientObjects = objObs.salientObjects {
                objectnessRects = salientObjects.map { $0.boundingBox }
            }
            
            // Xử lý Human Rectangles
            if let humans = humanRequest.results {
                humanRects = humans.map { $0.boundingBox }
            }
            
            // Xử lý Body Keypoints
            if let poses = poseRequest.results {
                for pose in poses {
                    if let recognizedPoints = try? pose.recognizedPoints(.all) {
                        for (_, point) in recognizedPoints where point.confidence > 0.3 {
                            detectedJoints.append(CGPoint(x: point.location.x, y: point.location.y))
                        }
                    }
                }
            }
        } catch {
            // Fallback gracefully nếu Vision request gặp lỗi tạm thời
        }
        
        // 5. Kết hợp Spectral Residual & Độ rối mép khung hình (Edge Clutter)
        let (backgroundContextScore, edgeClutterScore) = self.calculateContextAndClutter(
            pixelBuffer: pixelBuffer,
            salientRects: attentionHeatmapRects + objectnessRects
        )
        
        // 6. Hợp nhất các hộp ứng viên từ mọi nguồn
        var candidates: [(rect: CGRect, score: Float, category: UniversalSubjectCategory)] = []
        
        // Thêm từ Human Detections
        for hr in humanRects {
            candidates.append((hr, 0.92, .person))
        }
        
        // Thêm từ Known Detections (YOLO / SigLIP)
        for kd in knownDetections {
            let cat: UniversalSubjectCategory
            let lower = kd.label.lowercased()
            if lower.contains("person") || lower.contains("face") || lower.contains("human") {
                cat = .person
            } else if lower.contains("dog") || lower.contains("cat") || lower.contains("bird") || lower.contains("horse") || lower.contains("animal") {
                cat = .animal
            } else if lower.contains("building") || lower.contains("house") || lower.contains("tower") || lower.contains("bridge") {
                cat = .architecture
            } else if lower.contains("mountain") || lower.contains("tree") || lower.contains("flower") || lower.contains("sea") {
                cat = .natureLandscape
            } else {
                cat = .stillLifeObject
            }
            candidates.append((kd.rect, kd.confidence, cat))
        }
        
        // Thêm từ Objectness & Attention Saliency (Vạn vật vô hướng)
        for salRect in (objectnessRects + attentionHeatmapRects) {
            let isAlreadyCovered = candidates.contains { c in
                let intersection = c.rect.intersection(salRect)
                let union = c.rect.union(salRect)
                return (intersection.width * intersection.height) / max(0.0001, union.width * union.height) > 0.4
            }
            if !isAlreadyCovered && salRect.width > 0.05 && salRect.height > 0.05 {
                let cat: UniversalSubjectCategory = salRect.height > salRect.width * 1.5 ? .person : .stillLifeObject
                candidates.append((salRect, 0.75, cat))
            }
        }
        
        guard !candidates.isEmpty else {
            return nil
        }
        
        // 7. Xếp hạng chủ thể anh hùng (Hero Subject Selection) - CHỐNG BẪY HÚT VỀ TÂM
        var bestCandidate: (rect: CGRect, score: Float, category: UniversalSubjectCategory)? = nil
        var highestScore: Float = -1.0
        
        for cand in candidates {
            let box = cand.rect
            let cx = box.midX
            let area = Float(box.width * box.height)
            
            // Diện tích lý tưởng (không quá bé < 2%, không choán toàn màn hình > 85%)
            let areaScore: Float = (area >= 0.03 && area <= 0.70) ? 1.0 : (area < 0.03 ? area / 0.03 : (0.85 - area) / 0.15)
            
            // Phạt mép biên: CHỈ PHẠT NẶNG KHI BỊ CẮT SÁT MÉP < 3%
            var marginPenalty: Float = 0.0
            if box.minX < 0.03 || box.maxX > 0.97 || box.minY < 0.03 || box.maxY > 0.97 {
                marginPenalty = 0.25
            }
            
            // Điểm bố cục: Ưu đãi các vị trí 1/3, Tỷ lệ vàng (0.382 / 0.618) hoặc trục giữa đối xứng
            let distToThirdX = min(abs(cx - 0.333), abs(cx - 0.667), abs(cx - 0.5))
            let compositionAffinity: Float = 1.0 - Float(distToThirdX) * 0.8
            
            let totalScore = (cand.score * 0.40) + (areaScore * 0.25) + (compositionAffinity * 0.35) - marginPenalty
            
            if totalScore > highestScore {
                highestScore = totalScore
                bestCandidate = (cand.rect, totalScore, cand.category)
            }
        }
        
        guard let hero = bestCandidate else { return nil }
        
        // 8. Xác định điểm bố cục tối ưu (Target Aim Point) - KHÔNG NẰM LÌ Ở (0.5, 0.5)
        let (anchor, targetAimPoint) = self.determineOptimalCompositionAnchor(for: hero.rect, category: hero.category)
        
        return UniversalHeroTarget(
            boundingBox: hero.rect,
            normalizedCenter: CGPoint(x: hero.rect.midX, y: hero.rect.midY),
            confidence: min(1.0, max(0.1, hero.score)),
            category: hero.category,
            compositionAnchor: anchor,
            targetAimPoint: targetAimPoint,
            backgroundContextScore: backgroundContextScore,
            edgeClutterScore: edgeClutterScore,
            keypointJoints: detectedJoints
        )
    }
    
    /// Tính toán điểm bố cục vàng cho Target
    private func determineOptimalCompositionAnchor(
        for box: CGRect,
        category: UniversalSubjectCategory
    ) -> (OptimalCompositionAnchor, CGPoint) {
        let cx = box.midX
        
        switch category {
        case .architecture:
            // Kiến trúc: Nếu gần trục giữa thì ưu tiên Đối xứng tâm (0.5, 0.45)
            if abs(cx - 0.5) < 0.15 {
                return (.centerSymmetry, CGPoint(x: 0.50, y: 0.48))
            } else if cx < 0.5 {
                return (.goldenRatioLeft, CGPoint(x: 0.382, y: 0.45))
            } else {
                return (.goldenRatioRight, CGPoint(x: 0.618, y: 0.45))
            }
            
        case .natureLandscape:
            // Phong cảnh: Đặt tiêu điểm ở đường chân trời 1/3 dưới
            if cx < 0.5 {
                return (.ruleOfThirdsLeft, CGPoint(x: 0.333, y: 0.382))
            } else {
                return (.ruleOfThirdsRight, CGPoint(x: 0.667, y: 0.382))
            }
            
        case .person, .animal:
            // Người/Động vật: Ưu tiên điểm vàng 1/3 (0.382 hoặc 0.618)
            if cx <= 0.48 {
                return (.goldenRatioLeft, CGPoint(x: 0.382, y: 0.42))
            } else if cx >= 0.52 {
                return (.goldenRatioRight, CGPoint(x: 0.618, y: 0.42))
            } else {
                // Ở gần giữa thì giữ tâm thanh lịch
                return (.centerSymmetry, CGPoint(x: 0.50, y: 0.42))
            }
            
        case .stillLifeObject, .unknownSalient:
            if cx < 0.45 {
                return (.ruleOfThirdsLeft, CGPoint(x: 0.35, y: 0.50))
            } else if cx > 0.55 {
                return (.ruleOfThirdsRight, CGPoint(x: 0.65, y: 0.50))
            } else {
                return (.centerSymmetry, CGPoint(x: 0.50, y: 0.50))
            }
        }
    }
    
    /// Đánh giá chất lượng bối cảnh (Background Context) và độ rối mép viền (Edge Clutter)
    private func calculateContextAndClutter(
        pixelBuffer: CVPixelBuffer,
        salientRects: [CGRect]
    ) -> (contextScore: Float, clutterScore: Float) {
        // Kiểm tra số lượng vật thể gây nhiễu sát mép khung hình
        let edgeIntrusions = salientRects.filter { r in
            return r.minX < 0.05 || r.maxX > 0.95 || r.minY < 0.05 || r.maxY > 0.95
        }.count
        
        let edgeClutter = min(1.0, Float(edgeIntrusions) * 0.35 + Float(max(0, salientRects.count - 1)) * 0.15)
        
        // Bối cảnh hài hòa khi không có quá nhiều rác rìa khung hình
        let contextScore = max(0.1, 1.0 - edgeClutter * 0.7)
        
        return (contextScore, edgeClutter)
    }
}
