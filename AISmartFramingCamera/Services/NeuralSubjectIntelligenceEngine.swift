import Foundation
import Vision
import CoreGraphics
import CoreImage
import UIKit
import CoreML

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
        case .human: return 1.12
        case .face: return 0.92
        case .animal: return 1.05
        case .foregroundObject: return 1.0
        case .general: return 0.85
        }
    }
}

/// Optional semantic evidence. The model receives only detected image regions;
/// it never invents a box or overrides crop/tracking safety.
private final class SemanticCropRanker: @unchecked Sendable {
    static let shared = SemanticCropRanker()
    private var attemptedLoad = false
    private var model: VNCoreMLModel?
    private var prompts: [String: [Double]] = [:]
    var isAvailable: Bool { model != nil }

    private func loadIfAvailable() {
        guard !attemptedLoad else { return }
        attemptedLoad = true
        guard ProcessInfo.processInfo.physicalMemory >= 4_000_000_000,
              let url = Bundle.main.url(forResource: "SigLIPBaseImage", withExtension: "mlmodelc"),
              let promptURL = Bundle.main.url(forResource: "SigLIPPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: promptURL),
              let vectors = try? JSONDecoder().decode([String: [Double]].self, from: data),
              !vectors.isEmpty else { return }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            prompts = vectors
        } catch {
            model = nil
            prompts = [:]
            CameraLogger.warning("SigLIP không khả dụng, dùng Vision/YOLO: \(error)", category: .ai)
        }
    }

    func rerank(candidates: [NeuralSubjectCandidate], pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation) -> [NeuralSubjectCandidate] {
        loadIfAvailable()
        guard let model, !prompts.isEmpty else { return candidates }
        return candidates.prefix(6).map { candidate in
            let box = candidate.boundingBox
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            request.regionOfInterest = CGRect(x: box.minX, y: 1 - box.maxY,
                                              width: box.width, height: box.height)
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let array = observation.featureValue.multiArrayValue else { return candidate }
            let image = (0..<array.count).map { Double(truncating: array[$0]) }
            let keys: [String]
            switch candidate.category {
            case .human, .face: keys = ["person", "person_scenery", "group"]
            case .animal: keys = ["animal"]
            case .foregroundObject, .general:
                keys = ["building", "landscape", "object", "food", "vehicle"]
            }
            let affinity = keys.compactMap { key -> Double? in
                guard let text = prompts[key], text.count == image.count else { return nil }
                return zip(image, text).reduce(0) { $0 + $1.0 * $1.1 }
            }.max() ?? 0
            guard affinity.isFinite else { return candidate }
            let bounded = max(-0.15, min(0.15, (affinity - 0.25) * 0.6))
            return NeuralSubjectCandidate(boundingBox: box, category: candidate.category,
                confidence: candidate.confidence, label: candidate.label,
                prominenceScore: candidate.prominenceScore * (1 + bounded))
        } + Array(candidates.dropFirst(6))
    }

    func sceneHint(pixelBuffer: CVPixelBuffer,
                   orientation: CGImagePropertyOrientation,
                   candidates: [NeuralSubjectCandidate]) -> DetectedSceneType? {
        loadIfAvailable()
        guard let model, !prompts.isEmpty else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue else { return nil }
        let image = (0..<array.count).map { Double(truncating: array[$0]) }
        let scores = prompts.compactMap { key, vector -> (String, Double)? in
            guard vector.count == image.count else { return nil }
            return (key, zip(image, vector).reduce(0) { $0 + $1.0 * $1.1 })
        }.sorted { $0.1 > $1.1 }
        guard scores.count >= 2, scores[0].1 >= 0.25,
              scores[0].1 - scores[1].1 >= 0.03 else { return nil }
        switch scores[0].0 {
        case "building":
            return candidates.contains { $0.category == .foregroundObject && $0.areaRatio > 0.12 }
                ? .architecture : nil
        case "landscape": return .landscape
        case "person_scenery":
            return candidates.contains { $0.category == .human } ? .landscape : nil
        case "group", "person":
            return candidates.contains { $0.category == .human } ? .portrait : nil
        case "food": return .food
        case "animal": return .pet
        default: return nil
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

/// Kết quả phân tích thị giác ANE nâng cao
public struct NeuralAnalysisOutput {
    public let primaryCandidate: NeuralSubjectCandidate?
    public let allCandidates: [NeuralSubjectCandidate]
    public let detectedScene: DetectedSceneType
    public let allFaceRects: [CGRect]
    public let groupBoundingBox: CGRect?
    public let primaryEyePosition: CGPoint?
    public let lookingDirection: CGVector
    public let usedSemanticModel: Bool

    public init(
        primaryCandidate: NeuralSubjectCandidate?,
        allCandidates: [NeuralSubjectCandidate],
        detectedScene: DetectedSceneType,
        allFaceRects: [CGRect] = [],
        groupBoundingBox: CGRect? = nil,
        primaryEyePosition: CGPoint? = nil,
        lookingDirection: CGVector = CGVector(dx: 0, dy: 0),
        usedSemanticModel: Bool = false
    ) {
        self.primaryCandidate = primaryCandidate
        self.allCandidates = allCandidates
        self.detectedScene = detectedScene
        self.allFaceRects = allFaceRects
        self.groupBoundingBox = groupBoundingBox
        self.primaryEyePosition = primaryEyePosition
        self.lookingDirection = lookingDirection
        self.usedSemanticModel = usedSemanticModel
    }
}

/// Bộ Não Phân Tích Chủ Thể Nơ-ron Đa Tầng (Neural Subject Intelligence Engine)
/// Tận dụng tối đa chip xử lý trí tuệ nhân tạo Apple Neural Engine (ANE) của Apple
public final class NeuralSubjectIntelligenceEngine: @unchecked Sendable {
    public static let shared = NeuralSubjectIntelligenceEngine()
    private let analysisLock = NSLock()
    
    // MARK: - Vision Deep Learning Requests
    private lazy var animalRequest: VNRecognizeAnimalsRequest = {
        let req = VNRecognizeAnimalsRequest()
        req.revision = VNRecognizeAnimalsRequestRevision2
        return req
    }()
    
    private lazy var humanBodyRequest: VNDetectHumanRectanglesRequest = {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        req.revision = VNDetectHumanRectanglesRequestRevision2
        return req
    }()
    
    private lazy var faceLandmarksRequest: VNDetectFaceLandmarksRequest = {
        let req = VNDetectFaceLandmarksRequest()
        req.revision = VNDetectFaceLandmarksRequestRevision3
        return req
    }()
    
    private lazy var saliencyObjectRequest: VNGenerateObjectnessBasedSaliencyImageRequest = {
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        req.revision = VNGenerateObjectnessBasedSaliencyImageRequestRevision1
        return req
    }()

    private lazy var attentionRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    
    private lazy var sceneClassifierRequest: VNClassifyImageRequest = {
        let req = VNClassifyImageRequest()
        req.revision = VNClassifyImageRequestRevision1
        return req
    }()
    
    public init() {}
    
    // MARK: - Phân tích Khung Hình Đa Tầng (Multi-Modal Neural Scan)
    public func analyzeFrame(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> NeuralAnalysisOutput {
        analysisLock.lock()
        defer { analysisLock.unlock() }
        return analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: orientation)
    }

    private func analyzeCapturedFrame(pixelBuffer: CVPixelBuffer,
                                      orientation: CGImagePropertyOrientation) -> NeuralAnalysisOutput {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        
        // One unsupported/failed request must not erase evidence from the others.
        let requests: [VNRequest] = [humanBodyRequest, faceLandmarksRequest,
                                     animalRequest, saliencyObjectRequest,
                                     attentionRequest, sceneClassifierRequest]
        var completed = Set<ObjectIdentifier>()
        for request in requests {
            do {
                try handler.perform([request])
                completed.insert(ObjectIdentifier(request))
            }
            catch { CameraLogger.warning("Vision bỏ qua một bộ phân tích: \(error)", category: .ai) }
        }
        
        var candidates: [NeuralSubjectCandidate] = []
        var detectedFaces: [CGRect] = []
        var primaryEye: CGPoint? = nil
        var lookDir = CGVector(dx: 0, dy: 0)
        
        // 0. Nhận diện vật thể bằng YOLOv11 CoreML (nếu có model)
        if YOLODetectionEngine.shared.hasYOLOModel {
            let yoloCandidates = YOLODetectionEngine.shared.detectObjects(pixelBuffer: pixelBuffer, orientation: orientation)
            candidates.append(contentsOf: yoloCandidates)
        }
        
        // 1. Trích xuất Con người (Human Body)
        if completed.contains(ObjectIdentifier(humanBodyRequest)),
           let humans = humanBodyRequest.results {
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
        
        // 2. Trích xuất Khuôn mặt & Điểm mốc ANE (Face Landmarks & Gaze)
        if completed.contains(ObjectIdentifier(faceLandmarksRequest)),
           let faces = faceLandmarksRequest.results {
            for face in faces where face.confidence > 0.38 {
                let rect = convertVisionRectToUIRect(face.boundingBox)
                if isValidSubjectRect(rect) {
                    detectedFaces.append(rect)
                    let score = calculateProminenceScore(rect: rect, confidence: face.confidence, category: .face)
                    candidates.append(NeuralSubjectCandidate(
                        boundingBox: rect,
                        category: .face,
                        confidence: face.confidence,
                        label: "Khuôn mặt",
                        prominenceScore: score
                    ))

                    // Trích xuất vị trí mắt chính (Eye Level) từ khuôn mặt đầu tiên
                    if primaryEye == nil, let landmarks = face.landmarks {
                        var eyeCenters: [CGPoint] = []
                        if let leftEye = landmarks.leftEye, !leftEye.normalizedPoints.isEmpty {
                            let pts = leftEye.normalizedPoints
                            let avgX = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                            let avgY = pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count)
                            eyeCenters.append(CGPoint(x: avgX, y: avgY))
                        }
                        if let rightEye = landmarks.rightEye, !rightEye.normalizedPoints.isEmpty {
                            let pts = rightEye.normalizedPoints
                            let avgX = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
                            let avgY = pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count)
                            eyeCenters.append(CGPoint(x: avgX, y: avgY))
                        }
                        if !eyeCenters.isEmpty {
                            let avgEyeInFace = CGPoint(
                                x: eyeCenters.map { $0.x }.reduce(0, +) / CGFloat(eyeCenters.count),
                                y: eyeCenters.map { $0.y }.reduce(0, +) / CGFloat(eyeCenters.count)
                            )
                            let eyeVisionX = face.boundingBox.origin.x + avgEyeInFace.x * face.boundingBox.width
                            let eyeVisionY = face.boundingBox.origin.y + avgEyeInFace.y * face.boundingBox.height
                            primaryEye = CGPoint(x: eyeVisionX, y: 1.0 - eyeVisionY)
                        }

                        // Trích xuất hướng xoay đầu / nhìn (Head Yaw Gaze)
                        if let yaw = face.yaw?.floatValue {
                            let gazeDx = -sin(yaw)
                            if abs(gazeDx) > 0.08 {
                                lookDir = CGVector(dx: CGFloat(gazeDx), dy: 0)
                            }
                        }
                    }
                }
            }
        }
        
        // 3. Trích xuất Thú cưng / Động vật (Animal Recognition)
        if completed.contains(ObjectIdentifier(animalRequest)),
           let animals = animalRequest.results {
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
        
        // 4. Trích xuất Vật thể tiền cảnh thực tế (Objectness Saliency)
        if completed.contains(ObjectIdentifier(saliencyObjectRequest)),
           let saliency = saliencyObjectRequest.results?.first,
           let salientObjects = saliency.salientObjects {
            for obj in salientObjects where obj.confidence >= 0.48 {
                let rect = convertVisionRectToUIRect(obj.boundingBox)
                if isValidSubjectRect(rect) {
                    // Kiểm tra xem vật thể này có bị trùng lặp với người/mặt/thú cưng đã phát hiện không
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

        // Attention can find a meaningful region in architecture or scenery
        // where COCO detectors have no class. It supplies a region, not identity.
        if completed.contains(ObjectIdentifier(attentionRequest)),
           let regions = attentionRequest.results?.first?.salientObjects {
            for region in regions where region.confidence >= 0.55 {
                let rect = convertVisionRectToUIRect(region.boundingBox)
                guard isValidSubjectRect(rect) else { continue }
                let overlap = candidates.contains {
                    let intersection = $0.boundingBox.intersection(rect)
                    return intersection.width * intersection.height > rect.width * rect.height * 0.55
                }
                if !overlap {
                    candidates.append(NeuralSubjectCandidate(boundingBox: rect,
                        category: .foregroundObject, confidence: region.confidence,
                        label: "Vùng nổi bật", prominenceScore: calculateProminenceScore(
                            rect: rect, confidence: region.confidence,
                            category: .foregroundObject)))
                }
            }
        }
        
        // 5. Phân loại Cảnh quan
        var scene: DetectedSceneType = .general
        if completed.contains(ObjectIdentifier(sceneClassifierRequest)),
           let classifications = sceneClassifierRequest.results,
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
            } else if ["mountain", "sky", "nature", "beach", "forest", "valley",
                       "lake", "sea", "coast", "desert", "waterfall", "field"].contains(where: { id.contains($0) }) {
                scene = .landscape
            } else if ["street", "building", "city", "architecture", "house",
                       "castle", "skyscraper", "bridge", "tower", "temple",
                       "church", "palace"].contains(where: { id.contains($0) }) {
                scene = .architecture
            }
        }
        if let hint = SemanticCropRanker.shared.sceneHint(pixelBuffer: pixelBuffer,
                orientation: orientation, candidates: candidates),
           scene == .general || (scene == .portrait && hint == .landscape) {
            scene = hint
        }
        
        // 6. Tính toán Bounding Box cho ảnh nhóm (Group Framing)
        var groupBox: CGRect? = nil
        if detectedFaces.count > 1 {
            let minX = detectedFaces.map { $0.minX }.min() ?? 0
            let maxX = detectedFaces.map { $0.maxX }.max() ?? 1
            let minY = detectedFaces.map { $0.minY }.min() ?? 0
            let maxY = detectedFaces.map { $0.maxY }.max() ?? 1
            let padX = (maxX - minX) * 0.12
            let padY = (maxY - minY) * 0.12
            groupBox = CGRect(
                x: max(0.02, minX - padX),
                y: max(0.02, minY - padY),
                width: min(0.96, (maxX - minX) + padX * 2),
                height: min(0.96, (maxY - minY) + padY * 2)
            )
        }
        
        // 7. Xếp hạng và chọn ra VẬT THỂ CHÍNH NỔI BẬT NHẤT (True Primary Subject)
        let visualCandidates = candidates.sorted { $0.prominenceScore > $1.prominenceScore }
        let semanticCandidates = SemanticCropRanker.shared.rerank(candidates: visualCandidates,
            pixelBuffer: pixelBuffer, orientation: orientation)
        let sortedCandidates = semanticCandidates.sorted {
            let left = contextualScore($0, scene: scene)
            let right = contextualScore($1, scene: scene)
            return left > right
        }
        let primary = sortedCandidates.first
        
        if let p = primary {
            CameraLogger.info("Đã chọn Vật thể chính: \(p.category.rawValue) - \(p.label) (Điểm: \(String(format: "%.2f", p.prominenceScore)), Độ tin cậy: \(Int(p.confidence * 100))%)", category: .ai)
        }
        
        return NeuralAnalysisOutput(
            primaryCandidate: primary,
            allCandidates: sortedCandidates,
            detectedScene: scene,
            allFaceRects: detectedFaces,
            groupBoundingBox: groupBox,
            primaryEyePosition: primaryEye,
            lookingDirection: lookDir,
            usedSemanticModel: SemanticCropRanker.shared.isAvailable
        )
    }

    private func contextualScore(_ candidate: NeuralSubjectCandidate,
                                 scene: DetectedSceneType) -> Double {
        let area = candidate.areaRatio
        let architectureBonus = scene == .architecture &&
            candidate.category == .foregroundObject ? (1.0 + min(0.5, area)) : 1.0
        let portraitBonus = scene == .portrait && candidate.category == .human ? 1.12 : 1.0
        return candidate.prominenceScore * architectureBonus * portraitBonus
    }
    
    // MARK: - Thuật toán Tính Điểm Nổi Bật (Prominence Scoring Formula)
    private func calculateProminenceScore(rect: CGRect, confidence: Float, category: NeuralSubjectCategory, buffer: CVPixelBuffer? = nil) -> Double {
        let area = Double(rect.width * rect.height)
        
        // Large structures can be the primary subject. Penalize only tiny
        // or nearly full-frame boxes, never reject a building by area alone.
        let areaScore: Double
        if area < 0.02 {
            areaScore = area / 0.02 * 0.5 // Quá nhỏ
        } else if area > 0.55 {
            areaScore = max(0.45, 1.0 - (area - 0.55) * 1.1)
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
        
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buffer) > 0,
              CVPixelBufferGetHeight(buffer) > 0 else { return false }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width * 4 else { return false }
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
        guard rect.width <= 0.99, rect.height <= 0.99 else { return false }
        guard rect.minX >= -0.05, rect.minY >= -0.05 else { return false }
        guard rect.maxX <= 1.05, rect.maxY <= 1.05 else { return false }
        return true
    }
}
