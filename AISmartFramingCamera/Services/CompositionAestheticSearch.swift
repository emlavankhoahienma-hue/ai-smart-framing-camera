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
    }

    struct Result {
        let views: [View]
        let assessedCount: Int
        let canAutoselect: Bool
        let usedSpecialist: Bool
    }

    private let renderer: CompositionImageRenderer
    init(renderer: CompositionImageRenderer) { self.renderer = renderer }

    func run(proposals: [CompositionProposal], image: CIImage, aspect: Double,
             preferences: [String: Double], modelURL: URL?,
             cancellation: CompositionAnalysisCancellation,
             progress: @Sendable (String) -> Void,
             refine: ([CompositionProposal]) -> [CompositionProposal]) -> Result? {
        guard !cancellation.isCancelled else { return nil }
        let specialist = modelURL.flatMap { try? PhotographicCompositionModel(url: $0) }
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
                result.append(View(proposal: proposal, image: preview, assessment: assessment))
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
        let baseline = evaluated.first { $0.proposal.isUnchangedView }
        let baselineMean = baseline?.assessment?.mean
        let originalZoom = baseline?.proposal.zoom
        // The unchanged frame competes with every crop. Avoid trading away
        // image area for gains smaller than the model-conversion tolerance.
        let eligible = evaluated.filter { view in
            guard let baselineMean, let originalZoom, let assessment = view.assessment else { return true }
            return view.proposal.isUnchangedView || view.proposal.zoom <= originalZoom * 1.08 ||
                assessment.mean >= baselineMean + 0.10
        }
        let selected = CompositionPlanner.diverse(eligible.map(\.proposal), limit: 3).compactMap { proposal in
            eligible.first { $0.proposal.sourceCorners == proposal.sourceCorners &&
                $0.proposal.intent == proposal.intent && $0.proposal.zoom == proposal.zoom }
        }
        let usedSpecialist = !evaluated.isEmpty && assessedCount == evaluated.count
        var robust = false
        if usedSpecialist, let best = selected.first, let rating = best.assessment?.mean {
            if best.proposal.isUnchangedView {
                robust = true
            } else {
                let nearby = neighbours.filter {
                    hypot($0.proposal.aimPoint.x - best.proposal.aimPoint.x,
                          $0.proposal.aimPoint.y - best.proposal.aimPoint.y) < 0.055 &&
                        abs(log(Double($0.proposal.zoom / best.proposal.zoom))) < 0.12
                }.compactMap { $0.assessment?.mean }
                robust = nearby.count >= 2 && nearby.filter { $0 >= rating - 0.15 }.count >= 2 &&
                    baselineMean.map { rating >= $0 + 0.12 } == true
            }
        }
        return Result(views: selected, assessedCount: assessedCount,
                      canAutoselect: usedSpecialist && robust, usedSpecialist: usedSpecialist)
    }
}
