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
        var zoneBonuses: [String: Double] = [:]
    }

    static let shared = SemanticCropRanker()
    private let lock = NSLock()
    private var attemptedLoad = false
    private var activeSessionDepth = 0
    private var model: VNCoreMLModel?
    private var prompts: [String: [Double]] = [:]
    private var _didProduceEvidence = false
    var didProduceEvidence: Bool { lock.withLock { _didProduceEvidence } }

    private init() {
        // Evict SigLIP FIRST (priority 10) whenever real-time Jetsam headroom runs low so
        // smaller models and Metal MPSGraph (Charm, priority 90) avoid costly recompilations.
        CompositionMemoryBudget.registerCacheEvictor(id: "SigLIP", priority: 10) { [weak self] in
            self?.releaseModelNow() ?? false
        }
    }

    func beginAnalysis() {
        lock.withLock {
            if activeSessionDepth == 0 {
                _didProduceEvidence = false
                if model == nil {
                    attemptedLoad = false
                }
            }
            activeSessionDepth += 1
        }
    }
    func endAnalysis() {
        let shouldCheckRelease: Bool = lock.withLock {
            activeSessionDepth = max(0, activeSessionDepth - 1)
            return activeSessionDepth == 0
        }
        if shouldCheckRelease && !CompositionMemoryBudget.shouldRetainModelCache(
            minimumAvailableBytes: CompositionMemoryBudget.siglipRetainThresholdBytes
        ) {
            _ = releaseModelNow()
        }
    }
    /// Completes the outer analysis session and keeps SigLIP warm when Jetsam headroom is healthy,
    /// releasing it immediately on memory-constrained devices.
    func finishSession(lowMemoryBudget: Bool) {
        let modelWasNil: Bool = lock.withLock {
            activeSessionDepth = 0
            if model == nil {
                attemptedLoad = false
                return true
            }
            return false
        }
        if modelWasNil { return }
        let retainThreshold = lowMemoryBudget ? 520_000_000 : CompositionMemoryBudget.siglipRetainThresholdBytes
        if !CompositionMemoryBudget.shouldRetainModelCache(minimumAvailableBytes: retainThreshold) {
            _ = releaseModelNow()
        }
    }
    /// Resets any leaked depth (e.g. early cancellation return inside `analyzeCapturedFrame`)
    /// and unloads SigLIP cleanly under lock (used on memory warnings / app backgrounding).
    func resetSessionAndRelease() {
        lock.withLock {
            activeSessionDepth = 0
            model = nil
            attemptedLoad = false
        }
    }
    /// Releases SigLIP weights while keeping decoded prompt vectors (~150KB) cached and
    /// preserving `activeSessionDepth` balance.
    @discardableResult
    func releaseModelNow() -> Bool {
        lock.withLock {
            let hadModel = (model != nil)
            model = nil
            attemptedLoad = false
            return hadModel
        }
    }

    private func loadAndSnapshot() -> (model: VNCoreMLModel?, prompts: [String: [Double]]) {
        lock.lock()
        if let existingModel = model, !prompts.isEmpty {
            let snap = (Optional(existingModel), prompts)
            lock.unlock()
            return snap
        }
        if attemptedLoad {
            let snap = (model, prompts)
            lock.unlock()
            return snap
        }
        attemptedLoad = true
        let cachedPrompts = prompts
        lock.unlock()

        guard ProcessInfo.processInfo.physicalMemory >= 2_500_000_000,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              CompositionMemoryBudget.ensureHeadroom(
                  minimumBytes: CompositionMemoryBudget.siglipLoadHeadroomBytes,
                  excluding: "SigLIP"
              ),
              let url = Bundle.main.url(forResource: "SigLIPBaseImage", withExtension: "mlmodelc") else {
            return (nil, [:])
        }
        let vectors: [String: [Double]]
        if !cachedPrompts.isEmpty {
            vectors = cachedPrompts
        } else if let promptURL = Bundle.main.url(forResource: "SigLIPPrompts", withExtension: "json"),
                  let data = try? Data(contentsOf: promptURL),
                  let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data),
                  !decoded.isEmpty {
            vectors = decoded
        } else {
            return (nil, [:])
        }
        do {
            let config = MLModelConfiguration()
            // Static 224x224 W8A16 ViT runs purely on ANE — keeping SigLIP off Metal GPU prevents
            // MPSGraph heap fragmentation and 60fps viewfinder stalls with 100% identical accuracy.
            config.computeUnits = .cpuAndNeuralEngine
            config.allowLowPrecisionAccumulationOnGPU = true
            let loadedModel = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
            lock.lock()
            // Guard against a concurrent release occurring while MLModel compiled
            if attemptedLoad {
                model = loadedModel
                prompts = vectors
            }
            lock.unlock()
            return (loadedModel, vectors)
        } catch {
            lock.withLock {
                model = nil
            }
            CameraLogger.warning("SigLIP không khả dụng, dùng Vision/YOLO: \(error)", category: .ai)
            return (nil, [:])
        }
    }

    func sceneEvidence(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                       cancellation: CompositionAnalysisCancellation) -> [String: Double] {
        let snap = loadAndSnapshot()
        guard let model = snap.model, !snap.prompts.isEmpty, !cancellation.isCancelled else { return [:] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        return affinities(model: model, prompts: snap.prompts, handler: handler, cancellation: cancellation)
    }

    private func affinities(model: VNCoreMLModel, prompts: [String: [Double]],
                            handler: VNImageRequestHandler,
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
        if !scores.isEmpty {
            lock.withLock { _didProduceEvidence = true }
        }
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
        let snap = loadAndSnapshot()
        let activeModel = snap.model
        let activePrompts = snap.prompts
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let fullS: [String: Double]
        if !existingFull.isEmpty {
            fullS = existingFull
        } else if let activeModel, !activePrompts.isEmpty, !cancellation.isCancelled {
            fullS = affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation)
        } else {
            fullS = [:]
        }

        let hasRichPrompts = activePrompts["architecture_facade"] != nil && activeModel != nil && !fullS.isEmpty && !cancellation.isCancelled
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
        let isMobileSingleModel = ProcessInfo.processInfo.physicalMemory < 16_000_000_000
        if hasRichPrompts, let activeModel, !isThermalConstrained, !cancellation.isSoftDeadlineReached {
            coreS = autoreleasepool {
                affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
                           topLeftRoI: CGRect(x: 0.16, y: 0.16, width: 0.68, height: 0.68), cropScale: .scaleFill)
            }
            // On mobile devices, CompositionRaster already extracts 64x64 pixel-exact sky/wall/pillar/floor
            // avoidance in <0.3ms; skipping 4 redundant peripheral SigLIP ViT passes cuts latency & ANE heat ~3x.
            if !isMobileSingleModel && fullClutterSignal >= 0.015 && !cancellation.isSoftDeadlineReached && cancellation.remainingSoftBudget > 2.2 {
                leftS = affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
                                   topLeftRoI: CGRect(x: 0.0, y: 0.06, width: 0.52, height: 0.88), cropScale: .scaleFill)
                rightS = !cancellation.isSoftDeadlineReached
                    ? affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
                                 topLeftRoI: CGRect(x: 0.48, y: 0.06, width: 0.52, height: 0.88), cropScale: .scaleFill)
                    : [:]
                topS = !cancellation.isSoftDeadlineReached
                    ? affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
                                 topLeftRoI: CGRect(x: 0.06, y: 0.0, width: 0.88, height: 0.42), cropScale: .scaleFill)
                    : [:]
                botS = !cancellation.isSoftDeadlineReached
                    ? affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
                                 topLeftRoI: CGRect(x: 0.06, y: 0.58, width: 0.88, height: 0.42), cropScale: .scaleFill)
                    : [:]
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
            .portrait: max(Self.sc(comb, "person"), max(Self.sc(comb, "portrait_closeup"), Self.sc(comb, "person_scenery") * 0.95)),
            .group: Self.sc(comb, "group"),
            .animal: max(Self.sc(comb, "animal"), Self.sc(comb, "pet_portrait")),
            .food: max(Self.sc(comb, "food"), max(Self.sc(comb, "food_spread"), Self.sc(comb, "coffee_drink"))),
            .flower: max(Self.sc(comb, "flower"), Self.sc(comb, "flower_closeup")),
            .streetLeading: max(Self.sc(comb, "street_perspective", fallback: "street"), max(Self.sc(comb, "street"), Self.sc(comb, "night_city"))) +
                (Self.sc(fullS, "street_perspective") > 0.03 ? 0.015 : 0.0),
            .architecture: max(Self.sc(comb, "architecture_facade", fallback: "building"), max(Self.sc(comb, "building"), Self.sc(comb, "architecture_symmetry"))),
            .landscapeSky: 0.55 * max(Self.sc(comb, "horizon_sky", fallback: "landscape"), Self.sc(comb, "dramatic_clouds")) +
                0.45 * max(Self.sc(comb, "sky"), max(Self.sc(comb, "landscape"), max(Self.sc(comb, "sunset"), max(Self.sc(comb, "golden_hour"), max(Self.sc(comb, "mountain_vista"), Self.sc(comb, "ocean_beach")))))),
            .foliageGarden: max(Self.sc(comb, "foliage_garden", fallback: "foliage"), max(Self.sc(comb, "foliage"), Self.sc(comb, "forest_woods"))),
            .deskWorkspace: Self.sc(comb, "desk_workspace"),
            .tabletopEnsemble: Self.sc(comb, "tabletop_ensemble"),
            .indoorRoom: max(Self.sc(comb, "indoor_furnished"), Self.sc(comb, "indoor_living_room")),
            .apertureView: Self.sc(comb, "frame_aperture")
        ]

        let hasHuman = candidates.contains {
            ($0.category == .human || $0.category == .face) && $0.confidence >= 0.48 && $0.areaRatio >= 0.04
        }
        let hasAnimal = candidates.contains { $0.category == .animal && $0.confidence >= 0.45 }
        let deskObjs = candidates.filter {
            !$0.isAttentionRegion && $0.confidence >= 0.25 &&
            Self.deskTabletopLabelTokens.contains($0.label.lowercased())
        }.sorted { $0.prominenceScore > $1.prominenceScore }
        let hasSingleDominantForeground = candidates.contains {
            !$0.isAttentionRegion && $0.category == .foregroundObject &&
            $0.confidence >= 0.32 && $0.areaRatio >= 0.015 &&
            hypot(Double($0.center.x - 0.50), Double($0.center.y - 0.48)) <= 0.28
        }
        if hasHuman { roleScores[.portrait, default: 0.0] += 0.05 }
        if hasAnimal { roleScores[.animal, default: 0.0] += 0.05 }
        if deskObjs.count >= 2 {
            let isBalancedEnsemble = deskObjs[0].prominenceScore < deskObjs[1].prominenceScore * 1.42
            roleScores[.tabletopEnsemble, default: 0.0] += isBalancedEnsemble ? 0.014 : 0.006
            if deskObjs.contains(where: { $0.confidence >= 0.28 && Self.deskDisplayLabelTokens.contains($0.label.lowercased()) }) {
                roleScores[.deskWorkspace, default: 0.0] += isBalancedEnsemble ? 0.016 : 0.007
            }
        }

        var bestRole: SemanticCompositionRole = roleScores.max(by: { $0.value < $1.value })?.key ?? .general
        if bestRole == .indoorRoom && hasSingleDominantForeground {
            let indoorScore = roleScores[.indoorRoom] ?? 0.0
            let nextBest = roleScores.filter { $0.key != .indoorRoom }.map(\.value).max() ?? 0.0
            if indoorScore - nextBest < 0.012 {
                bestRole = .general
            }
        }
        if comb.isEmpty || (roleScores[bestRole] ?? 0.0) <= 0.005 {
            if hasHuman { bestRole = candidates.contains(where: \.isGroup) ? .group : .portrait }
            else if hasAnimal { bestRole = .animal }
            else if deskObjs.count >= 2 && !hasSingleDominantForeground { bestRole = .tabletopEnsemble }
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
        var zoneBonuses: [String: Double] = [:]
        if !coreS.isEmpty { zoneBonuses["core"] = cropBonus(cropScores: coreS, origScores: fullS, role: bestRole) }
        if !leftS.isEmpty { zoneBonuses["left"] = cropBonus(cropScores: leftS, origScores: fullS, role: bestRole) }
        if !rightS.isEmpty { zoneBonuses["right"] = cropBonus(cropScores: rightS, origScores: fullS, role: bestRole) }
        if !topS.isEmpty { zoneBonuses["top"] = cropBonus(cropScores: topS, origScores: fullS, role: bestRole) }
        if !botS.isEmpty { zoneBonuses["bottom"] = cropBonus(cropScores: botS, origScores: fullS, role: bestRole) }

        return SpatialSemanticProfile(
            role: bestRole,
            avoid: EdgeAvoidanceHints(left: avoidLeft, right: avoidRight, top: avoidTop, bottom: avoidBottom),
            topIsSky: topIsSky,
            roleScores: roleScores,
            fullScores: fullS,
            zoneBonuses: zoneBonuses
        )
    }

    /// Zero-latency spatial-zone SigLIP scorer: propagates already-computed SigLIP zone semantics
    /// (`core`, `left`, `right`, `top`, `bottom`) across all 256 crop proposals in <0.5ms without
    /// keeping the 175MB SigLIP model resident during OpenWorld/Mask/SAMP/Charm inference.
    func scoreProposalsFromSpatialProfile(_ proposals: [CompositionProposal],
                                          profile: SpatialSemanticProfile) -> [CompositionProposal] {
        guard !profile.zoneBonuses.isEmpty, !proposals.isEmpty else { return proposals }
        let zones: [(key: String, rect: CGRect)] = [
            ("core", CGRect(x: 0.16, y: 0.16, width: 0.68, height: 0.68)),
            ("left", CGRect(x: 0.0, y: 0.06, width: 0.52, height: 0.88)),
            ("right", CGRect(x: 0.48, y: 0.06, width: 0.52, height: 0.88)),
            ("top", CGRect(x: 0.06, y: 0.0, width: 0.88, height: 0.42)),
            ("bottom", CGRect(x: 0.06, y: 0.58, width: 0.88, height: 0.42)),
        ]
        var updated = proposals
        for i in updated.indices where !updated[i].isUnchangedView {
            let corners = updated[i].sourceCorners
            let minX = max(0.0, min(1.0, corners.map(\.x).min() ?? 0.0))
            let maxX = max(0.0, min(1.0, corners.map(\.x).max() ?? 1.0))
            let minY = max(0.0, min(1.0, corners.map(\.y).min() ?? 0.0))
            let maxY = max(0.0, min(1.0, corners.map(\.y).max() ?? 1.0))
            let crop = CGRect(x: minX, y: minY, width: max(0.02, maxX - minX), height: max(0.02, maxY - minY))
            var wSum = 0.0
            var bSum = 0.0
            for z in zones {
                guard let zBonus = profile.zoneBonuses[z.key] else { continue }
                let inter = crop.intersection(z.rect)
                guard !inter.isNull, !inter.isEmpty else { continue }
                let ia = Double(inter.width * inter.height)
                let ua = Double(crop.width * crop.height + z.rect.width * z.rect.height) - ia
                let iou = ua > 1e-6 ? ia / ua : 0.0
                if iou > 0.12 {
                    wSum += iou
                    bSum += iou * zBonus
                }
            }
            if wSum > 0.05 {
                updated[i].semanticCropBonus = max(-0.18, min(0.26, bSum / wSum))
            }
        }
        return updated
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
        let snap = lock.withLock { (model, prompts) }
        guard let activeModel = snap.0, !snap.1.isEmpty, snap.1["clean_composition"] != nil,
              fullScores["clean_composition"] != nil, !cancellation.isCancelled, !proposals.isEmpty else {
            return proposals
        }
        let activePrompts = snap.1
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
                return 1
            }
            return thermal == .fair ? 2 : 3
        }()
        var chosen: [(idx: Int, rect: CGRect, bonus: Double)] = []
        for item in indexed {
            guard chosen.count < maxSemanticCrops, !cancellation.isCancelled else { break }
            let rect = cropRect(from: item.element.sourceCorners)
            if chosen.contains(where: { rectIoU($0.rect, rect) > 0.84 }) { continue }
            let cropScores = affinities(model: activeModel, prompts: activePrompts, handler: handler, cancellation: cancellation,
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
    private let analysisLock = NSRecursiveLock()
    /// Dedicated serial worker queue with `.workItem` autorelease draining so CoreML/Vision ObjC
    /// allocations never linger on the worker thread between runs and Swift Concurrency never blocks on `analysisLock`.
    private let analysisQueue = DispatchQueue(
        label: "com.alignstudio.localAI.analysis",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let renderer = CompositionImageRenderer()
    public init() {
        #if canImport(UIKit)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleReleaseAllModelCaches()
        }
        #endif
    }

    private func releaseAllModelCachesLocked() {
        autoreleasepool {
            SemanticCropRanker.shared.resetSessionAndRelease()
            _ = OpenWorldSubjectDetector.shared.releaseCachedModel()
            GAICCompositionModel.clearCache()
            PhotographicCompositionModel.clearCache()
            CharmPhotographicModel.clearCache()
            _ = renderer.releaseDepthModel()
            renderer.clearCaches()
        }
    }

    /// Thread-safe cache release: runs immediately if idle, or serializes cleanly behind any
    /// in-flight `analyzeComposition` on `analysisQueue` so external callers never race with
    /// active `SemanticCropRanker` or `CIContext` work.
    public func releaseAllModelCaches() {
        if analysisLock.try() {
            defer { analysisLock.unlock() }
            releaseAllModelCachesLocked()
        } else {
            scheduleReleaseAllModelCaches()
        }
    }

    /// Non-blocking serialized release on `analysisQueue` for app backgrounding / memory warning callers.
    public func scheduleReleaseAllModelCaches() {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisLock.lock()
            defer { self.analysisLock.unlock() }
            self.releaseAllModelCachesLocked()
        }
    }

    /// Non-blocking serialized pressure-only trim for manual UI cancellation while remaining in camera:
    /// keeps warm singletons intact when iOS Jetsam headroom is healthy, avoiding costly reload leaks.
    public func scheduleTrimCachesUnderPressure(
        minimumReserveBytes: Int? = nil
    ) {
        let targetReserve = minimumReserveBytes ?? CompositionMemoryBudget.postRunPhotoCaptureReserveBytes
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.analysisLock.lock()
            defer { self.analysisLock.unlock() }
            self.renderer.clearCaches()
            let evicted = CompositionMemoryBudget.trimForReserve(minimumBytes: targetReserve)
            if !evicted.isEmpty {
                CameraLogger.info(
                    "LocalAI cancel-trim: evicted=\(evicted.joined(separator: ",")) availMB=\(CompositionMemoryBudget.availableMB())",
                    category: .ai
                )
            }
        }
    }

    private struct SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    /// Non-blocking async entry point for UI/ViewModel callers. Runs on the dedicated serial worker queue
    /// and exits immediately if cancelled while queued behind an earlier request.
    func analyzeCompositionAsync(pixelBuffer: CVPixelBuffer, frame: TrackingFrameContext,
                                 pose: simd_quatd, allowedZooms: [CGFloat],
                                 preferences: [String: Double], requestID: UUID,
                                 lowMemoryBudget: Bool = false,
                                 cancellation: CompositionAnalysisCancellation,
                                 progress: @escaping @Sendable (String) -> Void = { _ in }) async -> LocalCompositionAnalysis? {
        let bufferBox = SendablePixelBuffer(value: pixelBuffer)
        return await withCheckedContinuation { continuation in
            analysisQueue.async {
                if cancellation.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                let result: LocalCompositionAnalysis? = autoreleasepool {
                    self.analyzeComposition(
                        pixelBuffer: bufferBox.value, frame: frame, pose: pose,
                        allowedZooms: allowedZooms, preferences: preferences,
                        requestID: requestID, lowMemoryBudget: lowMemoryBudget,
                        cancellation: cancellation, progress: progress
                    )
                }
                continuation.resume(returning: result)
            }
        }
    }

    func analyzeComposition(pixelBuffer: CVPixelBuffer, frame: TrackingFrameContext,
                            pose: simd_quatd, allowedZooms: [CGFloat],
                            preferences: [String: Double], requestID: UUID,
                            lowMemoryBudget: Bool = false,
                            cancellation: CompositionAnalysisCancellation,
                            progress: @Sendable (String) -> Void = { _ in }) -> LocalCompositionAnalysis? {
        guard !cancellation.isCancelled else { return nil }
        let lowMem = lowMemoryBudget
        let siglipRetainBytes = lowMemoryBudget ? 520_000_000 : CompositionMemoryBudget.siglipRetainThresholdBytes
        let postRunReserveBytes = lowMemoryBudget ? 420_000_000 : CompositionMemoryBudget.postRunPhotoCaptureReserveBytes
        analysisLock.lock()
        SemanticCropRanker.shared.beginAnalysis()
        defer {
            SemanticCropRanker.shared.finishSession(lowMemoryBudget: lowMemoryBudget)
            renderer.clearCaches()
            let evicted = CompositionMemoryBudget.trimForReserve(minimumBytes: postRunReserveBytes)
            if !evicted.isEmpty {
                CameraLogger.info(
                    "LocalAI post-run trim: evicted=\(evicted.joined(separator: ",")) availMB=\(CompositionMemoryBudget.availableMB())",
                    category: .ai
                )
            }
            analysisLock.unlock()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let startAvailMB = CompositionMemoryBudget.availableMB()
        CameraLogger.info(
            "LocalAI start [livePhotoLowMem=\(lowMem ? 1 : 0)]: availMB=\(startAvailMB)",
            category: .ai
        )
        func receipt(count: Int = 0, specialist: Bool = false, modern: Int = 0) -> CompositionAnalysisReceipt {
            CompositionAnalysisReceipt(requestID: requestID, sourceTimestamp: frame.timestamp,
                elapsed: max(0, ProcessInfo.processInfo.systemUptime - started),
                assessedFrames: count, usedSpecialist: specialist, modernAssessments: modern)
        }
        // Stage 0 runs inside its own tight autoreleasepool so 9 Vision requests + DepthAnythingV2 + YOLO
        // ObjC intermediates are immediately drained BEFORE OpenWorld/Mask/GAIC/SAMP/Charm allocate.
        let maybeOutput: NeuralAnalysisOutput? = autoreleasepool {
            guard !cancellation.isCancelled else { return nil }
            return analyzeCapturedFrame(pixelBuffer: pixelBuffer, orientation: frame.orientation,
                                        cancellation: cancellation)
        }
        guard !cancellation.isCancelled, let output = maybeOutput else { return nil }
        let tAfterDetect = ProcessInfo.processInfo.systemUptime
        // Choose identity intelligently using spatial SigLIP semantics, pixel clutter/roof/VP maps, and filtered detectors.
        guard let raster = output.compositionRaster else {
            let basicHero = output.allCandidates.first ?? NeuralSubjectCandidate(
                boundingBox: CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.55),
                category: .general, confidence: 0.70, label: "Khung cảnh", prominenceScore: 0.20
            )
            return LocalCompositionAnalysis(detection: output, choices: [], fallbackCandidates: [basicHero], receipt: receipt())
        }

        // MEMORY-SAFE STAGE ORDER:
        // 1) SigLIP is ALREADY loaded in RAM by `analyzeCapturedFrame`. Extract spatial semantic profile NOW...
        progress("Đang phân tích ngữ nghĩa & chiều sâu bố cục…")
        let spatialProfile: SemanticCropRanker.SpatialSemanticProfile = autoreleasepool {
            SemanticCropRanker.shared.spatialProfile(
                pixelBuffer: pixelBuffer,
                orientation: frame.orientation,
                fullScores: output.semanticAffinities,
                candidates: output.allCandidates,
                detectedScene: output.detectedScene,
                cancellation: cancellation
            )
        }
        let tAfterSigLIP = ProcessInfo.processInfo.systemUptime
        // 2) Keep SigLIP singleton warm across taps when Jetsam headroom is healthy (preventing
        //    ANE/CoreML reload leaks on Run #2/#3); evict immediately only when RAM is constrained.
        autoreleasepool {
            if !CompositionMemoryBudget.shouldRetainModelCache(minimumAvailableBytes: siglipRetainBytes) {
                _ = SemanticCropRanker.shared.releaseModelNow()
            }
            renderer.clearCaches()
        }
        guard !cancellation.isCancelled else { return nil }

        // 3) Run Open-World Photographic YOLOE-26m (curated classes) + iOS 17+ Foreground Instance Mask (512px)
        progress("Đang nhận diện vật thể mở rộng & tách nền tiền cảnh…")
        let openWorldDetections: [DirectorDetection] = autoreleasepool {
            OpenWorldSubjectDetector.shared.detect(
                pixelBuffer: pixelBuffer,
                orientation: frame.orientation,
                cancellation: cancellation,
                preferSequential: lowMemoryBudget || ProcessInfo.processInfo.physicalMemory < 16_000_000_000
            )
        }
        let tAfterOpenWorld = ProcessInfo.processInfo.systemUptime
        let directorDetections: [DirectorDetection] = {
            var list: [DirectorDetection] = output.allCandidates.map { c in
                let domain = CameraFramingDirector.classifyDomain(
                    label: c.label,
                    isHumanCategory: c.category == .human,
                    isFaceCategory: c.category == .face,
                    isAnimalCategory: c.category == .animal,
                    isGeneralCategory: c.category == .general
                )
                return DirectorDetection(
                    label: c.label,
                    localizedLabel: CameraFramingDirector.localizedName(for: c.label),
                    boundingBox: c.boundingBox,
                    anchor: c.eyePosition ?? c.trackingPoint,
                    confidence: Double(c.confidence),
                    domain: domain,
                    gazeX: Double(c.gaze),
                    isGroup: c.isGroup,
                    isAttentionOnly: c.isAttentionRegion,
                    companionBounds: c.companionBounds,
                    faceBounds: c.faceBounds
                )
            }
            for faceRect in output.allFaceRects {
                list.append(DirectorDetection(
                    label: "human face",
                    localizedLabel: "Khuôn mặt",
                    boundingBox: faceRect,
                    anchor: CGPoint(x: faceRect.midX, y: faceRect.minY + 0.42 * faceRect.height),
                    confidence: 0.90,
                    domain: .face
                ))
            }
            list.append(contentsOf: openWorldDetections)
            return list
        }()

        // Enrich candidates with OpenWorld detections without mutating locked analyzeCapturedFrame
        let enrichedCandidates: [NeuralSubjectCandidate] = {
            var merged = output.allCandidates
            for ow in openWorldDetections where ow.domain != .backgroundSurface && ow.domain != .wideNature && ow.confidence >= 0.24 {
                let duplicate = merged.contains { existing in
                    let inter = existing.boundingBox.intersection(ow.boundingBox)
                    guard !inter.isNull, !inter.isEmpty else { return false }
                    let ia = Double(inter.width * inter.height)
                    let ua = existing.areaRatio + ow.area - ia
                    return ua > 1e-6 && (ia / ua) > 0.55
                }
                if !duplicate {
                    let cat: NeuralSubjectCategory = {
                        switch ow.domain {
                        case .human: return .human
                        case .face: return .face
                        case .animal: return .animal
                        default: return .foregroundObject
                        }
                    }()
                    merged.append(NeuralSubjectCandidate(
                        boundingBox: ow.boundingBox,
                        category: cat,
                        confidence: Float(ow.confidence),
                        label: ow.localizedLabel,
                        prominenceScore: ow.confidence * sqrt(max(0.01, ow.area)),
                        trackingPoint: ow.anchor
                    ))
                }
            }
            return merged
        }()
        let meanLuma = raster.luminance.reduce(0.0, +) / Double(max(1, raster.luminance.count))
        let builtPlan = buildIntelligentSubjectPlan(
            output: output,
            raster: raster,
            spatialProfile: spatialProfile,
            isLowLuma: meanLuma < 0.35,
            candidates: enrichedCandidates
        )
        let hero = builtPlan.hero
        let sceneHints = builtPlan.sceneHints
        let extraProtectedBounds = builtPlan.protectedBounds
        let extraIncidentalBounds = builtPlan.incidentalBounds
        let allowsHeroAttentionCrop = builtPlan.allowsAttentionCrop

        var portraitBounds: CGRect?
        var poseProfile: AnatomicalPoseProfile?
        if hero.category == .human, !hero.isGroup {
            autoreleasepool {
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
        let secondarySubject: CompositionSubject? = builtPlan.secondaryHero.map { sec in
            let secAnchor: CGPoint = {
                if let eye = sec.eyePosition { return eye }
                if let tp = sec.trackingPoint {
                    return CGPoint(x: min(sec.boundingBox.maxX, max(sec.boundingBox.minX, tp.x)),
                                   y: min(sec.boundingBox.maxY, max(sec.boundingBox.minY, tp.y)))
                }
                return sec.center
            }()
            return CompositionSubject(
                index: 1, bounds: sec.boundingBox, anchor: secAnchor,
                kind: builtPlan.secondarySubjectKind,
                confidence: Double(sec.confidence), importance: sec.prominenceScore, gaze: sec.gaze,
                allowsAttentionCrop: sec.isAttentionRegion, verticalGaze: sec.verticalGaze,
                shotScaleBias: output.semanticGuidance.shotScaleBias,
                contextPreservationWeight: output.semanticGuidance.contextPreservationWeight,
                isAttentionOnly: sec.isAttentionRegion
            )
        }
        let secondaryIntents: [LocalCompositionIntent] = builtPlan.secondaryHero.map { sec in
            refinedIntents(base: compositionIntents(output, hero: sec), hero: sec, role: sceneHints.role)
        } ?? []
        func proposals(refining seeds: [CompositionProposal] = []) -> [CompositionProposal] {
            let primarySeeds = seeds.filter { $0.subjectIndex == 0 }
            let secondarySeeds = seeds.filter { $0.subjectIndex == 1 }
            var combined: [CompositionProposal] = []
            if seeds.isEmpty || !primarySeeds.isEmpty {
                combined.append(contentsOf: CompositionPlanner.photographicProposals(subject: subject, intents: intents,
                    portraitBounds: portraitBounds, raster: raster, calibration: frame.calibration,
                    currentZoom: CGFloat(frame.displayZoom), allowedZooms: allowedZooms,
                    protectedBounds: resolvedProtected,
                    incidentalBounds: arbitratedIncidentals,
                    proposalLimit: seeds.isEmpty ? seedLimit : refineLimit, refining: primarySeeds,
                    poseProfile: poseProfile,
                    sceneHints: sceneHints,
                    isCancelled: { cancellation.isCancelled }))
            }
            if let secSub = secondarySubject, let secHero = builtPlan.secondaryHero,
               !secondaryIntents.isEmpty, (seeds.isEmpty || !secondarySeeds.isEmpty) {
                let secLimit = seeds.isEmpty ? max(8, seedLimit / 3) : max(4, refineLimit / 3)
                let secProtected = secHero.companionBounds.isEmpty ? [secHero.boundingBox] : secHero.companionBounds
                let secProps = CompositionPlanner.photographicProposals(subject: secSub, intents: secondaryIntents,
                    portraitBounds: nil, raster: raster, calibration: frame.calibration,
                    currentZoom: CGFloat(frame.displayZoom), allowedZooms: allowedZooms,
                    protectedBounds: secProtected,
                    incidentalBounds: arbitratedIncidentals,
                    proposalLimit: secLimit, refining: secondarySeeds,
                    poseProfile: nil,
                    sceneHints: sceneHints,
                    isCancelled: { cancellation.isCancelled })
                for sp in secProps where !sp.isUnchangedView {
                    combined.append(sp)
                }
            }
            return combined
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
        // Zero-latency spatial-zone SigLIP scoring across all 256 proposals (<0.5ms, zero extra RAM)
        if !constrained && !initialProposals.isEmpty {
            initialProposals = SemanticCropRanker.shared.scoreProposalsFromSpatialProfile(
                initialProposals,
                profile: spatialProfile
            )
        }
        // Trim cached models strictly if headroom fell below search reserve; keep all warm when healthy.
        autoreleasepool {
            renderer.clearCaches()
            _ = CompositionMemoryBudget.trimForReserve(minimumBytes: lowMemoryBudget ? 380_000_000 : 300_000_000)
        }
        progress("Đang đánh giá bố cục bằng mô hình trên máy…")
        let orientedCI = CIImage(cvPixelBuffer: pixelBuffer).oriented(frame.orientation)
        let tBeforeSearch = ProcessInfo.processInfo.systemUptime
        let searchResult: CompositionAestheticSearch.Result? = autoreleasepool {
            let search = CompositionAestheticSearch(renderer: renderer)
            return search.run(proposals: initialProposals,
                image: orientedCI,
                aspect: frame.calibration.aspect, preferences: preferences,
                raster: raster,
                modelURL: sampModelURL,
                gaicModelURL: gaicModelURL,
                aestheticModelURL: constrained ? nil : Bundle.main.url(forResource: "CharmAesthetics", withExtension: "mlmodelc"),
                positionURL: constrained ? nil : Bundle.main.url(forResource: "CharmPositionEmbedding", withExtension: "bin"),
                requiresModernModel: false,
                sceneHints: sceneHints,
                lowMemoryBudget: lowMem,
                cancellation: cancellation, progress: progress, refine: { proposals(refining: $0) })
        }
        guard let result = searchResult else {
            renderer.clearCaches()
            return nil
        }
        let tAfterSearch = ProcessInfo.processInfo.systemUptime

        // Solve true 3D physical camera pan/tilt + smart optical zoom using Free-Form Neural-Guided Director:
        // fuses OpenWorld YOLOE + DepthAnythingV2 + iOS 17 Foreground Mask + SigLIP clutter avoidance +
        // ALL 256 GAIC boxes + SAMP/Charm aesthetic consensus (no Golden-Ratio straitjacket).
        let directorDecision = CameraFramingDirector.direct(
            detections: directorDetections,
            raster: raster,
            sceneHints: sceneHints,
            semanticAffinities: spatialProfile.fullScores.isEmpty ? output.semanticAffinities : spatialProfile.fullScores,
            neuralProposals: result.allEvaluatedViews.map(\.proposal),
            gaicProposals: result.allGAICProposals,
            incidentalBounds: arbitratedIncidentals,
            calibration: frame.calibration,
            pose: pose,
            currentZoom: CGFloat(frame.displayZoom),
            allowedZooms: allowedZooms,
            portraitBounds: portraitBounds,
            poseProfile: poseProfile
        )
        let tAfterDirector = ProcessInfo.processInfo.systemUptime
        let endAvailMB = CompositionMemoryBudget.availableMB()
        CameraLogger.info(
            String(
                format: "LocalAI timings [lowMem=%d]: availMB=%d->%d detect=%.0fms siglip=%.0fms openWorld=%.0fms proposals=%.0fms search=%.0fms director=%.0fms total=%.0fms (hero=%@, style=%@)",
                lowMem ? 1 : 0,
                startAvailMB,
                endAvailMB,
                (tAfterDetect - started) * 1000.0,
                (tAfterSigLIP - tAfterDetect) * 1000.0,
                (tAfterOpenWorld - tAfterSigLIP) * 1000.0,
                (tBeforeSearch - tAfterOpenWorld) * 1000.0,
                (tAfterSearch - tBeforeSearch) * 1000.0,
                (tAfterDirector - tAfterSearch) * 1000.0,
                (tAfterDirector - started) * 1000.0,
                directorDecision.heroLabel,
                directorDecision.compositionStyle.rawValue
            ),
            category: .ai
        )
        let directorPreviewCorners: [CGPoint] = {
            let relZoom = max(1.0, Double(directorDecision.recommendedZoom) / max(0.5, frame.displayZoom))
            let half = 0.5 / relZoom
            let cx = max(half, min(1.0 - half, Double(directorDecision.aimPointInSource.x)))
            let cy = max(half, min(1.0 - half, Double(directorDecision.aimPointInSource.y)))
            return [
                CGPoint(x: cx - half, y: cy - half),
                CGPoint(x: cx + half, y: cy - half),
                CGPoint(x: cx + half, y: cy + half),
                CGPoint(x: cx - half, y: cy + half),
            ]
        }()
        let directorPreviewImage: CGImage? = autoreleasepool {
            renderer.preview(
                image: orientedCI,
                corners: directorPreviewCorners,
                aspect: frame.calibration.aspect
            ) ?? result.views.first?.image
        }
        renderer.clearCaches()

        let primaryHero = hero
        let neuralChoices = result.views.map { view -> LocalCompositionChoice in
            let proposal = view.proposal
            let hero = (proposal.subjectIndex == 1 ? (builtPlan.secondaryHero ?? primaryHero) : primaryHero)
            let activePortraitBounds = (proposal.subjectIndex == 1 ? nil : portraitBounds)
            let activeAnchor = (proposal.subjectIndex == 1 ? (secondarySubject?.anchor ?? hero.center) : subject.anchor)
            let activeAllowsAtt = (proposal.subjectIndex == 1 ? (secondarySubject?.allowsAttentionCrop ?? false) : subject.allowsAttentionCrop)
            let explanationText = sceneHints.hasRichGuidance
                ? proposal.explanation
                : (proposal.explanation + (result.usedSpecialist ? " Đã tối ưu bố cục bằng AI thẩm mỹ." : " Bố cục tự nhiên."))
            let plan = LocalFramingPlan(subjectPoint: hero.trackingPoint ?? proposal.subjectPoint, subjectRect: hero.boundingBox,
                cropProtectionRect: CompositionCropProtection.bounds(body: hero.boundingBox,
                    portrait: activePortraitBounds, intent: proposal.intent, anchor: activeAnchor,
                    attentionRegion: activeAllowsAtt),
                aimPointInSource: proposal.aimPoint, aimWorldRay: pose.act(proposal.rotation.act(SIMD3(0, 0, -1))),
                zoom: proposal.zoom, confidence: proposal.evidenceConfidence,
                minimumAutoselectConfidence: (output.detectedScene == .night ? 0.28 :
                    (LocalAutoselectCalibration.threshold(scene: output.detectedScene, category: hero.category) ?? 0.32)),
                intent: proposal.intent, score: proposal.score, explanation: explanationText,
                usesCenter: proposal.usesCenter, preferenceKey: proposal.preferenceKey,
                recommendedEVBias: proposal.recommendedEVBias)
            return LocalCompositionChoice(candidate: hero, plan: plan, preview: view.image,
                                          preservesOriginalFrame: proposal.isUnchangedView)
        }

        let directedCategory: NeuralSubjectCategory = {
            switch directorDecision.role {
            case .portrait, .environmentalPortrait, .group: return .human
            case .animal: return .animal
            case .skyLandscape, .scene: return .general
            default: return .foregroundObject
            }
        }()
        let directedHero = NeuralSubjectCandidate(
            boundingBox: directorDecision.heroBounds,
            category: directedCategory,
            confidence: Float(directorDecision.confidence),
            label: directorDecision.heroLocalizedLabel,
            prominenceScore: directorDecision.confidence,
            eyePosition: (directedCategory == .human) ? directorDecision.heroAnchor : nil,
            trackingPoint: directorDecision.heroAnchor,
            isGroup: directorDecision.role == .group
        )
        var choices: [LocalCompositionChoice] = []
        if let dirImage = directorPreviewImage {
            let topNeuralScore = result.views.first?.proposal.score ?? 0.85
            let mappedRule: CompositionRule = {
                switch directorDecision.compositionStyle {
                case .centerFocus, .elevatedCenter, .groundedCenter, .symmetry, .mirrorHorizon:
                    return .centerSymmetry
                case .negativeSpace, .openHeadroom:
                    return .negativeSpace
                case .lookingRoom:
                    return .lookingRoom
                case .leadingLines:
                    return .leadingLines
                case .diagonalDynamic:
                    return .diagonal
                case .frameInFrame:
                    return .frameInFrame
                case .ruleOfThirds, .lowHorizonSky, .highHorizonGround:
                    return .ruleOfThirds
                case .keepNatural, .neuralFreeform, .subtleBalance, .ultraWide:
                    return .dynamicAI
                }
            }()
            let directedCropProtection = CompositionCropProtection.bounds(
                body: directorDecision.heroBounds,
                portrait: (directedCategory == .human && directorDecision.role == .portrait) ? portraitBounds : nil,
                intent: directorDecision.role.intent,
                anchor: directorDecision.heroAnchor,
                attentionRegion: false
            )
            let directedPlan = LocalFramingPlan(
                subjectPoint: directorDecision.heroAnchor,
                subjectRect: directorDecision.heroBounds,
                cropProtectionRect: directedCropProtection,
                aimPointInSource: directorDecision.aimPointInSource,
                aimWorldRay: directorDecision.aimWorldRay,
                zoom: directorDecision.recommendedZoom,
                confidence: directorDecision.confidence,
                minimumAutoselectConfidence: output.detectedScene == .night ? 0.28 : 0.32,
                intent: directorDecision.role.intent,
                score: topNeuralScore + 0.05,
                explanation: directorDecision.explanation,
                usesCenter: directorDecision.usesCenter,
                preferenceKey: "director|\(directorDecision.role.rawValue)|\(Int((directorDecision.recommendedZoom * 10).rounded()))",
                recommendedEVBias: result.views.first?.proposal.recommendedEVBias ?? 0.0,
                compositionRule: mappedRule
            )
            choices.append(LocalCompositionChoice(
                candidate: directedHero,
                plan: directedPlan,
                preview: dirImage,
                preservesOriginalFrame: directorDecision.preservesOriginalFrame
            ))
        }
        for alt in neuralChoices where choices.count < 3 {
            let duplicate = choices.contains { existing in
                hypot(Double(existing.plan.aimPointInSource.x - alt.plan.aimPointInSource.x),
                      Double(existing.plan.aimPointInSource.y - alt.plan.aimPointInSource.y)) < 0.04 &&
                abs(Double(existing.plan.zoom - alt.plan.zoom)) < 0.08
            }
            if !duplicate { choices.append(alt) }
        }
        let effectiveCandidates = [directedHero] + enrichedCandidates.filter { $0.boundingBox != directedHero.boundingBox }
        return LocalCompositionAnalysis(detection: output, choices: choices, fallbackCandidates: effectiveCandidates,
            assessedCompositionCount: result.assessedCount, usedCompositionModel: result.usedSpecialist,
            canAutoselectComposition: result.canAutoselect || directorDecision.confidence >= 0.38,
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
        var secondaryHero: NeuralSubjectCandidate? = nil
        var secondarySubjectKind: CompositionSubjectKind = .object
    }

    private static let deskEquipmentTokens: Set<String> = [
        "tv", "tivi", "laptop", "keyboard", "bàn phím"
    ]

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
                                             isLowLuma: Bool,
                                             candidates: [NeuralSubjectCandidate]? = nil) -> IntelligentSubjectPlan {
        let sourceCandidates = candidates ?? output.allCandidates
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
        if let groupHero = sourceCandidates.first(where: { $0.isGroup && !$0.isAttentionRegion }) {
            sceneHints.reasonSubject = "Nhận diện \(groupHero.label)"
            return IntelligentSubjectPlan(
                hero: groupHero, subjectKind: .group, protectedBounds: groupHero.companionBounds,
                incidentalBounds: [], sceneHints: sceneHints, allowsAttentionCrop: false, isFallbackScenery: false
            )
        }

        var validYolo: [NeuralSubjectCandidate] = []
        var incidentalSlivers: [CGRect] = []
        for c in sourceCandidates where !c.isAttentionRegion {
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

        func aimDistance(_ c: NeuralSubjectCandidate) -> Double {
            hypot(Double(c.center.x - 0.50), Double(c.center.y - 0.48))
        }
        func isPeripheralClippedEquipment(_ c: NeuralSubjectCandidate) -> Bool {
            let lower = c.label.lowercased()
            let b = c.boundingBox
            let touchesEdge = b.minX <= 0.025 || b.maxX >= 0.975 || b.minY <= 0.025 || b.maxY >= 0.975
            guard touchesEdge else { return false }
            if Self.deskEquipmentTokens.contains(lower) {
                return aimDistance(c) > 0.18 || c.areaRatio > 0.22
            }
            return (b.minX <= 0.012 || b.maxX >= 0.988) && aimDistance(c) > 0.28 && c.areaRatio > 0.28
        }
        func heroSelectionScore(_ c: NeuralSubjectCandidate) -> Double {
            let rawScore = Double(c.confidence) * sqrt(max(0.002, c.areaRatio))
            let baseScore = max(rawScore, c.prominenceScore * 0.82)
            let dAim = aimDistance(c)
            let aimFactor = 0.72 + 0.48 * exp(-(dAim * dAim) / (2.0 * 0.26 * 0.26))
            let dStats = raster.depthStats(in: c.boundingBox)
            let depthFactor = 0.80 + 0.32 * dStats.meanDepth + 0.14 * dStats.depthContrast
            let clutterFactor = max(0.35, 1.0 - 0.50 * sceneHints.clutterDensity(in: c.boundingBox, side: raster.side))
            let b = c.boundingBox
            let touchesBorder = b.minX <= 0.018 || b.maxX >= 0.982 || b.minY <= 0.018 || b.maxY >= 0.982
            let borderFactor: Double
            if isPeripheralClippedEquipment(c) {
                borderFactor = 0.52
            } else if touchesBorder && c.category == .foregroundObject && dAim > 0.24 {
                borderFactor = 0.76
            } else {
                borderFactor = 1.0
            }
            let categoryFactor: Double
            if c.category == .human || c.category == .face {
                categoryFactor = (!c.faceBounds.isEmpty || c.eyePosition != nil) ? 1.38 : 1.18
            } else if c.category == .animal {
                categoryFactor = 1.15
            } else {
                categoryFactor = 1.0
            }
            return baseScore * aimFactor * depthFactor * clutterFactor * borderFactor * categoryFactor
        }

        // Case A: Clear Human / Face / Animal hero
        let humanAnimal = validYolo.filter {
            ($0.category == .human || $0.category == .face || $0.category == .animal) &&
            ($0.areaRatio >= 0.012 || ($0.category == .face && $0.confidence >= 0.54 && $0.areaRatio >= 0.004)) &&
            !($0.boundingBox.maxY >= 0.96 && $0.boundingBox.height < 0.24)
        }.sorted { heroSelectionScore($0) > heroSelectionScore($1) }
        if let topHA = humanAnimal.first {
            let runnerUpHA = humanAnimal.dropFirst().first
            let topObject = validYolo.filter { $0.category == .foregroundObject && !isPeripheralClippedEquipment($0) }
                .max(by: { heroSelectionScore($0) < heroSelectionScore($1) })
            let secCandidate = runnerUpHA ?? topObject
            sceneHints.reasonSubject = "Nhận diện \(topHA.label) nổi bật"
            return IntelligentSubjectPlan(
                hero: topHA, subjectKind: kind(topHA.category), protectedBounds: [],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: false, isFallbackScenery: false,
                secondaryHero: secCandidate,
                secondarySubjectKind: secCandidate.map { kind($0.category) } ?? .object
            )
        }

        let deskItems = validYolo.filter { Self.deskTabletopTokens.contains($0.label.lowercased()) }
        let rankedObjects = validYolo.filter { $0.category == .foregroundObject }
            .sorted { heroSelectionScore($0) > heroSelectionScore($1) }

        func buildCohesiveTabletopEnsemble() -> (hero: NeuralSubjectCandidate, protected: [CGRect], reason: String)? {
            let focalDeskItems = deskItems.filter { !isPeripheralClippedEquipment($0) }
            let chosenDeskItems = focalDeskItems.isEmpty ? deskItems : focalDeskItems
            var coreItems: [CGRect] = []
            for item in chosenDeskItems.sorted(by: { heroSelectionScore($0) > heroSelectionScore($1) }) where !isEdgeSliver(item.boundingBox) {
                if coreItems.isEmpty {
                    coreItems.append(item.boundingBox)
                } else {
                    let tentative = unionRects(coreItems + [item.boundingBox])
                    if tentative.width <= 0.84 && tentative.height <= 0.82 {
                        coreItems.append(item.boundingBox)
                    }
                }
            }
            for cl in cleanClusters.prefix(2) {
                let cb = cl.bounds
                if sceneHints.clutterDensity(in: cb, side: raster.side) < 0.34 && !isEdgeSliver(cb) {
                    if coreItems.isEmpty {
                        coreItems.append(cb)
                    } else {
                        let cu = unionRects(coreItems)
                        let tentative = cu.union(cb)
                        if abs(cb.midY - cu.midY) < 0.30, tentative.width <= 0.82, tentative.height <= 0.80,
                           let topScore = cleanClusters.first?.score, cl.score >= 0.18 * topScore {
                            coreItems.append(cb)
                        }
                    }
                }
            }
            guard !coreItems.isEmpty else { return nil }
            let groupBox = unionRects(coreItems)
            var cxSum = 0.0, cySum = 0.0, wSum = 0.0
            for b in coreItems {
                let wt = sqrt(max(0.01, Double(b.width * b.height)))
                cxSum += Double(b.midX) * wt
                cySum += Double(b.midY) * wt
                wSum += wt
            }
            let anchor = CGPoint(x: cxSum / max(1e-6, wSum), y: cySum / max(1e-6, wSum))
            let names = Array(Set(chosenDeskItems.map(\.label))).sorted()
            let baseLbl = role == .deskWorkspace ? "Góc bàn học" : "Cụm đồ vật"
            let desc = names.isEmpty ? "đồ vật trên bàn" : names.prefix(3).joined(separator: " + ")
            let synthHero = NeuralSubjectCandidate(
                boundingBox: groupBox, category: .foregroundObject, confidence: 0.85,
                label: baseLbl, prominenceScore: 0.85, trackingPoint: anchor
            )
            return (synthHero, coreItems, "\(baseLbl) (\(desc))")
        }

        // Case A2: Dominant Foreground YOLO Object (promoted before room/tabletop merge when clearly aimed/isolated)
        if let topObj = rankedObjects.first,
           !isPeripheralClippedEquipment(topObj),
           topObj.confidence >= (isLowLuma ? 0.24 : 0.29),
           topObj.areaRatio >= 0.010, topObj.areaRatio <= 0.72 {
            let topScore = heroSelectionScore(topObj)
            let topAim = aimDistance(topObj)
            let topDepth = raster.depthStats(in: topObj.boundingBox).meanDepth
            let dominatesRunnerUp: Bool = {
                guard rankedObjects.count >= 2 else { return true }
                let second = rankedObjects[1]
                if isPeripheralClippedEquipment(second) { return true }
                let secondScore = heroSelectionScore(second)
                let secondAim = aimDistance(second)
                return topScore >= secondScore * 1.32 ||
                    (topAim <= 0.22 && topAim + 0.08 < secondAim)
            }()
            let overridesSceneRole: Bool = {
                if !role.isWideRole && role != .tabletopEnsemble && role != .deskWorkspace {
                    return true
                }
                if role == .tabletopEnsemble || role == .deskWorkspace {
                    return dominatesRunnerUp && (topAim <= 0.28 || topObj.areaRatio >= 0.035)
                }
                if role == .indoorRoom {
                    return topAim <= 0.34 && topDepth >= raster.focalDepthPlane - 0.12
                }
                return topObj.confidence >= 0.35 && topObj.areaRatio >= 0.018 &&
                    topAim <= 0.26 && topDepth >= raster.focalDepthPlane - 0.08
            }()
            if dominatesRunnerUp && overridesSceneRole {
                let secHero: NeuralSubjectCandidate? = {
                    if deskItems.count >= 2, let ensemble = buildCohesiveTabletopEnsemble(),
                       ensemble.hero.boundingBox != topObj.boundingBox {
                        return ensemble.hero
                    }
                    return rankedObjects.dropFirst().first(where: { !isPeripheralClippedEquipment($0) })
                }()
                sceneHints.reasonSubject = "Chủ thể \(topObj.label)"
                return IntelligentSubjectPlan(
                    hero: topObj, subjectKind: kind(topObj.category), protectedBounds: [],
                    incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                    allowsAttentionCrop: false, isFallbackScenery: false,
                    secondaryHero: secHero,
                    secondarySubjectKind: secHero.map { kind($0.category) } ?? .object
                )
            }
        }

        // Case B: Desk Workspace or Tabletop Ensemble -> Group cohesive tabletop items + clean clusters
        if role == .tabletopEnsemble || role == .deskWorkspace || deskItems.count >= 2 {
            if let ensemble = buildCohesiveTabletopEnsemble() {
                let singleBest = rankedObjects.first(where: { !isPeripheralClippedEquipment($0) }) ?? rankedObjects.first
                sceneHints.reasonSubject = ensemble.reason
                return IntelligentSubjectPlan(
                    hero: ensemble.hero, subjectKind: .object, protectedBounds: ensemble.protected,
                    incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                    allowsAttentionCrop: false, isFallbackScenery: false,
                    secondaryHero: singleBest,
                    secondarySubjectKind: singleBest.map { kind($0.category) } ?? .object
                )
            }
        }

        let bestObjectHypothesis = rankedObjects.first(where: { !isPeripheralClippedEquipment($0) }) ?? rankedObjects.first

        // Case C: Indoor Furnished Room
        if role == .indoorRoom {
            var furnBoxes = cleanClusters.filter {
                $0.area >= 0.04 && sceneHints.clutterDensity(in: $0.bounds, side: raster.side) < 0.35
            }.map(\.bounds)
            for y in validYolo where y.areaRatio >= 0.015 && !isEdgeSliver(y.boundingBox) && !isPeripheralClippedEquipment(y) {
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
                    allowsAttentionCrop: true, isFallbackScenery: false,
                    secondaryHero: bestObjectHypothesis,
                    secondarySubjectKind: bestObjectHypothesis.map { kind($0.category) } ?? .object
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
                allowsAttentionCrop: true, isFallbackScenery: false,
                secondaryHero: bestObjectHypothesis,
                secondarySubjectKind: bestObjectHypothesis.map { kind($0.category) } ?? .object
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
                allowsAttentionCrop: true, isFallbackScenery: false,
                secondaryHero: bestObjectHypothesis,
                secondarySubjectKind: bestObjectHypothesis.map { kind($0.category) } ?? .object
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
                allowsAttentionCrop: true, isFallbackScenery: false,
                secondaryHero: bestObjectHypothesis,
                secondarySubjectKind: bestObjectHypothesis.map { kind($0.category) } ?? .object
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
                allowsAttentionCrop: true, isFallbackScenery: false,
                secondaryHero: bestObjectHypothesis,
                secondarySubjectKind: bestObjectHypothesis.map { kind($0.category) } ?? .object
            )
        }

        // Case H: Single clear YOLO object (food, vehicle, vase, etc.)
        if let topObj = validYolo.max(by: { heroSelectionScore($0) < heroSelectionScore($1) }) {
            let runnerUp = rankedObjects.dropFirst().first(where: { !isPeripheralClippedEquipment($0) })
            sceneHints.reasonSubject = "Chủ thể \(topObj.label)"
            return IntelligentSubjectPlan(
                hero: topObj, subjectKind: kind(topObj.category), protectedBounds: [],
                incidentalBounds: incidentalSlivers, sceneHints: sceneHints,
                allowsAttentionCrop: false, isFallbackScenery: false,
                secondaryHero: runnerUp,
                secondarySubjectKind: runnerUp.map { kind($0.category) } ?? .object
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
