import Foundation
import CoreML
import Vision
import CoreGraphics
import CoreVideo
import ImageIO
import CoreImage

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
    private var hasLoggedExperimentC: Bool = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var bufferPool: CVPixelBufferPool?
    private var bufferPoolSize: (w: Int, h: Int) = (0, 0)
    private let poolLock = NSLock()

    public init() { loadYOLOModel() }

    public func loadYOLOModel() {
        let highMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let names = highMemory ? ["yolov26_ane", "yolov26_416_fp16", "yolo26s", "yolo26n", "yolo12s", "yolo12n"] :
                                 ["yolov26_ane", "yolov26_416_fp16", "yolo26n", "yolo26s", "yolo12n", "yolo12s"]
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
            let isDedicated = name.hasPrefix("yolov26") || name.hasPrefix("yolo26")
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
            return detectWithDedicatedANE(model: nativeModel, pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
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
        return autoreleasepool {
            guard !cancellation.isCancelled else { return [] }
            guard let modelResult = makeModel(named: "yolov26_416_fp16", computeUnits: .cpuAndNeuralEngine) ??
                                    makeModel(named: "yolov26_ane", computeUnits: .all) ??
                                    makeModel(named: "yolo26s", computeUnits: .all) ??
                                    makeModel(named: "yolo12s", computeUnits: .all),
                  let vnModel = modelResult.vnModel else {
                return detectObjects(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
            }
            return detectWithVisionCoreML(vnModel: vnModel, pixelBuffer: pixelBuffer, orientation: orientation,
                                          cancellation: cancellation, photographic: true)
        }
    }

    private func inputSize(for model: MLModel) -> (width: Int, height: Int) {
        if let imageDesc = model.modelDescription.inputDescriptionsByName["image"],
           let constraint = imageDesc.imageConstraint,
           constraint.pixelsWide > 0, constraint.pixelsHigh > 0 {
            return (constraint.pixelsWide, constraint.pixelsHigh)
        }
        let currentName = modelLock.withLock { loadedModelName } ?? ""
        if currentName.contains("416") {
            return (416, 416)
        }
        return (640, 640)
    }

    private func getResizedPixelBuffer(
        from sourceBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        orientation: CGImagePropertyOrientation = .up
    ) -> CVPixelBuffer? {
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        let srcW = CVPixelBufferGetWidth(sourceBuffer)
        let srcH = CVPixelBufferGetHeight(sourceBuffer)
        if srcW == targetWidth && srcH == targetHeight && orientation == .up {
            return sourceBuffer
        }

        var destinationBuffer: CVPixelBuffer?
        poolLock.withLock {
            if bufferPool == nil || bufferPoolSize.w != targetWidth || bufferPoolSize.h != targetHeight {
                let poolAttributes: [CFString: Any] = [
                    kCVPixelBufferPoolMinimumBufferCountKey: 2
                ]
                let pixelBufferAttributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: targetWidth,
                    kCVPixelBufferHeightKey: targetHeight,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true
                ]
                var pool: CVPixelBufferPool?
                let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &pool)
                if status == kCVReturnSuccess, let pool {
                    bufferPool = pool
                    bufferPoolSize = (targetWidth, targetHeight)
                }
            }
            if let pool = bufferPool {
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationBuffer)
                if status != kCVReturnSuccess { destinationBuffer = nil }
            }
        }

        if destinationBuffer == nil {
            let pixelBufferAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: targetWidth,
                kCVPixelBufferHeightKey: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, pixelBufferAttributes as CFDictionary, &destinationBuffer)
        }

        guard let dest = destinationBuffer,
              CVPixelBufferGetWidth(dest) == targetWidth,
              CVPixelBufferGetHeight(dest) == targetHeight else {
            return nil
        }

        let ciImage = orientation == .up ? CIImage(cvPixelBuffer: sourceBuffer) : CIImage(cvPixelBuffer: sourceBuffer).oriented(orientation)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let normalizedOrigin = ciImage.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaleX = CGFloat(targetWidth) / extent.width
        let scaleY = CGFloat(targetHeight) / extent.height
        let scaled = normalizedOrigin.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: dest)
        return dest
    }

    private func detectWithDedicatedANE(
        model: MLModel,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        cancellation: CompositionAnalysisCancellation
    ) -> [NeuralSubjectCandidate] {
        guard !cancellation.isCancelled else { return [] }
        let targetSize = inputSize(for: model)
        guard targetSize.width > 0, targetSize.height > 0 else { return [] }
        guard let bufferToFeed = getResizedPixelBuffer(
            from: pixelBuffer,
            targetWidth: targetSize.width,
            targetHeight: targetSize.height,
            orientation: orientation
        ) else { return [] }
        let feedW = CVPixelBufferGetWidth(bufferToFeed)
        let feedH = CVPixelBufferGetHeight(bufferToFeed)
        guard feedW == targetSize.width, feedH == targetSize.height else {
            return []
        }
        do {
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: bufferToFeed)
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
        if !hasLoggedExperimentC {
            hasLoggedExperimentC = true
            CompositionExperiments.logExperimentC(coords: coords, conf: conf)
        }

        let numBoxes: Int
        let numClasses: Int
        let coordBoxStride: Int
        let coordElemStride: Int
        if coords.shape.count >= 3 && coords.strides.count >= 3 {
            numBoxes = coords.shape[1].intValue
            coordBoxStride = coords.strides[1].intValue
            coordElemStride = coords.strides[2].intValue
        } else if coords.shape.count == 2 && coords.strides.count >= 2 {
            numBoxes = coords.shape[0].intValue
            coordBoxStride = coords.strides[0].intValue
            coordElemStride = coords.strides[1].intValue
        } else {
            return []
        }

        let confBoxStride: Int
        let confClassStride: Int
        if conf.shape.count >= 3 && conf.strides.count >= 3 {
            numClasses = conf.shape[2].intValue
            confBoxStride = conf.strides[1].intValue
            confClassStride = conf.strides[2].intValue
        } else if conf.shape.count == 2 && conf.strides.count >= 2 {
            numClasses = conf.shape[1].intValue
            confBoxStride = conf.strides[0].intValue
            confClassStride = conf.strides[1].intValue
        } else {
            return []
        }

        guard numBoxes > 0, numClasses > 0 else { return [] }
        var rawCandidates: [NeuralSubjectCandidate] = []
        let baseThreshold: Float = CompositionTuning.yoloConfidenceThreshold

        let coordsCapacity = max(coords.count, numBoxes * coordBoxStride)
        let confCapacity = max(conf.count, numBoxes * confBoxStride)

        if coords.dataType == .float16 && conf.dataType == .float16 {
            let coordsPtr = coords.dataPointer.bindMemory(to: Float16.self, capacity: coordsCapacity)
            let confPtr = conf.dataPointer.bindMemory(to: Float16.self, capacity: confCapacity)
            for i in 0..<numBoxes {
                if cancellation.isCancelled { break }
                let confBoxBase = i * confBoxStride
                var maxScore: Float = 0.0
                var maxClassId: Int = 0
                for c in 0..<numClasses {
                    let score = Float(confPtr[confBoxBase + c * confClassStride])
                    if score > maxScore {
                        maxScore = score
                        maxClassId = c
                    }
                }
                let classThreshold: Float = (maxClassId == 0 || maxClassId == 2 || maxClassId == 3) ? max(baseThreshold, 0.52) : baseThreshold
                guard maxScore >= classThreshold else { continue }
                let coordBoxBase = i * coordBoxStride
                let cx = CGFloat(Float(coordsPtr[coordBoxBase + 0 * coordElemStride]))
                let cy = CGFloat(Float(coordsPtr[coordBoxBase + 1 * coordElemStride]))
                let w = CGFloat(Float(coordsPtr[coordBoxBase + 2 * coordElemStride]))
                let h = CGFloat(Float(coordsPtr[coordBoxBase + 3 * coordElemStride]))
                let rawRect = CompositionPureCalculations.decodeYOLORawBox(cx: cx, cy: cy, w: w, h: h)
                guard let uiRect = clippedValidBox(rawRect) else { continue }
                let area = uiRect.width * uiRect.height
                guard area >= 0.006 && area <= 0.95 else { continue }
                let category = mapDedicatedClassIdToCategory(maxClassId)
                let label = localizeDedicatedClassId(maxClassId)
                let prominence = calculateYOLOProminenceScore(rect: uiRect, confidence: maxScore, category: category, rawLabel: label)
                rawCandidates.append(NeuralSubjectCandidate(boundingBox: uiRect, category: category, confidence: maxScore, label: label, prominenceScore: prominence))
            }
        } else {
            let coordsPtr = coords.dataPointer.bindMemory(to: Float.self, capacity: coordsCapacity)
            let confPtr = conf.dataPointer.bindMemory(to: Float.self, capacity: confCapacity)
            for i in 0..<numBoxes {
                if cancellation.isCancelled { break }
                let confBoxBase = i * confBoxStride
                var maxScore: Float = 0.0
                var maxClassId: Int = 0
                for c in 0..<numClasses {
                    let score = confPtr[confBoxBase + c * confClassStride]
                    if score > maxScore {
                        maxScore = score
                        maxClassId = c
                    }
                }
                let classThreshold: Float = (maxClassId == 0 || maxClassId == 2 || maxClassId == 3) ? max(baseThreshold, 0.52) : baseThreshold
                guard maxScore >= classThreshold else { continue }
                let coordBoxBase = i * coordBoxStride
                let cx = CGFloat(coordsPtr[coordBoxBase + 0 * coordElemStride])
                let cy = CGFloat(coordsPtr[coordBoxBase + 1 * coordElemStride])
                let w = CGFloat(coordsPtr[coordBoxBase + 2 * coordElemStride])
                let h = CGFloat(coordsPtr[coordBoxBase + 3 * coordElemStride])
                let rawRect = CompositionPureCalculations.decodeYOLORawBox(cx: cx, cy: cy, w: w, h: h)
                guard let uiRect = clippedValidBox(rawRect) else { continue }
                let area = uiRect.width * uiRect.height
                guard area >= 0.006 && area <= 0.95 else { continue }
                let category = mapDedicatedClassIdToCategory(maxClassId)
                let label = localizeDedicatedClassId(maxClassId)
                let prominence = calculateYOLOProminenceScore(rect: uiRect, confidence: maxScore, category: category, rawLabel: label)
                rawCandidates.append(NeuralSubjectCandidate(boundingBox: uiRect, category: category, confidence: maxScore, label: label, prominenceScore: prominence))
            }
        }

        var nmsCandidates: [NeuralSubjectCandidate] = []
        for candidate in rawCandidates.sorted(by: { $0.confidence > $1.confidence }) {
            let isOverlapping = nmsCandidates.contains { existing in
                if existing.category != candidate.category { return false }
                let inter = existing.boundingBox.intersection(candidate.boundingBox)
                guard !inter.isNull, !inter.isEmpty else { return false }
                let interArea = inter.width * inter.height
                let unionArea = existing.boundingBox.width * existing.boundingBox.height + candidate.boundingBox.width * candidate.boundingBox.height - interArea
                guard unionArea > 0 else { return false }
                return (interArea / unionArea) > 0.45
            }
            if !isOverlapping {
                nmsCandidates.append(candidate)
            }
            if nmsCandidates.count >= 10 { break }
        }
        return nmsCandidates.sorted { $0.prominenceScore > $1.prominenceScore }
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
        let bufferW = Double(CVPixelBufferGetWidth(pixelBuffer))
        let bufferH = Double(CVPixelBufferGetHeight(pixelBuffer))

        if photographic {
            CompositionExperiments.logExperimentD(
                bufferWidth: Int(bufferW),
                bufferHeight: Int(bufferH),
                modelInputWidth: 640,
                modelInputHeight: 640,
                cropAndScaleOption: "scaleFit"
            )
        }

        var detectedCandidates: [NeuralSubjectCandidate] = []
        let threshold = CompositionTuning.yoloConfidenceThreshold

        let request = VNCoreMLRequest(model: vnModel) { [weak self] req, error in
            guard let self = self, error == nil else { return }
            
            if let results = req.results as? [VNRecognizedObjectObservation] {
                for obs in results where obs.confidence >= threshold {
                    guard let topLabel = obs.labels.first else { continue }
                    
                    let confidence = min(obs.confidence, topLabel.confidence)
                    guard confidence >= threshold else { continue }
                    
                    let category = self.mapYOLOLabelToCategory(topLabel.identifier)
                    let localizedName = self.localizeYOLOLabel(topLabel.identifier)
                    
                    // Chuyen doi he toa do Vision (Goc duoi-trai) sang UI Camera (Goc tren-trai)
                    let visionRect = CompositionPureCalculations.visionToUprightRect(obs.boundingBox)
                    
                    // Hoan nguyen vien den letterbox khi dung .scaleFit
                    let rawRect: CGRect
                    if photographic {
                        let isPortrait = (orientation == .right || orientation == .left || orientation == .rightMirrored || orientation == .leftMirrored) || (bufferH > bufferW)
                        rawRect = CompositionPureCalculations.unpadLetterbox(
                            normalizedRect: visionRect,
                            sourceWidth: bufferW,
                            sourceHeight: bufferH,
                            modelSize: 640.0,
                            isPortraitOrientation: isPortrait
                        )
                    } else {
                        rawRect = visionRect
                    }
                    
                    guard let uiRect = self.clippedValidBox(rawRect) else { continue }
                    guard uiRect.width >= 0.04, uiRect.height >= 0.04, uiRect.width <= 0.95, uiRect.height <= 0.95 else { continue }
                    let aspectRatio = uiRect.width / max(0.001, uiRect.height)
                    guard aspectRatio >= 0.15 && aspectRatio <= 6.5 else { continue }
                    
                    let score = self.calculateYOLOProminenceScore(rect: uiRect, confidence: confidence, category: category, rawLabel: topLabel.identifier)
                    
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
    
    private func calculateYOLOProminenceScore(rect: CGRect, confidence: Float, category: NeuralSubjectCategory, rawLabel: String = "") -> Double {
        let area = Double(rect.width * rect.height)
        
        let areaScore: Double
        if area < 0.02 {
            areaScore = area / 0.02 * 0.45
        } else if area > 0.55 {
            areaScore = max(0.30, 1.0 - (area - 0.55) * 1.35)
        } else {
            areaScore = 1.0 - abs(area - 0.22) * 1.05
        }
        
        let dx = Double(rect.midX - 0.5)
        let dy = Double(rect.midY - 0.5)
        let distToCenter = sqrt(dx * dx + dy * dy)
        let centerScore = max(0.25, 1.0 - distToCenter * 0.72)
        
        let lowerLabel = rawLabel.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let backgroundFurnitureLabels: Set<String> = [
            "chair", "dining table", "couch", "bed", "tv", "bench", "toilet",
            "sink", "refrigerator", "oven", "microwave", "ghế", "bàn ăn", "sofa", "giường", "tivi"
        ]
        let heroTabletopLabels: Set<String> = [
            "cup", "wine glass", "bottle", "bowl", "cake", "donut", "pizza", "sandwich",
            "banana", "apple", "orange", "potted plant", "vase", "book", "cell phone",
            "laptop", "clock", "teddy bear", "backpack", "handbag",
            "cốc nước", "ly rượu", "chai nước", "bát đĩa", "bánh ngọt", "chậu cây",
            "bình hoa", "cuốn sách", "điện thoại", "gấu bông"
        ]
        
        // Ưu tiên cao nhất cho Face và Animal, sau đó tới Human và Vật thể tiền cảnh; phạt nặng bàn ghế hậu cảnh
        let categoryBonus: Double
        switch category {
        case .face:
            categoryBonus = 2.4
        case .animal:
            categoryBonus = 2.0
        case .human:
            let distantBackgroundHuman = (area < 0.045 && rect.maxY < 0.62)
            categoryBonus = distantBackgroundHuman ? 0.65 : 1.8
        default:
            if backgroundFurnitureLabels.contains(lowerLabel) {
                categoryBonus = 0.26
            } else if heroTabletopLabels.contains(lowerLabel) {
                categoryBonus = 1.55
            } else {
                categoryBonus = 1.05
            }
        }
        
        return Double(confidence) * 1.5 * areaScore * centerScore * category.priorityWeight * categoryBonus
    }
    
    private func clippedValidBox(_ rect: CGRect) -> CGRect? {
        return CompositionPureCalculations.validateAndClipBox(rawRect: rect)
    }
}
