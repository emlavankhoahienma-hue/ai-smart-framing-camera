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
    private var loadedModelName: String?
    
    public init() {
        loadYOLOModel()
    }
    
    /// Nạp mô hình theo thứ tự ưu tiên YOLOv26 mới nhất, tối ưu bộ nhớ ANE (Apple Neural Engine).
    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let prioritizedNames = (highMemory ? ["yolo26m", "yolo26s", "yolo26", "yolov26", "YOLOv26", "yolo11s"] : []) +
            ["yolo26n", "yolov26n", "yolo26", "yolov26", "YOLOv26", "yolo11n", "YOLOv11", "yolov8n"]
        
        for name in prioritizedNames {
            guard let model = makeModel(named: name) else { continue }
            modelLock.withLock {
                yoloCoreMLModel = model
                loadedModelName = name
            }
            CameraLogger.success("Đã nạp thành công YOLO CoreML [\(name)] với tối ưu ANE/GPU", category: .ai)
            return
        }
        
        // Quét tự động bundle nếu người dùng nhúng model YOLO có tên khác
        if let bundleUrls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) {
            for url in bundleUrls {
                let baseName = url.deletingPathExtension().lastPathComponent
                if baseName.lowercased().contains("yolo") {
                    if let model = makeModel(named: baseName) {
                        modelLock.withLock {
                            yoloCoreMLModel = model
                            loadedModelName = baseName
                        }
                        CameraLogger.success("Đã phát hiện và nạp tự động YOLO CoreML [\(baseName)]", category: .ai)
                        return
                    }
                }
            }
        }
        
        CameraLogger.info("Chưa tìm thấy tệp model YOLO đã biên dịch trong bundle, hệ thống sử dụng Apple Vision NPU song song", category: .ai)
    }

    private func makeModel(named name: String) -> VNCoreMLModel? {
        let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
        let package = Bundle.main.url(forResource: name, withExtension: "mlpackage")
        guard let url = compiled ?? package else { return nil }
        do {
            let modelURL = compiled == nil ? try MLModel.compileModel(at: url) : url
            let config = MLModelConfiguration()
            config.computeUnits = .all
            config.allowLowPrecisionAccumulationOnGPU = true
            return try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: config))
        } catch {
            CameraLogger.warning("Không thể nạp YOLO [\(name)]: \(error.localizedDescription)", category: .ai)
            return nil
        }
    }
    
    public var hasYOLOModel: Bool {
        modelLock.withLock { yoloCoreMLModel != nil }
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
        guard let vnModel = modelLock.withLock({ yoloCoreMLModel }) else { return [] }
        
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
                    loadedModelName = nil
                }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    if let fallback = self.makeModel(named: "yolo26n") ?? self.makeModel(named: "yolo11n") {
                        self.modelLock.withLock {
                            self.yoloCoreMLModel = fallback
                            self.loadedModelName = "yolo26n"
                        }
                        CameraLogger.info("Đã tự động chuyển về YOLOv26 Nano để tiết kiệm tài nguyên", category: .ai)
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
