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
                let item: View? = autoreleasepool {
                    guard let preview = renderer.preview(image: image, corners: candidate.sourceCorners, aspect: aspect) else { return nil }
                    let assessment = specialist?.assess(preview, cancellation: cancellation)
                    var proposal = candidate
                    if let assessment {
                        assessedCount += 1
                        // Phản biện 2: Khi xoay camera 3D ở 1.0x (outOfBoundsFraction > 0), cửa sổ preview bị giới hạn trong [0, 1]
                        // nên ưu tiên trọng số Trường Thế Năng Thị Giác 3D (candidate.continuousFieldScore) để không bị thiên vị cho khung đứng yên
                        let oobWeight = min(0.32, candidate.outOfBoundsFraction * 0.45)
                        let specialistWeight = 0.46 - oobWeight
                        let fieldWeight = 0.54 + oobWeight
                        proposal.score = specialistWeight * (assessment.mean - 1) / 4 + fieldWeight * candidate.score
                    } else if let aesthetic = renderer.aestheticScore(image: preview, cancellation: cancellation) {
                        proposal.score += aesthetic * 0.075
                    }
                    if !proposal.isUnchangedView {
                        let subjCenterX = Double(proposal.expectedSubjectRect.midX)
                        let subjTopThirdY = Double(proposal.expectedSubjectRect.minY + proposal.expectedSubjectRect.height * 0.28)
                        let thirdX = min(abs(subjCenterX - Double(CompositionTuning.goldenSectionLeft)),
                                         abs(subjCenterX - Double(CompositionTuning.goldenSectionRight)))
                        let thirdY = min(abs(subjTopThirdY - 0.36), abs(Double(proposal.expectedSubjectRect.midY) - 0.382))
                        proposal.score += 0.055 * exp(-14 * (thirdX * thirdX + thirdY * thirdY))
                        if proposal.zoom >= 1.15 {
                            proposal.score += 0.045
                        } else if proposal.zoom > 1.05 {
                            proposal.score += 0.020
                        }
                    }
                    // preferences bonus removed to ensure unbiased realtime evaluation
                    return View(proposal: proposal, image: preview, assessment: assessment,
                                geometryScore: candidate.score)
                }
                guard let item else { continue }
                result.append(item)
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
            for index in zoomed.prefix(4) { include(index) }
            let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled ||
                ProcessInfo.processInfo.physicalMemory < 6_000_000_000 || ProcessInfo.processInfo.thermalState == .serious
            let budget = constrained ? 4 : 6
            for index in evaluated.indices.sorted(by: { evaluated[$0].proposal.score > evaluated[$1].proposal.score }) {
                if indices.count >= budget { break }
                include(index)
            }
            var pool = indices.prefix(budget).map { evaluated[$0] }
            var modern: CharmPhotographicModel?
            if let aestheticModelURL, let positionURL {
                modern = try? CharmPhotographicModel(url: aestheticModelURL, positionURL: positionURL)
            } else { modern = nil }
            if let activeModern = modern {
                for index in pool.indices {
                    guard !cancellation.isCancelled else { return nil }
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
                           outOfBoundsFraction: pool[index].proposal.outOfBoundsFraction
                       ) {
                        pool[index].proposal.score = score
                        modernCount += 1
                    }
                    progress("Charm 2025 đã chấm \(modernCount)/\(pool.count) khung và mức zoom…")
                }
            } else {
                progress("Không nạp được Charm. Đang chuẩn bị các khung để chọn thủ công…")
            }
            modern = nil
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
            if view.proposal.isUnchangedView { return true }
            guard usedSpecialist, let baseline, let originalZoom else { return true }
            if view.proposal.zoom <= originalZoom * 1.08 { return true }
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
                robust = (nearby.filter { $0.proposal.score >= best.proposal.score - 0.035 }.count >= 1 ||
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
        return Result(views: selected, assessedCount: assessedCount,
                      canAutoselect: usedSpecialist && robust && assessedCount >= 10, usedSpecialist: usedSpecialist,
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
            composition >= originalComposition - 0.20 && aesthetics >= originalAesthetics - 0.20
    }

    static func score(composition: Double, aesthetics: Double, geometry: Double, outOfBoundsFraction: Double = 0.0) -> Double? {
        guard composition.isFinite, aesthetics.isFinite, geometry.isFinite,
              (1...5).contains(composition), (1...5).contains(aesthetics) else { return nil }
        let fieldBoost = min(0.28, max(0.0, outOfBoundsFraction * 0.38))
        let compW = 0.38 - fieldBoost * 0.55
        let aesthW = 0.34 - fieldBoost * 0.45
        let geomW = 0.28 + fieldBoost
        return compW * (composition - 1) / 4 + aesthW * (aesthetics - 1) / 4 +
            geomW * min(1, max(0, geometry))
    }

    static func prefersCrop(score: Double, original: Double) -> Bool {
        score.isFinite && original.isFinite && score >= original + 0.008
    }
}
