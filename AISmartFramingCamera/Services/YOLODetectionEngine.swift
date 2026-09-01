import Foundation
import CoreML
import Vision
import CoreGraphics
import UIKit

/// Động cơ Nhận Diện Vật Thể YOLOv11 CoreML (YOLO Real-time 80 Classes Neural Detection)
/// Chạy trực tiếp trên Apple Neural Engine (ANE) của chip A12 Bionic trở lên
public final class YOLODetectionEngine: @unchecked Sendable {
    public static let shared = YOLODetectionEngine()
    
    private var yoloCoreMLModel: VNCoreMLModel?
    private var isModelLoaded: Bool = false
    
    public init() {
        loadYOLOModel()
    }
    
    /// Tải model YOLOv11 CoreML từ App Bundle
    public func loadYOLOModel() {
        // Tìm file .mlmodelc (đã biên dịch) hoặc .mlpackage trong App Bundle
        if let modelURL = Bundle.main.url(forResource: "YOLOv11", withExtension: "mlmodelc") ??
                          Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all // Tận dụng tối đa Apple Neural Engine + GPU + CPU
                let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                self.yoloCoreMLModel = vnModel
                self.isModelLoaded = true
                CameraLogger.success("Đã nạp thành công Model YOLOv11 CoreML (Neural Engine ANE)", category: .ai)
            } catch {
                CameraLogger.warning("Không thể nạp YOLOv11 compiled model: \(error)", category: .ai)
            }
        } else if let packageURL = Bundle.main.url(forResource: "YOLOv11", withExtension: "mlpackage") ??
                                   Bundle.main.url(forResource: "yolo11n", withExtension: "mlpackage") {
            do {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                self.yoloCoreMLModel = vnModel
                self.isModelLoaded = true
                CameraLogger.success("Đã biên dịch & nạp Model YOLOv11 CoreML", category: .ai)
            } catch {
                CameraLogger.warning("Lỗi biên dịch YOLO package: \(error)", category: .ai)
            }
        } else {
            CameraLogger.info("Model YOLOv11 chưa được đính kèm bundle, sử dụng Vision Native Fallback", category: .ai)
        }
    }
    
    public var hasYOLOModel: Bool {
        return isModelLoaded && yoloCoreMLModel != nil
    }
    
    /// Chạy nhận diện 80 danh mục vật thể thời gian thực bằng YOLOv11
    public func detectObjects(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) -> [NeuralSubjectCandidate] {
        guard let vnModel = self.yoloCoreMLModel else { return [] }
        
        var detectedCandidates: [NeuralSubjectCandidate] = []
        let semaphore = DispatchSemaphore(value: 0)
        
        let request = VNCoreMLRequest(model: vnModel) { [weak self] req, error in
            defer { semaphore.signal() }
            guard let self = self, error == nil else { return }
            
            if let results = req.results as? [VNRecognizedObjectObservation] {
                for obs in results where obs.confidence >= 0.48 {
                    guard let topLabel = obs.labels.first else { continue }
                    let category = self.mapYOLOLabelToCategory(topLabel.identifier)
                    let localizedName = self.localizeYOLOLabel(topLabel.identifier)
                    
                    // Vision (Bottom-Left) -> UI (Top-Left)
                    let uiRect = CGRect(
                        x: obs.boundingBox.origin.x,
                        y: 1.0 - obs.boundingBox.origin.y - obs.boundingBox.height,
                        width: obs.boundingBox.width,
                        height: obs.boundingBox.height
                    )
                    
                    guard self.isValidBox(uiRect) else { continue }
                    
                    let score = self.calculateYOLOProminenceScore(rect: uiRect, confidence: obs.confidence, category: category)
                    
                    detectedCandidates.append(NeuralSubjectCandidate(
                        boundingBox: uiRect,
                        category: category,
                        confidence: obs.confidence,
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
            _ = semaphore.wait(timeout: .now() + 0.05) // Tối đa 50ms
        } catch {
            CameraLogger.error("Lỗi thực thi YOLO Request", error: error, category: .ai)
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
            // Giảm mạnh điểm diện tích với các vùng quá lớn (tường/hậu cảnh tối)
            if area >= 0.85 {
                areaScore = 0.02
            } else {
                areaScore = max(0.05, 0.40 * (1.0 - (area - 0.55) / 0.30))
            }
        } else {
            areaScore = 1.0 - abs(area - 0.25) * 1.2
        }
        
        let dx = Double(rect.midX - 0.5)
        let dy = Double(rect.midY - 0.5)
        let distToCenter = sqrt(dx * dx + dy * dy)
        let centerScore = max(0.2, 1.0 - distToCenter * 0.7)
        
        return Double(confidence) * 1.6 * areaScore * centerScore * category.priorityWeight
    }
    
    private func isValidBox(_ rect: CGRect) -> Bool {
        guard rect.width >= 0.04, rect.height >= 0.04 else { return false }
        guard rect.width <= 0.96, rect.height <= 0.96 else { return false }
        return true
    }
}
