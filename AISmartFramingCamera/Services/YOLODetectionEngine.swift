import Foundation
import CoreML
import Vision
import CoreGraphics
import UIKit

/// Nhận diện 80 lớp COCO qua model YOLO Core ML đã đóng gói.
/// YOLO11s serves high-memory devices, YOLO11n serves older devices.
/// Vision remains the fallback when loading or inference fails.
public final class YOLODetectionEngine: @unchecked Sendable {
    public static let shared = YOLODetectionEngine()

    private let modelLock = NSLock()
    private var yoloCoreMLModel: VNCoreMLModel?
    private var loadedModelName: String?
    
    public init() {
        loadYOLOModel()
    }
    
    /// Load one model at a time so the stronger tier does not keep the nano
    /// weights resident on devices that already load SigLIP for a one-shot AI.
    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let names = (highMemory ? ["yolo11s"] : []) +
            ["yolo11n", "YOLOv11", "yolov8n"]
        for name in names {
            guard let model = makeModel(named: name) else { continue }
            modelLock.withLock {
                yoloCoreMLModel = model
                loadedModelName = name
            }
            CameraLogger.success("Đã nạp YOLO CoreML: \(name)", category: .ai)
            return
        }
        CameraLogger.info("Model YOLO chưa khả dụng, dùng Apple Vision", category: .ai)
    }

    private func makeModel(named name: String) -> VNCoreMLModel? {
        let compiled = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
        let package = Bundle.main.url(forResource: name, withExtension: "mlpackage")
        guard let url = compiled ?? package else { return nil }
        do {
            let modelURL = compiled == nil ? try MLModel.compileModel(at: url) : url
            let config = MLModelConfiguration()
            config.computeUnits = .all
            return try VNCoreMLModel(for: MLModel(contentsOf: modelURL,
                                                  configuration: config))
        } catch {
            CameraLogger.warning("Không thể nạp \(name): \(error)", category: .ai)
            return nil
        }
    }
    
    public var hasYOLOModel: Bool {
        modelLock.withLock { yoloCoreMLModel != nil }
    }
    
    /// Chạy nhận diện 80 lớp COCO trên một ảnh nguồn.
    public func detectObjects(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> [NeuralSubjectCandidate] {
        guard let vnModel = modelLock.withLock({ yoloCoreMLModel }) else { return [] }
        
        var detectedCandidates: [NeuralSubjectCandidate] = []
        let request = VNCoreMLRequest(model: vnModel) { [weak self] req, error in
            guard let self = self, error == nil else { return }
            
            if let results = req.results as? [VNRecognizedObjectObservation] {
                for obs in results where obs.confidence >= 0.35 {
                    guard let topLabel = obs.labels.first else { continue }
                    // Vision object and class scores are independent evidence.
                    // A weak class may propose a box, but cannot assert identity.
                    let confidence = min(obs.confidence, topLabel.confidence)
                    guard confidence >= 0.35 else { continue }
                    let category = confidence >= 0.48 ?
                        self.mapYOLOLabelToCategory(topLabel.identifier) : .general
                    let localizedName = confidence >= 0.48 ?
                        self.localizeYOLOLabel(topLabel.identifier) : "Vùng có thể chọn"
                    
                    // Vision (Bottom-Left) -> UI (Top-Left)
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
            try handler.perform([request])
        } catch {
            CameraLogger.error("Lỗi thực thi YOLO Request", error: error, category: .ai)
            detectedCandidates.removeAll()
            let failedSmall = modelLock.withLock { loadedModelName == "yolo11s" }
            if failedSmall {
                // The current frame can safely continue through Vision. Release
                // the failed model before loading nano for the next AI session.
                modelLock.withLock {
                    yoloCoreMLModel = nil
                    loadedModelName = nil
                }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self, let nano = self.makeModel(named: "yolo11n") else { return }
                    self.modelLock.withLock {
                        self.yoloCoreMLModel = nano
                        self.loadedModelName = "yolo11n"
                    }
                }
            }
        }
        
        return detectedCandidates.sorted { $0.prominenceScore > $1.prominenceScore }
    }
    
    // MARK: - Mapping YOLO 80 COCO Classes sang NeuralSubjectCategory
    private func mapYOLOLabelToCategory(_ label: String) -> NeuralSubjectCategory {
        let l = label.lowercased()
        if l == "person" {
            return .human
        } else if l == "cat" || l == "dog" || l == "horse" || l == "sheep" || l == "cow" || l == "elephant" || l == "bear" || l == "zebra" || l == "giraffe" || l == "bird" {
            return .animal
        } else {
            return .foregroundObject
        }
    }
    
    private func localizeYOLOLabel(_ label: String) -> String {
        let dict: [String: String] = [
            "person": "Người",
            "bicycle": "Xe đạp",
            "car": "Ô tô",
            "motorcycle": "Xe máy",
            "airplane": "Máy bay",
            "bus": "Xe bus",
            "train": "Tàu hỏa",
            "truck": "Xe tải",
            "boat": "Thuyền",
            "traffic light": "Đèn giao thông",
            "bird": "Chim",
            "cat": "Mèo",
            "dog": "Chó",
            "horse": "Ngựa",
            "sheep": "Cừu",
            "cow": "Bò",
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
        return dict[label.lowercased()] ?? label.capitalized
    }
    
    private func calculateYOLOProminenceScore(rect: CGRect, confidence: Float, category: NeuralSubjectCategory) -> Double {
        let area = Double(rect.width * rect.height)
        
        let areaScore: Double
        if area < 0.02 {
            areaScore = area / 0.02 * 0.5
        } else if area > 0.55 {
            areaScore = max(0.45, 1.0 - (area - 0.55) * 1.1)
        } else {
            areaScore = 1.0 - abs(area - 0.25) * 1.2
        }
        
        let dx = Double(rect.midX - 0.5)
        let dy = Double(rect.midY - 0.5)
        let distToCenter = sqrt(dx * dx + dy * dy)
        let centerScore = max(0.2, 1.0 - distToCenter * 0.7)
        
        return Double(confidence) * 1.6 * areaScore * centerScore * category.priorityWeight
    }
    
    private func clippedValidBox(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let visible = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !visible.isNull, !visible.isEmpty,
              visible.width >= 0.04, visible.height >= 0.04,
              visible.width <= 0.99, visible.height <= 0.99,
              visible.width * visible.height >= rect.width * rect.height * 0.80 else { return nil }
        return visible
    }
}
