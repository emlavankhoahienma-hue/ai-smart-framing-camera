import Foundation
import CoreML
import Vision
import CoreGraphics
import CoreVideo
import ImageIO

/// Pretrained COCO detection. Vision remains the fallback when loading fails.
/// The legacy detectObjects contract is retained for optical target recovery.
public final class YOLODetectionEngine: @unchecked Sendable {
    public static let shared = YOLODetectionEngine()
    private let modelLock = NSLock()
    private var yoloCoreMLModel: VNCoreMLModel?
    private var loadedModelName: String?

    public init() { loadYOLOModel() }

    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let names = highMemory ? ["yolo12s", "yolo12n", "yolo11s", "yolo11n"] :
                                 ["yolo12n", "yolo12s", "yolo11n", "yolo11s"]
        for name in names {
            if let model = makeModel(named: name, computeUnits: .all) {
                modelLock.withLock { yoloCoreMLModel = model; loadedModelName = name }
                return
            }
        }
        CameraLogger.info("Không có YOLO, tiếp tục bằng Apple Vision", category: .ai)
    }

    private func makeModel(named name: String, computeUnits: MLComputeUnits) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            config.allowLowPrecisionAccumulationOnGPU = true
            return try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        } catch {
            CameraLogger.warning("Không nạp được \(name): \(error)", category: .ai)
            return nil
        }
    }

    public var hasYOLOModel: Bool { modelLock.withLock { yoloCoreMLModel != nil } }
    public var activeModelName: String { modelLock.withLock { loadedModelName ?? "Apple Vision" } }

    func detectObjects(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                       cancellation: CompositionAnalysisCancellation) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled, CVPixelBufferGetWidth(pixelBuffer) > 32,
              CVPixelBufferGetHeight(pixelBuffer) > 32,
              let model = modelLock.withLock({ yoloCoreMLModel }) else { return [] }
        return detectWithVisionCoreML(vnModel: model, pixelBuffer: pixelBuffer,
                                     orientation: orientation, cancellation: cancellation)
    }

    /// A separate short-lived quality model cannot replace the model used by
    /// target reacquisition. Slower still-image inference is intentional on XS.
    func detectPhotographicObjects(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                   cancellation: CompositionAnalysisCancellation) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled else { return [] }
        let process = ProcessInfo.processInfo
        if process.thermalState == .serious || process.thermalState == .critical || process.isLowPowerModeEnabled {
            return detectObjects(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
        }
        return autoreleasepool {
            guard !cancellation.isCancelled else { return [] }
            guard let model = makeModel(named: "yolo12s", computeUnits: .cpuAndNeuralEngine) ??
                              makeModel(named: "yolo12s", computeUnits: .all) else {
                return detectObjects(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
            }
            return detectWithVisionCoreML(vnModel: model, pixelBuffer: pixelBuffer, orientation: orientation,
                                          cancellation: cancellation, photographic: true)
        }
    }

    private func detectWithVisionCoreML(
        vnModel: VNCoreMLModel,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        cancellation: CompositionAnalysisCancellation,
        photographic: Bool = false
    ) -> [NeuralSubjectCandidate] {
        var detectedCandidates: [NeuralSubjectCandidate] = []
        let request = VNCoreMLRequest(model: vnModel) { [weak self] req, error in
            guard let self = self, error == nil else { return }
            
            if let results = req.results as? [VNRecognizedObjectObservation] {
                for obs in results where obs.confidence >= 0.45 {
                    guard let topLabel = obs.labels.first else { continue }
                    
                    let confidence = min(obs.confidence, topLabel.confidence)
                    guard confidence >= 0.45 else { continue }
                    
                    let category = self.mapYOLOLabelToCategory(topLabel.identifier)
                    let localizedName = self.localizeYOLOLabel(topLabel.identifier)
                    
                    // Chuyển đổi hệ tọa độ Vision (Gốc dưới-trái) sang UI Camera (Gốc trên-trái)
                    let rawRect = CGRect(
                        x: obs.boundingBox.origin.x,
                        y: 1.0 - obs.boundingBox.origin.y - obs.boundingBox.height,
                        width: obs.boundingBox.width,
                        height: obs.boundingBox.height
                    )
                    
                    guard let uiRect = self.clippedValidBox(rawRect) else { continue }
                    guard uiRect.width >= 0.04, uiRect.height >= 0.04, uiRect.width <= 0.95, uiRect.height <= 0.95 else { continue }
                    let aspectRatio = uiRect.width / max(0.001, uiRect.height)
                    guard aspectRatio >= 0.15 && aspectRatio <= 6.5 else { continue }
                    
                    let score = self.calculateYOLOProminenceScore(rect: uiRect, confidence: confidence, category: category)
                    
                    detectedCandidates.append(NeuralSubjectCandidate(
                        boundingBox: uiRect,
                        category: category,
                        confidence: confidence,
                        label: localizedName,
                        prominenceScore: score
                    ))
                }
            }
        }
        
        request.imageCropAndScaleOption = photographic ? .scaleFit : .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try cancellation.perform(request, with: handler)
        } catch {
            if cancellation.isCancelled { return [] }
            CameraLogger.error("Lỗi thực thi YOLO Request", error: error, category: .ai)
            detectedCandidates.removeAll()
            
            if !photographic { recoverLightweightModel() }
        }
        
        return detectedCandidates.sorted { $0.prominenceScore > $1.prominenceScore }
    }
    
    private func recoverLightweightModel() {
        let current = modelLock.withLock { loadedModelName }
        guard current == "yolo12s" || current == "yolo11s" else { return }
        modelLock.withLock { yoloCoreMLModel = nil; loadedModelName = nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for name in ["yolo12n", "yolo11n"] {
                if let model = self.makeModel(named: name, computeUnits: .all) {
                    self.modelLock.withLock { self.yoloCoreMLModel = model; self.loadedModelName = name }
                    return
                }
            }
        }
    }

    // MARK: - COCO labels
    public func mapYOLOLabelToCategory(_ label: String) -> NeuralSubjectCategory {
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Nhận diện Khuôn mặt (Face)
        if l == "face" || l == "human face" || l == "head" || l == "portrait_face" || l == "khuon mat" {
            return .face
        }
        
        // 2. Nhận diện Con người (Human)
        if l == "person" || l == "human" || l == "man" || l == "woman" || l == "boy" || l == "girl" ||
           l == "child" || l == "pedestrian" || l == "body" || l == "nguoi" {
            return .human
        }
        
        // 3. Nhận diện Động vật / Thú cưng (Animal / Pets)
        let animalLabels: Set<String> = [
            "cat", "dog", "bird", "horse", "sheep", "cow", "elephant", "bear",
            "zebra", "giraffe", "rabbit", "deer", "fox", "monkey", "panda",
            "lion", "tiger", "pet", "kitten", "puppy", "hamster", "animal",
            "dog face", "cat face", "animal face", "duck", "chicken", "pig",
            "goat", "mouse", "squirrel", "wolf", "otter", "koala", "kangaroo"
        ]
        if animalLabels.contains(l) || l.contains("dog") || l.contains("cat") || l.contains("pet") {
            return .animal
        }
        
        return .foregroundObject
    }
    
    public func localizeYOLOLabel(_ label: String) -> String {
        let key = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let dict: [String: String] = [
            "person": "Người",
            "human": "Người",
            "man": "Người",
            "woman": "Người",
            "boy": "Người",
            "girl": "Người",
            "child": "Trẻ em",
            "face": "Khuôn mặt",
            "human face": "Khuôn mặt",
            "head": "Khuôn mặt",
            "cat": "Mèo",
            "kitten": "Mèo con",
            "dog": "Chó",
            "puppy": "Chó con",
            "pet": "Thú cưng",
            "bird": "Chim",
            "horse": "Ngựa",
            "sheep": "Cừu",
            "cow": "Bò",
            "elephant": "Voi",
            "bear": "Gấu",
            "zebra": "Ngựa vằn",
            "giraffe": "Hươu cao cổ",
            "rabbit": "Thỏ",
            "deer": "Hươu",
            "fox": "Cáo",
            "monkey": "Khỉ",
            "panda": "Gấu trúc",
            "lion": "Sư tử",
            "tiger": "Hổ",
            "hamster": "Hamster",
            "duck": "Vịt",
            "chicken": "Gà",
            "pig": "Heo",
            "goat": "Dê",
            "bicycle": "Xe đạp",
            "car": "Ô tô",
            "motorcycle": "Xe máy",
            "airplane": "Máy bay",
            "bus": "Xe bus",
            "train": "Tàu hỏa",
            "truck": "Xe tải",
            "boat": "Thuyền",
            "traffic light": "Đèn giao thông",
            "backpack": "Balo",
            "umbrella": "Chiếc ô",
            "handbag": "Túi xách",
            "bottle": "Chai nước",
            "wine glass": "Ly rượu",
            "cup": "Cốc nước",
            "fork": "Nĩa",
            "knife": "Dao",
            "spoon": "Muỗng",
            "bowl": "Bát đĩa",
            "banana": "Chuối",
            "apple": "Táo",
            "sandwich": "Bánh mì",
            "orange": "Quả cam",
            "pizza": "Pizza",
            "donut": "Bánh donut",
            "cake": "Bánh ngọt",
            "chair": "Ghế",
            "couch": "Sofa",
            "potted plant": "Chậu cây",
            "bed": "Giường",
            "dining table": "Bàn ăn",
            "tv": "Tivi",
            "laptop": "Laptop",
            "mouse": "Chuột máy tính",
            "remote": "Điều khiển",
            "keyboard": "Bàn phím",
            "cell phone": "Điện thoại",
            "book": "Cuốn sách",
            "clock": "Đồng hồ",
            "vase": "Bình hoa",
            "teddy bear": "Gấu bông"
        ]
        return dict[key] ?? label.capitalized
    }
    
    private func calculateYOLOProminenceScore(rect: CGRect, confidence: Float, category: NeuralSubjectCategory) -> Double {
        let area = Double(rect.width * rect.height)
        
        let areaScore: Double
        if area < 0.02 {
            areaScore = area / 0.02 * 0.5
        } else if area > 0.60 {
            areaScore = max(0.40, 1.0 - (area - 0.60) * 1.1)
        } else {
            areaScore = 1.0 - abs(area - 0.25) * 1.1
        }
        
        let dx = Double(rect.midX - 0.5)
        let dy = Double(rect.midY - 0.5)
        let distToCenter = sqrt(dx * dx + dy * dy)
        let centerScore = max(0.2, 1.0 - distToCenter * 0.7)
        
        // Ưu tiên cao nhất cho Face và Animal, sau đó tới Human
        let categoryBonus: Double
        switch category {
        case .face: categoryBonus = 2.4
        case .animal: categoryBonus = 2.0
        case .human: categoryBonus = 1.8
        default: categoryBonus = 0.8
        }
        
        return Double(confidence) * 1.5 * areaScore * centerScore * category.priorityWeight * categoryBonus
    }
    
    private func clippedValidBox(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull, !visible.isEmpty,
              visible.width >= 0.03, visible.height >= 0.03,
              visible.width <= 0.99, visible.height <= 0.99,
              visible.width * visible.height >= rect.width * rect.height * 0.75 else { return nil }
        return visible
    }
}
