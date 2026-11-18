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
    struct SpatialSemanticProfile: Sendable {
        let role: SemanticCompositionRole
        let avoid: EdgeAvoidanceHints
        let topIsSky: Bool
        let roleScores: [SemanticCompositionRole: Double]
        let fullScores: [String: Double]
    }

    static let shared = SemanticCropRanker()
    private var attemptedLoad = false
    private var activeSessionDepth = 0
    private var model: VNCoreMLModel?
    private var prompts: [String: [Double]] = [:]
    private(set) var didProduceEvidence = false

    func beginAnalysis() {
        if activeSessionDepth == 0 {
            didProduceEvidence = false
        }
        activeSessionDepth += 1
    }
    func endAnalysis() {
        activeSessionDepth = max(0, activeSessionDepth - 1)
        guard activeSessionDepth == 0 else { return }
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
                            cancellation: CompositionAnalysisCancellation,
                            topLeftRoI: CGRect? = nil,
                            cropScale: VNImageCropAndScaleOption = .scaleFit) -> [String: Double] {
        let request = VNCoreMLRequest(model: model)
        // Preserve relative spacing when comparing complete portrait frames, or scale-fill sub-crops.
        request.imageCropAndScaleOption = cropScale
        if let roi = topLeftRoI {
            let rx = max(0.0, min(0.98, roi.minX))
            let ryTop = max(0.0, min(0.98, roi.minY))
            let rw = max(0.02, min(1.0 - rx, roi.width))
            let rh = max(0.02, min(1.0 - ryTop, roi.height))
            // Vision normalized regionOfInterest uses bottom-left origin.
            let vy = max(0.0, min(1.0 - rh, 1.0 - (ryTop + rh)))
            request.regionOfInterest = CGRect(x: rx, y: vy, width: rw, height: rh)
        }
        guard (try? cancellation.perform(request, with: handler)) != nil,
              let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue else { return [:] }
        let count = array.count
        guard count > 0 else { return [:] }
        var image = [Double](repeating: 0.0, count: count)
        var sumSq: Double = 0.0
        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                let v = Double(ptr[i])
                image[i] = v
                sumSq += v * v
            }
        } else if array.dataType == .float16 {
            let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count {
                let v = Double(ptr[i])
                image[i] = v
                sumSq += v * v
            }
        } else {
            for i in 0..<count {
                let v = Double(truncating: array[i])
                image[i] = v
                sumSq += v * v
            }
        }
        let norm = sqrt(sumSq)
        guard norm.isFinite, norm > 0.001 else { return [:] }
        var scores: [String: Double] = [:]
        for (key, text) in prompts where text.count == image.count {
            let score = zip(image, text).reduce(0) { $0 + $1.0 * $1.1 } / norm
            if score.isFinite { scores[key] = score }
        }
        didProduceEvidence = didProduceEvidence || !scores.isEmpty
        return scores
    }

    private static func sc(_ row: [String: Double], _ key: String, fallback: String? = nil) -> Double {
        if let v = row[key] { return v }
        if let fb = fallback, let v = row[fb] { return v }
        return 0.0
    }

    private static let deskTabletopLabelTokens: Set<String> = [
        "cup", "cốc nước", "mug", "wine glass", "ly rượu", "mouse", "chuột máy tính",
        "keyboard", "bàn phím", "tv", "tivi", "laptop", "bottle", "chai nước",
        "scissors", "kéo", "book", "cuốn sách", "bowl", "bát đĩa", "vase", "bình hoa",
        "cell phone", "điện thoại", "clock", "đồng hồ", "remote", "điều khiển"
    ]

    private static let deskDisplayLabelTokens: Set<String> = [
        "tv", "tivi", "keyboard", "bàn phím", "laptop"
    ]

    func spatialProfile(pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation,
                        fullScores existingFull: [String: Double],
                        candidates: [NeuralSubjectCandidate],
                        detectedScene: DetectedSceneType,
                        cancellation: CompositionAnalysisCancellation) -> SpatialSemanticProfile {
        loadIfAvailable()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let fullS: [String: Double]
        if !existingFull.isEmpty {
            fullS = existingFull
        } else if let model, !prompts.isEmpty, !cancellation.isCancelled {
            fullS = affinities(model: model, handler: handler, cancellation: cancellation)
        } else {
            fullS = [:]
        }

        let hasRichPrompts = prompts["architecture_facade"] != nil && model != nil && !fullS.isEmpty && !cancellation.isCancelled
        let isThermalConstrained = ProcessInfo.processInfo.thermalState == .serious ||
            ProcessInfo.processInfo.thermalState == .critical ||
            ProcessInfo.processInfo.isLowPowerModeEnabled
        let fullClutterSignal =
            0.48 * max(0.0, Self.sc(fullS, "edge_obstacle")) +
            0.40 * max(0.0, Self.sc(fullS, "dead_wall")) +
            0.40 * max(0.0, Self.sc(fullS, "dead_floor")) +
            0.42 * max(0.0, Self.sc(fullS, "wire_clutter")) +
            0.28 * max(0.0, Self.sc(fullS, "tin_roof_clutter"))
        let leftS: [String: Double]
        let rightS: [String: Double]
        let topS: [String: Double]
        let botS: [String: Double]
        let coreS: [String: Double]
        if hasRichPrompts, let model, !isThermalConstrained {
            coreS = affinities(model: model, handler: handler, cancellation: cancellation,
                               topLeftRoI: CGRect(x: 0.16, y: 0.16, width: 0.68, height: 0.68), cropScale: .scaleFill)
            if fullClutterSignal >= 0.008 {
                leftS = affinities(model: model, handler: handler, cancellation: cancellation,
                                   topLeftRoI: CGRect(x: 0.0, y: 0.06, width: 0.52, height: 0.88), cropScale: .scaleFill)
                rightS = affinities(model: model, handler: handler, cancellation: cancellation,
                                    topLeftRoI: CGRect(x: 0.48, y: 0.06, width: 0.52, height: 0.88), cropScale: .scaleFill)
                topS = affinities(model: model, handler: handler, cancellation: cancellation,
                                  topLeftRoI: CGRect(x: 0.06, y: 0.0, width: 0.88, height: 0.42), cropScale: .scaleFill)
                botS = affinities(model: model, handler: handler, cancellation: cancellation,
                                  topLeftRoI: CGRect(x: 0.06, y: 0.58, width: 0.88, height: 0.42), cropScale: .scaleFill)
            } else {
                leftS = [:]; rightS = [:]; topS = [:]; botS = [:]
            }
        } else {
            leftS = [:]; rightS = [:]; topS = [:]; botS = [:]; coreS = fullS
        }

        let allKeys = Set(fullS.keys).union(coreS.keys)
        var comb: [String: Double] = [:]
        for k in allKeys {
            let fv = fullS[k] ?? 0.0
            let cv = coreS[k] ?? fv
            comb[k] = 0.62 * fv + 0.38 * cv
        }

        var roleScores: [SemanticCompositionRole: Double] = [
            .portrait: max(Self.sc(comb, "person"), Self.sc(comb, "person_scenery") * 0.95),
            .group: Self.sc(comb, "group"),
            .animal: Self.sc(comb, "animal"),
            .food: Self.sc(comb, "food"),
            .flower: Self.sc(comb, "flower"),
            .streetLeading: max(Self.sc(comb, "street_perspective", fallback: "street"), Self.sc(comb, "street")) +
                (Self.sc(fullS, "street_perspective") > 0.03 ? 0.015 : 0.0),
            .architecture: max(Self.sc(comb, "architecture_facade", fallback: "building"), Self.sc(comb, "building")),
            .landscapeSky: 0.55 * Self.sc(comb, "horizon_sky", fallback: "landscape") +
                0.45 * max(Self.sc(comb, "sky"), max(Self.sc(comb, "landscape"), Self.sc(comb, "sunset"))),
            .foliageGarden: max(Self.sc(comb, "foliage_garden", fallback: "foliage"), Self.sc(comb, "foliage")),
            .deskWorkspace: Self.sc(comb, "desk_workspace"),
            .tabletopEnsemble: Self.sc(comb, "tabletop_ensemble"),
            .indoorRoom: Self.sc(comb, "indoor_furnished"),
            .apertureView: Self.sc(comb, "frame_aperture")
        ]

        let hasHuman = candidates.contains {
            ($0.category == .human || $0.category == .face) && $0.confidence >= 0.48 && $0.areaRatio >= 0.04
        }
        let hasAnimal = candidates.contains { $0.category == .animal && $0.confidence >= 0.45 }
        let deskObjs = candidates.filter {
            !$0.isAttentionRegion && $0.confidence >= 0.25 &&
            Self.deskTabletopLabelTokens.contains($0.label.lowercased())
        }
        if hasHuman { roleScores[.portrait, default: 0.0] += 0.05 }
        if hasAnimal { roleScores[.animal, default: 0.0] += 0.05 }
        if deskObjs.count >= 2 {
            roleScores[.tabletopEnsemble, default: 0.0] += 0.025
            if deskObjs.contains(where: { $0.confidence >= 0.28 && Self.deskDisplayLabelTokens.contains($0.label.lowercased()) }) {
                roleScores[.deskWorkspace, default: 0.0] += 0.030
            }
        }

        var bestRole: SemanticCompositionRole = roleScores.max(by: { $0.value < $1.value })?.key ?? .general
        if comb.isEmpty || (roleScores[bestRole] ?? 0.0) <= 0.005 {
            if hasHuman { bestRole = candidates.contains(where: \.isGroup) ? .group : .portrait }
            else if hasAnimal { bestRole = .animal }
            else if deskObjs.count >= 2 { bestRole = .tabletopEnsemble }
            else {
                switch detectedScene {
                case .portrait: bestRole = .portrait
                case .pet: bestRole = .animal
                case .food: bestRole = .food
                case .macro: bestRole = .flower
                case .foliage: bestRole = .foliageGarden
                case .architecture: bestRole = .architecture
                case .street, .night: bestRole = .streetLeading
                case .landscape, .sky, .water, .sunset: bestRole = .landscapeSky
                case .general: bestRole = .general
                }
            }
        }

        guard hasRichPrompts && !leftS.isEmpty && !rightS.isEmpty && !topS.isEmpty && !botS.isEmpty else {
            return SpatialSemanticProfile(role: bestRole, avoid: .zero, topIsSky: false,
                                          roleScores: roleScores, fullScores: fullS)
        }

        func clutterVal(_ row: [String: Double]) -> Double {
            0.48 * max(0.0, Self.sc(row, "edge_obstacle")) +
            0.40 * max(0.0, Self.sc(row, "dead_wall")) +
            0.40 * max(0.0, Self.sc(row, "dead_floor")) +
            0.42 * max(0.0, Self.sc(row, "wire_clutter")) +
            0.28 * max(0.0, Self.sc(row, "tin_roof_clutter"))
        }

        func subjectVal(_ row: [String: Double]) -> Double {
            max(
                Self.sc(row, "architecture_facade"),
                Self.sc(row, "street_perspective"),
                Self.sc(row, "desk_workspace"),
                Self.sc(row, "tabletop_ensemble"),
                Self.sc(row, "indoor_furnished"),
                Self.sc(row, "person"),
                Self.sc(row, "animal"),
                Self.sc(row, "food"),
                Self.sc(row, "flower"),
                0.78 * Self.sc(row, "foliage_garden")
            )
        }

        let cL = clutterVal(leftS), cR = clutterVal(rightS), cCore = clutterVal(coreS)
        let vL = subjectVal(leftS), vR = subjectVal(rightS), vB = subjectVal(botS), vCore = subjectVal(coreS)

        var avoidLeft = min(1.0, max(0.0,
            (cL - min(cR, cCore)) * 7.5 +
            max(0.0, Self.sc(leftS, "edge_obstacle") - Self.sc(rightS, "edge_obstacle") - 0.012) * 9.5 +
            max(0.0, (vR - vL) * 4.0) * (cL > 0.010 ? 1.0 : 0.0)
        ))
        var avoidRight = min(1.0, max(0.0,
            (cR - min(cL, cCore)) * 7.5 +
            max(0.0, Self.sc(rightS, "edge_obstacle") - Self.sc(leftS, "edge_obstacle") - 0.012) * 9.5 +
            max(0.0, Self.sc(rightS, "dead_wall") - max(0.0, Self.sc(leftS, "dead_wall")) - 0.022) * 8.5
        ))
        if avoidLeft >= 0.45 && cL > cR + 0.012 {
            avoidRight = 0.0
        } else if avoidRight >= 0.45 && cR > cL + 0.012 {
            avoidLeft = 0.0
        }

        let topSkyMax = max(Self.sc(topS, "sky"), max(Self.sc(topS, "horizon_sky"), Self.sc(topS, "sunset")))
        let topClutMax = max(Self.sc(topS, "dead_wall"), max(Self.sc(topS, "wire_clutter"), Self.sc(topS, "edge_obstacle")))
        let topIsSky = topSkyMax > topClutMax + 0.010
        let avoidTop: Double
        if topIsSky && (bestRole == .architecture || bestRole == .landscapeSky || bestRole == .foliageGarden) {
            avoidTop = 0.0
        } else {
            let wireV = max(0.0, Self.sc(topS, "wire_clutter") - (bestRole == .streetLeading ? 0.018 : 0.0))
            let obsV = max(0.0, Self.sc(topS, "edge_obstacle") - (bestRole == .streetLeading ? 0.010 : 0.0))
            let wallV = max(0.0, Self.sc(topS, "dead_wall") - 0.018)
            avoidTop = min(1.0, max(0.0, (wireV * 1.3 + obsV * 1.1 + wallV) * 10.0))
        }

        let floorV = bestRole == .streetLeading ? 0.0 : max(0.0, Self.sc(botS, "dead_floor")) * 1.2
        var botBad = max(0.0, Self.sc(botS, "tin_roof_clutter")) * 1.1 +
            floorV +
            max(0.0, Self.sc(botS, "wire_clutter")) +
            max(0.0, Self.sc(botS, "edge_obstacle") - 0.01) * 0.9
        if vB > vCore + 0.025 {
            botBad *= 0.35
        }
        let avoidBottom = min(1.0, max(0.0, botBad * 9.0))

        return SpatialSemanticProfile(
            role: bestRole,
            avoid: EdgeAvoidanceHints(left: avoidLeft, right: avoidRight, top: avoidTop, bottom: avoidBottom),
            topIsSky: topIsSky,
            roleScores: roleScores,
            fullScores: fullS
        )
    }

    private func cropBonus(cropScores: [String: Double], origScores: [String: Double], role: SemanticCompositionRole) -> Double {
        func posSig(_ row: [String: Double]) -> Double {
            switch role {
            case .architecture: return 0.65 * Self.sc(row, "architecture_facade", fallback: "building") + 0.35 * Self.sc(row, "building")
            case .streetLeading: return 0.70 * Self.sc(row, "street_perspective", fallback: "street") + 0.30 * Self.sc(row, "street")
            case .deskWorkspace: return 0.60 * Self.sc(row, "desk_workspace") + 0.40 * Self.sc(row, "tabletop_ensemble")
            case .tabletopEnsemble: return 0.70 * Self.sc(row, "tabletop_ensemble") + 0.30 * Self.sc(row, "desk_workspace")
            case .indoorRoom: return Self.sc(row, "indoor_furnished")
            case .landscapeSky: return 0.60 * Self.sc(row, "horizon_sky", fallback: "landscape") + 0.40 * max(Self.sc(row, "sky"), Self.sc(row, "landscape"))
            case .apertureView: return Self.sc(row, "frame_aperture")
            case .foliageGarden: return Self.sc(row, "foliage_garden", fallback: "foliage")
            case .portrait: return max(Self.sc(row, "person"), Self.sc(row, "person_scenery"))
            default: return Self.sc(row, "clean_composition")
            }
        }
        func clutSig(_ row: [String: Double]) -> Double {
            0.40 * max(0.0, Self.sc(row, "edge_obstacle")) +
            0.35 * max(0.0, Self.sc(row, "wire_clutter")) +
            0.30 * max(0.0, Self.sc(row, "dead_wall")) +
            0.30 * max(0.0, Self.sc(row, "dead_floor")) +
            0.25 * max(0.0, Self.sc(row, "tin_roof_clutter"))
        }
        let posD = posSig(cropScores) - posSig(origScores)
        let clutD = clutSig(origScores) - clutSig(cropScores)
        let cleanD = Self.sc(cropScores, "clean_composition") - Self.sc(origScores, "clean_composition")
        let posTerm = 0.90 * max(0.0, posD) + 2.20 * min(0.0, posD + 0.025)
        return max(-0.18, min(0.28, posTerm + 2.10 * clutD + 1.15 * cleanD))
    }

    func scoreProposalsSemantically(_ proposals: [CompositionProposal],
                                    role: SemanticCompositionRole,
                                    fullScores: [String: Double],
                                    pixelBuffer: CVPixelBuffer,
                                    orientation: CGImagePropertyOrientation,
                                    cancellation: CompositionAnalysisCancellation) -> [CompositionProposal] {
        guard let model, !prompts.isEmpty, prompts["clean_composition"] != nil,
              fullScores["clean_composition"] != nil, !cancellation.isCancelled, !proposals.isEmpty else {
            return proposals
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        func cropRect(from corners: [CGPoint]) -> CGRect {
            let minX = max(0.0, min(1.0, corners.map(\.x).min() ?? 0.0))
            let maxX = max(0.0, min(1.0, corners.map(\.x).max() ?? 1.0))
            let minY = max(0.0, min(1.0, corners.map(\.y).min() ?? 0.0))
            let maxY = max(0.0, min(1.0, corners.map(\.y).max() ?? 1.0))
            return CGRect(x: minX, y: minY, width: max(0.02, maxX - minX), height: max(0.02, maxY - minY))
        }
        func rectIoU(_ a: CGRect, _ b: CGRect) -> Double {
            let inter = a.intersection(b)
            guard !inter.isNull, !inter.isEmpty else { return 0.0 }
            let ia = Double(inter.width * inter.height)
            let ua = Double(a.width * a.height + b.width * b.height) - ia
            return ua > 1e-6 ? ia / ua : 0.0
        }

        let indexed = proposals.enumerated()
            .filter { !$0.element.isUnchangedView }
            .sorted { $0.element.score > $1.element.score }

        let maxSemanticCrops: Int = {
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled {
                return 2
            }
            return thermal == .fair ? 3 : 5
        }()
        var chosen: [(idx: Int, rect: CGRect, bonus: Double)] = []
        for item in indexed {
            guard chosen.count < maxSemanticCrops, !cancellation.isCancelled else { break }
            let rect = cropRect(from: item.element.sourceCorners)
            if chosen.contains(where: { rectIoU($0.rect, rect) > 0.84 }) { continue }
            let cropScores = affinities(model: model, handler: handler, cancellation: cancellation,
                                        topLeftRoI: rect, cropScale: .scaleFill)
            guard !cropScores.isEmpty else { continue }
            let bonus = cropBonus(cropScores: cropScores, origScores: fullScores, role: role)
            chosen.append((item.offset, rect, bonus))
        }
        guard !chosen.isEmpty else { return proposals }
        var updated = proposals
        for i in updated.indices where !updated[i].isUnchangedView {
            let r = cropRect(from: updated[i].sourceCorners)
            if let exact = chosen.first(where: { $0.idx == i }) {
                updated[i].semanticCropBonus = exact.bonus
            } else if let near = chosen.max(by: { rectIoU($0.rect, r) < rectIoU($1.rect, r) }),
                      rectIoU(near.rect, r) >= 0.72 {
                updated[i].semanticCropBonus = near.bonus
            }
        }
        return updated
    }

    func sceneHint(scores: [String: Double], candidates: [NeuralSubjectCandidate]) -> DetectedSceneType? {
        let ordered = scores.sorted { $0.value > $1.value }
        // SigLIP L2-normalized cosine dot-product scores fall in [-0.01 ... 0.12]
        guard let best = ordered.first, best.value >= 0.025,
              ordered.count < 2 || best.value - ordered[1].value >= 0.006 else { return nil }
        switch best.key {
        case "building", "architecture_facade": return .architecture
        case "landscape", "person_scenery", "horizon_sky": return .landscape
        case "group", "person": return candidates.contains { $0.category == .human || $0.category == .face } ? .portrait : nil
        case "flower", "macro": return .macro
        case "foliage", "foliage_garden": return .foliage
        case "sky": return .sky
        case "water": return .water
        case "sunset": return .sunset
        case "street", "street_perspective": return .street
        case "food": return .food
        case "animal": return .pet
        default: return nil
        }
    }

    func extractSemanticGuidance(scores: [String: Double], candidates: [NeuralSubjectCandidate]) -> SemanticSceneGuidance {
        guard !scores.isEmpty else { return .neutral }
        var wideScore: Double = 0.0
        for key in ["landscape", "person_scenery", "building", "architecture_facade", "street", "street_perspective", "sky", "horizon_sky", "water", "group"] {
            if let v = scores[key], v > wideScore { wideScore = v }
        }
        var tightScore: Double = 0.0
        for key in ["flower", "macro", "food"] {
            if let v = scores[key], v > tightScore { tightScore = v }
        }
        if let vp = scores["person"], vp * 0.92 > tightScore { tightScore = vp * 0.92 }
        if let va = scores["animal"], va * 0.92 > tightScore { tightScore = va * 0.92 }
        let shotScaleBias: Double = max(-1.0, min(1.0, (tightScore - wideScore) * 12.0))
        let contextWeight: Double = max(0.15, min(0.95, 0.50 + (wideScore - tightScore) * 6.0))
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
    var attentionDominance: Double = 0.0

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
    var subjectAttentionDominance: Double = 0.0
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
        SemanticCropRanker.shared.beginAnalysis()
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
        // Choose identity intelligently using spatial SigLIP semantics, pixel clutter/roof/VP maps, and filtered detectors.
        guard let raster = output.compositionRaster else {
            let basicHero = output.allCandidates.first ?? NeuralSubjectCandidate(
                boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.55),
                category: .general, confidence: 0.70, label: "Khung cảnh", prominenceScore: 0.20
            )
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [basicHero], receipt: receipt())
        }
        let spatialProfile = SemanticCropRanker.shared.spatialProfile(
            pixelBuffer: pixelBuffer,
            orientation: frame.orientation,
            fullScores: output.semanticAffinities,
            candidates: output.allCandidates,
            detectedScene: output.detectedScene,
            cancellation: cancellation
        )
        let meanLuma = raster.luminance.reduce(0.0, +) / Double(max(1, raster.luminance.count))
        let builtPlan = buildIntelligentSubjectPlan(
            output: output,
            raster: raster,
            spatialProfile: spatialProfile,
            isLowLuma: meanLuma < 0.35
        )
        let hero = builtPlan.hero
        let sceneHints = builtPlan.sceneHints
        let extraProtectedBounds = builtPlan.protectedBounds
        let extraIncidentalBounds = builtPlan.incidentalBounds
        let allowsHeroAttentionCrop = builtPlan.allowsAttentionCrop

        var portraitBounds: CGRect?
        var poseProfile: AnatomicalPoseProfile?
        if hero.category == .human, !hero.isGroup {
            let poseRequest = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: frame.orientation, options: [:])
            if (try? cancellation.perform(poseRequest, with: handler)) != nil {
                let observations = poseRequest.results ?? []
                if !hero.faceBounds.isEmpty {
                    portraitBounds = PortraitFramingEvidence.bounds(body: hero.boundingBox,
                        faces: hero.faceBounds, observations: observations)
                }
                poseProfile = PortraitFramingEvidence.extractProfile(body: hero.boundingBox,
                    faces: hero.faceBounds, observations: observations)
            }
        }
        if portraitBounds == nil && (hero.category == .human || hero.category == .face) && !hero.isGroup {
            let box = hero.boundingBox
            let torsoHeight = min(box.height, max(0.22, box.height * 0.60))
            portraitBounds = CGRect(x: box.minX, y: box.minY, width: box.width, height: torsoHeight)
        }
        let resolvedAnchor: CGPoint = {
            if let eye = hero.eyePosition { return eye }
            if hero.category == .human || hero.category == .face {
                if let p = poseProfile {
                    if let l = p.leftEye, let r = p.rightEye {
                        return CGPoint(x: (l.x + r.x) * 0.5, y: (l.y + r.y) * 0.5)
                    }
                    if let pt = p.nose ?? p.leftEye ?? p.rightEye {
                        return pt
                    }
                    if let neck = p.neck {
                        let headOffset = min(hero.boundingBox.height * 0.07, 0.05)
                        return CGPoint(x: neck.x, y: max(hero.boundingBox.minY + hero.boundingBox.height * 0.08, neck.y - headOffset))
                    }
                }
                let box = hero.boundingBox
                return CGPoint(x: box.midX, y: min(box.minY + box.height * 0.45, box.minY + min(box.height * 0.20, 0.14)))
            }
            if let tp = hero.trackingPoint {
                return CGPoint(x: min(hero.boundingBox.maxX, max(hero.boundingBox.minX, tp.x)),
                               y: min(hero.boundingBox.maxY, max(hero.boundingBox.minY, tp.y)))
            }
            return hero.center
        }()
        let heroArea = hero.boundingBox.width * hero.boundingBox.height
        let heroTouchesEdge = hero.boundingBox.minX <= 0.04 || hero.boundingBox.minY <= 0.04 ||
            hero.boundingBox.maxX >= 0.96 || hero.boundingBox.maxY >= 0.96
        let fallbackAllowAtt = hero.isAttentionRegion && raster.hasAttention &&
            (heroArea > 0.12 || (heroArea > 0.045 && heroTouchesEdge))
        let subject = CompositionSubject(index: 0, bounds: hero.boundingBox,
            anchor: resolvedAnchor, kind: builtPlan.subjectKind,
            confidence: Double(hero.confidence), importance: hero.prominenceScore, gaze: hero.gaze,
            allowsAttentionCrop: allowsHeroAttentionCrop || fallbackAllowAtt,
            verticalGaze: hero.verticalGaze,
            shotScaleBias: output.semanticGuidance.shotScaleBias,
            contextPreservationWeight: output.semanticGuidance.contextPreservationWeight,
            isAttentionOnly: hero.isAttentionRegion || allowsHeroAttentionCrop)
        let intents = refinedIntents(base: compositionIntents(output, hero: hero),
                                     hero: hero, role: sceneHints.role)
        if poseProfile == nil && (hero.category == .human || hero.category == .face) {
            poseProfile = PortraitFramingEvidence.extractProfile(body: hero.boundingBox,
                faces: hero.faceBounds, observations: [])
        }
        let constrained = ProcessInfo.processInfo.thermalState == .critical
        let isHighMemory = ProcessInfo.processInfo.physicalMemory >= 5_200_000_000
        let seedLimit = constrained ? 16 : (isHighMemory ? 64 : 40)
        let refineLimit = constrained ? 8 : (isHighMemory ? 28 : 20)
        let resolvedProtected = hero.companionBounds.isEmpty ? extraProtectedBounds : (extraProtectedBounds + hero.companionBounds)
        let arbitratedIncidentals = arbitratedIncidentalBounds(hero: hero, output: output, raster: raster) + extraIncidentalBounds
        func proposals(refining seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            CompositionPlanner.photographicProposals(subject: subject, intents: intents,
                portraitBounds: portraitBounds, raster: raster, calibration: frame.calibration,
                currentZoom: CGFloat(frame.displayZoom), allowedZooms: allowedZooms,
                protectedBounds: resolvedProtected,
                incidentalBounds: arbitratedIncidentals,
                proposalLimit: seeds.isEmpty ? seedLimit : refineLimit, refining: seeds,
                poseProfile: poseProfile,
                sceneHints: sceneHints,
                isCancelled: { cancellation.isCancelled })
        }
        let sampModelURL = Bundle.main.url(forResource: "SAMPComposition", withExtension: "mlmodelc")
        let gaicModelURL = GAICCompositionModel.defaultModelURL(near: sampModelURL)
        let isFallbackScenery = builtPlan.isFallbackScenery
        var initialProposals = proposals()
        if gaicModelURL != nil && !initialProposals.isEmpty {
            let heroProtection: [CGRect]
            if subject.kind == .person, let portraitBounds,
               subject.bounds.contains(portraitBounds), portraitBounds.contains(subject.anchor) {
                heroProtection = [portraitBounds]
            } else if subject.kind == .scenery && !extraProtectedBounds.isEmpty {
                heroProtection = extraProtectedBounds
            } else if subject.kind == .scenery {
                if let sceneryPt = raster.sceneryAnchor {
                    let sx = min(0.84, max(0.16, sceneryPt.x))
                    let sy = min(0.84, max(0.16, sceneryPt.y))
                    heroProtection = [CGRect(x: sx - 0.16, y: sy - 0.16, width: 0.32, height: 0.32)]
                } else {
                    heroProtection = [CGRect(x: 0.28, y: 0.28, width: 0.44, height: 0.44)]
                }
            } else if !extraProtectedBounds.isEmpty {
                heroProtection = extraProtectedBounds
            } else {
                heroProtection = [CompositionCropProtection.bounds(
                    body: subject.bounds,
                    portrait: portraitBounds,
                    intent: intents.first ?? .object,
                    anchor: subject.anchor,
                    attentionRegion: subject.allowsAttentionCrop
                )]
            }
            let protectList = heroProtection + hero.companionBounds + hero.faceBounds
            initialProposals = CompositionPlanner.denseCompositionalWindows(
                existing: initialProposals,
                calibration: frame.calibration,
                currentZoom: CGFloat(frame.displayZoom),
                allowedZooms: allowedZooms,
                subjectAnchor: subject.anchor,
                subjectBounds: subject.bounds,
                protectedBounds: protectList,
                incidentalBounds: arbitratedIncidentals,
                intent: intents.first ?? .object,
                confidence: subject.confidence,
                raster: raster,
                maxCount: isFallbackScenery ? min(72, GAICCompositionModel.maxBoxes) : GAICCompositionModel.maxBoxes,
                subject: subject,
                poseProfile: poseProfile,
                sceneryFallback: isFallbackScenery,
                sceneHints: sceneHints
            )
        }
        // Score top diverse crop candidates semantically with SigLIP RoI BEFORE releasing SigLIP RAM.
        if !constrained && !initialProposals.isEmpty {
            initialProposals = SemanticCropRanker.shared.scoreProposalsSemantically(
                initialProposals,
                role: sceneHints.role,
                fullScores: spatialProfile.fullScores,
                pixelBuffer: pixelBuffer,
                orientation: frame.orientation,
                cancellation: cancellation
            )
        }
        // Release the semantic encoder before loading the composition specialist,
        // especially on iPhone XS. Detection and group membership remain unchanged.
        autoreleasepool {
            SemanticCropRanker.shared.endAnalysis()
        }
        progress("Đang đánh giá bố cục bằng mô hình trên máy…")
        let search = CompositionAestheticSearch(renderer: renderer)
        let searchResult = search.run(proposals: initialProposals,
            image: CIImage(cvPixelBuffer: pixelBuffer).oriented(frame.orientation),
            aspect: frame.calibration.aspect, preferences: preferences,
            raster: raster,
            modelURL: sampModelURL,
            gaicModelURL: gaicModelURL,
            aestheticModelURL: constrained ? nil : Bundle.main.url(forResource: "CharmAesthetics", withExtension: "mlmodelc"),
            positionURL: constrained ? nil : Bundle.main.url(forResource: "CharmPositionEmbedding", withExtension: "bin"),
            requiresModernModel: false,
            sceneHints: sceneHints,
            cancellation: cancellation, progress: progress, refine: { proposals(refining: $0) })
        renderer.clearCaches()
        guard let result = searchResult else { return nil }
        let choices = result.views.map { view -> LocalCompositionChoice in
            let proposal = view.proposal
            let explanationText = sceneHints.hasRichGuidance
                ? proposal.explanation
                : (proposal.explanation + (result.usedSpecialist ? " Đã tối ưu bố cục theo Tỷ lệ vàng và Luật một phần ba." : " Bố cục tự nhiên."))
            let plan = LocalFramingPlan(subjectPoint: hero.trackingPoint ?? proposal.subjectPoint, subjectRect: hero.boundingBox,
                cropProtectionRect: CompositionCropProtection.bounds(body: hero.boundingBox,
                    portrait: portraitBounds, intent: proposal.intent, anchor: subject.anchor,
                    attentionRegion: subject.allowsAttentionCrop),
                aimPointInSource: proposal.aimPoint, aimWorldRay: pose.act(proposal.rotation.act(SIMD3(0, 0, -1))),
                zoom: proposal.zoom, confidence: proposal.evidenceConfidence,
                minimumAutoselectConfidence: (output.detectedScene == .night ? 0.42 :
                    (LocalAutoselectCalibration.threshold(scene: output.detectedScene, category: hero.category) ?? 0.56)),
                intent: proposal.intent, score: proposal.score, explanation: explanationText,
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

    private struct IntelligentSubjectPlan {
        let hero: NeuralSubjectCandidate
        let subjectKind: CompositionSubjectKind
        let protectedBounds: [CGRect]
        let incidentalBounds: [CGRect]
        var sceneHints: CompositionSceneHints
        let allowsAttentionCrop: Bool
        let isFallbackScenery: Bool
    }

    private static let suspiciousOutdoorTokens: Set<String> = [
        "knife", "dao", "bench", "ghế dài", "umbrella", "chiếc ô",
        "airplane", "máy bay", "kite", "surfboard", "skis",
        "bed", "giường", "toilet", "bồn cầu"
    ]

    private static let diningTableTokens: Set<String> = [
        "dining table", "bàn ăn"
    ]

    private static let deskTabletopTokens: Set<String> = [
        "cup", "cốc nước", "mug", "wine glass", "ly rượu", "mouse", "chuột máy tính",
        "keyboard", "bàn phím", "tv", "tivi", "laptop", "bottle", "chai nước",
        "scissors", "kéo", "book", "cuốn sách", "bowl", "bát đĩa", "vase", "bình hoa",
        "cell phone", "điện thoại", "clock", "đồng hồ", "remote", "điều khiển"
    ]

    private func refinedIntents(base: [LocalCompositionIntent],
                                hero: NeuralSubjectCandidate,
                                role: SemanticCompositionRole) -> [LocalCompositionIntent] {
        if hero.isGroup || hero.category == .human || hero.category == .face || hero.category == .animal {
            return base
        }
        switch role {
        case .architecture, .indoorRoom: return [.architecture, .object]
        case .streetLeading: return [.street, .object]
        case .landscapeSky: return [.landscape, .object]
        case .foliageGarden: return [.landscape, .closeUp]
        case .deskWorkspace, .tabletopEnsemble, .apertureView: return [.object]
        case .food: return [.food]
        case .flower: return [.closeUp]
        default: return base
        }
    }

    private func buildIntelligentSubjectPlan(output: NeuralAnalysisOutput,
                                             raster: CompositionRaster,
                                             spatialProfile: SemanticCropRanker.SpatialSemanticProfile,
                                             isLowLuma: Bool) -> IntelligentSubjectPlan {
        var sceneHints = CompositionSceneHints.build(
            from: raster,
            role: spatialProfile.role,
            semanticAvoid: spatialProfile.avoid
        )
        let role = spatialProfile.role
        let minConf: Float = isLowLuma ? 0.18 : 0.24

        func isEdgeSliver(_ rect: CGRect) -> Bool {
            let touchesLR = rect.minX <= 0.015 || rect.maxX >= 0.985
            let touchesTB = rect.minY <= 0.015 || rect.maxY >= 0.985
            return (touchesLR && rect.width < 0.11) || (touchesTB && rect.height < 0.11)
        }
        func unionRects(_ rects: [CGRect]) -> CGRect {
            guard var acc = rects.first else { return .zero }
            for r in rects.dropFirst() { acc = acc.union(r) }
            return acc
        }
        func clustersClose(_ a: CGRect, _ b: CGRect) -> Bool {
            let gapX = max(0.0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
            let gapY = max(0.0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
            return gapX < 0.25 && gapY < 0.25
        }

        // Preserve established group detection first
        if let groupHero = output.allCandidates.first(where: { $0.isGroup && !$0.isAttentionRegion }) {
            sceneHints.reasonSubject = "Nhận diện \(groupHero.label)"
            return IntelligentSubjectPlan(
                hero: groupHero, subjectKind: .group, protectedBounds: groupHero.companionBounds,
                incidentalBounds: [], sceneHints: sceneHints, allowsAttentionCrop: false, isFallbackScenery: false
            )
        }

        var validYolo: [NeuralSubjectCandidate] = []
        var incidentalSlivers: [CGRect] = []
        for c in output.allCandidates where !c.isAttentionRegion {
            if c.confidence < minConf { continue }
            let box = c.boundingBox
            let area = c.areaRatio
            if area < 0.002 || box.width > 0.95 || box.height > 0.95 { continue }
            let lower = c.label.lowercased()
            let isHumanOrPet = (c.category == .human || c.category == .face || c.category == .animal)

            if Self.suspiciousOutdoorTokens.contains(lower),
               (role == .architecture || role == .landscapeSky || role == .foliageGarden ||
                role == .apertureView || role == .streetLeading || role == .indoorRoom) {
                continue
            }
            if Self.diningTableTokens.contains(lower) { continue }

            if isEdgeSliver(box) && !isHumanOrPet {
                incidentalSlivers.append(box)
                continue
            }
            if c.category == .human && area < 0.012 &&
               (role == .streetLeading || role == .architecture || role == .landscapeSky || role == .foliageGarden) {
                incidentalSlivers.append(box)
                continue
            }
            let rc = sceneHints.clutterDensity(in: box, side: raster.side)
            if rc > 0.58 && !isHumanOrPet { continue }
            validYolo.append(c)
        }

        let cleanClusters = sceneHints.extractCleanClusters(raster: raster, minPeak: 0.22, maxCount: 5)

        // Case A: Clear Human / Face / Animal hero
        let humanAnimal = validYolo.filter {
            ($0.category == .human || $0.category == .face || $0.category == .animal) &&
            ($0.areaRatio >= 0.012 || ($0.category == .face && $0.confidence >= 0.54 && $0.areaRatio >= 0.004)) &&
            !($0.boundingBox.maxY >= 0.96 && $0.boundingBox.height < 0.24)
        }
        if let topHA = humanAnimal.max(by: { a, b in
            let sa = Double(a.confidence) * sqrt(max(0.001, a.areaRatio)) * (a.category == .animal ? 1.0 : 1.2)
            let sb = Double(b.confidence) * sqrt(max(0.001, b.areaRatio)) * (b.category == .animal ? 1.0 : 1.2)
            return sa < sb
        }) {
            sceneHints.reasonSubject = "Nhận diện \(topHA.label) nổi bật"
            return IntelligentSubjectPlan(
                hero: topHA, subjectKind: kind(topHA.category), protectedBounds: [],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: false, isFallbackScenery: false
            )
        }

        // Case B: Desk Workspace or Tabletop Ensemble -> Group cohesive tabletop items + clean clusters
        let deskItems = validYolo.filter { Self.deskTabletopTokens.contains($0.label.lowercased()) }
        if role == .tabletopEnsemble || role == .deskWorkspace || deskItems.count >= 2 {
            var coreItems = deskItems.map(\.boundingBox).filter { !isEdgeSliver($0) }
            for cl in cleanClusters.prefix(3) {
                let cb = cl.bounds
                if sceneHints.clutterDensity(in: cb, side: raster.side) < 0.38 && !isEdgeSliver(cb) {
                    if coreItems.isEmpty {
                        coreItems.append(cb)
                    } else {
                        let cu = unionRects(coreItems)
                        if abs(cb.midY - cu.midY) < 0.36, let topScore = cleanClusters.first?.score, cl.score >= 0.12 * topScore {
                            coreItems.append(cb)
                        }
                    }
                }
            }
            if !coreItems.isEmpty {
                let groupBox = unionRects(coreItems)
                var cxSum = 0.0, cySum = 0.0, wSum = 0.0
                for b in coreItems {
                    let wt = sqrt(max(0.01, Double(b.width * b.height)))
                    cxSum += Double(b.midX) * wt
                    cySum += Double(b.midY) * wt
                    wSum += wt
                }
                let anchor = CGPoint(x: cxSum / max(1e-6, wSum), y: cySum / max(1e-6, wSum))
                let names = Array(Set(deskItems.map(\.label))).sorted()
                let baseLbl = role == .deskWorkspace ? "Góc bàn học" : "Cụm đồ vật"
                let desc = names.isEmpty ? "đồ vật trên bàn" : names.prefix(3).joined(separator: " + ")
                sceneHints.reasonSubject = "\(baseLbl) (\(desc))"
                let synthHero = NeuralSubjectCandidate(
                    boundingBox: groupBox, category: .foregroundObject, confidence: 0.85,
                    label: baseLbl, prominenceScore: 0.85, trackingPoint: anchor
                )
                return IntelligentSubjectPlan(
                    hero: synthHero, subjectKind: .object, protectedBounds: coreItems,
                    incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                    allowsAttentionCrop: false, isFallbackScenery: false
                )
            }
        }

        // Case C: Indoor Furnished Room
        if role == .indoorRoom {
            var furnBoxes = cleanClusters.filter {
                $0.area >= 0.04 && sceneHints.clutterDensity(in: $0.bounds, side: raster.side) < 0.35
            }.map(\.bounds)
            for y in validYolo where y.areaRatio >= 0.015 && !isEdgeSliver(y.boundingBox) {
                furnBoxes.append(y.boundingBox)
            }
            if !furnBoxes.isEmpty {
                let gb = sceneHints.trimBoxAwayFromClutter(unionRects(furnBoxes))
                let anchor = CGPoint(x: gb.midX, y: gb.minY + 0.48 * gb.height)
                sceneHints.reasonSubject = "Không gian góc phòng & nội thất"
                let synthHero = NeuralSubjectCandidate(
                    boundingBox: gb, category: .foregroundObject, confidence: 0.80,
                    label: "Góc nội thất", prominenceScore: 0.78, trackingPoint: anchor
                )
                return IntelligentSubjectPlan(
                    hero: synthHero, subjectKind: .object, protectedBounds: [gb],
                    incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                    allowsAttentionCrop: true, isFallbackScenery: false
                )
            }
        }

        // Case D: Street / Alley Leading Lines
        if role == .streetLeading {
            let gb: CGRect
            let anchor: CGPoint
            if let fa = sceneHints.focalAccent, let vp = sceneHints.refinedVanishingPoint {
                let ax = 0.55 * Double(fa.point.x) + 0.45 * Double(vp.point.x)
                let ay = 0.55 * Double(fa.point.y) + 0.45 * Double(vp.point.y)
                let x0 = max(sceneHints.avoid.left > 0.35 ? 0.18 : 0.08, min(Double(fa.point.x), Double(vp.point.x)) - 0.16)
                let y0 = max(sceneHints.avoid.top > 0.45 ? 0.14 : 0.08, min(Double(fa.point.y), Double(vp.point.y)) - 0.16)
                let x1 = min(sceneHints.avoid.right > 0.45 ? 0.84 : 0.92, max(Double(fa.point.x), Double(vp.point.x)) + 0.18)
                let y1 = min(sceneHints.avoid.bottom > 0.45 ? 0.86 : 0.90, max(Double(fa.point.y), Double(vp.point.y)) + 0.18)
                gb = CGRect(x: x0, y: y0, width: max(0.24, x1 - x0), height: max(0.24, y1 - y0))
                anchor = CGPoint(x: ax, y: ay)
            } else if let vp = sceneHints.refinedVanishingPoint {
                let ax = Double(vp.point.x), ay = Double(vp.point.y) + 0.10
                gb = sceneHints.trimBoxAwayFromClutter(CGRect(x: max(0.08, ax - 0.30), y: max(0.10, ay - 0.25), width: 0.60, height: 0.52))
                anchor = CGPoint(x: ax, y: ay)
            } else if let c0 = cleanClusters.first {
                gb = sceneHints.trimBoxAwayFromClutter(c0.bounds)
                anchor = CGPoint(x: gb.midX, y: gb.midY)
            } else {
                gb = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
                anchor = CGPoint(x: 0.50, y: 0.48)
            }
            sceneHints.reasonSubject = "Ngõ phố có đường dẫn" + (sceneHints.focalAccent != nil ? " & điểm nhấn màu" : "")
            let synthHero = NeuralSubjectCandidate(
                boundingBox: gb, category: .foregroundObject, confidence: 0.80,
                label: "Đường dẫn & tiêu điểm", prominenceScore: 0.78, trackingPoint: anchor
            )
            return IntelligentSubjectPlan(
                hero: synthHero, subjectKind: .object, protectedBounds: [gb],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: true, isFallbackScenery: false
            )
        }

        // Case E: Architecture & Roofline / Skyline
        if role == .architecture {
            let archCls = cleanClusters.filter {
                $0.bounds.maxY > 0.35 && sceneHints.clutterDensity(in: $0.bounds, side: raster.side) < 0.42
            }
            let gb: CGRect
            let anchor: CGPoint
            if let c0 = archCls.first {
                var box = (archCls.count >= 2 && clustersClose(c0.bounds, archCls[1].bounds))
                    ? unionRects([c0.bounds, archCls[1].bounds])
                    : c0.bounds
                box = sceneHints.trimBoxAwayFromClutter(box)
                if let roofY = sceneHints.archRoofTopY, roofY < Double(box.minY), roofY > 0.10 {
                    let newY0 = max(0.05, roofY - 0.02)
                    box = CGRect(x: box.minX, y: CGFloat(newY0), width: box.width, height: max(0.18, box.maxY - CGFloat(newY0)))
                }
                gb = box
                anchor = CGPoint(x: gb.midX, y: gb.minY + 0.46 * gb.height)
            } else {
                gb = CGRect(x: 0.16, y: 0.25, width: 0.68, height: 0.55)
                anchor = CGPoint(x: 0.50, y: 0.50)
            }
            sceneHints.reasonSubject = "Kiến trúc công trình & mái nhà"
            let synthHero = NeuralSubjectCandidate(
                boundingBox: gb, category: .foregroundObject, confidence: 0.80,
                label: "Kiến trúc ngôi nhà", prominenceScore: 0.78, trackingPoint: anchor
            )
            return IntelligentSubjectPlan(
                hero: synthHero, subjectKind: .object, protectedBounds: [gb],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: true, isFallbackScenery: false
            )
        }

        // Case F: Wide Landscape / Sky & Horizon
        if role == .landscapeSky {
            let hy = sceneHints.estimatedHorizonY ?? 0.52
            let gb = CGRect(x: 0.12, y: max(0.10, hy - 0.18), width: 0.76, height: min(0.85, 0.42))
            let prot = CGRect(x: 0.25, y: max(0.12, hy - 0.14), width: 0.50, height: 0.28)
            sceneHints.reasonSubject = "Cảnh rộng bầu trời & đường chân trời"
            let synthHero = NeuralSubjectCandidate(
                boundingBox: gb, category: .general, confidence: 0.78,
                label: "Bầu trời & đường chân trời", prominenceScore: 0.72,
                trackingPoint: CGPoint(x: 0.50, y: hy)
            )
            return IntelligentSubjectPlan(
                hero: synthHero, subjectKind: .scenery, protectedBounds: [prot],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: true, isFallbackScenery: false
            )
        }

        // Case G: Balcony / Doorway Aperture
        if role == .apertureView {
            let cOpen = cleanClusters.filter {
                $0.bounds.midY < 0.72 && sceneHints.clutterDensity(in: $0.bounds, side: raster.side) < 0.35
            }
            let gb: CGRect
            let anchor: CGPoint
            if let first = cOpen.first {
                var keep = [first.bounds]
                for c2 in cOpen.dropFirst() where c2.score >= 0.35 * first.score &&
                    sceneHints.clutterDensity(in: c2.bounds, side: raster.side) < 0.22 {
                    keep.append(c2.bounds)
                }
                gb = sceneHints.trimBoxAwayFromClutter(unionRects(keep))
                anchor = CGPoint(x: gb.midX, y: gb.midY)
            } else {
                gb = CGRect(x: 0.28, y: 0.08, width: 0.68, height: 0.62)
                anchor = CGPoint(x: 0.58, y: 0.38)
            }
            sceneHints.reasonSubject = "Khung cảnh nhìn qua cửa/ban công"
            let synthHero = NeuralSubjectCandidate(
                boundingBox: gb, category: .foregroundObject, confidence: 0.78,
                label: "Khung nhìn qua cửa", prominenceScore: 0.75, trackingPoint: anchor
            )
            return IntelligentSubjectPlan(
                hero: synthHero, subjectKind: .object, protectedBounds: [gb],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: true, isFallbackScenery: false
            )
        }

        // Case H: Single clear YOLO object (food, vehicle, vase, etc.)
        if let topObj = validYolo.max(by: { a, b in
            let ca = 1.0 - 0.5 * sceneHints.clutterDensity(in: a.boundingBox, side: raster.side)
            let cb = 1.0 - 0.5 * sceneHints.clutterDensity(in: b.boundingBox, side: raster.side)
            return Double(a.confidence) * sqrt(max(0.001, a.areaRatio)) * ca <
                   Double(b.confidence) * sqrt(max(0.001, b.areaRatio)) * cb
        }) {
            sceneHints.reasonSubject = "Chủ thể \(topObj.label)"
            return IntelligentSubjectPlan(
                hero: topObj, subjectKind: kind(topObj.category), protectedBounds: [],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: false, isFallbackScenery: false
            )
        }

        // Clean saliency cluster (Foliage Garden or Distinct Foreground Cluster)
        if let topCluster = cleanClusters.first {
            let gb = sceneHints.trimBoxAwayFromClutter(topCluster.bounds)
            let isFoliage = (role == .foliageGarden)
            let lbl = isFoliage ? "Tán cây & thiên nhiên" : "Chủ thể nổi bật"
            sceneHints.reasonSubject = lbl
            let synthHero = NeuralSubjectCandidate(
                boundingBox: gb, category: isFoliage ? .general : .foregroundObject, confidence: 0.74,
                label: lbl, prominenceScore: 0.70, trackingPoint: CGPoint(x: gb.midX, y: gb.midY)
            )
            return IntelligentSubjectPlan(
                hero: synthHero, subjectKind: isFoliage ? .scenery : .object, protectedBounds: [gb],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: true, isFallbackScenery: false
            )
        }

        // Fallback Scenery
        let fallbackHero = NeuralSubjectCandidate(
            boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60),
            category: .general, confidence: 0.70, label: "Khung cảnh", prominenceScore: 0.20
        )
        sceneHints.reasonSubject = "Toàn cảnh"
        return IntelligentSubjectPlan(
            hero: fallbackHero, subjectKind: .scenery, protectedBounds: [],
            incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
            allowsAttentionCrop: true, isFallbackScenery: output.allCandidates.isEmpty
        )
    }

    private func arbitratedIncidentalBounds(hero: NeuralSubjectCandidate, output: NeuralAnalysisOutput,
                                            raster: CompositionRaster) -> [CGRect] {
        let focalDepth = raster.focalDepthPlane
        var protected = hero.companionBounds + hero.faceBounds
        protected.append(hero.boundingBox)

        var incidentals: [CGRect] = output.allFaceRects.filter { !hero.faceBounds.contains($0) }
        for candidate in output.allCandidates where candidate.id != hero.id {
            let box = candidate.boundingBox
            let overlapsProtected = protected.contains { $0.intersects(box) }
            guard !overlapsProtected else { continue }
            let edgeMargin = min(box.minX, min(1.0 - box.maxX, min(box.minY, 1.0 - box.maxY)))
            let radialDist = hypot(Double(box.midX - 0.5), Double(box.midY - 0.5))
            let nearEdge = edgeMargin < 0.14 || radialDist > 0.34
            let stats = raster.depthStats(in: box)
            let depthDivergence = abs(stats.meanDepth - focalDepth)
            let weakSync = stats.meanSync < 0.22
            if (nearEdge && depthDivergence >= 0.16 && weakSync) ||
               (nearEdge && (candidate.category == .human || candidate.category == .animal) &&
                candidate.prominenceScore < hero.prominenceScore * 0.45) ||
               (depthDivergence >= 0.28 && weakSync && candidate.areaRatio < 0.12) {
                incidentals.append(box)
            }
        }
        return incidentals
    }

    private func compositionIntents(_ output: NeuralAnalysisOutput, hero: NeuralSubjectCandidate) -> [LocalCompositionIntent] {
        if hero.isGroup { return [.group, .environmentalPortrait] }
        if hero.category == .human || hero.category == .face {
            let scenicContext = output.semanticGuidance.contextPreservationWeight >= 0.58 ||
                output.detectedScene == .landscape || output.detectedScene == .street ||
                output.detectedScene == .architecture || output.detectedScene == .water ||
                output.detectedScene == .sunset ||
                (hero.category == .human && hero.areaRatio < 0.052 && hero.faceBounds.isEmpty)
            return scenicContext
                ? [.environmentalPortrait, .portrait]
                : [.portrait, .environmentalPortrait]
        }
        if hero.category == .animal { return [.animal] }
        if hero.category == .general { return [.landscape] }
        if output.detectedScene == .general,
           let landscape = output.semanticAffinities["landscape"], landscape > 0.04,
           landscape > (output.semanticAffinities["object"] ?? 0) + 0.008 {
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
        let measuredDepth: [Double]? = autoreleasepool {
            renderer.estimateMonocularDepth(image: image, side: 64, cancellation: cancellation)
        }
        let raster = renderer.raster(image: image,
            saliency: completed.contains(ObjectIdentifier(attention)) ? attention.results?.first?.pixelBuffer : nil,
            objectness: completed.contains(ObjectIdentifier(objectness)) ? objectness.results?.first?.pixelBuffer : nil,
            foregroundMask: fgMaskBuffer,
            measuredDepth: measuredDepth,
            measuredHorizon: measuredHorizon,
            measuredVanishingPoint: measuredVP)
        let sceneLuma = SmartSceneExposureEngine.estimateSceneLuminance(from: pixelBuffer)
        let isLowLight = sceneLuma < 0.42
        var candidates = YOLODetectionEngine.shared.detectPhotographicObjects(
            pixelBuffer: pixelBuffer, orientation: orientation,
            depthGrid: raster?.foregroundDepth, depthSide: raster?.side ?? 0,
            cancellation: cancellation)
        var faceCandidates: [NeuralSubjectCandidate] = []
        if completed.contains(ObjectIdentifier(faces)) {
            let faceMinConf: Float = isLowLight ? 0.20 : 0.30
            for face in faces.results ?? [] where face.confidence >= faceMinConf {
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
            let bodyMinConf: Float = isLowLight ? 0.22 : 0.32
            let bodyFallbackConf: Float = isLowLight ? 0.32 : 0.45
            for body in bodies.results ?? [] where body.confidence >= bodyMinConf {
                let upright = CompositionPureCalculations.visionToUprightRect(body.boundingBox)
                let hasMatchingFace = faceCandidates.contains { face in
                    upright.contains(CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)) ||
                    (abs(face.boundingBox.midX - upright.midX) < upright.width * 0.45 && face.boundingBox.minY <= upright.minY + upright.height * 0.45)
                }
                let hasYoloPerson = candidates.contains {
                    $0.category == .human && $0.boundingBox.intersects(upright)
                }
                guard hasMatchingFace || hasYoloPerson || body.confidence >= bodyFallbackConf else { continue }
                if let c = candidate(visionRect: body.boundingBox, category: .human, confidence: body.confidence, label: "Người") {
                    candidates.append(c)
                }
            }
        }
        if completed.contains(ObjectIdentifier(animals)) {
            let animalMinConf: Float = isLowLight ? 0.28 : 0.35
            for animal in animals.results ?? [] where animal.confidence >= animalMinConf {
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
                let salMinConf: Float = isLowLight ? 0.18 : 0.30
            for region in observation.salientObjects ?? [] where region.confidence >= salMinConf {
                    let area = region.boundingBox.width * region.boundingBox.height
                    guard area >= 0.012 && area <= 0.78 else { continue }
                    // Loại bỏ chướng ngại vật sát biên khung hình (Vision boundingBox gốc dùng hệ bottom-left: y=0 ở đáy, y=1 ở đỉnh)
                    let b = region.boundingBox
                    let isSideOccluder = (b.minX <= 0.03 || b.maxX >= 0.97) && b.height >= 0.55 && b.width <= 0.18
                    let isBottomOccluder = b.minY <= 0.04 && b.height <= 0.35 && b.width >= 0.50
                    guard !isSideOccluder && !isBottomOccluder else { continue }
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
            if let r = raster {
                let syncClusters = r.extractSynchronizedClusters(minPeak: hasExplicitDetectorCandidate ? 0.34 : 0.24, maxClusters: 4)
                for cluster in syncClusters {
                    // Only suppress if existing detections cover most of THIS cluster (not a tiny sub-object inside it)
                    let alreadyCovered = candidates.contains { existing in
                        let inter = existing.boundingBox.intersection(cluster.bounds)
                        guard !inter.isNull, !inter.isEmpty else { return false }
                        let interArea = Double(inter.width * inter.height)
                        let unionArea = existing.areaRatio + cluster.area - interArea
                        return interArea / max(0.0001, cluster.area) > 0.58 ||
                            interArea / max(0.0001, unionArea) > 0.48
                    }
                    guard !alreadyCovered else { continue }
                    let label = cluster.area <= 0.42 ? "Chủ thể tiền cảnh" : "Vùng trọng tâm"
                    let rawConf = 0.30 * cluster.peakValue + 0.44 * cluster.dominance + 0.26 * cluster.meanDepth
                    let b = cluster.bounds
                    let touchesBorder = b.minX <= 0.025 || b.maxX >= 0.975 || b.minY <= 0.025 || b.maxY >= 0.975
                    let offCenter = Double(hypot(cluster.anchor.x - 0.5, cluster.anchor.y - 0.5))
                    var explicitScale = 1.0
                    if hasExplicitDetectorCandidate {
                        if touchesBorder && (cluster.dominance < 0.12 || offCenter > 0.34) {
                            explicitScale = 0.62
                        } else if offCenter > 0.38 && cluster.dominance < 0.14 {
                            explicitScale = 0.72
                        } else if !candidates.contains(where: { $0.areaRatio < 0.015 }) {
                            explicitScale = 0.88
                        }
                    }
                    let adjusted = Float(min(0.90, max(0.38, rawConf * explicitScale)))
                    var c = NeuralSubjectCandidate(
                        boundingBox: cluster.bounds,
                        category: .foregroundObject,
                        confidence: adjusted,
                        label: label,
                        prominenceScore: HeroSubjectPolicy.score(bounds: cluster.bounds, kind: .object,
                            confidence: Double(adjusted), evidence: r.evidence(in: cluster.bounds))
                    )
                    c.trackingPoint = cluster.anchor
                    c.attentionDominance = cluster.dominance
                    candidates.append(c)
                }
            }
        }
        if candidates.isEmpty, let r = raster, r.hasAttention {
            let clusters = r.extractSynchronizedClusters(minPeak: 0.20, maxClusters: 4)
            if !clusters.isEmpty {
                for (idx, cluster) in clusters.enumerated() {
                    let label = cluster.area <= 0.42 ? "Chủ thể tiền cảnh" : (idx == 0 ? "Vùng trọng tâm" : "Vùng chi tiết")
                    let conf = Float(min(0.92, max(0.38, 0.42 * cluster.peakValue + 0.35 * cluster.dominance + 0.23 * cluster.meanDepth)))
                    var c = NeuralSubjectCandidate(
                        boundingBox: cluster.bounds,
                        category: .foregroundObject,
                        confidence: conf,
                        label: label,
                        prominenceScore: max(0.18, cluster.dominance * 0.48)
                    )
                    c.trackingPoint = cluster.anchor
                    c.attentionDominance = cluster.dominance
                    candidates.append(c)
                }
            } else if !r.isDiffuseAttention, let com = r.visualCenterOfMass {
                let comVal = r.value(r.synchronizedSaliency, at: com)
                if comVal >= 0.22 {
                    let bw: CGFloat = 0.32
                    let bh: CGFloat = 0.32
                    let bx = min(max(0.04, com.x - bw / 2), 1 - bw - 0.04)
                    let by = min(max(0.04, com.y - bh / 2), 1 - bh - 0.04)
                    let box = CGRect(x: bx, y: by, width: bw, height: bh)
                    var c = NeuralSubjectCandidate(
                        boundingBox: box,
                        category: .foregroundObject,
                        confidence: Float(max(0.40, comVal)),
                        label: "Vùng trọng tâm",
                        prominenceScore: 0.22
                    )
                    c.trackingPoint = com
                    c.attentionDominance = r.subjectAttentionDominance
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
        let heroDominance = candidates.first?.attentionDominance ?? 0.0
        let rasterDominance = raster?.subjectAttentionDominance ?? 0.0
        let combinedDominance = candidates.isEmpty ? rasterDominance : min(1.0, max(0.0, 0.62 * heroDominance + 0.38 * rasterDominance))
        var output = NeuralAnalysisOutput(allCandidates: candidates, detectedScene: scene,
            allFaceRects: faceCandidates.map(\.boundingBox), primaryEyePosition: candidates.first?.eyePosition,
            lookingDirection: CGVector(dx: candidates.first?.gaze ?? 0, dy: 0),
            usedSemanticModel: didUseSigLIP)
        output.compositionRaster = raster
        output.semanticAffinities = semantics
        output.semanticGuidance = guidance
        output.subjectAttentionDominance = combinedDominance
        return output
    }

    private func rankedDistinct(_ raw: [NeuralSubjectCandidate], raster: CompositionRaster?) -> [NeuralSubjectCandidate] {
        let ranked = raw.map { c -> NeuralSubjectCandidate in
            var copy = c
            let ev = raster?.evidence(in: c.boundingBox)
            copy.prominenceScore = HeroSubjectPolicy.score(bounds: c.boundingBox, kind: kind(c.category),
                confidence: Double(c.confidence), evidence: ev, hasFace: c.eyePosition != nil)
            if let ev {
                let syncTerm = ev.syncAttention ?? ev.attentionDensity
                copy.attentionDominance = min(1.0, max(copy.attentionDominance, 0.55 * syncTerm + 0.45 * min(1.0, ev.attentionShare * 2.2)))
            }
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
        group.attentionDominance = raster?.evidence(in: union)?.syncAttention ?? (members.map(\.attentionDominance).max() ?? hero.attentionDominance)
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
