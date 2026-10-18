import Foundation
import Vision
import CoreGraphics
import CoreImage
import UIKit
import CoreML
import simd

/// Phân loại danh mục chủ thể đời thực
public enum NeuralSubjectCategory: String, Sendable {
    case human = "Người (Human Body)"
    case face = "Khuôn mặt (Human Face)"
    case animal = "Thú cưng / Động vật"
    case foregroundObject = "Vật thể tiền cảnh (Object)"
    case general = "Cảnh quan chung"
    
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

/// Optional semantic evidence from the original frame and feasible composition previews.
/// It never invents a box or overrides crop/tracking safety. Access is serialized by the engine.
private final class SemanticCropRanker: @unchecked Sendable {
    static let shared = SemanticCropRanker()
    private var attemptedLoad = false
    private var model: VNCoreMLModel?
    private var prompts: [String: [Double]] = [:]
    private(set) var didProduceEvidence = false

    func beginAnalysis() { didProduceEvidence = false }
    func endAnalysis() {
        model = nil
        prompts.removeAll(keepingCapacity: false)
        attemptedLoad = false
    }

    private func loadIfAvailable() {
        guard !attemptedLoad else { return }
        attemptedLoad = true
        guard ProcessInfo.processInfo.physicalMemory >= 4_000_000_000,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              let url = Bundle.main.url(forResource: "SigLIPBaseImage", withExtension: "mlmodelc"),
              let promptURL = Bundle.main.url(forResource: "SigLIPPrompts", withExtension: "json") else { return }
        do {
            try CompositionInferenceResources.requireHeadroom(320 * 1024 * 1024)
            let data = try Data(contentsOf: promptURL)
            let vectors = try JSONDecoder().decode([String: [Double]].self, from: data)
            guard !vectors.isEmpty, vectors.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isFinite) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            prompts = vectors
        } catch {
            model = nil
            prompts = [:]
            CameraLogger.warning("SigLIP không khả dụng, dùng Vision/YOLO: \(error)", category: .ai)
        }
    }

    func sceneEvidence(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                       cancellation: CompositionAnalysisCancellation) -> [String: Double] {
        loadIfAvailable()
        guard let model, !prompts.isEmpty, !cancellation.isCancelled else { return [:] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        return affinities(model: model, handler: handler, cancellation: cancellation)
    }

    private func affinities(model: VNCoreMLModel, handler: VNImageRequestHandler,
                            cancellation: CompositionAnalysisCancellation) -> [String: Double] {
        let request = VNCoreMLRequest(model: model)
        // Preserve relative spacing when comparing complete portrait frames.
        request.imageCropAndScaleOption = .scaleFit
        do { try cancellation.perform(request, with: handler) }
        catch {
            if !cancellation.isCancelled { CompositionInferenceResources.report("SigLIP prediction", error: error) }
            return [:]
        }
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue else { return [:] }
        let image = (0..<array.count).map { Double(truncating: array[$0]) }
        let norm = sqrt(image.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.001 else { return [:] }
        var scores: [String: Double] = [:]
        for (key, text) in prompts where text.count == image.count {
            let score = zip(image, text).reduce(0) { $0 + $1.0 * $1.1 } / norm
            if score.isFinite { scores[key] = score }
        }
        didProduceEvidence = didProduceEvidence || !scores.isEmpty
        return scores
    }

    func sceneHint(scores: [String: Double], candidates: [NeuralSubjectCandidate]) -> DetectedSceneType? {
        let ordered = scores.sorted { $0.value > $1.value }
        guard let best = ordered.first, best.value >= 0.25,
              ordered.count < 2 || best.value - ordered[1].value >= 0.025 else { return nil }
        switch best.key {
        case "building": return .architecture
        case "landscape", "person_scenery": return .landscape
        case "group", "person": return candidates.contains { $0.category == .human || $0.category == .face } ? .portrait : nil
        case "flower", "macro": return .macro
        case "foliage": return .foliage
        case "sky": return .sky
        case "water": return .water
        case "sunset": return .sunset
        case "street": return .street
        case "food": return .food
        case "animal": return .pet
        default: return nil
        }
    }
}

/// Ứng viên chủ thể được AI phát hiện và xếp hạng
public struct NeuralSubjectCandidate: Identifiable, Sendable {
    public let id = UUID()
    public let boundingBox: CGRect // Toạ độ chuẩn hóa UI (Top-Left 0..1)
    public let category: NeuralSubjectCategory
    public let confidence: Float
    public let label: String
    public var prominenceScore: Double
    var eyePosition: CGPoint? = nil
    var gaze: CGFloat = 0
    var companionBounds: [CGRect] = []
    var faceBounds: [CGRect] = []
    var trackingPoint: CGPoint? = nil
    var isGroup = false

    // The preserved candidate format identifies Vision saliency regions by this
    // fixed internal label. YOLO class labels never use it. A region is a field
    // of attention, not a physical object whose complete outline must be kept.
    var isAttentionRegion: Bool { category == .foregroundObject && label == "Vùng nổi bật" }
    
    public var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
    
    public var areaRatio: Double {
        Double(boundingBox.width * boundingBox.height)
    }
}

/// Kết quả phân tích thị giác ANE nâng cao
public struct NeuralAnalysisOutput: Sendable {
    public let allCandidates: [NeuralSubjectCandidate]
    public let detectedScene: DetectedSceneType
    public let allFaceRects: [CGRect]
    public let primaryEyePosition: CGPoint?
    public let lookingDirection: CGVector
    public let usedSemanticModel: Bool
    var compositionRaster: CompositionRaster?
    var semanticAffinities: [String: Double] = [:]
    var primaryFaceCount: Int { allCandidates.first?.faceBounds.count ?? 0 }

    public init(
        allCandidates: [NeuralSubjectCandidate],
        detectedScene: DetectedSceneType,
        allFaceRects: [CGRect] = [],
        primaryEyePosition: CGPoint? = nil,
        lookingDirection: CGVector = CGVector(dx: 0, dy: 0),
        usedSemanticModel: Bool = false
    ) {
        self.allCandidates = allCandidates
        self.detectedScene = detectedScene
        self.allFaceRects = allFaceRects
        self.primaryEyePosition = primaryEyePosition
        self.lookingDirection = lookingDirection
        self.usedSemanticModel = usedSemanticModel
    }
}

// CGImage is immutable; choices cross the worker/MainActor boundary without mutation.
struct LocalCompositionChoice: Identifiable, @unchecked Sendable {
    let id = UUID()
    let candidate: NeuralSubjectCandidate
    let plan: LocalFramingPlan
    let preview: CGImage
    var title: String { plan.preservesOriginalFrame ? "Giữ khung hiện tại" : plan.intent.title }
}

struct LocalCompositionAnalysis: Sendable {
    let detection: NeuralAnalysisOutput
    let choices: [LocalCompositionChoice]
    let fallbackCandidates: [NeuralSubjectCandidate]
    var usedCompositionModel = false
    var canAutoselectComposition = false
    var receipt: CompositionAnalysisReceipt? = nil
}

/// Expensive interpretation runs only on the serialized one-shot worker.
/// No camera-pool buffer is cached and none of this state enters the target tracker.
public final class NeuralSubjectIntelligenceEngine: @unchecked Sendable {
    public static let shared = NeuralSubjectIntelligenceEngine()
    private let analysisLock = NSLock()
    private let renderer = CompositionImageRenderer()
    public init() {}

    func analyzeComposition(pixelBuffer: CVPixelBuffer, frame: TrackingFrameContext,
                            pose: simd_quatd, allowedZooms: [CGFloat], maximumOpticalZoom: CGFloat? = nil,
                            preferences: [String: Double], requestID: UUID,
                            cancellation: CompositionAnalysisCancellation,
                            progress: @Sendable (String) -> Void = { _ in }) -> LocalCompositionAnalysis? {
        guard !cancellation.isCancelled else { return nil }
        analysisLock.lock()
        defer { SemanticCropRanker.shared.endAnalysis(); analysisLock.unlock() }
        let started = ProcessInfo.processInfo.systemUptime
        func receipt(count: Int = 0, specialist: Bool = false, modern: Int = 0, system: Int = 0) -> CompositionAnalysisReceipt {
            CompositionAnalysisReceipt(requestID: requestID, sourceTimestamp: frame.timestamp,
                elapsed: max(0, ProcessInfo.processInfo.systemUptime - started),
                assessedFrames: count, usedSpecialist: specialist, modernAssessments: modern, systemAssessments: system)
        }
        CompositionInferenceResources.report("Recognition begin")
        let detected: NeuralAnalysisOutput? = autoreleasepool {
            defer { SemanticCropRanker.shared.endAnalysis() }
            return analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: frame.orientation,
                                        cancellation: cancellation)
        }
        guard !cancellation.isCancelled, let output = detected else { return nil }
        CompositionInferenceResources.report("Recognition complete; Focal begin")
        // Choose identity before optimizing layout. Different crops must never
        // compete by silently substituting an unrelated background object.
        guard let hero = output.allCandidates.first else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [], receipt: receipt())
        }
        guard let baseRaster = output.compositionRaster else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(frame.orientation)
        guard let reference = renderer.referenceImage(sourceImage),
              let url = Bundle.main.url(forResource: "FocalCrop", withExtension: "mlmodelc") else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        let cropModel: FocalCropModel
        do { cropModel = try autoreleasepool { try FocalCropModel(url: url, image: reference) } }
        catch {
            CompositionInferenceResources.report("Focal load failed", error: error)
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        guard cropModel.assess([CGRect(x: 0, y: 0, width: 1, height: 1)], cancellation: cancellation) != nil else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        let raster = cropModel.enriching(baseRaster)
        var subject = CompositionSubject(index: 0, bounds: hero.boundingBox,
            anchor: CompositionSubject.framingAnchor(bounds: hero.boundingBox, preferred: hero.eyePosition),
            kind: hero.isGroup ? .group : kind(hero.category),
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze)
        subject.allowsAttentionCrop = hero.isAttentionRegion && raster.hasAttention &&
            hero.boundingBox.width * hero.boundingBox.height > 0.45
        let intents = compositionIntents(output, hero: hero)
        var portraitBounds: CGRect?
        if hero.category == .human, !hero.isGroup, !hero.faceBounds.isEmpty {
            let poseRequest = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: frame.orientation, options: [:])
            do {
                try cancellation.perform(poseRequest, with: handler)
                portraitBounds = PortraitFramingEvidence.bounds(body: hero.boundingBox,
                    faces: hero.faceBounds, observations: poseRequest.results ?? [])
            } catch {
                if cancellation.isCancelled { return nil }
                CompositionInferenceResources.report("Portrait pose unavailable", error: error)
            }
        }
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled ||
            ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ||
            ProcessInfo.processInfo.physicalMemory < 6_000_000_000
        let budget = CompositionSearchBudget(complexScene: CompositionSearchBudget.isComplex(
            group: hero.isGroup, intents: intents), constrained: constrained)
        func proposals(refining seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents,
                portraitBounds: portraitBounds, raster: raster, calibration: frame.calibration,
                currentZoom: CGFloat(frame.displayZoom), allowedZooms: allowedZooms,
                protectedBounds: hero.companionBounds,
                incidentalBounds: output.allFaceRects.filter { !hero.faceBounds.contains($0) } +
                    output.allCandidates.filter { $0.category == .animal && $0.id != hero.id }.map(\.boundingBox),
                proposalLimit: seeds.isEmpty ? budget.coarse : budget.refinement, refining: seeds,
                allowsCameraPan: true,
                maximumOpticalZoom: maximumOpticalZoom,
                isCancelled: { cancellation.isCancelled })
        }
        progress("Đang đánh giá bố cục bằng mô hình trên máy…")
        let search = CompositionAestheticSearch(renderer: renderer)
        guard let result = search.run(proposals: proposals(),
            image: sourceImage,
            aspect: frame.calibration.aspect, preferences: preferences,
            modelURL: Bundle.main.url(forResource: "SAMPComposition", withExtension: "mlmodelc"),
            aestheticModelURL: Bundle.main.url(forResource: "CharmAesthetics", withExtension: "mlmodelc"),
            positionURL: Bundle.main.url(forResource: "CharmPositionEmbedding", withExtension: "bin"),
            aestheticLimit: budget.aesthetics, cropModel: cropModel,
            cancellation: cancellation, progress: progress,
            diagnostic: { CameraLogger.warning("Composition search: \($0)", category: .ai) },
            refine: { proposals(refining: $0) }) else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        CompositionInferenceResources.report("Analysis completed")
        let choices = result.views.map { view -> LocalCompositionChoice in
            let proposal = view.proposal
            let explanation = result.needsQualityReview ?
                "Các khung crop bị đánh giá kém hơn. Hãy xem khung gốc trước khi chọn chụp." : proposal.explanation
            var plan = LocalFramingPlan(subjectPoint: hero.trackingPoint ?? proposal.subjectPoint, subjectRect: hero.boundingBox,
                cropProtectionRect: CompositionCropProtection.bounds(body: hero.boundingBox,
                    portrait: portraitBounds, intent: proposal.intent, anchor: subject.anchor,
                    attentionRegion: subject.allowsAttentionCrop),
                aimPointInSource: proposal.aimPoint, aimWorldRay: pose.act(proposal.rotation.act(SIMD3(0, 0, -1))),
                zoom: proposal.zoom, confidence: proposal.evidenceConfidence,
                minimumAutoselectConfidence: max(0.72, LocalAutoselectCalibration.threshold(
                    scene: output.detectedScene, category: hero.category) ?? 1),
                intent: proposal.intent, explanation: explanation + " Đã so sánh vùng ảnh bằng FocalNet và kiểm tra bằng SAMP-Net, Charm 2025.",
                usesCenter: proposal.usesCenter, preferenceKey: proposal.preferenceKey)
            plan.requiresSceneVerification = !proposal.isEntirelyObserved
            plan.preservesOriginalFrame = proposal.isUnchangedView
            plan.subjectKind = subject.kind
            plan.expectedFaces = hero.faceBounds.count
            plan.expectedPeople = hero.isGroup ? hero.companionBounds.filter { !hero.faceBounds.contains($0) }.count :
                (subject.kind == .person ? 1 : 0)
            return LocalCompositionChoice(candidate: hero, plan: plan, preview: view.image)
        }
        return LocalCompositionAnalysis(detection: output, choices: choices, fallbackCandidates: [hero],
            usedCompositionModel: result.usedSpecialist,
            canAutoselectComposition: result.canAutoselect,
            receipt: receipt(count: result.cropAssessmentCount, specialist: result.usedSpecialist, modern: result.modernAssessmentCount, system: result.systemAssessmentCount))
    }

    func verifyFinalFraming(pixelBuffer: CVPixelBuffer, frame: TrackingFrameContext,
                            protectedBounds: CGRect, expectedKind: CompositionSubjectKind,
                            minimumFaces: Int, minimumPeople: Int,
                            cancellation: CompositionAnalysisCancellation) -> Bool {
        guard !cancellation.isCancelled else { return false }
        analysisLock.lock()
        defer { SemanticCropRanker.shared.endAnalysis(); analysisLock.unlock() }
        return autoreleasepool {
            guard let output = analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: frame.orientation,
                                                    cancellation: cancellation, includeSceneSemantics: false),
                  !cancellation.isCancelled else { return false }
            let subjects = output.allCandidates.map {
                CompositionSubject(index: 0, bounds: $0.boundingBox,
                    anchor: CompositionSubject.framingAnchor(bounds: $0.boundingBox, preferred: $0.eyePosition),
                    kind: $0.isGroup ? .group : kind($0.category), confidence: Double($0.confidence),
                    importance: $0.prominenceScore, gaze: $0.gaze)
            }
            return FinalFramingEvidence.accepts(protectedBounds: protectedBounds, expectedKind: expectedKind,
                minimumFaces: minimumFaces, minimumPeople: minimumPeople,
                subjects: subjects, faces: output.allFaceRects)
        }
    }

    private func compositionIntents(_ output: NeuralAnalysisOutput, hero: NeuralSubjectCandidate) -> [LocalCompositionIntent] {
        if hero.isGroup { return [.group] }
        if hero.category == .human || hero.category == .face {
            let context = [.landscape, .architecture, .street, .sunset].contains(output.detectedScene)
            return context ? [.environmentalPortrait, .portrait] : [.portrait, .environmentalPortrait]
        }
        if hero.category == .animal { return [.animal] }
        if hero.category == .general { return [.landscape] }
        if output.detectedScene == .general,
           let landscape = output.semanticAffinities["landscape"], landscape > 0.30,
           landscape > (output.semanticAffinities["object"] ?? 0) + 0.025 {
            return [.landscape, .object]
        }
        switch output.detectedScene {
        case .food: return [.food]
        case .macro, .foliage: return [.closeUp]
        case .architecture: return [.architecture, .object]
        case .landscape, .sky, .water, .sunset: return [.landscape, .object]
        case .street, .night: return [.street, .object]
        case .portrait, .pet, .general: return [.object]
        }
    }

    private func analyzeCapturedFrame(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                                      cancellation: CompositionAnalysisCancellation,
                                      includeSceneSemantics: Bool = true) -> NeuralAnalysisOutput? {
        SemanticCropRanker.shared.beginAnalysis()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let classification = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        var completed = Set<ObjectIdentifier>()
        let requests: [VNRequest] = includeSceneSemantics ?
            [bodies, faces, animals, objectness, attention, classification] : [bodies, faces, animals, objectness, attention]
        for request in requests {
            if cancellation.isCancelled { return nil }
            do { try cancellation.perform(request, with: handler); completed.insert(ObjectIdentifier(request)) }
            catch {
                if cancellation.isCancelled { return nil }
                CameraLogger.warning("Vision bỏ qua một bằng chứng: \(error)", category: .ai)
            }
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let raster = renderer.raster(image: image,
            saliency: completed.contains(ObjectIdentifier(attention)) ? attention.results?.first?.pixelBuffer : nil,
            objectness: completed.contains(ObjectIdentifier(objectness)) ? objectness.results?.first?.pixelBuffer : nil)
        var candidates = YOLODetectionEngine.shared.detectPhotographicObjects(
            pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
        if completed.contains(ObjectIdentifier(bodies)) {
            for body in bodies.results ?? [] where body.confidence >= 0.40 {
                if let c = candidate(visionRect: body.boundingBox, category: .human, confidence: body.confidence, label: "Người") {
                    candidates.append(c)
                }
            }
        }
        var faceCandidates: [NeuralSubjectCandidate] = []
        if completed.contains(ObjectIdentifier(faces)) {
            for face in faces.results ?? [] where face.confidence >= 0.40 {
                guard var c = candidate(visionRect: face.boundingBox, category: .face,
                                        confidence: face.confidence, label: "Khuôn mặt") else { continue }
                c.faceBounds = [c.boundingBox]
                let eyes = [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap { $0 }
                    .flatMap { $0.normalizedPoints }
                if !eyes.isEmpty {
                    let x = eyes.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(eyes.count)
                    let y = eyes.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(eyes.count)
                    c.eyePosition = CGPoint(x: face.boundingBox.minX + x * face.boundingBox.width,
                                            y: 1 - face.boundingBox.minY - y * face.boundingBox.height)
                }
                if let yaw = face.yaw?.doubleValue, yaw.isFinite { c.gaze = CGFloat(-sin(yaw)) }
                faceCandidates.append(c)
            }
        }
        if completed.contains(ObjectIdentifier(animals)) {
            for animal in animals.results ?? [] where animal.confidence >= 0.45 {
                let label = animal.labels.first?.identifier.lowercased() ?? ""
                if let c = candidate(visionRect: animal.boundingBox, category: .animal, confidence: animal.confidence,
                                     label: label.contains("cat") ? "Mèo" : (label.contains("dog") ? "Chó" : "Động vật")) {
                    candidates.append(c)
                }
            }
        }
        for observation in [objectness.results?.first, attention.results?.first].compactMap({ $0 }) {
            for region in observation.salientObjects ?? [] where region.confidence >= 0.35 {
                if let c = candidate(visionRect: region.boundingBox, category: .foregroundObject,
                                     confidence: region.confidence, label: "Vùng nổi bật") { candidates.append(c) }
            }
        }
        // Keep the complete body for crop safety; attach that body's own face,
        // eye line and head direction rather than the first face in request order.
        for i in candidates.indices where candidates[i].category == .human {
            let box = candidates[i].boundingBox
            let face = faceCandidates.compactMap { face -> (NeuralSubjectCandidate, Double)? in
                HeroSubjectPolicy.faceAffinity(face: face.boundingBox, body: box).map { (face, $0) }
            }.max { $0.1 < $1.1 }?.0
            if let face {
                candidates[i].eyePosition = face.eyePosition ?? face.center
                candidates[i].gaze = face.gaze
                candidates[i].companionBounds = [face.boundingBox]
                candidates[i].faceBounds = [face.boundingBox]
            }
        }
        candidates.append(contentsOf: faceCandidates.filter { face in
            !candidates.contains { $0.category == .human && $0.boundingBox.insetBy(dx: -0.025, dy: -0.025).contains(face.center) }
        })
        candidates = rankedDistinct(candidates, raster: raster)
        if let group = coherentGroup(candidates, raster: raster) { candidates.insert(group, at: 0) }
        if candidates.isEmpty, let raster, let anchor = raster.sceneryAnchor {
            let bounds = CGRect(x: anchor.x - 0.045, y: anchor.y - 0.045, width: 0.09, height: 0.09)
            // A texture patch is only a manual suggestion, never detector certainty.
            candidates = [NeuralSubjectCandidate(boundingBox: bounds, category: .general,
                confidence: 0.35, label: "Chi tiết trong cảnh", prominenceScore: HeroSubjectPolicy.score(
                    bounds: bounds, kind: .scenery, confidence: 0.35, evidence: raster.evidence(in: bounds)))]
        }
        var scene = sceneType(completed.contains(ObjectIdentifier(classification)) ? classification.results ?? [] : [])
        // Final shutter admission needs identity, counts and overlap, not another
        // large scene encoder. Subject ranking and group membership stay identical.
        let semantics = includeSceneSemantics ? SemanticCropRanker.shared.sceneEvidence(
            pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation) : [:]
        if let hint = SemanticCropRanker.shared.sceneHint(scores: semantics, candidates: candidates), scene == .general { scene = hint }
        if scene == .general, let hero = candidates.first {
            if hero.category == .human || hero.category == .face { scene = .portrait }
            else if hero.category == .animal { scene = .pet }
        }
        guard !cancellation.isCancelled else { return nil }
        var output = NeuralAnalysisOutput(allCandidates: candidates, detectedScene: scene,
            allFaceRects: faceCandidates.map(\.boundingBox), primaryEyePosition: candidates.first?.eyePosition,
            lookingDirection: CGVector(dx: candidates.first?.gaze ?? 0, dy: 0),
            usedSemanticModel: SemanticCropRanker.shared.didProduceEvidence)
        output.compositionRaster = raster
        output.semanticAffinities = semantics
        return output
    }

    private func rankedDistinct(_ raw: [NeuralSubjectCandidate], raster: CompositionRaster?) -> [NeuralSubjectCandidate] {
        let ranked = raw.map { c -> NeuralSubjectCandidate in
            var copy = c
            copy.prominenceScore = HeroSubjectPolicy.score(bounds: c.boundingBox, kind: kind(c.category),
                confidence: Double(c.confidence), evidence: raster?.evidence(in: c.boundingBox), hasFace: c.eyePosition != nil)
            return copy
        }.sorted { $0.prominenceScore > $1.prominenceScore }
        var result: [NeuralSubjectCandidate] = []
        for c in ranked where c.prominenceScore >= 0.12 {
            let duplicate = result.contains { other in
                HeroSubjectPolicy.duplicate(c.boundingBox, other.boundingBox,
                    eyeA: c.eyePosition, eyeB: other.eyePosition)
            }
            if !duplicate { result.append(c) }
            if result.count == 12 { break }
        }
        return result
    }

    private func coherentGroup(_ candidates: [NeuralSubjectCandidate], raster: CompositionRaster?) -> NeuralSubjectCandidate? {
        guard let hero = candidates.first, hero.category == .human || hero.category == .face else { return nil }
        let people = candidates.filter { ($0.category == .human || $0.category == .face) &&
            $0.prominenceScore >= hero.prominenceScore * 0.48 }
        var members = [hero]
        var added = true
        while added {
            added = false
            for person in people where !members.contains(where: { $0.id == person.id }) {
                if members.contains(where: { HeroSubjectPolicy.coherent($0.boundingBox, person.boundingBox) }) {
                    members.append(person); added = true
                }
            }
        }
        guard members.count >= 2 else { return nil }
        let union = members.dropFirst().reduce(hero.boundingBox) { $0.union($1.boundingBox) }
        guard union.width * union.height <= 0.9 else { return nil }
        let eyes = members.compactMap(\.eyePosition)
        var group = NeuralSubjectCandidate(boundingBox: union, category: .human,
            confidence: members.map(\.confidence).min() ?? hero.confidence, label: "Nhóm \(members.count) người",
            prominenceScore: HeroSubjectPolicy.score(bounds: union, kind: .group,
                confidence: Double(members.map(\.confidence).min() ?? hero.confidence),
                evidence: raster?.evidence(in: union), hasFace: !eyes.isEmpty))
        if !eyes.isEmpty {
            group.eyePosition = CGPoint(x: eyes.reduce(0) { $0 + $1.x } / CGFloat(eyes.count),
                                        y: eyes.reduce(0) { $0 + $1.y } / CGFloat(eyes.count))
        }
        group.isGroup = true
        // Group layout uses the group's eye line. Optical tracking must seed
        // a real member, never the empty space between two people's faces.
        group.trackingPoint = hero.eyePosition ?? hero.center
        group.companionBounds = members.flatMap { [$0.boundingBox] + $0.companionBounds }
        group.faceBounds = members.flatMap(\.faceBounds)
        return group
    }

    private func kind(_ category: NeuralSubjectCategory) -> CompositionSubjectKind {
        switch category {
        case .human: return .person
        case .face: return .face
        case .animal: return .animal
        case .foregroundObject: return .object
        case .general: return .scenery
        }
    }

    private func candidate(visionRect: CGRect, category: NeuralSubjectCategory,
                           confidence: Float, label: String) -> NeuralSubjectCandidate? {
        let raw = CGRect(x: visionRect.minX, y: 1 - visionRect.maxY, width: visionRect.width, height: visionRect.height)
        guard [raw.minX, raw.minY, raw.width, raw.height].allSatisfy(\.isFinite),
              confidence.isFinite, raw.width > 0, raw.height > 0 else { return nil }
        let rect = raw.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, !rect.isEmpty, rect.width >= 0.025, rect.height >= 0.025,
              rect.width * rect.height >= raw.width * raw.height * 0.8 else { return nil }
        return NeuralSubjectCandidate(boundingBox: rect, category: category, confidence: confidence, label: label,
            prominenceScore: HeroSubjectPolicy.score(bounds: rect, kind: kind(category), confidence: Double(confidence), evidence: nil))
    }

    private func sceneType(_ classifications: [VNClassificationObservation]) -> DetectedSceneType {
        let categories: [(DetectedSceneType, [String])] = [
            (.food, ["food", "dish", "meal", "drink"]), (.pet, ["cat", "dog", "pet", "animal"]),
            (.macro, ["flower", "macro"]), (.foliage, ["plant", "foliage"]),
            (.sunset, ["sunset", "sunrise"]), (.night, ["night"]),
            (.landscape, ["mountain", "beach", "forest", "valley", "lake", "sea", "coast", "waterfall", "field"]),
            (.sky, ["sky", "cloud"]), (.architecture, ["building", "architecture", "castle", "bridge", "tower", "temple", "church"]),
            (.street, ["street", "city"]), (.portrait, ["portrait", "person", "face"])]
        var scores: [DetectedSceneType: Double] = [:]
        for observation in classifications.prefix(12) where observation.confidence >= 0.08 {
            let label = observation.identifier.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            for (scene, words) in categories where words.contains(where: { label.contains($0) }) {
                scores[scene, default: 0] += Double(observation.confidence)
            }
        }
        return scores.max { $0.value < $1.value }.flatMap { $0.value >= 0.20 ? $0.key : nil } ?? .general
    }
}
