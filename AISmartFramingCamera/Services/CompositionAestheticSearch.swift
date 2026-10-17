import Foundation
import CoreGraphics
import CoreImage

/// Two passes over feasible camera views. The trained composition model ranks
/// photographic layout and focal length; the planner enforces subject safety.
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
    }

    private let renderer: CompositionImageRenderer
    init(renderer: CompositionImageRenderer) { self.renderer = renderer }

    func run(proposals: [CompositionProposal], image: CIImage, aspect: Double,
             preferences: [String: Double], modelURL: URL?,
             aestheticModelURL: URL? = nil, positionURL: URL? = nil, requiresModernModel: Bool = false,
             cancellation: CompositionAnalysisCancellation,
             progress: @Sendable (String) -> Void,
             refine: ([CompositionProposal]) -> [CompositionProposal]) -> Result? {
        guard !cancellation.isCancelled else { return nil }
        var specialist = modelURL.flatMap { try? PhotographicCompositionModel(url: $0) }
        var assessedCount = 0
        func evaluate(_ candidates: [CompositionProposal]) -> [View] {
            var result: [View] = []
            for (index, candidate) in candidates.enumerated() {
                if cancellation.isCancelled { return [] }
                guard let preview = renderer.preview(image: image, corners: candidate.sourceCorners, aspect: aspect) else { continue }
                let assessment = specialist?.assess(preview, cancellation: cancellation)
                var proposal = candidate
                if let assessment {
                    assessedCount += 1
                    // Expected expert rating is not detector confidence.
                    proposal.score = 0.78 * (assessment.mean - 1) / 4 + 0.22 * candidate.score
                } else if let aesthetic = renderer.aestheticScore(image: preview, cancellation: cancellation) {
                    proposal.score += aesthetic * 0.075
                }
                proposal.score += min(0.01, max(-0.01, preferences[proposal.preferenceKey] ?? 0))
                result.append(View(proposal: proposal, image: preview, assessment: assessment,
                                   geometryScore: candidate.score))
                progress("Đang so sánh bố cục và zoom \(index + 1)/\(candidates.count)…")
            }
            return result
        }
        var evaluated = evaluate(proposals)
        guard !cancellation.isCancelled else { return nil }
        let initial = CompositionPlanner.diverse(evaluated.map(\.proposal), limit: 3)
        progress("Đang kiểm tra lại khung và các mức zoom lân cận…")
        let neighbours = evaluate(refine(initial))
        evaluated.append(contentsOf: neighbours)
        guard !cancellation.isCancelled else { return nil }
        var usedSpecialist = !evaluated.isEmpty && assessedCount == evaluated.count
        if specialist != nil && !usedSpecialist {
            // Never compare learned 1-to-5 ratings against unrelated fallback
            // scores if a request fails partway through the comparison.
            for index in evaluated.indices { evaluated[index].proposal.score = evaluated[index].geometryScore }
        }
        // Release the first scorer before loading the 2025 aesthetic specialist.
        specialist = nil
        var modernCount = 0
        if requiresModernModel || aestheticModelURL != nil {
            var indices: [Int] = []
            func include(_ index: Int) { if !indices.contains(index) { indices.append(index) } }
            if let original = evaluated.firstIndex(where: { $0.proposal.isUnchangedView }) { include(original) }
            let leaders = CompositionPlanner.diverse(evaluated.map(\.proposal), limit: 3)
            for leader in leaders {
                if let index = evaluated.firstIndex(where: { $0.proposal.sourceCorners == leader.sourceCorners }) { include(index) }
                let nearby = evaluated.indices.filter {
                    hypot(evaluated[$0].proposal.aimPoint.x - leader.aimPoint.x,
                          evaluated[$0].proposal.aimPoint.y - leader.aimPoint.y) < 0.055 &&
                        abs(log(Double(evaluated[$0].proposal.zoom / leader.zoom))) < 0.12
                }.sorted { evaluated[$0].proposal.score > evaluated[$1].proposal.score }
                for index in nearby.prefix(3) { include(index) }
            }
            // A strong tighter view must reach the second model even when the
            // old whole-image composition scorer slightly prefers the wide view.
            let sourceZoom = evaluated.first(where: { $0.proposal.isUnchangedView })?.proposal.zoom ?? 1
            let zoomed = evaluated.indices.filter { evaluated[$0].proposal.zoom > sourceZoom * 1.25 }
                .sorted { evaluated[$0].proposal.score > evaluated[$1].proposal.score }
            for index in zoomed.prefix(2) { include(index) }
            let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled ||
                ProcessInfo.processInfo.physicalMemory < 6_000_000_000 || ProcessInfo.processInfo.thermalState == .serious
            let budget = constrained ? 12 : 18
            for index in evaluated.indices.sorted(by: { evaluated[$0].proposal.score > evaluated[$1].proposal.score }) {
                if indices.count >= budget { break }
                include(index)
            }
            var pool = indices.prefix(budget).map { evaluated[$0] }
            let modern: CharmPhotographicModel?
            if let aestheticModelURL, let positionURL {
                modern = try? CharmPhotographicModel(url: aestheticModelURL, positionURL: positionURL)
            } else { modern = nil }
            if let modern {
                for index in pool.indices {
                    guard !cancellation.isCancelled else { return nil }
                    pool[index].aesthetics = modern.assess(pool[index].image, cancellation: cancellation)
                    if let composition = pool[index].assessment, let aesthetics = pool[index].aesthetics,
                       let score = CompositionPreferencePolicy.score(composition: composition.mean,
                           aesthetics: aesthetics.mean, geometry: pool[index].geometryScore) {
                        pool[index].proposal.score = score
                        modernCount += 1
                    }
                    progress("Charm 2025 đã chấm \(modernCount)/\(pool.count) khung và mức zoom…")
                }
            } else {
                progress("Không nạp được Charm. Đang chuẩn bị các khung để chọn thủ công…")
            }
            usedSpecialist = usedSpecialist && !pool.isEmpty && modernCount == pool.count
            evaluated = pool
            if !usedSpecialist {
                for index in evaluated.indices { evaluated[index].proposal.score = evaluated[index].geometryScore }
            }
        }
        let baseline = evaluated.first { $0.proposal.isUnchangedView }
        let originalZoom = baseline?.proposal.zoom
        // Compare the two models jointly. A fixed SAMP-only 0.10/0.12-rating
        // veto prevented useful zoom even when the aesthetic model preferred it.
        let eligible = evaluated.filter { view in
            guard usedSpecialist, let baseline, let originalZoom else { return true }
            if view.proposal.isUnchangedView || view.proposal.zoom <= originalZoom * 1.08 { return true }
            guard let composition = view.assessment, let aesthetics = view.aesthetics,
                  let originalComposition = baseline.assessment, let originalAesthetics = baseline.aesthetics else { return false }
            return CompositionPreferencePolicy.prefersCrop(score: view.proposal.score, original: baseline.proposal.score) &&
                CompositionPreferencePolicy.consistent(composition: composition.mean, aesthetics: aesthetics.mean,
                    originalComposition: originalComposition.mean, originalAesthetics: originalAesthetics.mean)
        }
        var selected = CompositionPlanner.diverse(eligible.map(\.proposal), limit: 3).compactMap { proposal in
            eligible.first { $0.proposal.sourceCorners == proposal.sourceCorners &&
                $0.proposal.intent == proposal.intent && $0.proposal.zoom == proposal.zoom }
        }
        if let baseline, !selected.contains(where: { $0.proposal.isUnchangedView }) {
            selected = Array(selected.prefix(2)) + [baseline]
        }
        // The view model compares the leading two scores before auto-selection.
        // Restoring the original frame must not leave a stronger runner-up third.
        selected.sort { $0.proposal.score > $1.proposal.score }
        var robust = false
        if usedSpecialist, let best = selected.first {
            if best.proposal.isUnchangedView {
                robust = true
            } else {
                let nearby = evaluated.filter {
                    $0.proposal.sourceCorners != best.proposal.sourceCorners &&
                    hypot($0.proposal.aimPoint.x - best.proposal.aimPoint.x,
                          $0.proposal.aimPoint.y - best.proposal.aimPoint.y) < 0.055 &&
                        abs(log(Double($0.proposal.zoom / best.proposal.zoom))) < 0.12
                }
                robust = nearby.filter { $0.proposal.score >= best.proposal.score - 0.025 }.count >= 2 &&
                    baseline.map { CompositionPreferencePolicy.prefersCrop(score: best.proposal.score, original: $0.proposal.score) } == true
            }
        }
        if let best = selected.first, selected.count > 1 {
            let alternative = selected[1]
            let nearlySame = hypot(best.proposal.aimPoint.x - alternative.proposal.aimPoint.x,
                                   best.proposal.aimPoint.y - alternative.proposal.aimPoint.y) < 0.045 &&
                abs(log(Double(best.proposal.zoom / alternative.proposal.zoom))) < 0.08
            robust = robust && (nearlySame || best.proposal.score - alternative.proposal.score >= 0.015)
        }
        return Result(views: selected, assessedCount: assessedCount,
                      canAutoselect: usedSpecialist && robust && assessedCount >= 12, usedSpecialist: usedSpecialist,
                      modernAssessmentCount: modernCount)
    }
}

enum CompositionPreferencePolicy {
    /// Numerical tolerance is small on the native 1...5 rating scales. A large
    /// aesthetic regression cannot be traded for a composition score increase.
    static func consistent(composition: Double, aesthetics: Double,
                           originalComposition: Double, originalAesthetics: Double) -> Bool {
        let ratings = [composition, aesthetics, originalComposition, originalAesthetics]
        return ratings.allSatisfy { $0.isFinite && (1...5).contains($0) } &&
            composition >= originalComposition - 0.06 && aesthetics >= originalAesthetics - 0.06
    }

    static func score(composition: Double, aesthetics: Double, geometry: Double) -> Double? {
        guard composition.isFinite, aesthetics.isFinite, geometry.isFinite,
              (1...5).contains(composition), (1...5).contains(aesthetics) else { return nil }
        return 0.45 * (composition - 1) / 4 + 0.40 * (aesthetics - 1) / 4 +
            0.15 * min(1, max(0, geometry))
    }

    static func prefersCrop(score: Double, original: Double) -> Bool {
        score.isFinite && original.isFinite && score >= original + 0.008
    }
}
