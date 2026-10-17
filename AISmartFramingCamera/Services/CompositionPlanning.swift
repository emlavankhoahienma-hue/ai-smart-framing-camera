import Foundation
import CoreGraphics
import simd

/// Translates the existing subject bearing into the selected photographic aim.
/// It reads tracking output; it never corrects or replaces the optical tracker.
struct CompositionAimGeometry {
    private let aimFromSubject: simd_quatd

    init?(subject: CGPoint, calibration: TrackingCalibration,
          sourcePose: simd_quatd, aimWorldRay: SIMD3<Double>) {
        guard calibration.isValid, subject.x.isFinite, subject.y.isFinite,
              (0...1).contains(subject.x), (0...1).contains(subject.y),
              sourcePose.vector.indices.allSatisfy({ sourcePose.vector[$0].isFinite }),
              simd_length(sourcePose.vector) > 0.000001,
              aimWorldRay.indices.allSatisfy({ aimWorldRay[$0].isFinite }),
              simd_length(aimWorldRay) > 0.000001 else { return nil }
        let bearing = simd_normalize(sourcePose).act(calibration.deviceRay(at: subject))
        aimFromSubject = simd_quatd(from: bearing, to: simd_normalize(aimWorldRay))
    }

    func projection(subject: CGPoint, calibration: TrackingCalibration,
                    pose: simd_quatd) -> TrackingProjection? {
        guard calibration.isValid, subject.x.isFinite, subject.y.isFinite,
              pose.vector.indices.allSatisfy({ pose.vector[$0].isFinite }),
              simd_length(pose.vector) > 0.000001 else { return nil }
        let rotation = simd_normalize(pose)
        let ray = rotation.act(calibration.deviceRay(at: subject))
        return calibration.project(deviceRay: rotation.inverse.act(aimFromSubject.act(ray)))
    }
}

enum CompositionCropProtection {
    /// Only a measured, contained torso region may relax the full-body crop gate.
    /// The returned rectangle is a crop constraint, never the tracking seed.
    static func bounds(body: CGRect, portrait: CGRect?, intent: LocalCompositionIntent,
                       anchor: CGPoint) -> CGRect {
        guard intent == .portrait, let portrait,
              [portrait.minX, portrait.minY, portrait.width, portrait.height].allSatisfy(\.isFinite),
              portrait.width > 0, portrait.height > 0,
              body.contains(portrait), portrait.contains(anchor) else { return body }
        return portrait
    }
}

/// A completed analysis belongs to one button press and one captured image.
/// Model warm-up changes elapsed time, never the evidence required for a result.
struct CompositionAnalysisReceipt: Sendable {
    let requestID: UUID
    let sourceTimestamp: TimeInterval
    let elapsed: TimeInterval
    let assessedFrames: Int
    let usedSpecialist: Bool
    var modernAssessments = 0

    func belongs(to request: UUID, timestamp: TimeInterval) -> Bool {
        requestID == request && sourceTimestamp.isFinite && timestamp.isFinite &&
            sourceTimestamp == timestamp && elapsed.isFinite && elapsed >= 0 && assessedFrames >= 0
    }

    static func acceptsFrame(timestamp: TimeInterval, requestedAt: TimeInterval, now: TimeInterval) -> Bool {
        timestamp.isFinite && requestedAt.isFinite && now.isFinite &&
            timestamp >= requestedAt && timestamp <= now + 0.02 && now - timestamp <= 1
    }

    static func acceptsSelection(sourceTimestamp: TimeInterval, completedAt: TimeInterval,
                                 now: TimeInterval) -> Bool {
        [sourceTimestamp, completedAt, now].allSatisfy(\.isFinite) &&
            sourceTimestamp <= completedAt + 0.02 && completedAt <= now + 0.02 &&
            now - sourceTimestamp <= 90 && now - completedAt <= 15
    }
}

/// Intent describes what the frame should preserve. It is not an aesthetic verdict.
enum LocalCompositionIntent: String, Codable, Sendable {
    case portrait, environmentalPortrait, group, landscape, architecture
    case closeUp, food, animal, object, street

    var title: String {
        switch self {
        case .portrait: return "Chân dung"
        case .environmentalPortrait: return "Người trong cảnh"
        case .group: return "Giữ cả nhóm"
        case .landscape: return "Toàn cảnh"
        case .architecture: return "Kiến trúc"
        case .closeUp: return "Hoa lá · Chi tiết"
        case .food: return "Món ăn"
        case .animal: return "Thú cưng"
        case .object: return "Chủ thể nổi bật"
        case .street: return "Câu chuyện đường phố"
        }
    }

    var promptKey: String {
        switch self {
        case .portrait: return "person"
        case .environmentalPortrait: return "person_scenery"
        case .group: return "group"
        case .landscape: return "landscape"
        case .architecture: return "building"
        case .closeUp: return "flower"
        case .food: return "food"
        case .animal: return "animal"
        case .object: return "object"
        case .street: return "street"
        }
    }

    var preservesContext: Bool {
        self == .environmentalPortrait || self == .landscape || self == .street || self == .group
    }
}

enum CompositionSubjectKind: Sendable { case person, face, group, animal, object, scenery }

struct CompositionSubject: Sendable {
    let index: Int
    let bounds: CGRect
    let anchor: CGPoint
    let kind: CompositionSubjectKind
    let confidence: Double
    let importance: Double
    let gaze: CGFloat
}

/// Photographic importance is independent of detector certainty. In particular,
/// texture/noise can support a subject, but cannot turn it into a detected person.
struct SubjectVisualEvidence: Sendable {
    let attentionDensity: Double
    let attentionShare: Double
    let separation: Double
    let detail: Double
    let exposure: Double
}

enum HeroSubjectPolicy {
    static func faceAffinity(face: CGRect, body: CGRect) -> Double? {
        guard body.width > 0, body.height > 0,
              body.insetBy(dx: -0.025, dy: -0.025).contains(CGPoint(x: face.midX, y: face.midY)) else { return nil }
        let x = Double((face.midX - body.midX) / body.width)
        let y = Double((face.midY - body.minY) / body.height)
        guard x.isFinite, y.isFinite, y < 0.6 else { return nil }
        return exp(-4 * x * x - 6 * pow(y - 0.16, 2))
    }

    static func duplicate(_ a: CGRect, _ b: CGRect, eyeA: CGPoint?, eyeB: CGPoint?) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        // Two overlapping people with distinct face anchors are two subjects.
        if let eyeA, let eyeB,
           hypot(eyeA.x - eyeB.x, eyeA.y - eyeB.y) > min(a.width, b.width) * 0.22 { return false }
        let small = min(a.width * a.height, b.width * b.height)
        return intersection.width * intersection.height / max(0.0001, small) > 0.65
    }

    static func score(bounds: CGRect, kind: CompositionSubjectKind, confidence: Double,
                      evidence: SubjectVisualEvidence?, hasFace: Bool = false) -> Double {
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, confidence.isFinite else { return 0 }
        let area = Double(bounds.width * bounds.height)
        let scale = min(1, sqrt(area / (kind == .face ? 0.06 : 0.24)))
        let centrality = exp(-2 * pow(hypot(Double(bounds.midX - 0.5), Double(bounds.midY - 0.48)), 2))
        let semantic: Double
        switch kind {
        case .person, .group: semantic = hasFace ? 1 : 0.84
        case .face: semantic = 0.94
        case .animal: semantic = 0.88
        case .object: semantic = 0.62
        case .scenery: semantic = 0.40
        }
        let visual: Double
        if let e = evidence {
            visual = 0.18 * e.attentionDensity + 0.15 * sqrt(max(0, e.attentionShare)) +
                0.10 * e.separation + 0.06 * e.detail * e.exposure
        } else { visual = 0.20 * scale }
        let tinyPenalty = min(1, area / (kind == .face ? 0.002 : 0.008))
        return max(0, min(1, confidence)) * tinyPenalty *
            (0.25 * semantic + 0.19 * scale + 0.07 * centrality + visual)
    }

    /// Comparable scale and spatial proximity distinguish a group from passers-by.
    static func coherent(_ a: CGRect, _ b: CGRect) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        let scaleRatio = min(a.height, b.height) / max(a.height, b.height)
        let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let verticalGap = abs(a.midY - b.midY)
        return scaleRatio >= 0.48 && horizontalGap <= max(a.width, b.width) * 1.2 &&
            verticalGap <= max(a.height, b.height) * 0.50
    }
}

/// Presentation-only identity hysteresis. It never changes the pinned target,
/// optical measurements, device motion, or capture/alignment state.
struct HeroIdentitySelector {
    private(set) var selected: UUID?
    private var challenger: UUID?
    private var challengeStarted: TimeInterval = 0
    private var lastTimestamp: TimeInterval = 0

    mutating func select(_ scores: [(UUID, Double)], timestamp: TimeInterval) -> UUID? {
        let ranked = scores.filter { $0.1.isFinite && $0.1 > 0.12 }.sorted { $0.1 > $1.1 }
        guard timestamp.isFinite, let best = ranked.first else {
            self = Self(); return nil
        }
        if timestamp < lastTimestamp || timestamp - lastTimestamp > 1 {
            self = Self()
        }
        lastTimestamp = timestamp
        guard let current = ranked.first(where: { $0.0 == selected }) else {
            selected = best.0; challenger = nil; return selected
        }
        guard best.0 != current.0, best.1 > current.1 * 1.22 + 0.025 else {
            challenger = nil; return selected
        }
        if challenger != best.0 { challenger = best.0; challengeStarted = timestamp }
        if timestamp - challengeStarted >= 0.55 { selected = best.0; challenger = nil }
        return selected
    }
}

/// Small, upright, top-left-origin image evidence. No camera buffers or UI objects.
struct CompositionRaster: Sendable {
    let side: Int
    let luminance: [Double]
    let attention: [Double]
    let edges: [Double]
    let hasAttention: Bool

    var isValid: Bool {
        (8...64).contains(side) && luminance.count == side * side &&
        attention.count == luminance.count && edges.count == luminance.count &&
        luminance.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        attention.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        edges.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func value(_ values: [Double], at point: CGPoint) -> Double {
        guard side > 0, values.count == side * side, point.x.isFinite, point.y.isFinite else { return 0 }
        let x = min(side - 1, max(0, Int(point.x * CGFloat(side))))
        let y = min(side - 1, max(0, Int(point.y * CGFloat(side))))
        return values[y * side + x]
    }

    func evidence(in rect: CGRect) -> SubjectVisualEvidence? {
        guard isValid, rect.width > 0, rect.height > 0 else { return nil }
        var count = 0.0, light = 0.0, square = 0.0, detail = 0.0, mass = 0.0
        var outside = 0.0, outsideCount = 0.0
        let surround = rect.insetBy(dx: -0.08, dy: -0.08)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let p = CGPoint(x: (Double(x) + 0.5) / Double(side), y: (Double(y) + 0.5) / Double(side))
                if rect.contains(p) {
                    count += 1; light += luminance[i]; square += luminance[i] * luminance[i]
                    mass += attention[i]; detail += edges[i]
                } else if surround.contains(p) { outside += luminance[i]; outsideCount += 1 }
            }
        }
        guard count > 0 else { return nil }
        let mean = light / count
        let contrast = sqrt(max(0, square / count - mean * mean))
        let exposure = min(1, max(0, min(mean, 1 - mean) / 0.16))
        return SubjectVisualEvidence(attentionDensity: mass / count,
            attentionShare: mass / max(0.001, attention.reduce(0, +)),
            separation: min(1, abs(mean - outside / max(1, outsideCount)) * 3),
            detail: min(1, (max(0, detail / count - 0.015) + max(0, contrast - 0.01)) * 2), exposure: exposure)
    }

    /// A line needs edge support across the image, not just a local bright patch.
    var horizon: (y: CGFloat, confidence: Double)? {
        guard isValid else { return nil }
        var best: (CGFloat, Double)?
        for y in side / 5..<(side * 4 / 5) {
            var energy = 0.0, supported = 0.0
            for x in 0..<side {
                let delta = abs(luminance[(y + 1) * side + x] - luminance[(y - 1) * side + x])
                energy += delta
                if delta > 0.055 { supported += 1 }
            }
            let score = min(1, energy / Double(side) * 4) * supported / Double(side)
            if score > (best?.1 ?? 0.16) { best = (CGFloat(Double(y) / Double(side)), score) }
        }
        return best.map { (y: $0.0, confidence: $0.1) }
    }

    /// A measured texture patch can guide scenery without pretending to identify an object.
    var sceneryAnchor: CGPoint? {
        guard isValid else { return nil }
        var best: (CGPoint, Double)?
        for y in side / 5..<(side * 4 / 5) {
            for x in side / 5..<(side * 4 / 5) {
                let i = y * side + x
                let score = edges[i] * (0.5 + attention[i])
                let point = CGPoint(x: (Double(x) + 0.5) / Double(side),
                                    y: (Double(y) + 0.5) / Double(side))
                if score > (best?.1 ?? 0.04) { best = (point, score) }
            }
        }
        return best?.0
    }
}

struct CompositionProposal: Sendable {
    let subjectIndex: Int
    let intent: LocalCompositionIntent
    let subjectPoint: CGPoint
    let aimPoint: CGPoint
    let expectedSubjectRect: CGRect
    /// Top-left, top-right, bottom-right, bottom-left in the original camera image.
    let sourceCorners: [CGPoint]
    let rotation: simd_quatd
    let zoom: CGFloat
    let evidenceConfidence: Double
    var score: Double
    let explanation: String
    let usesCenter: Bool

    var isUnchangedView: Bool {
        let original = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        return sourceCorners.count == 4 && zip(sourceCorners, original).allSatisfy {
            hypot($0.x - $1.x, $0.y - $1.y) < 0.00001
        }
    }

    var preferenceKey: String {
        let x = min(2, max(0, Int(expectedSubjectRect.midX * 3)))
        let size = min(3, max(0, Int(expectedSubjectRect.width * expectedSubjectRect.height * 8)))
        return intent.rawValue + "|" + String(x) + "|" + String(size)
    }
}

/// Bounded search over real, visible camera rays. Scores are heuristic comparisons,
/// never calibrated probabilities that a photographer will like an image.
enum CompositionPlanner {
    private static let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                  CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

    static func photographicProposals(subject: CompositionSubject, intents: [LocalCompositionIntent],
        portraitBounds: CGRect?, raster: CompositionRaster, calibration: TrackingCalibration,
        currentZoom: CGFloat, allowedZooms: [CGFloat], protectedBounds: [CGRect] = [],
        incidentalBounds: [CGRect] = [], proposalLimit: Int = 36, refining: [CompositionProposal] = [],
        isCancelled: () -> Bool = { false }) -> [CompositionProposal] {
        let perIntent = max(6, proposalLimit / max(1, intents.count))
        let batches = intents.map { intent -> [CompositionProposal] in
            if !refining.isEmpty && !refining.contains(where: { $0.intent == intent }) { return [] }
            let bounds: CGRect
            if intent == .portrait, subject.kind == .person, let portraitBounds,
               subject.bounds.contains(portraitBounds), portraitBounds.contains(subject.anchor) {
                bounds = portraitBounds
            } else { bounds = subject.bounds }
            let framed = CompositionSubject(index: subject.index, bounds: bounds, anchor: subject.anchor,
                kind: subject.kind, confidence: subject.confidence, importance: subject.importance, gaze: subject.gaze)
            return proposals(subjects: [framed], intents: [intent], raster: raster, calibration: calibration,
                currentZoom: currentZoom, allowedZooms: allowedZooms, protectedBounds: protectedBounds,
                incidentalBounds: incidentalBounds, proposalLimit: perIntent,
                refining: refining.filter { $0.intent == intent }, isCancelled: isCancelled)
        }
        let candidates = batches.flatMap { $0 }
        var result = diverse(candidates, limit: proposalLimit, raySeparation: 0.008, zoomSeparation: 0.018)
        if refining.isEmpty, let original = candidates.first(where: \.isUnchangedView),
           !result.contains(where: \.isUnchangedView) {
            result = Array(result.prefix(max(0, proposalLimit - 1))) + [original]
        }
        return result
    }

    static func proposals(subjects: [CompositionSubject], intents: [LocalCompositionIntent],
                          raster: CompositionRaster, calibration: TrackingCalibration,
                          currentZoom: CGFloat, allowedZooms: [CGFloat], protectedBounds: [CGRect] = [],
                          incidentalBounds: [CGRect] = [],
                          proposalLimit: Int = 6, refining: [CompositionProposal] = [],
                          isCancelled: () -> Bool = { false }) -> [CompositionProposal] {
        guard raster.isValid, calibration.isValid, currentZoom.isFinite, currentZoom > 0 else { return [] }
        let horizonHint = raster.horizon
        let validSubjects = subjects.filter {
            valid($0.bounds) && inside($0.anchor, margin: 0) && $0.bounds.contains($0.anchor) &&
                $0.confidence.isFinite && $0.importance.isFinite && $0.gaze.isFinite
        }
        let protectedPeople = validSubjects.filter { $0.kind == .person || $0.kind == .face || $0.kind == .group }
        let protectedRects = protectedPeople.map(\.bounds) + protectedBounds.filter { valid($0) }
        let incidentalRects = incidentalBounds.filter { valid($0) }
        let hardwareMax = allowedZooms.filter { $0.isFinite && $0 > 0 }.max() ?? currentZoom
        // Avoid throwing away excessive source resolution. Lens availability is
        // supplied by CameraService; existing long telephoto framing remains valid.
        let maxZoom = max(currentZoom, min(5, hardwareMax, currentZoom * 2.4))
        let zooms = Array(Set((0...10).map {
            currentZoom * CGFloat(exp(log(Double(maxZoom / currentZoom)) * Double($0) / 10))
        } + allowedZooms.filter { $0.isFinite && $0 >= currentZoom && $0 <= maxZoom })).sorted()
        var result: [CompositionProposal] = []
        for subject in validSubjects.prefix(4) {
            for intent in applicableIntents(subject: subject, preferred: intents, people: protectedPeople) {
                if isCancelled() { return [] }
                let desired = preferredPlacement(subject: subject, intent: intent, raster: raster)
                func evaluate(_ destination: CGPoint, zoom: CGFloat) -> CompositionProposal? {
                    let unchanged = zoom == currentZoom && hypot(destination.x - subject.anchor.x,
                                                                  destination.y - subject.anchor.y) < 0.000001
                    guard inside(destination, margin: unchanged ? 0 : 0.04), zoom.isFinite,
                          zoom >= currentZoom, zoom <= maxZoom else { return nil }
                    let ratio = Double(zoom / currentZoom)
                    let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                        cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect, isMeasured: false)
                    let rotation = simd_quatd(from: future.deviceRay(at: destination),
                                             to: calibration.deviceRay(at: subject.anchor))
                    let sourceCorners = corners.map {
                        calibration.project(deviceRay: rotation.act(future.deviceRay(at: $0)))
                    }
                    guard sourceCorners.allSatisfy({ $0.isInFront && inside($0.point, margin: -0.00001) }),
                          let box = project(subject.bounds, from: calibration, to: future, rotation: rotation),
                          safe(box, original: subject.bounds),
                          protectedRects.allSatisfy({ original in
                              guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return false }
                              return safe(rect, original: original)
                          }), incidentalRects.allSatisfy({ original in
                              guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return true }
                              let fraction = visibleFraction(rect)
                              return fraction <= 0.02 || fraction >= 0.98
                          }) else { return nil }
                    let aim = calibration.project(deviceRay: rotation.act(SIMD3(0, 0, -1)))
                    guard aim.isInFront, inside(aim.point, margin: 0) else { return nil }
                    let metrics = measure(raster: raster, subject: subject, box: box,
                        calibration: calibration, future: future, rotation: rotation, protectedPeople: protectedPeople)
                    let desiredArea: Double
                    switch intent {
                    case .portrait: desiredArea = subject.kind == .face ? 0.16 : 0.34
                    case .environmentalPortrait, .street: desiredArea = 0.13
                    case .group: desiredArea = 0.40
                    case .landscape: desiredArea = 0.15
                    case .architecture: desiredArea = 0.48
                    case .closeUp, .food: desiredArea = 0.40
                    case .animal, .object: desiredArea = 0.32
                    }
                    let area = Double(box.width * box.height)
                    let sizeFit = subject.kind == .scenery ? 1 : exp(-pow(log(max(0.001, area) / desiredArea), 2) / 1.6)
                    let placement = exp(-12 * pow(Double(destination.x - desired.x), 2) -
                                        10 * pow(Double(destination.y - desired.y), 2))
                    let context = intent.preservesContext && raster.hasAttention ? metrics.retention : 1
                    let contextFit = intent.preservesContext ? min(1, 1 / (ratio * ratio * 0.72)) : 1
                    let space = abs(subject.gaze) > 0.12 ? metrics.lookRoom : metrics.balance
                    let symmetry = intent == .architecture ? metrics.symmetry : metrics.balance
                    let person = subject.kind == .person || subject.kind == .face || subject.kind == .group
                    let headroom = person ? exp(-pow((Double(box.minY) - 0.075) / 0.14, 2)) : 1
                    let margin = min(box.minX, box.minY, 1 - box.maxX, 1 - box.maxY)
                    let edgeSafety = min(1, max(0, Double(margin) / 0.07))
                    var horizonFit = 1.0
                    if intent == .landscape, let horizon = horizonHint {
                        let p = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: CGPoint(x: 0.5, y: horizon.y))))
                        if p.isInFront {
                            let distance = min(abs(Double(p.point.y) - 0.382), abs(Double(p.point.y) - 0.618))
                            horizonFit = 1 - horizon.confidence * min(1, distance * 4)
                        }
                    }
                    let motion = hypot(Double(aim.point.x - 0.5), Double(aim.point.y - 0.5))
                    let intentPrior = intent == intents.first ? 0.045 : (intents.contains(intent) ? 0.02 : 0)
                    let score = 0.18 * sizeFit + 0.13 * context + 0.10 * contextFit +
                        0.11 * metrics.cleanEdges + 0.10 * space + 0.07 * symmetry +
                        0.05 * metrics.separation + 0.11 * placement + 0.05 * headroom +
                        0.04 * edgeSafety + 0.03 * horizonFit + intentPrior -
                        0.035 * motion - 0.035 * abs(log(ratio))
                    return CompositionProposal(subjectIndex: subject.index, intent: intent,
                        subjectPoint: subject.anchor, aimPoint: aim.point, expectedSubjectRect: box,
                        sourceCorners: sourceCorners.map(\.point), rotation: rotation, zoom: zoom,
                        evidenceConfidence: min(1, max(0, subject.confidence)), score: score,
                        explanation: explanation(intent: intent, gaze: subject.gaze,
                            cleanEdges: metrics.cleanEdges, context: raster.hasAttention ? context : 0),
                        usesCenter: abs(destination.x - 0.5) < 0.055)
                }
                if !refining.isEmpty {
                    for seed in refining where seed.subjectIndex == subject.index && seed.intent == intent {
                        let ratio = Double(seed.zoom / currentZoom)
                        let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                            cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
                        let p = future.project(deviceRay: seed.rotation.inverse.act(calibration.deviceRay(at: subject.anchor)))
                        guard p.isInFront else { continue }
                        // Score neighbours with the learned model on the next pass.
                        // A slightly wider crop is a real alternative, not an
                        // assumption that more zoom always improves a photograph.
                        for axis in 0..<3 { for sign in [-1.0, 1.0] {
                            if isCancelled() { return [] }
                            let destination = CGPoint(x: p.point.x + (axis == 0 ? sign * 0.018 : 0),
                                                      y: p.point.y + (axis == 1 ? sign * 0.018 : 0))
                            let zoom = axis == 2 ? seed.zoom * CGFloat(exp(sign * 0.045)) : seed.zoom
                            if let neighbour = evaluate(destination, zoom: zoom) { result.append(neighbour) }
                        } }
                    }
                    continue
                }
                var seeds: [CompositionProposal] = []
                var placements = [subject.anchor, desired, CGPoint(x: 0.5, y: 0.5)]
                for y in 0...4 { for x in 0...4 {
                    placements.append(CGPoint(x: 0.22 + Double(x) * 0.14, y: 0.22 + Double(y) * 0.14))
                } }
                for zoom in zooms {
                    for destination in placements {
                        if isCancelled() { return [] }
                        if let plan = evaluate(destination, zoom: zoom) { seeds.append(plan) }
                    }
                }
                // Refine in continuous pan/tilt/log-focal-length space. Coarse
                // grids seed the solver; they never restrict the final target.
                for seed in diverse(seeds, limit: 3) {
                    var best = seed
                    for step in [0.035, 0.0175, 0.00875] {
                        let ratio = Double(best.zoom / currentZoom)
                        let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                            cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect, isMeasured: false)
                        let p = future.project(deviceRay: best.rotation.inverse.act(calibration.deviceRay(at: subject.anchor))).point
                        for axis in 0..<3 { for sign in [-1.0, 1.0] {
                            if isCancelled() { return [] }
                            let destination = CGPoint(x: p.x + (axis == 0 ? sign * step : 0),
                                                      y: p.y + (axis == 1 ? sign * step : 0))
                            let zoom = axis == 2 ? best.zoom * CGFloat(exp(sign * step * 2)) : best.zoom
                            if let refined = evaluate(destination, zoom: zoom), refined.score > best.score { best = refined }
                        } }
                    }
                    result.append(best)
                }
                if proposalLimit > 6 {
                    result.append(contentsOf: seeds)
                } else {
                    result.append(contentsOf: seeds.sorted { $0.score > $1.score }.prefix(6))
                }
            }
        }
        guard !isCancelled() else { return [] }
        if !refining.isEmpty {
            return diverse(result, limit: proposalLimit, raySeparation: 0.008, zoomSeparation: 0.018)
        }
        guard proposalLimit > 6 else { return diverse(result, limit: proposalLimit) }
        // Preserve a no-change baseline and explore several focal lengths and
        // directions, including crops that do not match the heuristic's favourite.
        var selected = result.filter(\.isUnchangedView).prefix(1).map { $0 }
        selected += diverse(result, limit: proposalLimit / 3, raySeparation: 0.035, zoomSeparation: 0.07)
        var buckets: [String: CompositionProposal] = [:]
        for proposal in result {
            let z = Int((log(Double(proposal.zoom / currentZoom)) * 12).rounded())
            let x = Int((proposal.aimPoint.x * 6).rounded())
            let y = Int((proposal.aimPoint.y * 6).rounded())
            let key = "\(z)|\(x)|\(y)|\(proposal.intent.rawValue)"
            if proposal.score > (buckets[key]?.score ?? -.infinity) { buckets[key] = proposal }
        }
        let explored = buckets.keys.sorted().compactMap { buckets[$0] }
        if !explored.isEmpty {
            for index in 0..<proposalLimit {
                selected.append(explored[min(explored.count - 1, index * explored.count / proposalLimit)])
            }
        }
        // Keep exploration in the shortlist even when its heuristic score is low.
        var unique: [CompositionProposal] = []
        for proposal in selected + result.sorted(by: { $0.score > $1.score }) {
            if !unique.contains(where: { hypot($0.aimPoint.x - proposal.aimPoint.x, $0.aimPoint.y - proposal.aimPoint.y) < 0.025 &&
                abs(log(Double($0.zoom / proposal.zoom))) < 0.055 }) { unique.append(proposal) }
            if unique.count == proposalLimit { break }
        }
        return unique
    }

    private static func preferredPlacement(subject: CompositionSubject, intent: LocalCompositionIntent,
                                           raster: CompositionRaster) -> CGPoint {
        if intent == .group { return CGPoint(x: 0.5, y: 0.36) }
        if intent == .architecture || intent == .food { return CGPoint(x: 0.5, y: 0.5) }
        let person = subject.kind == .person || subject.kind == .face
        let lead = min(1, max(-1, Double(subject.gaze)))
        // Positive gaze means image-right: subject belongs left of centre.
        var x = 0.5 - 0.145 * lead
        if abs(lead) < 0.12 && intent != .landscape {
            var left = 0.0, right = 0.0
            for y in 0..<raster.side { for column in 0..<raster.side {
                let weight = raster.attention[y * raster.side + column]
                if column < raster.side / 2 { left += weight } else { right += weight }
            } }
            let imbalance = (right - left) / max(0.001, right + left)
            x += min(0.118, max(-0.118, -imbalance * 0.18))
        }
        let anchorFraction = Double((subject.anchor.y - subject.bounds.minY) / subject.bounds.height)
        let y = person ? min(0.48, max(0.30, 0.075 + anchorFraction * 0.64)) : 0.5
        return CGPoint(x: x, y: y)
    }


    static func diverse(_ proposals: [CompositionProposal], limit: Int,
                        raySeparation: CGFloat = 0.065, zoomSeparation: Double = 0.15) -> [CompositionProposal] {
        guard limit > 0 else { return [] }
        var selected: [CompositionProposal] = []
        for proposal in proposals.filter({ $0.score.isFinite }).sorted(by: { $0.score > $1.score }) {
            let duplicate = selected.contains { previous in
                let rayDistance = hypot(previous.aimPoint.x - proposal.aimPoint.x,
                                        previous.aimPoint.y - proposal.aimPoint.y)
                return previous.subjectIndex == proposal.subjectIndex && rayDistance < raySeparation &&
                    abs(log(Double(previous.zoom / proposal.zoom))) < zoomSeparation
            }
            if !duplicate { selected.append(proposal) }
            if selected.count == limit { break }
        }
        return selected
    }

    static func visibleFraction(_ rect: CGRect) -> Double {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return 0 }
        let overlap = rect.intersection(frame)
        guard !overlap.isNull, !overlap.isEmpty else { return 0 }
        return min(1, max(0, Double(overlap.width * overlap.height / (rect.width * rect.height))))
    }

    private static func applicableIntents(subject: CompositionSubject,
                                         preferred: [LocalCompositionIntent],
                                         people: [CompositionSubject]) -> [LocalCompositionIntent] {
        if subject.kind == .scenery { return [.landscape] }
        if subject.kind == .group { return [.group] }
        if subject.kind == .person || subject.kind == .face {
            let others = people.filter { $0.index != subject.index &&
                !subject.bounds.insetBy(dx: -0.02, dy: -0.02).contains($0.bounds) &&
                !$0.bounds.insetBy(dx: -0.02, dy: -0.02).contains(subject.bounds) }
            if !others.isEmpty { return [.group] }
            if preferred.contains(.environmentalPortrait) || preferred.contains(.landscape) ||
                preferred.contains(.architecture) || preferred.contains(.street) {
                let explicit = preferred.filter { $0 == .environmentalPortrait || $0 == .portrait }
                return explicit.isEmpty ? [.environmentalPortrait, .portrait] : explicit
            }
            return preferred.contains(.portrait) ? [.portrait] : [.portrait, .environmentalPortrait]
        }
        if subject.kind == .animal { return [.animal] }
        let applicable = preferred.filter { [.landscape, .architecture, .closeUp, .food, .street, .object].contains($0) }
        return applicable.isEmpty ? [.object] : Array(applicable.prefix(2))
    }

    private struct Metrics {
        let retention: Double
        let cleanEdges: Double
        let balance: Double
        let lookRoom: Double
        let separation: Double
        let symmetry: Double
    }

    private static func measure(raster: CompositionRaster, subject: CompositionSubject, box: CGRect,
                                calibration: TrackingCalibration,
                                future: TrackingCalibration, rotation: simd_quatd,
                                protectedPeople: [CompositionSubject]) -> Metrics {
        var total = 0.0, retained = 0.0
        for y in 0..<raster.side {
            for x in 0..<raster.side {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(raster.side),
                                y: (Double(y) + 0.5) / Double(raster.side))
                let weight = raster.attention[y * raster.side + x]
                total += weight
                let mapped = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: p)))
                if mapped.isInFront && inside(mapped.point, margin: 0) { retained += weight }
            }
        }
        var weightSum = 0.0, weightedX = 0.0, weightedY = 0.0
        var border = 0.0, borderCount = 0.0, subjectLight = 0.0, subjectCount = 0.0
        var surroundLight = 0.0, surroundCount = 0.0, symmetryError = 0.0
        let side = 12
        for y in 0..<side {
            for x in 0..<side {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(side), y: (Double(y) + 0.5) / Double(side))
                let original = calibration.project(deviceRay: rotation.act(future.deviceRay(at: p))).point
                let attention = raster.value(raster.attention, at: original)
                let edge = raster.value(raster.edges, at: original)
                let luma = raster.value(raster.luminance, at: original)
                let weight = 0.1 + attention
                weightSum += weight; weightedX += Double(p.x) * weight; weightedY += Double(p.y) * weight
                if box.contains(p) { subjectLight += luma; subjectCount += 1 }
                else if box.insetBy(dx: -0.12, dy: -0.12).contains(p) {
                    surroundLight += luma; surroundCount += 1
                }
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                    if !subject.bounds.contains(original) && !protectedPeople.contains(where: { $0.bounds.contains(original) }) {
                        border += 0.6 * attention + 0.4 * edge
                    }
                    borderCount += 1
                }
                let mirror = CGPoint(x: 1 - p.x, y: p.y)
                let mirroredSource = calibration.project(deviceRay: rotation.act(future.deviceRay(at: mirror))).point
                symmetryError += abs(luma - raster.value(raster.luminance, at: mirroredSource))
            }
        }
        let centerDistance = hypot(weightedX / max(weightSum, 0.001) - 0.5,
                                   weightedY / max(weightSum, 0.001) - 0.5)
        let room = subject.gaze >= 0 ? Double(1 - box.maxX) : Double(box.minX)
        let opposite = subject.gaze >= 0 ? Double(box.minX) : Double(1 - box.maxX)
        let separation = subjectCount > 0 && surroundCount > 0 ?
            abs(subjectLight / subjectCount - surroundLight / surroundCount) : 0
        return Metrics(retention: total > 0.001 ? retained / total : 1,
            cleanEdges: 1 - min(1, border / max(1, borderCount)),
            balance: 1 - min(1, centerDistance * 2),
            lookRoom: min(1, max(0, 0.5 + (room - opposite) * 1.5)),
            separation: min(1, separation * 3),
            symmetry: 1 - min(1, symmetryError / Double(side * side) * 3))
    }

    private static func explanation(intent: LocalCompositionIntent, gaze: CGFloat,
                                    cleanEdges: Double, context: Double) -> String {
        let purpose: String
        switch intent {
        case .portrait: purpose = "Ưu tiên người và khoảng đầu."
        case .environmentalPortrait: purpose = "Giữ người cùng bối cảnh để ảnh có câu chuyện."
        case .group: purpose = "Giữ các khuôn mặt và phần người đang nhìn thấy trong khung."
        case .landscape: purpose = "Giữ các vùng nổi bật và không gian của cảnh."
        case .architecture: purpose = "Cân bằng công trình với khoảng trống xung quanh."
        case .closeUp: purpose = "Làm rõ chi tiết, giữ trọn vùng hoa lá được nhận diện."
        case .food: purpose = "Nhấn vào món ăn và giữ mép chủ thể."
        case .animal: purpose = "Giữ dáng và khoảng trống quanh thú cưng."
        case .object: purpose = "Làm rõ chủ thể và giữ đường viền trong khung."
        case .street: purpose = "Giữ người, hoạt động và bối cảnh đường phố."
        }
        if abs(gaze) > 0.12 && (intent == .portrait || intent == .environmentalPortrait) {
            return purpose + " Chừa khoảng trống theo hướng quay đầu."
        }
        if intent.preservesContext && context >= 0.85 { return purpose + " Phương án giữ phần lớn vùng thu hút chú ý." }
        return purpose + (cleanEdges > 0.72 ? " Mép khung ít chi tiết gây phân tán." : " Kiểm tra chi tiết sát mép trước khi chụp.")
    }

    static func project(_ rect: CGRect, from source: TrackingCalibration,
                        to output: TrackingCalibration, rotation: simd_quatd) -> CGRect? {
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let mapped = points.map { output.project(deviceRay: rotation.inverse.act(source.deviceRay(at: $0))) }
        guard mapped.allSatisfy({ $0.isInFront && $0.point.x.isFinite && $0.point.y.isFinite }),
              let x0 = mapped.map(\.point.x).min(), let x1 = mapped.map(\.point.x).max(),
              let y0 = mapped.map(\.point.y).min(), let y1 = mapped.map(\.point.y).max() else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
        rect.width > 0.01 && rect.height > 0.01 && frame.contains(rect)
    }

    private static func inside(_ point: CGPoint, margin: CGFloat) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= margin && point.y >= margin &&
        point.x <= 1 - margin && point.y <= 1 - margin
    }

    private static func safe(_ rect: CGRect, original: CGRect) -> Bool {
        // Do not cut any additional part of a subject already touching the source edge.
        rect.minX >= min(0.025, original.minX) - 0.00001 &&
        rect.minY >= min(0.025, original.minY) - 0.00001 &&
        rect.maxX <= max(0.975, original.maxX) + 0.00001 &&
        rect.maxY <= max(0.975, original.maxY) + 0.00001
    }
}
