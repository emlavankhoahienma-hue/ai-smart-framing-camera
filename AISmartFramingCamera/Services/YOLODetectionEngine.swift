import Foundation
import CoreML
import Vision
import CoreGraphics
import UIKit

/// Nhận diện 80 lớp COCO, Khuôn mặt và Động vật/Thú cưng qua mô hình YOLOv26 Core ML.
/// YOLO11s/yolo26s serves high-memory devices, YOLO11n/yolo26n serves older devices.
/// Vision remains the fallback when loading or inference fails.
public final class YOLODetectionEngine: @unchecked Sendable {
    public static let shared = YOLODetectionEngine()

    private let modelLock = NSLock()
    private var yoloCoreMLModel: VNCoreMLModel?
    private var yoloNativeMLModel: MLModel?
    private var isDedicatedYOLO26ANE: Bool = false
    private var loadedModelName: String?
    
    public init() {
        loadYOLOModel()
    }
    
    /// Nạp mô hình theo thứ tự ưu tiên YOLOv26 mới nhất, tối ưu bộ nhớ ANE (Apple Neural Engine).
    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let prioritizedNames = (highMemory
            ? ["yolov26_ane", "yolov26_640_fp16", "yolo26m", "yolo26s", "yolo26", "yolov26", "YOLOv26", "yolov26_416_fp16", "yolo11s"]
            : ["yolov26_416_fp16", "yolov26_ane", "yolo26n", "yolov26n", "yolo26", "yolov26", "YOLOv26", "yolo11n", "yolov8n"])
        
        for name in prioritizedNames {
            guard let modelResult = makeModel(named: name) else { continue }
            modelLock.withLock {
                yoloNativeMLModel = modelResult.mlModel
                yoloCoreMLModel = modelResult.vnModel
                isDedicatedYOLO26ANE = modelResult.isDedicatedANE
                loadedModelName = name
            }
            let modelTypeDesc = modelResult.isDedicatedANE ? "YOLOv26 ANE NMS-Free" : "YOLO CoreML Vision"
            CameraLogger.success("Đã nạp thành công [\(name)] (\(modelTypeDesc)) với tối ưu ANE/GPU", category: .ai)
            return
        }
        
        // Quét tự động bundle nếu người dùng nhúng model YOLO có tên khác
        if let bundleUrls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) {
            for url in bundleUrls {
                let baseName = url.deletingPathExtension().lastPathComponent
                if baseName.lowercased().contains("yolo") {
                    if let modelResult = makeModel(named: baseName) {
                        modelLock.withLock {
                            yoloNativeMLModel = modelResult.mlModel
                            yoloCoreMLModel = modelResult.vnModel
                            isDedicatedYOLO26ANE = modelResult.isDedicatedANE
                            loadedModelName = baseName
                        }
                        CameraLogger.success("Đã phát hiện và nạp tự động YOLO [\(baseName)]", category: .ai)
                        return
                    }
                }
            }
        }
        
        CameraLogger.info("Chưa tìm thấy tệp model YOLO đã biên dịch trong bundle, hệ thống sử dụng Apple Vision NPU song song", category: .ai)
    }

    private func makeModel(named name: String) -> (mlModel: MLModel, vnModel: VNCoreMLModel?, isDedicatedANE: Bool)? {
        let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
        let package = Bundle.main.url(forResource: name, withExtension: "mlpackage")
        guard let url = compiled ?? package else { return nil }
        do {
            let modelURL = compiled == nil ? try MLModel.compileModel(at: url) : url
            let config = MLModelConfiguration()
            config.computeUnits = .all
            config.allowLowPrecisionAccumulationOnGPU = true
            let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            
            // Nhận biết mô hình YOLOv26 ANE chuyên biệt qua 2 tensor đầu ra coordinates & confidence
            let outputs = mlModel.modelDescription.outputDescriptionsByName
            let isDedicated = outputs["coordinates"] != nil && outputs["confidence"] != nil
            
            let vnModel = isDedicated ? nil : try? VNCoreMLModel(for: mlModel)
            return (mlModel, vnModel, isDedicated)
        } catch {
            CameraLogger.warning("Không thể nạp YOLO [\(name)]: \(error.localizedDescription)", category: .ai)
            return nil
        }
    }
    
    public var hasYOLOModel: Bool {
        modelLock.withLock { yoloNativeMLModel != nil || yoloCoreMLModel != nil }
    }
    
    public var activeModelName: String {
        modelLock.withLock { loadedModelName ?? "YOLOv26" }
    }
    
    /// Chạy nhận diện người, khuôn mặt, động vật và đồ vật trên CVPixelBuffer.
    func detectObjects(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        cancellation: CompositionAnalysisCancellation
    ) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled else { return [] }
        
        let (nativeModel, vnModel, isDedicated) = modelLock.withLock {
            (yoloNativeMLModel, yoloCoreMLModel, isDedicatedYOLO26ANE)
        }
        
        if isDedicated, let nativeModel {
            return detectWithDedicatedANE(model: nativeModel, pixelBuffer: pixelBuffer, cancellation: cancellation)
        } else if let vnModel {
            return detectWithVisionCoreML(vnModel: vnModel, pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
        }
        
        return []
    }
    
    // MARK: - Direct Apple Neural Engine Inference (NMS-Free, 0% CPU Overhead)
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
        let threshold: Float = 0.30
        
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
                
                candidates.append(NeuralSubjectCandidate(
                    boundingBox: uiRect,
                    category: category,
                    confidence: maxScore,
                    label: label,
                    prominenceScore: prominence
                ))
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
                
                candidates.append(NeuralSubjectCandidate(
                    boundingBox: uiRect,
                    category: category,
                    confidence: maxScore,
                    label: label,
                    prominenceScore: prominence
                ))
            }
        }
        
        return candidates.sorted { $0.prominenceScore > $1.prominenceScore }
    }
    
    private func mapDedicatedClassIdToCategory(_ classId: Int) -> NeuralSubjectCategory {
        switch classId {
        case 0: return .face
        case 1: return .human
        case 2: return .animal
        case 3: return .animal
        default: return .foregroundObject
        }
    }
    
    private func localizeDedicatedClassId(_ classId: Int) -> String {
        switch classId {
        case 0: return "Khuôn mặt"
        case 1: return "Người"
        case 2: return "Chó"
        case 3: return "Mèo"
        default: return "Đối tượng"
        }
    }
    
    // MARK: - Vision Framework Fallback Inference (YOLO11 / Classic Models)
    private func detectWithVisionCoreML(
        vnModel: VNCoreMLModel,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        cancellation: CompositionAnalysisCancellation
    ) -> [NeuralSubjectCandidate] {
        var detectedCandidates: [NeuralSubjectCandidate] = []
        let request = VNCoreMLRequest(model: vnModel) { [weak self] req, error in
            guard let self = self, error == nil else { return }
            
            if let results = req.results as? [VNRecognizedObjectObservation] {
                for obs in results where obs.confidence >= 0.30 {
                    guard let topLabel = obs.labels.first else { continue }
                    
                    let confidence = min(obs.confidence, topLabel.confidence)
                    guard confidence >= 0.30 else { continue }
                    
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
        
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try cancellation.perform(request, with: handler)
        } catch {
            if cancellation.isCancelled { return [] }
            CameraLogger.error("Lỗi thực thi YOLO Request", error: error, category: .ai)
            detectedCandidates.removeAll()
            
            // Xử lý tự phục hồi khi model bị quá tải bộ nhớ
            let current = modelLock.withLock { loadedModelName }
            if current == "yolo26m" || current == "yolo26s" || current == "yolo11s" {
                modelLock.withLock {
                    yoloCoreMLModel = nil
                    yoloNativeMLModel = nil
                    loadedModelName = nil
                }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    if let fallback = self.makeModel(named: "yolov26_416_fp16") ?? self.makeModel(named: "yolo26n") ?? self.makeModel(named: "yolo11n") {
                        self.modelLock.withLock {
                            self.yoloNativeMLModel = fallback.mlModel
                            self.yoloCoreMLModel = fallback.vnModel
                            self.isDedicatedYOLO26ANE = fallback.isDedicatedANE
                            self.loadedModelName = "yolov26_416_fp16"
                        }
                        CameraLogger.info("Đã tự động chuyển về YOLOv26 Nano/416 để tiết kiệm tài nguyên", category: .ai)
                    }
                }
            }
        }
        
        return detectedCandidates.sorted { $0.prominenceScore > $1.prominenceScore }
    }
    
    // MARK: - Mapping YOLOv26 & COCO Classes sang NeuralSubjectCategory
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
