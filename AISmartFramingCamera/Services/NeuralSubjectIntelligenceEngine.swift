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

    func affinity(image: CGImage, intent: LocalCompositionIntent,
                  cancellation: CompositionAnalysisCancellation) -> Double? {
        guard let model, !prompts.isEmpty, !cancellation.isCancelled else { return nil }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let scores = affinities(model: model, handler: handler, cancellation: cancellation)
        let keys = intent == .closeUp ? ["flower", "foliage", "macro"] : [intent.promptKey]
        return keys.compactMap { scores[$0] }.max()
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
}

struct LocalCompositionAnalysis: Sendable {
    let detection: NeuralAnalysisOutput
    let choices: [LocalCompositionChoice]
    let fallbackCandidates: [NeuralSubjectCandidate]
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
                            preferences: [String: Double],
                            cancellation: CompositionAnalysisCancellation) -> LocalCompositionAnalysis? {
        guard !cancellation.isCancelled else { return nil }
        analysisLock.lock()
        defer { SemanticCropRanker.shared.endAnalysis(); analysisLock.unlock() }
        guard !cancellation.isCancelled,
              let output = analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: frame.orientation,
                                                 cancellation: cancellation) else { return nil }
        // Choose identity before optimizing layout. Different crops must never
        // compete by silently substituting an unrelated background object.
        guard let hero = output.allCandidates.first else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [])
        }
        guard let raster = output.compositionRaster else {
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [hero])
        }
        let subject = CompositionSubject(index: 0, bounds: hero.boundingBox,
            anchor: hero.eyePosition ?? hero.center, kind: hero.isGroup ? .group : kind(hero.category),
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze)
        let intents = compositionIntents(output, hero: hero)
        let proposals = CompositionPlanner.proposals(subjects: [subject], intents: intents,
            raster: raster, calibration: frame.calibration, currentZoom: CGFloat(frame.displayZoom),
            allowedZooms: allowedZooms, protectedBounds: hero.companionBounds,
            incidentalBounds: output.allFaceRects.filter { !hero.faceBounds.contains($0) },
            isCancelled: { cancellation.isCancelled })
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(frame.orientation)
        var rendered: [(CompositionProposal, CGImage)] = []
        for var proposal in proposals {
            if cancellation.isCancelled { return nil }
            guard let preview = renderer.preview(image: image, corners: proposal.sourceCorners,
                                                  aspect: frame.calibration.aspect) else { continue }
            if let aesthetic = renderer.aestheticScore(image: preview, cancellation: cancellation) {
                proposal.score += aesthetic * 0.075
            }
            if let affinity = SemanticCropRanker.shared.affinity(image: preview, intent: proposal.intent,
                                                               cancellation: cancellation) {
                let baseline = output.semanticAffinities[proposal.intent.promptKey] ?? affinity
                proposal.score += min(0.025, max(-0.025, (affinity - baseline) * 0.35))
            }
            proposal.score += min(0.025, max(-0.025, preferences[proposal.preferenceKey] ?? 0))
            rendered.append((proposal, preview))
        }
        guard !cancellation.isCancelled else { return nil }
        let choices = CompositionPlanner.diverse(rendered.map(\.0), limit: 3).compactMap { proposal -> LocalCompositionChoice? in
            guard let preview = rendered.first(where: {
                $0.0.zoom == proposal.zoom && $0.0.intent == proposal.intent && $0.0.sourceCorners == proposal.sourceCorners
            })?.1 else { return nil }
            let plan = LocalFramingPlan(subjectPoint: hero.trackingPoint ?? proposal.subjectPoint, subjectRect: hero.boundingBox,
                aimPointInSource: proposal.aimPoint, aimWorldRay: pose.act(proposal.rotation.act(SIMD3(0, 0, -1))),
                zoom: proposal.zoom, confidence: proposal.evidenceConfidence,
                minimumAutoselectConfidence: max(0.72, LocalAutoselectCalibration.threshold(
                    scene: output.detectedScene, category: hero.category) ?? 1),
                intent: proposal.intent, score: proposal.score, explanation: proposal.explanation,
                usesCenter: proposal.usesCenter, preferenceKey: proposal.preferenceKey)
            return LocalCompositionChoice(candidate: hero, plan: plan, preview: preview)
        }
        return LocalCompositionAnalysis(detection: output, choices: choices, fallbackCandidates: [hero])
    }

    private func compositionIntents(_ output: NeuralAnalysisOutput, hero: NeuralSubjectCandidate) -> [LocalCompositionIntent] {
        if hero.isGroup { return [.group] }
        if hero.category == .human || hero.category == .face {
            let context = [.landscape, .architecture, .street, .sunset].contains(output.detectedScene)
            return context ? [.environmentalPortrait, .portrait] : [.portrait, .environmentalPortrait]
        }
        if hero.category == .animal { return [.animal] }
        if hero.category == .general { return [.landscape] }
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
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        var completed = Set<ObjectIdentifier>()
        for request in [bodies, faces, animals, objectness, attention, classification] as [VNRequest] {
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
        let semantics = SemanticCropRanker.shared.sceneEvidence(pixelBuffer: pixelBuffer, orientation: orientation, cancellation: cancellation)
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
