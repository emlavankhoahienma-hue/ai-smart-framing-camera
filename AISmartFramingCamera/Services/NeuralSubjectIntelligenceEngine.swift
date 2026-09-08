import Foundation
import Vision
import CoreGraphics
import CoreImage
import UIKit

/// Phân loại danh mục chủ thể đời thực
public enum NeuralSubjectCategory: String {
    case human = "👤 Người (Human Body)"
    case face = "😀 Khuôn mặt (Human Face)"
    case animal = "🐶🐱 Thú cưng / Động vật"
    case foregroundObject = "📦 Vật thể tiền cảnh (Object)"
    case general = "🖼️ Cảnh quan chung"
    
    /// Trọng số ưu tiên (Hệ số trí tuệ nhân tạo)
    public var priorityWeight: Double {
        switch self {
        case .human: return 3.0
        case .face: return 2.8
        case .animal: return 2.5
        case .foregroundObject: return 2.0
        case .general: return 0.8
        }
    }
}

/// Ứng viên chủ thể được AI phát hiện và xếp hạng
public struct NeuralSubjectCandidate: Identifiable {
    public let id = UUID()
    public let boundingBox: CGRect // Toạ độ chuẩn hóa UI (Top-Left 0..1)
    public let category: NeuralSubjectCategory
    public let confidence: Float
    public let label: String
    public let prominenceScore: Double
    
    public var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
    
    public var areaRatio: Double {
        Double(boundingBox.width * boundingBox.height)
    }
}

/// Bộ Não Phân Tích Chủ Thể Nơ-ron Đa Tầng (Neural Subject Intelligence Engine)
/// Tận dụng tối đa chip xử lý trí tuệ nhân tạo Apple Neural Engine (ANE) của Apple
public final class NeuralSubjectIntelligenceEngine: @unchecked Sendable {
    public static let shared = NeuralSubjectIntelligenceEngine()
    
    // MARK: - Vision Deep Learning Requests
    private var animalRequest: VNRecognizeAnimalsRequest!
    private var humanBodyRequest: VNDetectHumanRectanglesRequest!
    private var faceRequest: VNDetectFaceRectanglesRequest!
    private var faceLandmarksRequest: VNDetectFaceLandmarksRequest!
    private var saliencyObjectRequest: VNGenerateObjectnessBasedSaliencyImageRequest!
    private var saliencyAttentionRequest: VNGenerateAttentionBasedSaliencyImageRequest!
    private var sceneClassifierRequest: VNClassifyImageRequest!
    
    public init() {
        setupNeuralRequests()
    }
    
    private func setupNeuralRequests() {
        // 1. Nhận diện Thú cưng / Động vật (Chó, Mèo)
        animalRequest = VNRecognizeAnimalsRequest()
        animalRequest.revision = VNRecognizeAnimalsRequestRevision2
        
        // 2. Nhận diện Cơ thể Người (Full Body & Upper Body)
        humanBodyRequest = VNDetectHumanRectanglesRequest()
        humanBodyRequest.upperBodyOnly = false
        humanBodyRequest.revision = VNDetectHumanRectanglesRequestRevision2
        
        // 3. Nhận diện Khuôn mặt Người
        faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        
        // 4. Nhận diện Điểm mốc Khuôn mặt & Hướng nhìn (Eyes, Nose, Yaw, Gaze)
        faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        faceLandmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        
        // 5. Nhận diện Vật thể tiền cảnh thực tế (Objectness Saliency)
        saliencyObjectRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        saliencyObjectRequest.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
        
        // 6. Nhận diện Vùng tập trung thị giác mắt người (Attention-based Saliency)
        saliencyAttentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        saliencyAttentionRequest.revision = VNGenerateAttentionBasedSaliencyImageRequestRevision1
        
        // 7. Phân loại Cảnh quan tổng thể
        sceneClassifierRequest = VNClassifyImageRequest()
        sceneClassifierRequest.revision = VNClassifyImageRequestRevision1
    }
    
    // MARK: - Phân tích Khung Hình Đa Tầng (Multi-Modal Neural Scan)
    public func analyzeFrame(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> (primaryCandidate: NeuralSubjectCandidate?, allCandidates: [NeuralSubjectCandidate], detectedScene: DetectedSceneType, detectionResult: SubjectDetectionResult) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        
        do {
            try handler.perform([
                self.humanBodyRequest,
                self.faceRequest,
                self.faceLandmarksRequest,
                self.animalRequest,
                self.saliencyObjectRequest,
                self.saliencyAttentionRequest,
                self.sceneClassifierRequest
            ])
        } catch {
            CameraLogger.error("Lỗi thực thi Neural Vision Request", error: error, category: .ai)
            return (nil, [], .general, SubjectDetectionResult())
        }
        
        var candidates: [NeuralSubjectCandidate] = []
        var detectionResult = SubjectDetectionResult()
        
        // 0. Nhận diện vật thể bằng YOLOv11 CoreML (nếu có model)
        if YOLODetectionEngine.shared.hasYOLOModel {
            let yoloCandidates = YOLODetectionEngine.shared.detectObjects(pixelBuffer: pixelBuffer, orientation: orientation)
            candidates.append(contentsOf: yoloCandidates)
        }
        
        // 1. Trích xuất Con người (Human Body)
        if let humans = humanBodyRequest.results {
            for human in humans where human.confidence > 0.40 {
                let rect = convertVisionRectToUIRect(human.boundingBox)
                if isValidSubjectRect(rect) {
                    let score = calculateProminenceScore(rect: rect, confidence: human.confidence, category: .human)
                    candidates.append(NeuralSubjectCandidate(
                        boundingBox: rect,
                        category: .human,
                        confidence: human.confidence,
                        label: "Người",
                        prominenceScore: score
                    ))
                }
            }
        }
        
        // 2. Trích xuất Khuôn mặt (Face) & Face Landmarks (Mắt, Mũi, Hướng nhìn Gaze, Headroom)
        if let faces = faceRequest.results {
            for face in faces where face.confidence > 0.45 {
                let rect = convertVisionRectToUIRect(face.boundingBox)
                if isValidSubjectRect(rect) {
                    let score = calculateProminenceScore(rect: rect, confidence: face.confidence, category: .face)
                    candidates.append(NeuralSubjectCandidate(
                        boundingBox: rect,
                        category: .face,
                        confidence: face.confidence,
                        label: "Khuôn mặt",
                        prominenceScore: score
                    ))
                }
            }
        }
        
        // Trích xuất Headroom & Hướng nhìn (Yaw / Gaze) & Primary Eye từ Face Landmarks
        if let faceObs = (faceLandmarksRequest.results as? [VNFaceObservation])?.first ?? faceRequest.results?.first {
            let faceUIRect = convertVisionRectToUIRect(faceObs.boundingBox)
            // Headroom: khoảng cách từ cạnh trên khuôn mặt đến mép trên khung hình UI
            detectionResult.headroomRatio = max(0.0, min(1.0, faceUIRect.minY))
            
            // Góc quay đầu (Yaw) xác định hướng nhìn (Looking room)
            if let yawNum = faceObs.yaw {
                let yaw = yawNum.doubleValue
                detectionResult.lookingDirection = CGVector(dx: sin(yaw), dy: 0)
            }
            
            // Toạ độ mắt chính xác (Primary Eye Position)
            if let landmarks = faceObs.landmarks,
               let leftEye = landmarks.leftEye,
               let rightEye = landmarks.rightEye {
                let leftPts = leftEye.normalizedPoints
                let rightPts = rightEye.normalizedPoints
                if !leftPts.isEmpty && !rightPts.isEmpty {
                    let avgLX = leftPts.map { $0.x }.reduce(0, +) / CGFloat(leftPts.count)
                    let avgLY = leftPts.map { $0.y }.reduce(0, +) / CGFloat(leftPts.count)
                    let avgRX = rightPts.map { $0.x }.reduce(0, +) / CGFloat(rightPts.count)
                    let avgRY = rightPts.map { $0.y }.reduce(0, +) / CGFloat(rightPts.count)
                    
                    let midX = (avgLX + avgRX) / 2.0
                    let midY = (avgLY + avgRY) / 2.0
                    let box = faceObs.boundingBox
                    let visionEyeX = box.origin.x + midX * box.width
                    let visionEyeY = box.origin.y + midY * box.height
                    detectionResult.primaryEyePosition = CGPoint(x: visionEyeX, y: 1.0 - visionEyeY)
                }
            }
        }
        
        // 3. Trích xuất Thú cưng / Động vật (Animal Recognition)
        if let animals = animalRequest.results {
            for animal in animals where animal.confidence > 0.40 {
                let rect = convertVisionRectToUIRect(animal.boundingBox)
                let topLabel = animal.labels.first?.identifier ?? "Thú cưng"
                let localizedName = topLabel.contains("Cat") ? "Mèo" : (topLabel.contains("Dog") ? "Chó" : "Thú cưng")
                if isValidSubjectRect(rect) {
                    let score = calculateProminenceScore(rect: rect, confidence: animal.confidence, category: .animal)
                    candidates.append(NeuralSubjectCandidate(
                        boundingBox: rect,
                        category: .animal,
                        confidence: animal.confidence,
                        label: localizedName,
                        prominenceScore: score
                    ))
                }
            }
        }
        
        // 4. Trích xuất Attention-based Saliency (Vùng thu hút mắt người nhìn trước tiên)
        if let attentionObs = saliencyAttentionRequest.results?.first {
            if let salientObjects = attentionObs.salientObjects, !salientObjects.isEmpty {
                let bestAttention = salientObjects.max(by: { $0.confidence < $1.confidence }) ?? salientObjects[0]
                let uiRect = convertVisionRectToUIRect(bestAttention.boundingBox)
                detectionResult.attentionCentroid = CGPoint(x: uiRect.midX, y: uiRect.midY)
                detectionResult.saliencyPoints = salientObjects.map {
                    let r = convertVisionRectToUIRect($0.boundingBox)
                    return CGPoint(x: r.midX, y: r.midY)
                }
            }
        }
        
        // 5. Trích xuất Objectness-based Saliency (Vật thể tiền cảnh thực tế)
        if let saliency = saliencyObjectRequest.results?.first,
           let salientObjects = saliency.salientObjects {
            if let bestObj = salientObjects.first {
                let uiRect = convertVisionRectToUIRect(bestObj.boundingBox)
                detectionResult.objectnessCentroid = CGPoint(x: uiRect.midX, y: uiRect.midY)
            }
            for obj in salientObjects where obj.confidence >= 0.48 {
                let rect = convertVisionRectToUIRect(obj.boundingBox)
                if isValidSubjectRect(rect) {
                    let overlapsWithExisting = candidates.contains { existing in
                        existing.boundingBox.intersection(rect).width * existing.boundingBox.intersection(rect).height > (rect.width * rect.height * 0.45)
                    }
                    if !overlapsWithExisting {
                        let score = calculateProminenceScore(rect: rect, confidence: obj.confidence, category: .foregroundObject, buffer: pixelBuffer)
                        candidates.append(NeuralSubjectCandidate(
                            boundingBox: rect,
                            category: .foregroundObject,
                            confidence: obj.confidence,
                            label: "Vật thể",
                            prominenceScore: score
                        ))
                    }
                }
            }
        }
        
        // 6. Phân loại Cảnh quan
        var scene: DetectedSceneType = .general
        if let classifications = sceneClassifierRequest.results,
           let topClass = classifications.first(where: { $0.confidence > 0.20 }) {
            let id = topClass.identifier.lowercased()
            if id.contains("portrait") || id.contains("face") || id.contains("person") {
                scene = .portrait
            } else if id.contains("food") || id.contains("dish") || id.contains("meal") || id.contains("drink") {
                scene = .food
            } else if id.contains("cat") || id.contains("dog") || id.contains("pet") || id.contains("animal") {
                scene = .pet
            } else if id.contains("flower") || id.contains("plant") || id.contains("macro") {
                scene = .macro
            } else if id.contains("night") || id.contains("dark") {
                scene = .night
            } else if id.contains("sunset") || id.contains("sunrise") {
                scene = .sunset
            } else if id.contains("mountain") || id.contains("sky") || id.contains("nature") || id.contains("beach") {
                scene = .landscape
            } else if id.contains("street") || id.contains("building") || id.contains("city") {
                scene = .architecture
            }
        }
        
        // 7. Xếp hạng và chọn ra VẬT THỂ CHÍNH NỔI BẬT NHẤT (True Primary Subject)
        let sortedCandidates = candidates.sorted { $0.prominenceScore > $1.prominenceScore }
        let primary = sortedCandidates.first
        
        detectionResult.humanRectangles = candidates.filter { $0.category == .human }.map { $0.boundingBox }
        detectionResult.faceRectangles = candidates.filter { $0.category == .face }.map { $0.boundingBox }
        detectionResult.animalRectangles = candidates.filter { $0.category == .animal }.map { $0.boundingBox }
        detectionResult.detectedScene = scene
        
        if let p = primary {
            detectionResult.dominantSubjectRect = p.boundingBox
            detectionResult.confidence = p.confidence
            CameraLogger.info("Đã chọn Vật thể chính: \(p.category.rawValue) - \(p.label) (Điểm: \(String(format: "%.2f", p.prominenceScore)), Độ tin cậy: \(Int(p.confidence * 100))%)", category: .ai)
        }
        
        return (primary, sortedCandidates, scene, detectionResult)
    }
    
    // MARK: - Thuật toán Tính Điểm Nổi Bật (Prominence Scoring Formula)
    private func calculateProminenceScore(rect: CGRect, confidence: Float, category: NeuralSubjectCategory, buffer: CVPixelBuffer? = nil) -> Double {
        let area = Double(rect.width * rect.height)
        
        // 1. Điểm tỷ lệ diện tích (Lý tưởng nhất là từ 5% đến 55% màn hình)
        let areaScore: Double
        if area < 0.02 {
            areaScore = area / 0.02 * 0.5 // Quá nhỏ
        } else if area > 0.55 {
            // Giảm mạnh điểm diện tích với các vùng quá lớn (tường/nhà/hậu cảnh tối)
            if area >= 0.85 {
                areaScore = 0.02
            } else {
                areaScore = max(0.05, 0.40 * (1.0 - (area - 0.55) / 0.30))
            }
        } else {
            areaScore = 1.0 - abs(area - 0.25) * 1.2
        }
        
        // 2. Điểm khoảng cách tới trung tâm màn hình (Gần tâm hoặc điểm 1/3 được ưu tiên hơn mép viền)
        let dx = Double(rect.midX - 0.5)
        let dy = Double(rect.midY - 0.5)
        let distToCenter = sqrt(dx * dx + dy * dy)
        let centerScore = max(0.2, 1.0 - distToCenter * 0.7)
        
        // 3. Hệ số ưu tiên danh mục AI
        let categoryWeight = category.priorityWeight
        
        // 4. Lọc bỏ gạch lát sàn / nền đất (Floor Tile & Ground Suppression)
        var floorPenalty: Double = 1.0
        if category == .foregroundObject, let buf = buffer, isFloorTileOrGround(rect: rect, buffer: buf) {
            floorPenalty = 0.05 // Giảm 95% điểm nếu chỉ là mảng gạch lát sàn / nền đất phẳng
        } else if category == .foregroundObject && rect.midY > 0.70 && rect.width > 0.40 {
            floorPenalty = 0.10
        }
        
        // Điểm tổng hợp
        let totalScore = Double(confidence) * 1.5 * areaScore * centerScore * categoryWeight * floorPenalty
        return max(0.01, totalScore)
    }
    
    // MARK: - Phát hiện & Loại Bỏ Gạch Lát Sàn / Mặt Đất (Floor Tile & Ground Rejection)
    private func isFloorTileOrGround(rect: CGRect, buffer: CVPixelBuffer) -> Bool {
        if rect.midY > 0.65 && rect.width > 0.45 && rect.height < 0.40 {
            return true
        }
        
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)
        
        let minX = max(0, min(width - 1, Int(rect.origin.x * CGFloat(width))))
        let minY = max(0, min(height - 1, Int(rect.origin.y * CGFloat(height))))
        let maxX = max(minX + 1, min(width, Int((rect.origin.x + rect.size.width) * CGFloat(width))))
        let maxY = max(minY + 1, min(height, Int((rect.origin.y + rect.size.height) * CGFloat(height))))
        
        var lums: [Float] = []
        let step = max(2, (maxX - minX) / 16)
        for y in stride(from: minY, to: maxY, by: max(2, step)) {
            for x in stride(from: minX, to: maxX, by: max(2, step)) {
                let off = y * bytesPerRow + x * 4
                let b = Float(data[off])
                let g = Float(data[off+1])
                let r = Float(data[off+2])
                lums.append(r * 0.299 + g * 0.587 + b * 0.114)
            }
        }
        
        guard lums.count > 12 else { return false }
        let mean = lums.reduce(0, +) / Float(lums.count)
        let variance = lums.reduce(0) { $0 + pow($1 - mean, 2) } / Float(lums.count)
        
        // Gạch men / nền sàn phẳng có variance thấp (< 40) và nằm ở phần dưới màn hình (y > 0.55)
        if variance < 40.0 && rect.midY > 0.55 {
            return true
        }
        return false
    }
    
    // MARK: - Helpers
    private func convertVisionRectToUIRect(_ visionRect: CGRect) -> CGRect {
        // Vision: Bottom-Left (0,0) -> UI: Top-Left (0,0)
        return CGRect(
            x: visionRect.origin.x,
            y: 1.0 - visionRect.origin.y - visionRect.height,
            width: visionRect.width,
            height: visionRect.height
        )
    }
    
    private func isValidSubjectRect(_ rect: CGRect) -> Bool {
        // Loại bỏ các box rỗng hoặc nằm ngoài màn hình
        guard rect.width >= 0.04, rect.height >= 0.04 else { return false }
        guard rect.width <= 0.96, rect.height <= 0.96 else { return false }
        guard rect.minX >= -0.05, rect.minY >= -0.05 else { return false }
        guard rect.maxX <= 1.05, rect.maxY <= 1.05 else { return false }
        return true
    }
}
