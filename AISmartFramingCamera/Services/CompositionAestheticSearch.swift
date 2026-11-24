import Foundation
import CoreGraphics
import CoreImage

/// Two passes over feasible camera views. The trained composition models (GAIC + SAMP-Net + Charm-PARA)
/// rank photographic layout and optical focal length while the planner enforces subject safety.
final class CompositionAestheticSearch {
    struct View {
        var proposal: CompositionProposal
        let image: CGImage
        let assessment: PhotographicCompositionModel.Assessment?
        var aesthetics: CharmPhotographicModel.Assessment? = nil
        let geometryScore: Double
    }

    struct Result {
        let views: [View]
        let assessedCount: Int
        let canAutoselect: Bool
        let usedSpecialist: Bool
        var modernAssessmentCount = 0
        var allEvaluatedViews: [View] = []
        var allGAICProposals: [CompositionProposal] = []
    }

    private let renderer: CompositionImageRenderer
    init(renderer: CompositionImageRenderer) { self.renderer = renderer }

    func run(proposals: [CompositionProposal], image: CIImage, aspect: Double,
             preferences: [String: Double], raster: CompositionRaster? = nil, modelURL: URL?,
             gaicModelURL: URL? = nil,
             aestheticModelURL: URL? = nil, positionURL: URL? = nil, requiresModernModel: Bool = false,
             sceneHints: CompositionSceneHints = .neutral,
             lowMemoryBudget: Bool = false,
             cancellation: CompositionAnalysisCancellation,
             progress: @Sendable (String) -> Void,
             refine: ([CompositionProposal]) -> [CompositionProposal]) -> Result? {
        guard !cancellation.isCancelled else { return nil }
        let singleModelResidency = lowMemoryBudget || ProcessInfo.processInfo.physicalMemory < 16_000_000_000
        let resolvedGaicURL = gaicModelURL ?? GAICCompositionModel.defaultModelURL(near: modelURL)
        let sourceBaseZoom = max(0.5, Double(proposals.first(where: \.isUnchangedView)?.zoom ?? proposals.first?.zoom ?? 1.0))
        var workingProposals = proposals
        var allGAICScoredProposals: [CompositionProposal] = []
        var usedGAIC = false
        var preScoredGAIC: [(corners: [CGPoint], gaic: Double)] = []
        if let resolvedGaicURL, !workingProposals.isEmpty {
            let evaluatedGAIC: [Double]? = autoreleasepool {
                guard let gaicModel = GAICCompositionModel.cachedOrLoad(url: resolvedGaicURL) else { return nil }
                return gaicModel.evaluate(image: image, proposals: workingProposals, cancellation: cancellation)
            }
            if let evaluatedGAIC, evaluatedGAIC.count == workingProposals.count {
                usedGAIC = true
                preScoredGAIC.reserveCapacity(workingProposals.count)
                for idx in workingProposals.indices {
                    workingProposals[idx].gaicScore = evaluatedGAIC[idx]
                    preScoredGAIC.append((corners: workingProposals[idx].sourceCorners, gaic: evaluatedGAIC[idx]))
                }
                allGAICScoredProposals = workingProposals
                progress("GAIC đã đánh giá \(workingProposals.count) khung hình đa tỷ lệ…")
            }
            // Free GAIC immediately before SAMP-Net loads so peak RAM stays flat under Live Photo.
            if singleModelResidency {
                GAICCompositionModel.clearCache()
            }
            CompositionImageRenderer.clearSharedCaches()
        }
        guard !cancellation.isCancelled else { return nil }

        // Shortlist diverse peak candidates for SAMP-Net to stay fast and memory-safe even when
        // GAIC is unavailable (preventing runaway 64+28 SAMP / 28 Charm stalls on mobile devices).
        let isHighMem = ProcessInfo.processInfo.physicalMemory >= 5_800_000_000
        let sampBudget = usedGAIC ? (isHighMem ? 6 : 4) : (isHighMem ? 10 : 6)
        if workingProposals.count > sampBudget {
            let rankedForSamp = workingProposals.map { candidate -> CompositionProposal in
                var copy = candidate
                let zoomRatio = Double(candidate.zoom) / sourceBaseZoom
                let justified = CompositionPreferencePolicy.isJustifiedZoom(candidate)
                let zoomReg = (justified ? 0.025 : 0.08) * max(0.0, zoomRatio - (justified ? 1.95 : 1.65))
                let field = min(1.35, max(0.0, candidate.continuousFieldScore))
                let gaic = min(1.0, max(0.0, candidate.gaicScore))
                let semBonus = min(0.35, max(-0.20, candidate.semanticCropBonus))
                if usedGAIC {
                    if sceneHints.hasRichGuidance {
                        copy.score = 0.62 * field + 0.38 * gaic + 0.24 * semBonus - zoomReg
                    } else {
                        copy.score = 0.52 * field + 0.48 * gaic + 0.20 * semBonus - zoomReg
                    }
                } else {
                    copy.score = field + 0.22 * semBonus - zoomReg
                }
                return copy
            }
            let baselineCandidate = workingProposals.first(where: \.isUnchangedView)
            var shortlist: [CompositionProposal] = []
            shortlist.reserveCapacity(sampBudget)
            if let baselineCandidate { shortlist.append(baselineCandidate) }
            // Preserve the strongest pure-geometry photography champions before balanced GAIC+geometry selection
            let geometryChampions = CompositionPlanner.diverse(workingProposals, limit: min(6, max(3, sampBudget / 3)),
                                                               raySeparation: 0.05, zoomSeparation: 0.10)
            for pick in geometryChampions where shortlist.count < sampBudget {
                if !shortlist.contains(where: { $0.sourceCorners == pick.sourceCorners && $0.zoom == pick.zoom }) {
                    shortlist.append(pick)
                }
            }
            let diversePicks = CompositionPlanner.diverse(rankedForSamp, limit: max(1, sampBudget - shortlist.count),
                                                          raySeparation: 0.045, zoomSeparation: 0.09)
            for pick in diversePicks where shortlist.count < sampBudget {
                if !shortlist.contains(where: { $0.sourceCorners == pick.sourceCorners && $0.zoom == pick.zoom }) {
                    shortlist.append(pick)
                }
            }
            for peak in rankedForSamp.sorted(by: { $0.score > $1.score }) where shortlist.count < sampBudget {
                if !shortlist.contains(where: { $0.sourceCorners == peak.sourceCorners && $0.zoom == peak.zoom }) {
                    shortlist.append(peak)
                }
            }
            // Restore original geometry continuousFieldScore in proposal.score so downstream geometryScore stays pure.
            workingProposals = shortlist.map { item in
                var restored = item
                restored.score = item.continuousFieldScore
                return restored
            }
        }

        func matchedGAICScore(for proposal: CompositionProposal) -> Double {
            guard usedGAIC, proposal.sourceCorners.count == 4, !preScoredGAIC.isEmpty else {
                return proposal.gaicScore
            }
            var bestDist = Double.infinity
            var bestScore = proposal.gaicScore
            for entry in preScoredGAIC where entry.corners.count == 4 {
                var dist = 0.0
                for c in 0..<4 {
                    dist += abs(Double(entry.corners[c].x - proposal.sourceCorners[c].x)) +
                        abs(Double(entry.corners[c].y - proposal.sourceCorners[c].y))
                }
                if dist < bestDist {
                    bestDist = dist
                    bestScore = entry.gaic
                }
            }
            return bestDist < 0.20 ? bestScore : proposal.gaicScore
        }

        let preScoredSemantic = proposals.filter { !$0.isUnchangedView && abs($0.semanticCropBonus) > 1e-4 }
        func matchedSemanticBonus(for proposal: CompositionProposal) -> Double {
            guard !proposal.isUnchangedView,
                  abs(proposal.semanticCropBonus) <= 1e-4,
                  !preScoredSemantic.isEmpty else {
                return proposal.semanticCropBonus
            }
            var bestDist = Double.infinity
            var bestBonus = 0.0
            for entry in preScoredSemantic {
                let dAim = hypot(Double(entry.aimPoint.x - proposal.aimPoint.x),
                                 Double(entry.aimPoint.y - proposal.aimPoint.y))
                let dZoom = abs(log(max(0.1, Double(entry.zoom / max(0.1, proposal.zoom)))))
                let dist = dAim + 0.35 * dZoom
                if dist < bestDist {
                    bestDist = dist
                    bestBonus = entry.semanticCropBonus
                }
            }
            return bestDist < 0.14 ? bestBonus : proposal.semanticCropBonus
        }

        // Stage B: SAMP-Net runs inside its own tight autoreleasepool so 100% of CoreML / ANE / ObjC
        // buffers from PhotographicCompositionModel are drained BEFORE Charm DINOv2-small allocates.
        var assessedCount = 0
        var hadSpecialist = false
        var evaluated: [View] = autoreleasepool {
            var specialist: PhotographicCompositionModel? = nil
            if let modelURL,
               (!cancellation.isSoftDeadlineReached || !usedGAIC),
               CompositionMemoryBudget.hasHeadroom(minimumBytes: 140_000_000) {
                specialist = PhotographicCompositionModel.cachedOrLoad(url: modelURL)
            }
            hadSpecialist = (specialist != nil)
            func evaluate(_ candidates: [CompositionProposal]) -> [View] {
                var result: [View] = []
                for (index, rawCandidate) in candidates.enumerated() {
                    if cancellation.isCancelled { return [] }
                    let skipHeavyModel = cancellation.isSoftDeadlineReached && (usedGAIC || assessedCount >= 2)
                    var candidate = rawCandidate
                    if usedGAIC && rawCandidate.gaicScore == 0.5 {
                        candidate.gaicScore = matchedGAICScore(for: rawCandidate)
                    }
                    if abs(candidate.semanticCropBonus) <= 1e-4 && sceneHints.hasRichGuidance {
                        candidate.semanticCropBonus = matchedSemanticBonus(for: candidate)
                    }
                    let item: View? = autoreleasepool {
                        guard let preview = renderer.preview(image: image, corners: candidate.sourceCorners, aspect: aspect) else { return nil }
                        let syncCrop = skipHeavyModel ? nil : raster.flatMap {
                            renderer.synchronizedSaliencyCrop(from: $0, corners: candidate.sourceCorners, side: 224)
                        }
                        let assessment = skipHeavyModel ? nil : specialist?.assess(preview, synchronizedSaliencyCrop: syncCrop, cancellation: cancellation)
                        var proposal = candidate
                        let zoomRatio = Double(candidate.zoom) / sourceBaseZoom
                        let justified = CompositionPreferencePolicy.isJustifiedZoom(candidate)
                        let zoomReg = usedGAIC ? (justified ? 0.025 : 0.08) * max(0.0, zoomRatio - (justified ? 1.95 : 1.65)) : 0.0
                        let oobPenalty = min(0.18, candidate.outOfBoundsFraction * 0.22)
                        let geomClamped = min(1.35, max(0.0, candidate.score))
                        let gaicClamped = min(1.0, max(0.0, candidate.gaicScore))
                        let semBonus = sceneHints.hasRichGuidance ? min(0.35, max(-0.20, candidate.semanticCropBonus)) : 0.0
                        if let assessment {
                            assessedCount += 1
                            let sampNorm = (assessment.mean - 1) / 4
                            if usedGAIC {
                                proposal.score = 0.44 * geomClamped +
                                    0.28 * sampNorm +
                                    0.28 * gaicClamped +
                                    0.24 * semBonus -
                                    zoomReg - oobPenalty
                            } else {
                                proposal.score = 0.42 * sampNorm +
                                    0.46 * candidate.score +
                                    0.12 * gaicClamped +
                                    0.24 * semBonus -
                                    oobPenalty
                            }
                        } else if usedGAIC {
                            proposal.score = 0.54 * geomClamped +
                                0.46 * gaicClamped +
                                0.24 * semBonus -
                                zoomReg - oobPenalty
                        } else {
                            proposal.score += 0.24 * semBonus
                            if !skipHeavyModel, let aesthetic = renderer.aestheticScore(image: preview, cancellation: cancellation) {
                                proposal.score += aesthetic * 0.075
                            }
                        }
                        // preferences bonus removed to ensure unbiased realtime evaluation
                        return View(proposal: proposal, image: preview, assessment: assessment,
                                    geometryScore: candidate.score)
                    }
                    guard let item else { continue }
                    result.append(item)
                    progress("Đang so sánh bố cục và zoom \(index + 1)/\(candidates.count)…")
                    if skipHeavyModel && result.count >= 4 { break }
                }
                return result
            }
            var passViews = evaluate(workingProposals)
            if cancellation.isCancelled {
                specialist = nil
                return []
            }
            if !usedGAIC && !cancellation.isSoftDeadlineReached && cancellation.remainingSoftBudget > 1.2 {
                let initial = CompositionPlanner.diverse(passViews.map(\.proposal), limit: usedGAIC ? 2 : 3)
                progress("Đang kiểm tra lại khung và các mức zoom lân cận…")
                let refinedSeeds = refine(initial)
                let cappedNeighbours = Array(refinedSeeds.prefix(usedGAIC ? 2 : 3))
                let neighbours = evaluate(cappedNeighbours)
                if usedGAIC {
                    let bestSeedScore = initial.map(\.score).max() ?? 0.0
                    for nb in neighbours where nb.proposal.score >= bestSeedScore - 0.008 {
                        passViews.append(nb)
                    }
                } else {
                    passViews.append(contentsOf: neighbours)
                }
            }
            specialist = nil
            return passViews
        }
        if singleModelResidency {
            PhotographicCompositionModel.clearCache()
        }
        CompositionImageRenderer.clearSharedCaches()
        guard !cancellation.isCancelled else { return nil }
        var usedSpecialist = !evaluated.isEmpty && assessedCount == evaluated.count
        if hadSpecialist && !usedSpecialist && !usedGAIC {
            // Never compare learned 1-to-5 ratings against unrelated fallback
            // scores if a request fails partway through the comparison without GAIC.
            for index in evaluated.indices { evaluated[index].proposal.score = evaluated[index].geometryScore }
        }
        var allEvaluated = evaluated
        var modernCount = 0
        if (requiresModernModel || aestheticModelURL != nil) &&
            (requiresModernModel || !cancellation.isSoftDeadlineReached) {
            var indices: [Int] = []
            func include(_ index: Int) { if !indices.contains(index) { indices.append(index) } }
            if let original = evaluated.firstIndex(where: { $0.proposal.isUnchangedView }) { include(original) }
            let leaders = CompositionPlanner.diverse(evaluated.map(\.proposal), limit: 4)
            for leader in leaders {
                if let index = evaluated.firstIndex(where: { $0.proposal.sourceCorners == leader.sourceCorners }) { include(index) }
            }
            let baseView = evaluated.first(where: { $0.proposal.isUnchangedView })
            let sourceZoom = baseView?.proposal.zoom ?? 1
            let baseArea = baseView.map { Double($0.proposal.expectedSubjectRect.width * $0.proposal.expectedSubjectRect.height) } ?? 1.0
            let maxAllowedZoom: CGFloat = baseArea < 0.08 ? 3.5 : (baseArea < 0.22 ? 3.0 : 2.2)
            let zoomed = evaluated.indices.filter { evaluated[$0].proposal.zoom > sourceZoom * 1.20 && evaluated[$0].proposal.zoom <= maxAllowedZoom }
                .sorted { evaluated[$0].proposal.score > evaluated[$1].proposal.score }
            for index in zoomed.prefix(3) { include(index) }
            let geomSorted = evaluated.indices.sorted { evaluated[$0].geometryScore > evaluated[$1].geometryScore }
            for index in geomSorted.prefix(2) { include(index) }
            let thermalOrLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ||
                ProcessInfo.processInfo.thermalState == .serious
            let isLowMemory = ProcessInfo.processInfo.physicalMemory < 5_800_000_000
            // Bounded Charm-PARA DINOv2 budget (never 28x even if GAIC is absent!)
            let budget = usedGAIC ? 2 : (thermalOrLowPower ? 2 : (isLowMemory ? 3 : 4))
            for index in evaluated.indices.sorted(by: { evaluated[$0].proposal.score > evaluated[$1].proposal.score }) {
                if indices.count >= budget { break }
                include(index)
            }
            var pool = indices.prefix(budget).map { evaluated[$0] }
            // Stage C: Charm DINOv2-small (MPSGraph) runs inside its own tight autoreleasepool so 100%
            // of Metal MPSGraph / CoreML ObjC objects drain immediately when Charm completes.
            let charmCancelled: Bool = autoreleasepool {
                var modern: CharmPhotographicModel?
                if let aestheticModelURL, let positionURL,
                   (requiresModernModel || CompositionMemoryBudget.hasHeadroom(minimumBytes: 150_000_000)) {
                    modern = CharmPhotographicModel.cachedOrLoad(url: aestheticModelURL, positionURL: positionURL)
                } else { modern = nil }
                if let activeModern = modern {
                    for index in pool.indices {
                        guard !cancellation.isCancelled else {
                            modern = nil
                            return true
                        }
                        if !requiresModernModel && cancellation.isSoftDeadlineReached && (modernCount >= 2 || usedGAIC) {
                            break
                        }
                        guard ProcessInfo.processInfo.thermalState != .critical else {
                            progress("Nhiệt độ máy cao. Chuyển sang chọn bố cục thủ công…")
                            break
                        }
                        let assessment = autoreleasepool {
                            activeModern.assess(pool[index].image, cancellation: cancellation)
                        }
                        pool[index].aesthetics = assessment
                        if let composition = pool[index].assessment, let aesthetics = pool[index].aesthetics,
                           let score = CompositionPreferencePolicy.score(
                               composition: composition.mean,
                               aesthetics: aesthetics.mean,
                               geometry: pool[index].geometryScore,
                               gaic: pool[index].proposal.gaicScore,
                               outOfBoundsFraction: pool[index].proposal.outOfBoundsFraction,
                               hasLearnedGAIC: usedGAIC,
                               zoomRatio: Double(pool[index].proposal.zoom) / sourceBaseZoom,
                               justifiedZoom: CompositionPreferencePolicy.isJustifiedZoom(pool[index].proposal),
                               semanticCropBonus: sceneHints.hasRichGuidance ? pool[index].proposal.semanticCropBonus : 0.0
                           ) {
                            pool[index].proposal.score = score
                            modernCount += 1
                        } else if let aesthetics = pool[index].aesthetics, usedGAIC {
                            let aesthNorm = (aesthetics.mean - 1.0) / 4.0
                            pool[index].proposal.score = 0.72 * pool[index].proposal.score + 0.28 * aesthNorm
                            modernCount += 1
                        }
                        progress("Charm 2025 đã chấm \(modernCount)/\(pool.count) khung và mức zoom…")
                    }
                } else {
                    progress("Đang tổng hợp điểm bố cục từ GAIC & SAMP…")
                }
                modern = nil
                return false
            }
            if singleModelResidency {
                CharmPhotographicModel.clearCache()
            }
            CompositionImageRenderer.clearSharedCaches()
            guard !charmCancelled else { return nil }
            for poolItem in pool {
                if let matchIdx = allEvaluated.firstIndex(where: {
                    $0.proposal.sourceCorners == poolItem.proposal.sourceCorners &&
                    $0.proposal.zoom == poolItem.proposal.zoom &&
                    $0.proposal.intent == poolItem.proposal.intent
                }) {
                    allEvaluated[matchIdx].aesthetics = poolItem.aesthetics
                    allEvaluated[matchIdx].proposal.score = poolItem.proposal.score
                }
            }
            if modernCount == pool.count && !pool.isEmpty {
                usedSpecialist = usedSpecialist || usedGAIC
                evaluated = pool
            } else if modernCount > 0 {
                evaluated = pool
                usedSpecialist = usedGAIC || assessedCount == evaluated.count
            } else if !usedGAIC && !usedSpecialist {
                for index in evaluated.indices { evaluated[index].proposal.score = evaluated[index].geometryScore }
            }
        }
        // Per-photo neural consensus normalization: prevents narrow raw GAIC/SAMP/Charm
        // variance (~0.05) from being drowned 10:1 by wider hand-tuned geometryScore variance (~0.38).
        if (usedSpecialist || usedGAIC) && evaluated.count >= 2 {
            let geomVals = evaluated.map(\.geometryScore)
            let gMin = geomVals.min() ?? 0.0, gMax = geomVals.max() ?? 1.0
            let gSpan = gMax - gMin
            let gaicVals = evaluated.map(\.proposal.gaicScore)
            let kMin = gaicVals.min() ?? 0.0, kMax = gaicVals.max() ?? 1.0
            let kSpan = kMax - kMin
            let sampVals = evaluated.compactMap { $0.assessment?.mean }
            let sMin = sampVals.min() ?? 1.0, sMax = sampVals.max() ?? 5.0
            let sSpan = sMax - sMin
            let charmVals = evaluated.compactMap { $0.aesthetics?.mean }
            let cMin = charmVals.min() ?? 1.0, cMax = charmVals.max() ?? 5.0
            let cSpan = cMax - cMin

            for idx in evaluated.indices {
                let normGeom = gSpan > 1e-4 ? (evaluated[idx].geometryScore - gMin) / gSpan : 0.5
                var neuralSum = 0.0
                var neuralWeight = 0.0
                if usedGAIC && kSpan > 1e-4 {
                    neuralSum += 0.48 * ((evaluated[idx].proposal.gaicScore - kMin) / kSpan)
                    neuralWeight += 0.48
                }
                if let samp = evaluated[idx].assessment?.mean, sSpan > 1e-4 {
                    neuralSum += 0.26 * ((samp - sMin) / sSpan)
                    neuralWeight += 0.26
                }
                if let charm = evaluated[idx].aesthetics?.mean, cSpan > 1e-4 {
                    neuralSum += 0.26 * ((charm - cMin) / cSpan)
                    neuralWeight += 0.26
                }
                if neuralWeight > 0.0 {
                    let neuralConsensus = neuralSum / neuralWeight
                    let zoomRatio = Double(evaluated[idx].proposal.zoom) / sourceBaseZoom
                    let justified = CompositionPreferencePolicy.isJustifiedZoom(evaluated[idx].proposal)
                    let zoomReg = (justified ? 0.025 : 0.075) * max(0.0, zoomRatio - (justified ? 1.95 : 1.65))
                    let oobPen = min(0.18, evaluated[idx].proposal.outOfBoundsFraction * 0.22)
                    let semB = sceneHints.hasRichGuidance ? min(0.28, max(-0.18, evaluated[idx].proposal.semanticCropBonus)) : 0.0
                    let normalizedRank = 0.42 * normGeom + 0.58 * neuralConsensus + 0.16 * semB - zoomReg - oobPen
                    evaluated[idx].proposal.score = 0.45 * evaluated[idx].proposal.score + 0.55 * normalizedRank
                }
            }
        }
        let baseline = evaluated.first { $0.proposal.isUnchangedView }
        let originalZoom = baseline?.proposal.zoom
        let baseSubjectArea = baseline.map { Double($0.proposal.expectedSubjectRect.width * $0.proposal.expectedSubjectRect.height) } ?? 1.0
        let maxAllowedZoom: CGFloat = baseSubjectArea < 0.08 ? 3.5 : (baseSubjectArea < 0.22 ? 3.0 : 2.2)
        let baseWasteRatio = baseline?.proposal.sceneWasteRatio ?? 0.0
        let zoomNeeded = baseline.map {
            usedGAIC
                ? (($0.proposal.sizeRatio < 0.48 && baseSubjectArea < 0.16 && $0.proposal.intent != .landscape) ||
                   (sceneHints.hasRichGuidance && sceneHints.avoid.maxAvoid >= 0.56 && baseWasteRatio >= 0.46))
                : (CompositionPreferencePolicy.zoomIsNecessary(originalSizeRatio: $0.proposal.sizeRatio,
                                                                 sceneWasteRatio: baseWasteRatio) ||
                   ($0.proposal.expectedSubjectRect.width * $0.proposal.expectedSubjectRect.height < 0.18) ||
                   (sceneHints.hasRichGuidance && sceneHints.avoid.maxAvoid >= 0.25))
        } ?? false
        // Compare the learned models jointly. When GAIC scores clear wins, legacy SAMP 2019 does not override them.
        let eligible = evaluated.filter { view in
            if view.proposal.isUnchangedView { return true }
            if view.proposal.zoom > maxAllowedZoom { return false }
            let v5StrongClean = sceneHints.hasRichGuidance && view.proposal.sceneCleanGain >= 0.05
            let v5HasCleanPan = sceneHints.hasRichGuidance &&
                (view.proposal.sceneCleanGain >= 0.025 ||
                 view.proposal.excessTrimGain >= 0.028 ||
                 view.proposal.semanticCropBonus >= 0.04)
            if view.proposal.retainedAttention < 0.45 && view.proposal.frameWasteRatio < 0.48 && !v5StrongClean { return false }
            if view.proposal.isAttentionSubject && view.proposal.retainedAttention < 0.74 &&
               view.proposal.frameWasteRatio < 0.24 && !v5HasCleanPan {
                return false
            }
            guard usedSpecialist, let baseline, let originalZoom else { return true }
            if view.proposal.gaicScore < baseline.proposal.gaicScore - 0.16 && view.proposal.retainedAttention < 0.58 {
                return false
            }
            if view.proposal.zoom <= originalZoom * 1.08 { return true }
            if usedGAIC && (view.proposal.gaicScore >= baseline.proposal.gaicScore + 0.020 ||
                            view.proposal.excessTrimGain >= 0.028 ||
                            (sceneHints.hasRichGuidance && view.proposal.sceneCleanGain >= 0.03)) &&
               view.proposal.score >= baseline.proposal.score - 0.025 &&
               view.geometryScore >= max(0.34, baseline.geometryScore * 0.70) {
                let compOK: Bool
                if let composition = view.assessment, let originalComposition = baseline.assessment {
                    compOK = composition.mean >= originalComposition.mean - 0.45
                } else {
                    compOK = true
                }
                if let aesthetics = view.aesthetics, let originalAesthetics = baseline.aesthetics {
                    return compOK && aesthetics.mean >= originalAesthetics.mean - 0.45
                }
                return compOK
            }
            if zoomNeeded, (CompositionPreferencePolicy.tightensTowardTarget(
                sizeRatio: view.proposal.sizeRatio, original: baseline.proposal.sizeRatio) ||
                view.proposal.excessTrimGain >= 0.028 ||
                (sceneHints.hasRichGuidance && view.proposal.sceneCleanGain >= 0.025)) {
                let withinTolerance = view.proposal.score >=
                    baseline.proposal.score - CompositionPreferencePolicy.necessaryCropTolerance
                guard let composition = view.assessment, let originalComposition = baseline.assessment else {
                    return withinTolerance
                }
                if let aesthetics = view.aesthetics, let originalAesthetics = baseline.aesthetics {
                    return withinTolerance && CompositionPreferencePolicy.consistent(
                        composition: composition.mean, aesthetics: aesthetics.mean,
                        originalComposition: originalComposition.mean, originalAesthetics: originalAesthetics.mean)
                }
                return withinTolerance && composition.mean >= originalComposition.mean - 0.35
            }
            guard let composition = view.assessment, let originalComposition = baseline.assessment else {
                return view.proposal.score >= (baseline.proposal.score - 0.05)
            }
            if let aesthetics = view.aesthetics, let originalAesthetics = baseline.aesthetics {
                return CompositionPreferencePolicy.prefersCrop(score: view.proposal.score, original: baseline.proposal.score) &&
                    CompositionPreferencePolicy.consistent(composition: composition.mean, aesthetics: aesthetics.mean,
                        originalComposition: originalComposition.mean, originalAesthetics: originalAesthetics.mean)
            }
            return composition.mean >= originalComposition.mean - 0.35 &&
                   view.proposal.score >= baseline.proposal.score - 0.05
        }
        var rankedEligible = eligible
        if zoomNeeded, let baseline {
            let bonusScale = usedGAIC ? 0.32 : 1.0
            for index in rankedEligible.indices where !rankedEligible[index].proposal.isUnchangedView {
                if usedGAIC && rankedEligible[index].proposal.gaicScore < baseline.proposal.gaicScore - 0.045 {
                    continue
                }
                rankedEligible[index].proposal.score += bonusScale * CompositionPreferencePolicy.excessTrimAndScaleBonus(
                    sizeRatio: rankedEligible[index].proposal.sizeRatio,
                    original: baseline.proposal.sizeRatio,
                    excessTrimGain: max(rankedEligible[index].proposal.excessTrimGain,
                                        sceneHints.hasRichGuidance ? rankedEligible[index].proposal.sceneCleanGain : 0.0),
                    retainedAttention: rankedEligible[index].proposal.retainedAttention
                )
            }
        }
        var selected = CompositionPlanner.diverse(rankedEligible.map(\.proposal), limit: 3).compactMap { proposal in
            rankedEligible.first { $0.proposal.sourceCorners == proposal.sourceCorners &&
                $0.proposal.intent == proposal.intent && $0.proposal.zoom == proposal.zoom }
        }
        if let baseline, !selected.contains(where: { $0.proposal.isUnchangedView }) {
            selected = Array(selected.prefix(2)) + [baseline]
        }
        selected.sort { $0.proposal.score > $1.proposal.score }
        var robust = false
        if (usedSpecialist || usedGAIC), let best = selected.first {
            if best.proposal.isUnchangedView {
                robust = true
            } else {
                let nearby = evaluated.filter {
                    $0.proposal.sourceCorners != best.proposal.sourceCorners &&
                    hypot($0.proposal.aimPoint.x - best.proposal.aimPoint.x,
                          $0.proposal.aimPoint.y - best.proposal.aimPoint.y) < 0.055 &&
                        abs(log(Double($0.proposal.zoom / best.proposal.zoom))) < 0.12
                }
                robust = (best.proposal.isUnchangedView || best.geometryScore >= 0.38) &&
                    (nearby.filter { $0.proposal.score >= best.proposal.score - 0.035 }.count >= 1 ||
                     best.proposal.score >= (baseline?.proposal.score ?? 0) - 0.02)
            }
        }
        if let best = selected.first, selected.count > 1 {
            let alternative = selected[1]
            let nearlySame = hypot(best.proposal.aimPoint.x - alternative.proposal.aimPoint.x,
                                   best.proposal.aimPoint.y - alternative.proposal.aimPoint.y) < 0.045 &&
                abs(log(Double(best.proposal.zoom / alternative.proposal.zoom))) < 0.08
            robust = robust && (nearlySame || best.proposal.score - alternative.proposal.score >= 0.015)
        }
        let effectiveAssessed = usedGAIC ? max(assessedCount, allGAICScoredProposals.count) : assessedCount
        return Result(views: selected, assessedCount: effectiveAssessed,
                      canAutoselect: (usedSpecialist || usedGAIC) && robust && effectiveAssessed >= 6,
                      usedSpecialist: usedSpecialist || usedGAIC,
                      modernAssessmentCount: modernCount,
                      allEvaluatedViews: allEvaluated,
                      allGAICProposals: allGAICScoredProposals)
    }
}

enum CompositionPreferencePolicy {
    /// Numerical tolerance is small on the native 1...5 rating scales. A large
    /// aesthetic regression cannot be traded for a composition score increase.
    static func consistent(composition: Double, aesthetics: Double,
                           originalComposition: Double, originalAesthetics: Double) -> Bool {
        let ratings = [composition, aesthetics, originalComposition, originalAesthetics]
        return ratings.allSatisfy { $0.isFinite && (1...5).contains($0) } &&
            composition >= originalComposition - 0.45 && aesthetics >= originalAesthetics - 0.65
    }

    static func isJustifiedZoom(_ proposal: CompositionProposal) -> Bool {
        (proposal.sizeRatio <= 1.25 && proposal.retainedAttention >= 0.60) ||
        proposal.excessTrimGain >= 0.03 ||
        proposal.sceneCleanGain >= 0.025 ||
        proposal.semanticCropBonus >= 0.04
    }

    static func score(composition: Double, aesthetics: Double, geometry: Double,
                      gaic: Double = 0.5, outOfBoundsFraction: Double = 0.0,
                      hasLearnedGAIC: Bool = false, zoomRatio: Double = 1.0,
                      justifiedZoom: Bool = false,
                      semanticCropBonus: Double = 0.0) -> Double? {
        guard composition.isFinite, aesthetics.isFinite, geometry.isFinite,
              (1...5).contains(composition), (1...5).contains(aesthetics) else { return nil }
        let clampedOOB = outOfBoundsFraction.isFinite ? min(0.18, max(0.0, outOfBoundsFraction * 0.25)) : 0.0
        let clampedGaic = gaic.isFinite ? min(1.0, max(0.0, gaic)) : 0.5
        let clampedSem = semanticCropBonus.isFinite ? min(0.35, max(-0.20, semanticCropBonus)) : 0.0
        if hasLearnedGAIC {
            let geomW = 0.40 + clampedOOB * 0.36
            let aesthW = 0.24 - clampedOOB * 0.14
            let gaicW = 0.20 - clampedOOB * 0.12
            let compW = 0.16 - clampedOOB * 0.10
            let regWeight = justifiedZoom ? 0.025 : 0.08
            let regStart = justifiedZoom ? 1.95 : 1.65
            let zoomReg = zoomRatio.isFinite ? regWeight * max(0.0, zoomRatio - regStart) : 0.0
            return geomW * min(1.35, max(0, geometry)) +
                aesthW * (aesthetics - 1) / 4 +
                compW * (composition - 1) / 4 +
                gaicW * clampedGaic +
                0.24 * clampedSem -
                zoomReg
        }
        let compW = 0.28 - clampedOOB * 0.25
        let aesthW = 0.32 - clampedOOB * 0.25
        let gaicW = 0.12 - clampedOOB * 0.10
        let geomW = 0.28 + clampedOOB * 0.60
        return compW * (composition - 1) / 4 +
            aesthW * (aesthetics - 1) / 4 +
            gaicW * clampedGaic +
            geomW * min(1.35, max(0, geometry)) +
            0.24 * clampedSem
    }

    /// Below this share of its intent's target area the unchanged frame leaves the subject too small.
    static let undersizedSubjectRatio = 0.80
    /// How far a necessary tighter crop may trail the wide frame before the models' objection stands.
    static let necessaryCropTolerance = 0.12
    static let shotScaleBonusWeight = 0.18

    static func zoomIsNecessary(originalSizeRatio: Double, sceneWasteRatio: Double = 0.0) -> Bool {
        (originalSizeRatio.isFinite && originalSizeRatio > 0 && originalSizeRatio < undersizedSubjectRatio) ||
            (sceneWasteRatio.isFinite && sceneWasteRatio >= 0.34)
    }

    /// A crop that clearly moves the subject toward its target size without overshooting it.
    static func tightensTowardTarget(sizeRatio: Double, original: Double) -> Bool {
        sizeRatio.isFinite && original.isFinite && original > 0 &&
            sizeRatio >= original * 1.15 && sizeRatio <= 2.2
    }

    static func shotScaleBonus(sizeRatio: Double, original: Double) -> Double {
        guard tightensTowardTarget(sizeRatio: sizeRatio, original: original) else { return 0 }
        let progress = (min(1, sizeRatio) - original) / max(0.001, 1 - original)
        return shotScaleBonusWeight * min(1, max(0, progress))
    }

    static func excessTrimAndScaleBonus(sizeRatio: Double, original: Double,
                                        excessTrimGain: Double, retainedAttention: Double) -> Double {
        let retGate = min(1.0, max(0.0, (retainedAttention - 0.42) / 0.33))
        var scaleProg = 0.0
        if original > 0, original < undersizedSubjectRatio, tightensTowardTarget(sizeRatio: sizeRatio, original: original) {
            let linP = min(1.0, max(0.0, (min(1.0, sizeRatio) - original) / max(0.001, 1.0 - original)))
            if original < 0.28 {
                let denom = max(0.05, log(1.0 / max(0.004, original)))
                let logP = min(1.0, max(0.0, log(max(1.0, min(1.0, sizeRatio) / max(0.004, original))) / denom))
                scaleProg = 0.5 * linP + 0.5 * logP
            } else {
                scaleProg = linP
            }
        }
        let trimProg = min(1.0, max(0.0, excessTrimGain / 0.10))
        return shotScaleBonusWeight * max(scaleProg * retGate, 0.90 * trimProg)
    }

    static func prefersCrop(score: Double, original: Double) -> Bool {
        score.isFinite && original.isFinite && score >= original + 0.002
    }
}
