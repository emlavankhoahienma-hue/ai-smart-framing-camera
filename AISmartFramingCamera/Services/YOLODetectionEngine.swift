import Foundation
import CoreML
import Vision
import CoreGraphics
import CoreVideo
import ImageIO

/// Pretrained COCO and YOLOv26 ANE hardware-accelerated detection.
/// Vision remains the fallback when loading fails.
/// The legacy detectObjects contract is retained for optical target recovery.
public final class YOLODetectionEngine: @unchecked Sendable {
    public static let shared = YOLODetectionEngine()
    private let modelLock = NSLock()
    private var yoloCoreMLModel: VNCoreMLModel?
    private var yoloNativeMLModel: MLModel?
    private var isDedicatedYOLO26ANE: Bool = false
    private var loadedModelName: String?

    public init() { loadYOLOModel() }

    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let names = highMemory ? ["yolov26_ane", "yolo26s", "yolo12s", "yolo12n", "yolo11s", "yolo11n"] :
                                 ["yolov26_416_fp16", "yolov26_ane", "yolo26n", "yolo12n", "yolo12s", "yolo11n", "yolo11s"]
        for name in names {
            if let modelResult = makeModel(named: name, computeUnits: .all) {
                modelLock.withLock {
                    yoloCoreMLModel = modelResult.vnModel
                    yoloNativeMLModel = modelResult.mlModel
                    isDedicatedYOLO26ANE = modelResult.isDedicated
                    loadedModelName = name
                }
                return
            }
        }
        CameraLogger.info("Không có YOLO, tiếp tục bằng Apple Vision", category: .ai)
    }

    private func makeModel(named name: String, computeUnits: MLComputeUnits) -> (vnModel: VNCoreMLModel?, mlModel: MLModel?, isDedicated: Bool)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = computeUnits
            config.allowLowPrecisionAccumulationOnGPU = true
            let mlModel = try MLModel(contentsOf: url, configuration: config)
            let outputs = mlModel.modelDescription.outputDescriptionsByName
            let isDedicated = outputs["coordinates"] != nil && outputs["confidence"] != nil
            let vnModel = isDedicated ? nil : try? VNCoreMLModel(for: mlModel)
            return (vnModel, mlModel, isDedicated)
        } catch {
            CameraLogger.warning("Không nạp được \(name): \(error)", category: .ai)
            return nil
        }
    }

    public var hasYOLOModel: Bool { modelLock.withLock { yoloCoreMLModel != nil || yoloNativeMLModel != nil } }
    public var activeModelName: String { modelLock.withLock { loadedModelName ?? "Apple Vision" } }

    func detectObjects(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up,
                       cancellation: CompositionAnalysisCancellation) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled, CVPixelBufferGetWidth(pixelBuffer) > 32,
              CVPixelBufferGetHeight(pixelBuffer) > 32 else { return [] }
        let (vnModel, nativeModel, isDedicated) = modelLock.withLock { (yoloCoreMLModel, yoloNativeMLModel, isDedicatedYOLO26ANE) }
        if isDedicated, let nativeModel {
            return detectWithDedicatedANE(model: nativeModel, pixelBuffer: pixelBuffer, cancellation: cancellation)
        } else if let vnModel {
            return detectWithVisionCoreML(vnModel: vnModel, pixelBuffer: pixelBuffer,
                                          orientation: orientation, cancellation: cancellation)
        }
        return []
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
        let (nativeModel, isDedicated) = modelLock.withLock { (yoloNativeMLModel, isDedicatedYOLO26ANE) }
        if isDedicated, let nativeModel {
            return detectWithDedicatedANE(model: nativeModel, pixelBuffer: pixelBuffer, cancellation: cancellation)
        }
        return autoreleasepool {
            guard !cancellation.isCancelled else { return [] }
            guard let modelResult = makeModel(named: "yolo12s", computeUnits: .cpuAndNeuralEngine) ??
                                    makeModel(named: "yolo12s", computeUnits: .all),
                  let vnModel = modelResult.vnModel else {
                return detectObjects(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
            }
            return detectWithVisionCoreML(vnModel: vnModel, pixelBuffer: pixelBuffer, orientation: orientation,
                                          cancellation: cancellation, photographic: true)
        }
    }

    private func detectWithDedicatedANE(
        model: MLModel,
        pixelBuffer: CVPixelBuffer,
        cancellation: CompositionAnalysisCancellation
    ) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled else { return [] }
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: pixelBuffer)
            ])
            let output = try model.prediction(from: inputProvider)
            guard !cancellation.isCancelled else { return [] }
            guard let coordsArray = output.featureValue(for: "coordinates")?.multiArrayValue,
                  let confArray = output.featureValue(for: "confidence")?.multiArrayValue else {
                return []
            }
            return parseDedicatedANETensors(coords: coordsArray, conf: confArray, cancellation: cancellation)
        } catch {
            if cancellation.isCancelled { return [] }
            CameraLogger.error("Lỗi suy luận YOLOv26 ANE Dedicated Model", error: error, category: .ai)
            return []
        }
    }

    private func parseDedicatedANETensors(
        coords: MLMultiArray,
        conf: MLMultiArray,
        cancellation: CompositionAnalysisCancellation
    ) -> [NeuralSubjectCandidate] {
        guard coords.shape.count >= 3, conf.shape.count >= 3 else { return [] }
        let numBoxes = coords.shape[1].intValue
        let numClasses = conf.shape[2].intValue
        guard numBoxes > 0, numClasses > 0 else { return [] }
        var candidates: [NeuralSubjectCandidate] = []
        let threshold: Float = 0.45

        if coords.dataType == .float16 && conf.dataType == .float16 {
            let coordsPtr = coords.dataPointer.bindMemory(to: Float16.self, capacity: numBoxes * 4)
            let confPtr = conf.dataPointer.bindMemory(to: Float16.self, capacity: numBoxes * numClasses)
            for i in 0..<numBoxes {
                if cancellation.isCancelled { break }
                let confOffset = i * numClasses
                var maxScore: Float = 0.0
                var maxClassId: Int = 0
                for c in 0..<numClasses {
                    let score = Float(confPtr[confOffset + c])
                    if score > maxScore {
                        maxScore = score
                        maxClassId = c
                    }
                }
                guard maxScore >= threshold else { continue }
                let coordOffset = i * 4
                let cx = CGFloat(Float(coordsPtr[coordOffset + 0]))
                let cy = CGFloat(Float(coordsPtr[coordOffset + 1]))
                let w = CGFloat(Float(coordsPtr[coordOffset + 2]))
                let h = CGFloat(Float(coordsPtr[coordOffset + 3]))
                let x = max(0.0, cx - w / 2.0)
                let y = max(0.0, cy - h / 2.0)
                let rawRect = CGRect(x: x, y: y, width: w, height: h)
                guard let uiRect = clippedValidBox(rawRect) else { continue }
                let category = mapDedicatedClassIdToCategory(maxClassId)
                let label = localizeDedicatedClassId(maxClassId)
                let prominence = calculateYOLOProminenceScore(rect: uiRect, confidence: maxScore, category: category)
                candidates.append(NeuralSubjectCandidate(boundingBox: uiRect, category: category, confidence: maxScore, label: label, prominenceScore: prominence))
            }
        } else {
            let coordsPtr = coords.dataPointer.bindMemory(to: Float.self, capacity: numBoxes * 4)
            let confPtr = conf.dataPointer.bindMemory(to: Float.self, capacity: numBoxes * numClasses)
            for i in 0..<numBoxes {
                if cancellation.isCancelled { break }
                let confOffset = i * numClasses
                var maxScore: Float = 0.0
                var maxClassId: Int = 0
                for c in 0..<numClasses {
                    let score = confPtr[confOffset + c]
                    if score > maxScore {
                        maxScore = score
                        maxClassId = c
                    }
                }
                guard maxScore >= threshold else { continue }
                let coordOffset = i * 4
                let cx = CGFloat(coordsPtr[coordOffset + 0])
                let cy = CGFloat(coordsPtr[coordOffset + 1])
                let w = CGFloat(coordsPtr[coordOffset + 2])
                let h = CGFloat(coordsPtr[coordOffset + 3])
                let x = max(0.0, cx - w / 2.0)
                let y = max(0.0, cy - h / 2.0)
                let rawRect = CGRect(x: x, y: y, width: w, height: h)
                guard let uiRect = clippedValidBox(rawRect) else { continue }
                let category = mapDedicatedClassIdToCategory(maxClassId)
                let label = localizeDedicatedClassId(maxClassId)
                let prominence = calculateYOLOProminenceScore(rect: uiRect, confidence: maxScore, category: category)
                candidates.append(NeuralSubjectCandidate(boundingBox: uiRect, category: category, confidence: maxScore, label: label, prominenceScore: prominence))
            }
        }
        return candidates.sorted { $0.prominenceScore > $1.prominenceScore }
    }

    private func mapDedicatedClassIdToCategory(_ classId: Int) -> NeuralSubjectCategory {
        switch classId {
        case 0: return .face
        case 1: return .human
        case 2, 3: return .animal
        default: return .foregroundObject
        }
    }

    private func localizeDedicatedClassId(_ classId: Int) -> String {
        switch classId {
        case 0: return "Khuôn mặt"
        case 1: return "Người"
        case 2: return "Chó"
        case 3: return "Mèo"
        default: return "Chủ thể"
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
        guard current == "yolov26_ane" || current == "yolo26s" || current == "yolo12s" || current == "yolo11s" else { return }
        modelLock.withLock { yoloCoreMLModel = nil; yoloNativeMLModel = nil; loadedModelName = nil; isDedicatedYOLO26ANE = false }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for name in ["yolov26_416_fp16", "yolo26n", "yolo12n", "yolo11n"] {
                if let modelResult = self.makeModel(named: name, computeUnits: .all) {
                    self.modelLock.withLock {
                        self.yoloCoreMLModel = modelResult.vnModel
                        self.yoloNativeMLModel = modelResult.mlModel
                        self.isDedicatedYOLO26ANE = modelResult.isDedicated
                        self.loadedModelName = name
                    }
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
            "duck", "chicken", "pig", "goat", "mouse", "squirrel", "wolf",
            "otter", "koala", "kangaroo"
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
