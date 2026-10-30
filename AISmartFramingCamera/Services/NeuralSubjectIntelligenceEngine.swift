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
        guard ProcessInfo.processInfo.physicalMemory >= 2_500_000_000,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              let url = Bundle.main.url(forResource: "SigLIPBaseImage", withExtension: "mlmodelc"),
              let promptURL = Bundle.main.url(forResource: "SigLIPPrompts", withExtension: "json"),
              let data = try? Data(contentsOf: promptURL),
              let vectors = try? JSONDecoder().decode([String: [Double]].self, from: data),
              !vectors.isEmpty else { return }
        do {
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
        guard (try? cancellation.perform(request, with: handler)) != nil,
              let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
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
        guard let best = ordered.first, best.value >= 0.22,
              ordered.count < 2 || best.value - ordered[1].value >= 0.018 else { return nil }
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

    func extractSemanticGuidance(scores: [String: Double], candidates: [NeuralSubjectCandidate]) -> SemanticSceneGuidance {
        guard !scores.isEmpty else { return .neutral }
        var wideScore: Double = 0.0
        for key in ["landscape", "person_scenery", "building", "street", "sky", "water", "group"] {
            if let v = scores[key], v > wideScore { wideScore = v }
        }
        var tightScore: Double = 0.0
        for key in ["flower", "macro", "food"] {
            if let v = scores[key], v > tightScore { tightScore = v }
        }
        if let vp = scores["person"], vp * 0.92 > tightScore { tightScore = vp * 0.92 }
        if let va = scores["animal"], va * 0.92 > tightScore { tightScore = va * 0.92 }
        let shotScaleBias: Double = max(-1.0, min(1.0, (tightScore - wideScore) * 3.0))
        let contextWeight: Double = max(0.15, min(0.95, 0.50 + (wideScore - tightScore) * 1.8))
        return SemanticSceneGuidance(
            shotScaleBias: shotScaleBias,
            contextPreservationWeight: contextWeight,
            primarySceneHint: sceneHint(scores: scores, candidates: candidates),
            affinities: scores
        )
    }
}

public struct SemanticSceneGuidance: Sendable {
    public let shotScaleBias: Double
    public let contextPreservationWeight: Double
    public let primarySceneHint: DetectedSceneType?
    public let affinities: [String: Double]
    public static let neutral = SemanticSceneGuidance(
        shotScaleBias: 0.0,
        contextPreservationWeight: 0.50,
        primarySceneHint: nil,
        affinities: [:]
    )
}

/// Ứng viên chủ thể được AI phát hiện và xếp hạng
public struct NeuralSubjectCandidate: Identifiable, Sendable {
    public let id = UUID()
    public var boundingBox: CGRect // Toạ độ chuẩn hóa UI (Top-Left 0..1)
    public let category: NeuralSubjectCategory
    public let confidence: Float
    public let label: String
    public var prominenceScore: Double
    var eyePosition: CGPoint? = nil
    var gaze: CGFloat = 0
    var verticalGaze: CGFloat = 0
    var companionBounds: [CGRect] = []
    var faceBounds: [CGRect] = []
    var trackingPoint: CGPoint? = nil
    var isGroup = false

    // The preserved candidate format identifies Vision saliency regions by this
    // fixed internal label. YOLO class labels never use it. A region is a field
    // of attention, not a physical object whose complete outline must be kept.
    var isAttentionRegion: Bool {
        category == .foregroundObject && (label == "Vùng nổi bật" || label == "Chủ thể tiền cảnh" || label == "Vùng trọng tâm" || label == "Vùng chi tiết")
    }
    
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
    var semanticGuidance: SemanticSceneGuidance = .neutral
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
    var preservesOriginalFrame = false
    var title: String { preservesOriginalFrame ? "Giữ khung hiện tại" : plan.intent.title }
}

struct LocalCompositionAnalysis: Sendable {
    let detection: NeuralAnalysisOutput
    let choices: [LocalCompositionChoice]
    let fallbackCandidates: [NeuralSubjectCandidate]
    var assessedCompositionCount = 0
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
                            pose: simd_quatd, allowedZooms: [CGFloat],
                            preferences: [String: Double], requestID: UUID,
                            cancellation: CompositionAnalysisCancellation,
                            progress: @Sendable (String) -> Void = { _ in }) -> LocalCompositionAnalysis? {
        guard !cancellation.isCancelled else { return nil }
        analysisLock.lock()
        defer { SemanticCropRanker.shared.endAnalysis(); analysisLock.unlock() }
        let started = ProcessInfo.processInfo.systemUptime
        func receipt(count: Int = 0, specialist: Bool = false, modern: Int = 0) -> CompositionAnalysisReceipt {
            CompositionAnalysisReceipt(requestID: requestID, sourceTimestamp: frame.timestamp,
                elapsed: max(0, ProcessInfo.processInfo.systemUptime - started),
                assessedFrames: count, usedSpecialist: specialist, modernAssessments: modern)
        }
        guard !cancellation.isCancelled,
              let output = analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: frame.orientation,
                                                 cancellation: cancellation) else { return nil }
        // Choose identity before optimizing layout. Different crops must never
        // compete by silently substituting an unrelated background object.
        let hero: NeuralSubjectCandidate
        if let first = output.allCandidates.first {
            hero = first
        } else {
            hero = NeuralSubjectCandidate(
                boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.55),
                category: .general,
                confidence: 0.70,
                label: "Khung cảnh",
                prominenceScore: 0.20
            )
        }
        guard let raster = output.compositionRaster else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero], receipt: receipt())
        }
        let subject = CompositionSubject(index: 0, bounds: hero.boundingBox,
            anchor: hero.eyePosition ?? hero.center, kind: hero.isGroup ? .group : kind(hero.category),
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze,
            allowsAttentionCrop: hero.isAttentionRegion && raster.hasAttention &&
                hero.boundingBox.width * hero.boundingBox.height > 0.12,
            verticalGaze: hero.verticalGaze,
            shotScaleBias: output.semanticGuidance.shotScaleBias,
            contextPreservationWeight: output.semanticGuidance.contextPreservationWeight)
        let intents = compositionIntents(output, hero: hero)
        var portraitBounds: CGRect?
        var poseProfile: AnatomicalPoseProfile?
        if hero.category == .human, !hero.isGroup, !hero.faceBounds.isEmpty {
            let poseRequest = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: frame.orientation, options: [:])
            if (try? cancellation.perform(poseRequest, with: handler)) != nil {
                let observations = poseRequest.results ?? []
                portraitBounds = PortraitFramingEvidence.bounds(body: hero.boundingBox,
                    faces: hero.faceBounds, observations: observations)
                poseProfile = PortraitFramingEvidence.extractProfile(body: hero.boundingBox,
                    faces: hero.faceBounds, observations: observations)
            }
        }
        if portraitBounds == nil && (hero.category == .human || hero.category == .face) && !hero.isGroup {
            let box = hero.boundingBox
            let torsoHeight = min(box.height, max(0.22, box.height * 0.60))
            portraitBounds = CGRect(x: box.minX, y: box.minY, width: box.width, height: torsoHeight)
        }
        if poseProfile == nil && (hero.category == .human || hero.category == .face) {
            poseProfile = PortraitFramingEvidence.extractProfile(body: hero.boundingBox,
                faces: hero.faceBounds, observations: [])
        }
        // Release the semantic encoder before loading the composition specialist,
        // especially on iPhone XS. Detection and group membership remain unchanged.
        autoreleasepool {
            SemanticCropRanker.shared.endAnalysis()
        }
        let constrained = ProcessInfo.processInfo.thermalState == .critical
        func proposals(refining seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents,
                portraitBounds: portraitBounds, raster: raster, calibration: frame.calibration,
                currentZoom: CGFloat(frame.displayZoom), allowedZooms: allowedZooms,
                protectedBounds: hero.companionBounds,
                incidentalBounds: output.allFaceRects.filter { !hero.faceBounds.contains($0) } +
                    output.allCandidates.filter { $0.category == .animal && $0.id != hero.id }.map(\.boundingBox),
                proposalLimit: seeds.isEmpty ? (constrained ? 8 : 10) : (constrained ? 4 : 6), refining: seeds,
                poseProfile: poseProfile,
                isCancelled: { cancellation.isCancelled })
        }
        progress("Đang đánh giá bố cục bằng mô hình trên máy…")
        let search = CompositionAestheticSearch(renderer: renderer)
        let searchResult = search.run(proposals: proposals(),
            image: CIImage(cvPixelBuffer: pixelBuffer).oriented(frame.orientation),
            aspect: frame.calibration.aspect, preferences: preferences,
            modelURL: Bundle.main.url(forResource: "SAMPComposition", withExtension: "mlmodelc"),
            aestheticModelURL: constrained ? nil : Bundle.main.url(forResource: "CharmAesthetics", withExtension: "mlmodelc"),
            positionURL: constrained ? nil : Bundle.main.url(forResource: "CharmPositionEmbedding", withExtension: "bin"),
            requiresModernModel: false,
            cancellation: cancellation, progress: progress, refine: { proposals(refining: $0) })
        renderer.clearCaches()
        guard let result = searchResult else { return nil }
        let choices = result.views.map { view -> LocalCompositionChoice in
            let proposal = view.proposal
            let plan = LocalFramingPlan(subjectPoint: hero.trackingPoint ?? proposal.subjectPoint, subjectRect: hero.boundingBox,
                cropProtectionRect: CompositionCropProtection.bounds(body: hero.boundingBox,
                    portrait: portraitBounds, intent: proposal.intent, anchor: subject.anchor,
                    attentionRegion: subject.allowsAttentionCrop),
                aimPointInSource: proposal.aimPoint, aimWorldRay: pose.act(proposal.rotation.act(SIMD3(0, 0, -1))),
                zoom: proposal.zoom, confidence: proposal.evidenceConfidence,
                minimumAutoselectConfidence: max(0.72, LocalAutoselectCalibration.threshold(
                    scene: output.detectedScene, category: hero.category) ?? 1),
                intent: proposal.intent, score: proposal.score, explanation: proposal.explanation + (result.usedSpecialist ? " Đã tối ưu bố cục theo Tỷ lệ vàng và Luật một phần ba." : " Bố cục tự nhiên."),
                usesCenter: proposal.usesCenter, preferenceKey: proposal.preferenceKey,
                recommendedEVBias: proposal.recommendedEVBias)
            return LocalCompositionChoice(candidate: hero, plan: plan, preview: view.image,
                                          preservesOriginalFrame: proposal.isUnchangedView)
        }
        let effectiveCandidates = output.allCandidates.isEmpty ? [hero] : output.allCandidates
        return LocalCompositionAnalysis(detection: output, choices: choices, fallbackCandidates: effectiveCandidates,
            assessedCompositionCount: result.assessedCount, usedCompositionModel: result.usedSpecialist,
            canAutoselectComposition: result.canAutoselect,
            receipt: receipt(count: result.assessedCount, specialist: result.usedSpecialist, modern: result.modernAssessmentCount))
    }

    private func compositionIntents(_ output: NeuralAnalysisOutput, hero: NeuralSubjectCandidate) -> [LocalCompositionIntent] {
        if hero.isGroup { return [.group, .environmentalPortrait] }
        if hero.category == .human || hero.category == .face {
            return [.portrait, .environmentalPortrait]
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
                                      cancellation: CompositionAnalysisCancellation) -> NeuralAnalysisOutput? {
        SemanticCropRanker.shared.beginAnalysis()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let classification = VNClassifyImageRequest()
        let horizonReq = VNDetectHorizonRequest()
        let contoursReq = VNDetectContoursRequest()
        contoursReq.contrastAdjustment = 1.6
        contoursReq.detectsDarkOnLight = true
        contoursReq.maximumImageDimension = 192
        let personSegReq = VNGeneratePersonSegmentationRequest()
        personSegReq.qualityLevel = .fast
        personSegReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        var completed = Set<ObjectIdentifier>()
        for request in [bodies, faces, animals, objectness, attention, classification, horizonReq, contoursReq, personSegReq] as [VNRequest] {
            if cancellation.isCancelled { return nil }
            do { try cancellation.perform(request, with: handler); completed.insert(ObjectIdentifier(request)) }
            catch {
                if cancellation.isCancelled { return nil }
                CameraLogger.warning("Vision bỏ qua một bằng chứng: \(error)", category: .ai)
            }
        }
        let fgMaskBuffer = completed.contains(ObjectIdentifier(personSegReq)) ? personSegReq.results?.first?.pixelBuffer : nil
        var measuredHorizon: (y: CGFloat, confidence: Double)? = nil
        if completed.contains(ObjectIdentifier(horizonReq)), let hObs = horizonReq.results?.first, hObs.confidence >= 0.25 {
            let angleOffset = CGFloat(tan(Double(hObs.angle)) * 0.15)
            let hy = min(0.85, max(0.15, 0.5 + angleOffset))
            measuredHorizon = (y: hy, confidence: Double(hObs.confidence))
        }
        var measuredVP: (point: CGPoint, confidence: Double, rayAngles: [Double])? = nil
        if completed.contains(ObjectIdentifier(contoursReq)), let cObs = contoursReq.results?.first {
            measuredVP = renderer.extractRANSACVanishingPoint(from: cObs, foregroundMask: fgMaskBuffer)
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let raster = renderer.raster(image: image,
            saliency: completed.contains(ObjectIdentifier(attention)) ? attention.results?.first?.pixelBuffer : nil,
            objectness: completed.contains(ObjectIdentifier(objectness)) ? objectness.results?.first?.pixelBuffer : nil,
            foregroundMask: fgMaskBuffer,
            measuredHorizon: measuredHorizon,
            measuredVanishingPoint: measuredVP)
        var candidates = YOLODetectionEngine.shared.detectPhotographicObjects(
            pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
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
                var gazeX: CGFloat = 0
                var gazeY: CGFloat = 0
                if let yaw = face.yaw?.doubleValue, yaw.isFinite { gazeX = CGFloat(sin(yaw)) }
                if let pitch = face.pitch?.doubleValue, pitch.isFinite { gazeY = CGFloat(sin(pitch)) }
                if let lEye = face.landmarks?.leftEye?.normalizedPoints, !lEye.isEmpty,
                   let rEye = face.landmarks?.rightEye?.normalizedPoints, !rEye.isEmpty,
                   let lPupil = face.landmarks?.leftPupil?.normalizedPoints.first,
                   let rPupil = face.landmarks?.rightPupil?.normalizedPoints.first {
                    let lCx = lEye.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(lEye.count)
                    let lCy = lEye.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(lEye.count)
                    let rCx = rEye.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(rEye.count)
                    let rCy = rEye.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(rEye.count)
                    let pupilDx = ((lPupil.x - lCx) + (rPupil.x - rCx)) * 0.5
                    let pupilDy = ((lPupil.y - lCy) + (rPupil.y - rCy)) * 0.5
                    gazeX = max(-1.0, min(1.0, gazeX * 0.72 + pupilDx * 2.2))
                    gazeY = max(-1.0, min(1.0, gazeY * 0.70 - pupilDy * 2.0))
                }
                c.gaze = gazeX
                c.verticalGaze = gazeY
                faceCandidates.append(c)
            }
        }
        if completed.contains(ObjectIdentifier(bodies)) {
            for body in bodies.results ?? [] where body.confidence >= 0.40 {
                let upright = CompositionPureCalculations.visionToUprightRect(body.boundingBox)
                let hasMatchingFace = faceCandidates.contains { face in
                    upright.contains(CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)) ||
                    (abs(face.boundingBox.midX - upright.midX) < upright.width * 0.45 && face.boundingBox.minY <= upright.minY + upright.height * 0.45)
                }
                let hasYoloPerson = candidates.contains {
                    $0.category == .human && $0.boundingBox.intersects(upright)
                }
                guard hasMatchingFace || hasYoloPerson || body.confidence >= 0.62 else { continue }
                if let c = candidate(visionRect: body.boundingBox, category: .human, confidence: body.confidence, label: "Người") {
                    candidates.append(c)
                }
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
        let hasExplicitDetectorCandidate = !candidates.isEmpty || !faceCandidates.isEmpty
        let hasProminentSemanticSubject = candidates.contains {
            ($0.category == .human || $0.category == .animal) &&
            $0.confidence >= 0.52 &&
            $0.areaRatio >= 0.075 &&
            $0.boundingBox.maxY >= 0.56
        } || faceCandidates.contains { $0.areaRatio >= 0.015 }

        if !hasProminentSemanticSubject {
            var tightSaliencyCandidates: [NeuralSubjectCandidate] = []
            var broadSaliencyCandidates: [NeuralSubjectCandidate] = []
            for (index, observation) in [objectness.results?.first, attention.results?.first].compactMap({ $0 }).enumerated() {
                for region in observation.salientObjects ?? [] where region.confidence >= 0.30 {
                    let area = region.boundingBox.width * region.boundingBox.height
                    guard area >= 0.012 && area <= 0.78 else { continue }
                    let isObjectness = (index == 0)
                    let label = (isObjectness && area <= 0.42) ? "Chủ thể tiền cảnh" : "Vùng nổi bật"
                    let baseAdjusted = (isObjectness && area <= 0.42) ? min(0.92, region.confidence * 1.05) : region.confidence * 0.82
                    let adjustedConfidence = hasExplicitDetectorCandidate ? min(0.68, baseAdjusted * 0.85) : baseAdjusted
                    if let c = candidate(visionRect: region.boundingBox, category: .foregroundObject,
                                         confidence: adjustedConfidence, label: label) {
                        if area <= 0.42 {
                            tightSaliencyCandidates.append(c)
                        } else {
                            broadSaliencyCandidates.append(c)
                        }
                    }
                }
            }
            if !tightSaliencyCandidates.isEmpty {
                candidates.append(contentsOf: tightSaliencyCandidates)
            } else {
                candidates.append(contentsOf: broadSaliencyCandidates)
            }
        }
        if candidates.isEmpty, let r = raster, r.hasAttention {
            if let com = r.visualCenterOfMass {
                let comVal = r.value(r.attention, at: com)
                if comVal >= 0.18 {
                    let bw: CGFloat = 0.36
                    let bh: CGFloat = 0.36
                    let bx = min(max(0.04, com.x - bw / 2), 1 - bw - 0.04)
                    let by = min(max(0.04, com.y - bh / 2), 1 - bh - 0.04)
                    let box = CGRect(x: bx, y: by, width: bw, height: bh)
                    let c = NeuralSubjectCandidate(
                        boundingBox: box,
                        category: .foregroundObject,
                        confidence: Float(max(0.40, comVal)),
                        label: "Vùng trọng tâm",
                        prominenceScore: 0.22
                    )
                    candidates.append(c)
                }
            }
            if let anchor = r.sceneryAnchor {
                let anchorVal = r.value(r.attention, at: anchor)
                let bw: CGFloat = 0.32
                let bh: CGFloat = 0.32
                let bx = min(max(0.04, anchor.x - bw / 2), 1 - bw - 0.04)
                let by = min(max(0.04, anchor.y - bh / 2), 1 - bh - 0.04)
                let box = CGRect(x: bx, y: by, width: bw, height: bh)
                let isFarFromFirst = candidates.first.map { hypot($0.center.x - anchor.x, $0.center.y - anchor.y) > 0.25 } ?? true
                if isFarFromFirst {
                    let c = NeuralSubjectCandidate(
                        boundingBox: box,
                        category: .foregroundObject,
                        confidence: Float(max(0.38, anchorVal)),
                        label: "Vùng chi tiết",
                        prominenceScore: 0.18
                    )
                    candidates.append(c)
                }
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
                candidates[i].boundingBox = box.union(face.boundingBox)
                candidates[i].eyePosition = face.eyePosition ?? face.center
                candidates[i].gaze = face.gaze
                candidates[i].verticalGaze = face.verticalGaze
                candidates[i].companionBounds = [face.boundingBox]
                candidates[i].faceBounds = [face.boundingBox]
            }
        }
        candidates.append(contentsOf: faceCandidates.filter { face in
            !candidates.contains { $0.category == .human && $0.boundingBox.insetBy(dx: -0.025, dy: -0.025).contains(face.center) }
        })
        candidates = rankedDistinct(candidates, raster: raster)
        if let group = coherentGroup(candidates, raster: raster) { candidates.insert(group, at: 0) }
        var scene = sceneType(completed.contains(ObjectIdentifier(classification)) ? classification.results ?? [] : [])
        let (semantics, guidance, didUseSigLIP): ([String: Double], SemanticSceneGuidance, Bool) = autoreleasepool {
            let scores = SemanticCropRanker.shared.sceneEvidence(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
            let semGuidance = SemanticCropRanker.shared.extractSemanticGuidance(scores: scores, candidates: candidates)
            let produced = SemanticCropRanker.shared.didProduceEvidence
            // Giải phóng ngay model SigLIP nặng khỏi RAM trước khi nạp SAMPComposition & CharmAesthetics (an toàn tuyệt đối cho máy 4GB RAM)
            SemanticCropRanker.shared.endAnalysis()
            return (scores, semGuidance, produced)
        }
        if let hint = guidance.primarySceneHint, scene == .general { scene = hint }
        if scene == .general, let hero = candidates.first {
            if hero.category == .human || hero.category == .face {
                scene = (guidance.contextPreservationWeight >= 0.62) ? .landscape : .portrait
            } else if hero.category == .animal {
                scene = .pet
            }
        }
        guard !cancellation.isCancelled else { return nil }
        var output = NeuralAnalysisOutput(allCandidates: candidates, detectedScene: scene,
            allFaceRects: faceCandidates.map(\.boundingBox), primaryEyePosition: candidates.first?.eyePosition,
            lookingDirection: CGVector(dx: candidates.first?.gaze ?? 0, dy: 0),
            usedSemanticModel: didUseSigLIP)
        output.compositionRaster = raster
        output.semanticAffinities = semantics
        output.semanticGuidance = guidance
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
        let maxScore = ranked.first?.prominenceScore ?? 0.0
        let threshold = maxScore >= 0.12 ? 0.10 : max(0.04, maxScore * 0.5)
        for c in ranked where c.prominenceScore >= threshold {
            let duplicate = result.contains { other in
                HeroSubjectPolicy.duplicate(c.boundingBox, other.boundingBox,
                    eyeA: c.eyePosition, eyeB: other.eyePosition)
            }
            if !duplicate {
                var candidate = c
                if candidate.prominenceScore < 0.12 {
                    candidate.prominenceScore = 0.12
                }
                result.append(candidate)
            }
            if result.count == 12 { break }
        }
        if result.isEmpty, let top = ranked.first {
            var fallback = top
            fallback.prominenceScore = max(0.12, fallback.prominenceScore)
            result.append(fallback)
        }
        return result
    }

    private func coherentGroup(_ candidates: [NeuralSubjectCandidate], raster: CompositionRaster?) -> NeuralSubjectCandidate? {
        guard let hero = candidates.first,
              hero.category == .human || hero.category == .face,
              (hero.areaRatio >= 0.045 || !hero.faceBounds.isEmpty) else { return nil }
        let people = candidates.filter { ($0.category == .human || $0.category == .face) &&
            ($0.areaRatio >= 0.032 || !$0.faceBounds.isEmpty) &&
            $0.prominenceScore >= hero.prominenceScore * 0.52 }
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
        guard union.width * union.height <= 0.95 else { return nil }
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
        guard !rect.isNull, !rect.isEmpty, rect.width >= 0.015, rect.height >= 0.015,
              rect.width * rect.height >= raw.width * raw.height * 0.65 else { return nil }
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
