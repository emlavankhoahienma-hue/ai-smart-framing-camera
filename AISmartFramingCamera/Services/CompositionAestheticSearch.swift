import Foundation
import CoreGraphics
import CoreImage

struct CompositionSearchBudget {
    let coarse: Int
    let refinement: Int
    let aesthetics: Int

    init(complexScene: Bool, constrained: Bool) {
        // These regions share a source-image encoder, rather than running a
        // whole-image quality network once for every pan/zoom hypothesis.
        coarse = complexScene ? (constrained ? 64 : 96) : (constrained ? 48 : 72)
        refinement = constrained ? 18 : 28
        aesthetics = constrained ? 6 : 8
    }

    static func isComplex(group: Bool, intents: [LocalCompositionIntent]) -> Bool {
        group || intents.contains { $0 == .landscape || $0 == .architecture || $0 == .environmentalPortrait }
    }
}

/// Subject safety and photographic intent constrain the camera view. A trained
/// source-relative crop ranker chooses between admissible layouts; whole-image
/// quality models audit the shortlist instead of repeatedly vetoing reframing.
final class CompositionAestheticSearch {
    struct View {
        var proposal: CompositionProposal
        let image: CGImage
        let assessment: PhotographicCompositionModel.Assessment?
        var aesthetics: CharmPhotographicModel.Assessment? = nil
        let geometryScore: Double
        let cropPreference: Double
        let satisfiesFramingGoal: Bool
    }

    struct Result {
        let views: [View]
        let assessedCount: Int
        let canAutoselect: Bool
        let usedSpecialist: Bool
        let modernAssessmentCount: Int
        let cropAssessmentCount: Int
    }

    private struct Ranked {
        let proposal: CompositionProposal
        let preference: Double
    }

    private let renderer: CompositionImageRenderer
    init(renderer: CompositionImageRenderer) { self.renderer = renderer }

    func run(proposals: [CompositionProposal], image: CIImage, aspect: Double,
             preferences: [String: Double], modelURL: URL?,
             aestheticModelURL: URL? = nil, positionURL: URL? = nil,
             aestheticLimit: Int = 8, cropModel: FocalCropModel? = nil,
             cancellation: CompositionAnalysisCancellation,
             progress: @Sendable (String) -> Void,
             refine: ([CompositionProposal]) -> [CompositionProposal]) -> Result? {
        guard !cancellation.isCancelled, let cropModel, let modelURL,
              let aestheticModelURL, let positionURL else { return nil }
        var assessedRegions = 0
        func evaluate(_ candidates: [CompositionProposal]) -> [Ranked]? {
            guard !cancellation.isCancelled, !candidates.isEmpty, candidates.count <= 128 else { return nil }
            let regions = candidates.compactMap { CompositionViewSupport.region($0.sourceCorners) }
            guard regions.count == candidates.count,
                  let evidence = cropModel.assess(regions, cancellation: cancellation) else { return nil }
            assessedRegions += candidates.count
            return zip(candidates, evidence.preferences).map { Ranked(proposal: $0.0, preference: $0.1) }
        }
        guard var ranked = evaluate(proposals), !ranked.isEmpty else { return nil }
        func goalCandidates(_ values: [Ranked]) -> [Ranked] {
            guard let best = values.map({ $0.proposal.score }).max() else { return [] }
            return values.filter { LearnedFramingPolicy.admissible(geometry: $0.proposal.score, best: best) }
        }
        func learnedOrder(_ values: [Ranked], limit: Int) -> [Ranked] {
            let plans = values.map { value -> CompositionProposal in
                var plan = value.proposal; plan.score = value.preference; return plan
            }
            return CompositionPlanner.diverse(plans, limit: limit, raySeparation: 0.012, zoomSeparation: 0.025).compactMap { plan in
                values.first { $0.proposal.sourceCorners == plan.sourceCorners && $0.proposal.intent == plan.intent }
            }
        }
        progress("Đang chọn vùng chụp theo chủ thể và bố cục đã học…")
        let initial = learnedOrder(goalCandidates(ranked), limit: 3).map(\.proposal)
        let neighbours = refine(initial)
        if !neighbours.isEmpty {
            guard let evaluated = evaluate(neighbours) else { return nil }
            for value in evaluated where !ranked.contains(where: {
                $0.proposal.sourceCorners == value.proposal.sourceCorners && $0.proposal.intent == value.proposal.intent
            }) { ranked.append(value) }
        }
        guard !cancellation.isCancelled, let bestGeometry = ranked.map({ $0.proposal.score }).max() else { return nil }
        let admissible = goalCandidates(ranked)
        let budget = max(3, min(8, aestheticLimit))
        var pool = learnedOrder(admissible, limit: budget - 1)
        if let original = ranked.first(where: { $0.proposal.isUnchangedView }),
           !pool.contains(where: { $0.proposal.isUnchangedView }) { pool.append(original) }
        for value in admissible.sorted(by: { $0.preference > $1.preference }) where pool.count < budget {
            if !pool.contains(where: { $0.proposal.sourceCorners == value.proposal.sourceCorners && $0.proposal.intent == value.proposal.intent }) {
                pool.append(value)
            }
        }
        guard !pool.isEmpty else { return nil }
        var specialist = try? PhotographicCompositionModel(url: modelURL)
        guard specialist != nil else { return nil }
        var views: [View] = []
        for value in pool {
            guard !cancellation.isCancelled,
                  let preview = renderer.observedPreview(image: image, proposal: value.proposal, aspect: aspect),
                  let composition = specialist?.assess(preview, cancellation: cancellation) else { return nil }
            views.append(View(proposal: value.proposal, image: preview, assessment: composition,
                geometryScore: value.proposal.score, cropPreference: value.preference,
                satisfiesFramingGoal: LearnedFramingPolicy.admissible(geometry: value.proposal.score, best: bestGeometry)))
        }
        specialist = nil
        guard let modern = try? CharmPhotographicModel(url: aestheticModelURL, positionURL: positionURL) else { return nil }
        let peers = views.filter(\.satisfiesFramingGoal).map(\.cropPreference)
        for index in views.indices {
            guard !cancellation.isCancelled,
                  let aesthetics = modern.assess(views[index].image, cancellation: cancellation),
                  let composition = views[index].assessment,
                  let score = LearnedFramingPolicy.score(preference: views[index].cropPreference, peers: peers,
                    composition: composition.mean, aesthetics: aesthetics.mean, geometry: views[index].geometryScore) else { return nil }
            views[index].aesthetics = aesthetics
            views[index].proposal.score = score + min(0.003, max(-0.003, preferences[views[index].proposal.preferenceKey] ?? 0))
            progress("Đã kiểm tra thẩm mỹ \(index + 1)/\(views.count) phương án…")
        }
        let eligible = views.filter(\.satisfiesFramingGoal)
        var selected = CompositionPlanner.diverse(eligible.map(\.proposal), limit: 3).compactMap { plan in
            eligible.first { $0.proposal.sourceCorners == plan.sourceCorners && $0.proposal.intent == plan.intent }
        }
        if let original = views.first(where: { $0.proposal.isUnchangedView }),
           !selected.contains(where: { $0.proposal.isUnchangedView }) {
            selected = Array(selected.prefix(2)) + [original]
        }
        guard let best = selected.first else { return nil }
        // A fallback original stays available for inspection, but cannot silently
        // displace a layout that satisfies the selected photographic objective.
        let range = (peers.max() ?? 0) - (peers.min() ?? 0)
        let nearby = ranked.filter {
            $0.proposal.sourceCorners != best.proposal.sourceCorners &&
                hypot($0.proposal.aimPoint.x - best.proposal.aimPoint.x, $0.proposal.aimPoint.y - best.proposal.aimPoint.y) < 0.055 &&
                abs(log(Double($0.proposal.zoom / best.proposal.zoom))) < 0.12 &&
                $0.preference >= best.cropPreference - max(0.01, range * 0.15)
        }
        let stable = best.proposal.isUnchangedView ||
            (range > 0.0001 && (!nearby.isEmpty || assessedRegions >= 12))
        return Result(views: selected, assessedCount: views.count,
            canAutoselect: stable, usedSpecialist: true, modernAssessmentCount: views.count,
            cropAssessmentCount: assessedRegions)
    }
}
