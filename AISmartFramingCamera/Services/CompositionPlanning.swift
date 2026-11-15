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
    /// Torso measurements protect anatomy; attention fields protect their anchor.
    /// The planner separately enforces measured attention retention. This crop
    /// constraint never replaces a physical subject or the full tracking seed.
    static func bounds(body: CGRect, portrait: CGRect?, intent: LocalCompositionIntent,
                       anchor: CGPoint, attentionRegion: Bool = false) -> CGRect {
        if attentionRegion, body.contains(anchor), body.width > 0, body.height > 0 {
            let width = min(0.08, body.width), height = min(0.08, body.height)
            let clampedX = min(0.95 - width, max(0.05, min(body.maxX - width, max(body.minX, anchor.x - width / 2))))
            let clampedY = min(0.95 - height, max(0.05, min(body.maxY - height, max(body.minY, anchor.y - height / 2))))
            return CGRect(x: clampedX, y: clampedY, width: width, height: height)
        }
        if intent == .portrait, let portrait,
           [portrait.minX, portrait.minY, portrait.width, portrait.height].allSatisfy(\.isFinite),
           portrait.width > 0, portrait.height > 0,
           body.contains(portrait), portrait.contains(anchor) {
            return portrait
        }
        return body
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
    var allowsAttentionCrop = false
    var verticalGaze: CGFloat = 0
    var shotScaleBias: Double = 0
    var contextPreservationWeight: Double = 0.5
    var isAttentionOnly: Bool = false
}

/// Photographic importance is independent of detector certainty. In particular,
/// texture/noise can support a subject, but cannot turn it into a detected person.
struct SubjectVisualEvidence: Sendable {
    let attentionDensity: Double
    let attentionShare: Double
    let separation: Double
    let detail: Double
    let exposure: Double
    var foregroundDepth: Double = 0.5
    var syncAttention: Double? = nil
    var depthContrast: Double? = nil
}

enum HeroSubjectPolicy {
    static func faceAffinity(face: CGRect, body: CGRect) -> Double? {
        guard body.width > 0, body.height > 0,
              body.insetBy(dx: -body.width * 0.15, dy: -body.height * 0.20).contains(CGPoint(x: face.midX, y: face.midY)) else { return nil }
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
        case .scenery: semantic = 0.45
        }
        let visual: Double
        if let e = evidence {
            let syncBoost = e.syncAttention.map { 0.08 * $0 } ?? 0.0
            let depthIsolation = e.depthContrast.map { 0.05 * $0 } ?? 0.0
            visual = 0.18 * e.attentionDensity + 0.15 * sqrt(max(0, e.attentionShare)) +
                0.10 * e.separation + 0.06 * e.detail * e.exposure + 0.07 * max(0, e.foregroundDepth - 0.35) +
                syncBoost + depthIsolation
        } else { visual = 0.20 * scale }
        let touchesBorder = bounds.minX <= 0.025 || bounds.maxX >= 0.975 || bounds.minY <= 0.025 || bounds.maxY >= 0.975
        let distCenter = hypot(Double(bounds.midX - 0.5), Double(bounds.midY - 0.52))
        let share = evidence?.attentionShare ?? 0.5
        let fgDepth = evidence?.foregroundDepth ?? 0.5
        let syncAtt = evidence?.syncAttention ?? 0.5

        let tierMultiplier: Double
        switch kind {
        case .person, .group:
            let syncLow = evidence != nil && syncAtt < 0.16 && fgDepth < 0.42
            let distantBystander = !hasFace && (area < 0.045 || fgDepth < 0.28 || syncLow) && bounds.maxY < 0.60
            let bottomClippedPasserby = !hasFace && bounds.maxY >= 0.96 && bounds.height < 0.28 && area < 0.08
            let tinyEdgePedestrian = !hasFace && area < 0.024 && distCenter > 0.34
            if hasFace {
                tierMultiplier = 1.30
            } else if bottomClippedPasserby {
                tierMultiplier = 0.26
            } else if tinyEdgePedestrian {
                tierMultiplier = 0.44
            } else if distantBystander {
                tierMultiplier = 0.52
            } else {
                tierMultiplier = 1.12
            }
        case .face: tierMultiplier = 1.20
        case .animal:
            let backgroundPet = area < 0.025 && fgDepth < 0.30 && bounds.maxY < 0.56
            tierMultiplier = backgroundPet ? 0.68 : 1.10
        case .object:
            let bloatedRegion = area > 0.46 && (share < 0.32 || fgDepth < 0.50)
            let focusedLargeSubject = area > 0.46 && share >= 0.32 && fgDepth >= 0.50
            let edgeSliver = touchesBorder && (bounds.width < 0.16 || bounds.height < 0.16) && distCenter > 0.32
            let borderWeakBlob = touchesBorder && (share < 0.09 || syncAtt < 0.26 || distCenter > 0.38)
            let peripheralCorner = distCenter > 0.38 && share < 0.12
            let crispForegroundObject = (0.02...0.38).contains(area) && distCenter < 0.34
            if bloatedRegion {
                tierMultiplier = 0.52
            } else if edgeSliver {
                tierMultiplier = 0.54
            } else if borderWeakBlob {
                tierMultiplier = 0.58
            } else if peripheralCorner {
                tierMultiplier = 0.72
            } else if crispForegroundObject {
                tierMultiplier = 1.04
            } else if focusedLargeSubject {
                tierMultiplier = 0.96
            } else {
                tierMultiplier = 0.88
            }
        case .scenery: tierMultiplier = 0.45
        }
        let tinyPenalty = min(1, area / (kind == .face ? 0.002 : 0.008))
        return max(0, min(1, confidence)) * tinyPenalty * tierMultiplier *
            (0.25 * semantic + 0.19 * scale + 0.07 * centrality + visual)
    }

    /// Comparable scale and spatial proximity distinguish a group from passers-by.
    static func coherent(_ a: CGRect, _ b: CGRect) -> Bool {
        guard a.height > 0, b.height > 0 else { return false }
        let scaleRatio = min(a.height, b.height) / max(a.height, b.height)
        let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let verticalGap = abs(a.midY - b.midY)
        return scaleRatio >= 0.48 && horizontalGap <= max(max(a.width, b.width) * 2.5, 0.42) &&
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

struct SynchronizedSaliencyCluster: Sendable {
    let bounds: CGRect
    let anchor: CGPoint
    let peakValue: Double
    let meanSync: Double
    let meanDepth: Double
    let dominance: Double
    let area: Double
}

enum SemanticCompositionRole: String, Sendable {
    case portrait
    case group
    case animal
    case food
    case flower
    case streetLeading = "street_leading"
    case architecture
    case landscapeSky = "landscape_sky"
    case foliageGarden = "foliage_garden"
    case deskWorkspace = "desk_workspace"
    case tabletopEnsemble = "tabletop_ensemble"
    case indoorRoom = "indoor_room"
    case apertureView = "aperture_view"
    case general

    var isDiscreteRole: Bool {
        self == .portrait || self == .animal || self == .tabletopEnsemble || self == .deskWorkspace
    }

    var isWideRole: Bool {
        self == .indoorRoom || self == .foliageGarden || self == .apertureView ||
        self == .architecture || self == .streetLeading || self == .landscapeSky
    }
}

struct EdgeAvoidanceHints: Sendable {
    var left: Double = 0.0
    var right: Double = 0.0
    var top: Double = 0.0
    var bottom: Double = 0.0
    var maxAvoid: Double { max(left, max(right, max(top, bottom))) }
    var directionalWeightSum: Double {
        (left > 0.20 ? left : 0.0) + (right > 0.20 ? right : 0.0) +
        (top > 0.20 ? top : 0.0) + (bottom > 0.20 ? bottom : 0.0)
    }
    static let zero = EdgeAvoidanceHints()
}

struct FocalAccentHint: Sendable {
    let point: CGPoint
    let strength: Double
}

struct VanishingPointHint: Sendable {
    let point: CGPoint
    let confidence: Double
}

struct CleanInterestCluster: Sendable {
    let bounds: CGRect
    let anchor: CGPoint
    let area: Double
    let score: Double
}

struct CompositionSceneHints: Sendable {
    var role: SemanticCompositionRole = .general
    var avoid: EdgeAvoidanceHints = .zero
    var cleanInterest: [Double] = []
    var clutterMap: [Double] = []
    var blankSurface: [Double] = []
    var skyFraction: Double = 0.0
    var archRoofTopY: Double? = nil
    var estimatedHorizonY: Double? = nil
    var focalAccent: FocalAccentHint? = nil
    var refinedVanishingPoint: VanishingPointHint? = nil
    var hasRichGuidance: Bool = false
    var reasonSubject: String = ""

    static let neutral = CompositionSceneHints()

    func clutterDensity(in rect: CGRect, side: Int) -> Double {
        guard side > 0, clutterMap.count == side * side, rect.width > 0, rect.height > 0 else { return 0.0 }
        let x0 = max(0, min(side - 1, Int(Double(rect.minX) * Double(side))))
        let x1 = max(x0 + 1, min(side, Int(ceil(Double(rect.maxX) * Double(side)))))
        let y0 = max(0, min(side - 1, Int(Double(rect.minY) * Double(side))))
        let y1 = max(y0 + 1, min(side, Int(ceil(Double(rect.maxY) * Double(side)))))
        var sum = 0.0
        var count = 0
        for y in y0..<y1 {
            let row = y * side
            for x in x0..<x1 {
                sum += clutterMap[row + x]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0.0
    }

    func trimBoxAwayFromClutter(_ rect: CGRect) -> CGRect {
        var rx0 = Double(rect.minX)
        var ry0 = Double(rect.minY)
        var rx1 = Double(rect.maxX)
        var ry1 = Double(rect.maxY)
        if avoid.left >= 0.42 { rx0 = max(rx0, avoid.left >= 0.65 ? 0.14 : 0.08) }
        if avoid.right >= 0.42 { rx1 = min(rx1, avoid.right >= 0.65 ? 0.86 : 0.90) }
        if avoid.top >= 0.35 { ry0 = max(ry0, avoid.top >= 0.55 ? 0.10 : 0.06) }
        if avoid.bottom >= 0.42 { ry1 = min(ry1, avoid.bottom >= 0.65 ? 0.86 : 0.90) }
        return CGRect(x: rx0, y: ry0, width: max(0.15, rx1 - rx0), height: max(0.15, ry1 - ry0))
    }

    func extractCleanClusters(raster: CompositionRaster, minPeak: Double = 0.22, maxCount: Int = 5) -> [CleanInterestCluster] {
        guard raster.isValid, raster.side > 0 else { return [] }
        let side = raster.side
        let count = side * side
        let interest = cleanInterest.count == count ? cleanInterest : raster.synchronizedSaliency
        let depth = raster.foregroundDepth.count == count ? raster.foregroundDepth : [Double](repeating: 0.5, count: count)
        guard let peak = interest.max(), peak >= minPeak else { return [] }
        let thresh = max(minPeak * 0.72, 0.36 * peak)
        var visited = [Bool](repeating: false, count: count)
        var clusters: [CleanInterestCluster] = []
        let dirs = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for sy in 0..<side {
            for sx in 0..<side {
                let startIdx = sy * side + sx
                if interest[startIdx] < thresh || visited[startIdx] { continue }
                visited[startIdx] = true
                var queue = [startIdx]
                var head = 0
                var minX = sx, maxX = sx, minY = sy, maxY = sy
                var wSum = 0.0, wxSum = 0.0, wySum = 0.0, dSum = 0.0
                while head < queue.count {
                    let idx = queue[head]
                    head += 1
                    let cx = idx % side
                    let cy = idx / side
                    let w = interest[idx]
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    wSum += w
                    wxSum += ((Double(cx) + 0.5) / Double(side)) * w
                    wySum += ((Double(cy) + 0.5) / Double(side)) * w
                    dSum += depth[idx]
                    for (dx, dy) in dirs {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                        let nIdx = ny * side + nx
                        if !visited[nIdx] && interest[nIdx] >= thresh {
                            visited[nIdx] = true
                            queue.append(nIdx)
                        }
                    }
                }
                guard queue.count >= 6, wSum > 1e-6 else { continue }
                let x0 = Double(minX) / Double(side)
                let y0 = Double(minY) / Double(side)
                let x1 = Double(maxX + 1) / Double(side)
                let y1 = Double(maxY + 1) / Double(side)
                let w = x1 - x0, h = y1 - y0
                let meanDepth = dSum / Double(queue.count)
                let score = wSum * (1.0 + 0.35 * meanDepth)
                clusters.append(CleanInterestCluster(
                    bounds: CGRect(x: x0, y: y0, width: w, height: h),
                    anchor: CGPoint(x: wxSum / wSum, y: wySum / wSum),
                    area: w * h,
                    score: score
                ))
            }
        }
        clusters.sort { $0.score > $1.score }
        return Array(clusters.prefix(maxCount))
    }

    static func build(from raster: CompositionRaster,
                      role: SemanticCompositionRole,
                      semanticAvoid: EdgeAvoidanceHints,
                      reasonSubject: String = "") -> CompositionSceneHints {
        let side = raster.side
        let count = side * side
        guard raster.isValid, side > 0, count > 0 else {
            return CompositionSceneHints(role: role, avoid: semanticAvoid, hasRichGuidance: true, reasonSubject: reasonSubject)
        }
        var avoid = semanticAvoid
        avoid.left = max(avoid.left, raster.structuralGeometricAvoidance.left)
        avoid.right = max(avoid.right, raster.structuralGeometricAvoidance.right)

        var clutter = [Double](repeating: 0.0, count: count)
        if avoid.left > 0.18 {
            let xLim = Int(Double(side) * min(0.24, 0.10 + 0.14 * avoid.left))
            let v = avoid.left * 0.90
            for y in 0..<side { for x in 0..<min(side, max(0, xLim)) { clutter[y * side + x] = max(clutter[y * side + x], v) } }
        }
        if avoid.right > 0.18 {
            let xLim = max(0, min(side, Int(Double(side) * max(0.76, 0.90 - 0.14 * avoid.right))))
            let v = avoid.right * 0.90
            for y in 0..<side { for x in xLim..<side { clutter[y * side + x] = max(clutter[y * side + x], v) } }
        }
        if avoid.top > 0.18 {
            let yLim = max(0, min(side, Int(Double(side) * min(0.36, 0.16 + 0.20 * avoid.top))))
            let v = avoid.top * 0.88
            for y in 0..<yLim { for x in 0..<side { clutter[y * side + x] = max(clutter[y * side + x], v) } }
        }
        if avoid.bottom > 0.18 {
            let yLim = max(0, min(side, Int(Double(side) * max(0.66, 0.84 - 0.18 * avoid.bottom))))
            let v = avoid.bottom * 0.88
            for y in yLim..<side { for x in 0..<side { clutter[y * side + x] = max(clutter[y * side + x], v) } }
        }

        for x in 0..<min(side, max(0, raster.structuralEdgePillarColsLeft)) {
            for y in 0..<side { clutter[y * side + x] = max(clutter[y * side + x], 0.80) }
        }
        for dist in 0..<min(side, max(0, raster.structuralEdgePillarColsRight)) {
            let gx = side - 1 - dist
            for y in 0..<side { clutter[y * side + gx] = max(clutter[y * side + gx], 0.80) }
        }

        if (role == .foliageGarden || role == .architecture || role == .apertureView),
           raster.structuralBottomRailMask.count == count {
            let yStartBand = Int(Double(side) * 0.72)
            var foundStart: Int? = nil
            for y in yStartBand..<side {
                var hits = 0
                for x in 0..<side { if raster.structuralBottomRailMask[y * side + x] > 0.5 { hits += 1 } }
                if Double(hits) / Double(side) > 0.18 {
                    foundStart = y
                    break
                }
            }
            if let yStart = foundStart, yStart < Int(Double(side) * 0.94) {
                for y in yStart..<side { for x in 0..<side { clutter[y * side + x] = max(clutter[y * side + x], 0.75) } }
                avoid.bottom = max(avoid.bottom, min(1.0, Double(side - yStart) / (Double(side) * 0.26)))
            }
        }

        if raster.structuralIsolatedWallBlip.count == count {
            for i in 0..<count where raster.structuralIsolatedWallBlip[i] > 0.5 {
                clutter[i] = max(clutter[i], 0.85)
            }
        }

        var focalAccent: FocalAccentHint? = nil
        if raster.structuralChromaticAccentMap.count == count {
            var bestIdx = 0
            var bestVal = 0.0
            for i in 0..<count {
                let v = raster.structuralChromaticAccentMap[i] * (1.0 - min(1.0, max(0.0, clutter[i])))
                if v > bestVal { bestVal = v; bestIdx = i }
            }
            if bestVal >= 0.26 {
                let bx = bestIdx % side, by = bestIdx / side
                focalAccent = FocalAccentHint(
                    point: CGPoint(x: (Double(bx) + 0.5) / Double(side), y: (Double(by) + 0.5) / Double(side)),
                    strength: bestVal
                )
            }
        }

        let blankSurf = raster.structuralBlankSurface.count == count ? raster.structuralBlankSurface : [Double](repeating: 0.0, count: count)
        let skyMask = raster.structuralSkyMask.count == count ? raster.structuralSkyMask : [Double](repeating: 0.0, count: count)
        var cleanInterest = [Double](repeating: 0.0, count: count)
        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let i = y * side + x
                let rawInfo = 0.45 * raster.synchronizedSaliency[i] + 0.30 * raster.attention[i] + 0.25 * min(1.0, raster.edges[i] * 2.2)
                let damp = clutter[i] >= 0.45 ? 0.08 : (1.0 - 0.85 * clutter[i])
                var val = rawInfo * damp * (1.0 - 0.72 * blankSurf[i]) * (1.0 - 0.55 * skyMask[i])
                if let fa = focalAccent {
                    let dxF = px - Double(fa.point.x)
                    let dyF = py - Double(fa.point.y)
                    val = max(val, fa.strength * 0.85 * exp(-(dxF * dxF + dyF * dyF) / (2.0 * 0.08 * 0.08)))
                }
                cleanInterest[i] = min(1.0, max(0.0, val))
            }
        }

        var refinedVP: VanishingPointHint? = nil
        if role == .streetLeading || role == .architecture || role == .apertureView {
            var pxArr: [Double] = [], pyArr: [Double] = []
            var dxArr: [Double] = [], dyArr: [Double] = [], wArr: [Double] = []
            var wTotal = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    let i = y * side + x
                    let gx = raster.luminance[i] - raster.luminance[y * side + max(0, x - 1)]
                    let gy = raster.luminance[i] - raster.luminance[max(0, y - 1) * side + x]
                    let mag = hypot(gx, gy)
                    guard mag > 0.08, clutter[i] < 0.45, skyMask[i] < 0.5 else { continue }
                    let ang = atan2(gy, gx) + .pi / 2.0
                    let s = sin(ang), c = cos(ang)
                    guard abs(s) > 0.22, abs(c) > 0.22 else { continue }
                    pxArr.append((Double(x) + 0.5) / Double(side))
                    pyArr.append((Double(y) + 0.5) / Double(side))
                    dxArr.append(c)
                    dyArr.append(s)
                    wArr.append(mag)
                    wTotal += mag
                }
            }
            if pxArr.count >= 18 {
                var bestSup = 0.0
                var supSum = 0.0
                var bestV = CGPoint(x: 0.5, y: 0.38)
                for yi in 0..<7 {
                    let gy = 0.20 + Double(yi) * (0.58 - 0.20) / 6.0
                    for xi in 0..<7 {
                        let gx = 0.22 + Double(xi) * (0.78 - 0.22) / 6.0
                        var sup = 0.0
                        for k in 0..<pxArr.count {
                            let vx = gx - pxArr[k], vy = gy - pyArr[k]
                            let vlen = hypot(vx, vy) + 1e-6
                            let sinErr = abs(vx * dyArr[k] - vy * dxArr[k]) / vlen
                            if sinErr < 0.14 { sup += wArr[k] * (1.0 - sinErr / 0.14) }
                        }
                        supSum += sup
                        if sup > bestSup { bestSup = sup; bestV = CGPoint(x: gx, y: gy) }
                    }
                }
                let meanSup = supSum / 49.0
                let peakRatio = bestSup / max(1e-4, meanSup)
                let frac = bestSup / max(0.5, wTotal)
                let conf = min(1.0, 0.5 * (peakRatio - 1.0) + 1.4 * frac)
                if conf >= 0.32, bestV.y <= 0.62 {
                    refinedVP = VanishingPointHint(point: bestV, confidence: conf)
                }
            }
            if refinedVP == nil, let mvp = raster.measuredVanishingPoint, mvp.confidence >= 0.32 {
                let rcx = max(0, min(side - 1, Int(Double(mvp.point.x) * Double(side))))
                let rcy = max(0, min(side - 1, Int(Double(mvp.point.y) * Double(side))))
                if clutter[rcy * side + rcx] < 0.45, (0.15...0.62).contains(mvp.point.y) {
                    refinedVP = VanishingPointHint(point: mvp.point, confidence: mvp.confidence)
                }
            }
        }

        let horizonY: Double? = raster.measuredHorizon.map { Double($0.y) } ?? raster.structuralEstimatedHorizonY
        return CompositionSceneHints(
            role: role,
            avoid: avoid,
            cleanInterest: cleanInterest,
            clutterMap: clutter,
            blankSurface: blankSurf,
            skyFraction: raster.structuralSkyFraction,
            archRoofTopY: raster.structuralArchRoofTopY,
            estimatedHorizonY: horizonY,
            focalAccent: focalAccent,
            refinedVanishingPoint: refinedVP,
            hasRichGuidance: true,
            reasonSubject: reasonSubject
        )
    }
}

/// Small, upright, top-left-origin image evidence. No camera buffers or UI objects.
struct CompositionRaster: Sendable {
    let side: Int
    let luminance: [Double]
    let attention: [Double]
    let edges: [Double]
    let edgeAngles: [Double]
    let hasAttention: Bool
    let foregroundDepth: [Double]
    let synchronizedSaliency: [Double]
    let depthGradient: [Double]
    let focalDepthPlane: Double
    let hasCoreMLDepth: Bool
    let subjectAttentionDominance: Double
    var measuredHorizon: (y: CGFloat, confidence: Double)? = nil
    var measuredVanishingPoint: (point: CGPoint, confidence: Double, rayAngles: [Double])? = nil
    var structuralSkyFraction: Double = 0.0
    var structuralArchRoofTopY: Double? = nil
    var structuralEstimatedHorizonY: Double? = nil
    var structuralSkyMask: [Double] = []
    var structuralBlankSurface: [Double] = []
    var structuralIsolatedWallBlip: [Double] = []
    var structuralGeometricAvoidance: EdgeAvoidanceHints = .zero
    var structuralEdgePillarColsLeft: Int = 0
    var structuralEdgePillarColsRight: Int = 0
    var structuralBottomRailMask: [Double] = []
    var structuralChromaticAccentMap: [Double] = []

    init(side: Int, luminance: [Double], attention: [Double], edges: [Double], edgeAngles: [Double] = [],
         hasAttention: Bool, foregroundDepth: [Double] = [], synchronizedSaliency: [Double] = [],
         focalDepthPlane: Double? = nil, hasCoreMLDepth: Bool = false) {
        self.side = side
        self.luminance = luminance
        self.attention = attention
        self.edges = edges
        self.edgeAngles = edgeAngles.count == side * side ? edgeAngles : []
        self.hasAttention = hasAttention
        let count = max(0, side * side)
        let depth = foregroundDepth.count == count ? foregroundDepth : [Double](repeating: 0.5, count: count)
        self.foregroundDepth = depth
        self.hasCoreMLDepth = hasCoreMLDepth

        var grad = [Double](repeating: 0, count: count)
        if side > 1, depth.count == count {
            for y in 0..<side {
                for x in 0..<side {
                    let dl = depth[y * side + min(side - 1, x + 1)] - depth[y * side + max(0, x - 1)]
                    let dv = depth[min(side - 1, y + 1) * side + x] - depth[max(0, y - 1) * side + x]
                    grad[y * side + x] = min(1.0, hypot(dl, dv) * 2.0)
                }
            }
        }
        self.depthGradient = grad

        let resolvedFocalDepth: Double
        if let focalDepthPlane, focalDepthPlane.isFinite {
            resolvedFocalDepth = min(0.95, max(0.05, focalDepthPlane))
        } else if side > 0, attention.count == count, depth.count == count, hasAttention {
            var bins = [Double](repeating: 0, count: 16)
            var dSum = 0.0
            var wSum = 0.0
            for y in 0..<side {
                let ny = (Double(y) + 0.5) / Double(side) - 0.5
                for x in 0..<side {
                    let nx = (Double(x) + 0.5) / Double(side) - 0.5
                    let i = y * side + x
                    let centerWeight = exp(-1.8 * (nx * nx + ny * ny))
                    let w = max(0.0, attention[i]) * (0.45 + 0.55 * centerWeight) * (0.55 + 0.45 * depth[i])
                    let d = min(1.0, max(0.0, depth[i]))
                    let bin = min(15, max(0, Int(d * 16.0)))
                    bins[bin] += w
                    dSum += d * w
                    wSum += w
                }
            }
            if wSum > 0.01, let peakBin = bins.indices.max(by: { bins[$0] < bins[$1] }) {
                let modeDepth = (Double(peakBin) + 0.5) / 16.0
                let meanDepth = dSum / wSum
                resolvedFocalDepth = min(0.94, max(0.08, 0.58 * modeDepth + 0.42 * meanDepth))
            } else {
                resolvedFocalDepth = 0.5
            }
        } else {
            resolvedFocalDepth = 0.5
        }
        self.focalDepthPlane = resolvedFocalDepth

        let resolvedSync: [Double]
        if synchronizedSaliency.count == count, synchronizedSaliency.allSatisfy(\.isFinite) {
            resolvedSync = synchronizedSaliency.map { min(1.0, max(0.0, $0)) }
        } else if side > 0, attention.count == count, depth.count == count {
            let sigmaD = 0.28
            let twoSigmaSq = 2.0 * sigmaD * sigmaD
            let gamma = 0.65
            var raw = [Double](repeating: 0, count: count)
            var maxSync = 0.0
            for i in 0..<count {
                let diff = depth[i] - resolvedFocalDepth
                let depthGate = exp(-(diff * diff) / twoSigmaSq)
                let v = max(0.0, attention[i]) * depthGate * (1.0 + gamma * grad[i])
                raw[i] = v
                if v > maxSync { maxSync = v }
            }
            if maxSync > 0.01 {
                resolvedSync = raw.map { min(1.0, max(0.0, $0 / maxSync)) }
            } else {
                resolvedSync = [Double](repeating: 0, count: count)
            }
        } else {
            resolvedSync = [Double](repeating: 0, count: count)
        }
        self.synchronizedSaliency = resolvedSync

        if hasAttention, !resolvedSync.isEmpty {
            let total = resolvedSync.reduce(0, +)
            let mean = total / Double(resolvedSync.count)
            let peak = resolvedSync.max() ?? 0.0
            let sorted = resolvedSync.sorted(by: >)
            let topShareCount = max(1, resolvedSync.count / 6)
            let topMass = sorted.prefix(topShareCount).reduce(0, +)
            let concentration = total > 0.01 ? topMass / total : 0.0
            let snr = mean > 0.005 ? min(1.0, max(0.0, (peak / mean - 1.15) / 2.6)) : 0.0
            self.subjectAttentionDominance = min(1.0, max(0.0, concentration * (0.45 + 0.55 * snr)))
        } else {
            self.subjectAttentionDominance = 0.0
        }
    }

    var isValid: Bool {
        (8...64).contains(side) && luminance.count == side * side &&
        attention.count == luminance.count && edges.count == luminance.count &&
        synchronizedSaliency.count == luminance.count &&
        (edgeAngles.isEmpty || edgeAngles.count == luminance.count) &&
        luminance.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        attention.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        edges.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        synchronizedSaliency.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    var isDiffuseAttention: Bool {
        guard isValid, hasAttention, !synchronizedSaliency.isEmpty else { return true }
        let peak = synchronizedSaliency.max() ?? 0.0
        let mean = synchronizedSaliency.reduce(0, +) / Double(synchronizedSaliency.count)
        return peak < 0.20 || (mean > 0.01 && peak / mean < 1.28 && subjectAttentionDominance < 0.16)
    }

    func value(_ values: [Double], at point: CGPoint) -> Double {
        guard side > 0, values.count == side * side, point.x.isFinite, point.y.isFinite else { return 0 }
        let x = min(side - 1, max(0, Int(point.x * CGFloat(side))))
        let y = min(side - 1, max(0, Int(point.y * CGFloat(side))))
        return values[y * side + x]
    }

    func depthStats(in rect: CGRect) -> (meanDepth: Double, meanSync: Double, depthContrast: Double) {
        guard isValid, rect.width > 0, rect.height > 0 else { return (0.5, 0.0, 0.0) }
        var inDepth = 0.0, inSync = 0.0, inCount = 0.0
        var outDepth = 0.0, outCount = 0.0
        let surround = rect.insetBy(dx: -0.10, dy: -0.10)
        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let p = CGPoint(x: px, y: py)
                let i = y * side + x
                if rect.contains(p) {
                    inDepth += foregroundDepth[i]
                    inSync += synchronizedSaliency[i]
                    inCount += 1
                } else if surround.contains(p) {
                    outDepth += foregroundDepth[i]
                    outCount += 1
                }
            }
        }
        guard inCount > 0 else { return (0.5, 0.0, 0.0) }
        let mDepth = inDepth / inCount
        let mSync = inSync / inCount
        let contrast = outCount > 0 ? min(1.0, abs(mDepth - outDepth / outCount) * 2.5) : 0.0
        return (mDepth, mSync, contrast)
    }

    /// Connected-Components + Gaussian Mean-Shift on synchronized S_sync map.
    /// Extracts coherent visual clusters without fixed 0.36x0.36 arbitrary boxes.
    func extractSynchronizedClusters(minPeak: Double = 0.24, maxClusters: Int = 4) -> [SynchronizedSaliencyCluster] {
        guard isValid, hasAttention, !isDiffuseAttention else { return [] }
        let count = side * side
        let totalSync = synchronizedSaliency.reduce(0, +)
        guard totalSync > 0.05 else { return [] }
        let meanSync = totalSync / Double(count)
        let variance = synchronizedSaliency.reduce(0.0) { $0 + ($1 - meanSync) * ($1 - meanSync) } / Double(count)
        let stdSync = sqrt(max(0.0, variance))
        let globalPeak = synchronizedSaliency.max() ?? 0.0
        guard globalPeak >= minPeak, stdSync >= 0.035 else { return [] }

        let highThresh = min(globalPeak * 0.74, max(minPeak, meanSync + 0.52 * stdSync))
        let lowThresh = max(0.14, max(highThresh * 0.60, meanSync + 0.16 * stdSync))
        let minPixels = max(3, count / 160)

        let seedIndices = (0..<count).filter { synchronizedSaliency[$0] >= highThresh }
            .sorted { synchronizedSaliency[$0] > synchronizedSaliency[$1] }
        var visited = [Bool](repeating: false, count: count)
        var components: [[Int]] = []
        let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for startIdx in seedIndices {
            guard !visited[startIdx], synchronizedSaliency[startIdx] >= highThresh else { continue }
            var queue = [startIdx]
            var head = 0
            visited[startIdx] = true
            let seedDepth = foregroundDepth[startIdx]
            var comp: [Int] = []
            while head < queue.count {
                let curr = queue[head]
                head += 1
                comp.append(curr)
                let cx = curr % side
                let cy = curr / side
                for (dx, dy) in neighbors {
                    let nx = cx + dx
                    let ny = cy + dy
                    guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                    let nIdx = ny * side + nx
                    guard !visited[nIdx], synchronizedSaliency[nIdx] >= lowThresh else { continue }
                    // Strict depth gate prevents centered subjects from flooding into background regions
                    if abs(foregroundDepth[nIdx] - seedDepth) <= 0.22 {
                        visited[nIdx] = true
                        queue.append(nIdx)
                    }
                }
            }
            if comp.count >= minPixels {
                components.append(comp)
            }
        }

        func componentStats(_ indices: [Int]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double,
                                                 peakVal: Double, peakX: Double, peakY: Double, peakIdx: Int,
                                                 sumSync: Double, sumDepth: Double) {
            var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
            var peakVal = 0.0, peakX = 0.5, peakY = 0.5, peakIdx = indices[0]
            var sumSync = 0.0, sumDepth = 0.0
            for idx in indices {
                let x = idx % side
                let y = idx / side
                let px0 = Double(x) / Double(side)
                let px1 = Double(x + 1) / Double(side)
                let py0 = Double(y) / Double(side)
                let py1 = Double(y + 1) / Double(side)
                if px0 < minX { minX = px0 }
                if px1 > maxX { maxX = px1 }
                if py0 < minY { minY = py0 }
                if py1 > maxY { maxY = py1 }
                let s = synchronizedSaliency[idx]
                sumSync += s
                sumDepth += foregroundDepth[idx]
                if s > peakVal {
                    peakVal = s
                    peakX = (px0 + px1) * 0.5
                    peakY = (py0 + py1) * 0.5
                    peakIdx = idx
                }
            }
            return (minX, minY, maxX, maxY, peakVal, peakX, peakY, peakIdx, sumSync, sumDepth)
        }

        var clusters: [SynchronizedSaliencyCluster] = []
        for rawComp in components {
            var comp = rawComp
            var stats = componentStats(comp)
            var rect = CGRect(x: max(0.01, stats.minX), y: max(0.01, stats.minY),
                              width: min(0.98, stats.maxX - stats.minX), height: min(0.98, stats.maxY - stats.minY))
            var area = Double(rect.width * rect.height)

            // Refine oversized mega-components via 5x5 local mass peak instead of discarding them to vcom fallback
            if area > 0.48 || Double(comp.count) / Double(count) > 0.36 {
                let compSet = Set(comp)
                var bestScore = -1.0
                var bestSeed = stats.peakIdx
                for idx in comp {
                    let cx = idx % side, cy = idx / side
                    var locSum = 0.0, locN = 0.0
                    for yy in max(0, cy - 2)...min(side - 1, cy + 2) {
                        for xx in max(0, cx - 2)...min(side - 1, cx + 2) {
                            locSum += synchronizedSaliency[yy * side + xx]
                            locN += 1.0
                        }
                    }
                    let locMean = locSum / max(1.0, locN)
                    let nx = (Double(cx) + 0.5) / Double(side)
                    let ny = (Double(cy) + 0.5) / Double(side)
                    let cBias = max(0.45, 1.0 - 0.55 * hypot(nx - 0.5, ny - 0.5))
                    let sc = locMean * (0.45 + 0.55 * synchronizedSaliency[idx]) * cBias
                    if sc > bestScore {
                        bestScore = sc
                        bestSeed = idx
                    }
                }
                let seedVal = max(synchronizedSaliency[bestSeed], stats.peakVal * 0.72)
                let seedDepth = foregroundDepth[bestSeed]
                let sx0 = (Double(bestSeed % side) + 0.5) / Double(side)
                let sy0 = (Double(bestSeed / side) + 0.5) / Double(side)

                let passes: [(Double, Double, Double?)] = [(0.54, 0.20, nil), (0.62, 0.18, 0.36), (0.70, 0.16, 0.28)]
                for (mul, dGate, rLim) in passes {
                    let minS = max(highThresh, seedVal * mul)
                    var subVisited: Set<Int> = [bestSeed]
                    var subQ: [Int] = [bestSeed]
                    var subHead = 0
                    while subHead < subQ.count {
                        let c = subQ[subHead]
                        subHead += 1
                        let cx = c % side, cy = c / side
                        for dy in -1...1 {
                            let ny = cy + dy
                            guard ny >= 0, ny < side else { continue }
                            for dx in -1...1 {
                                if dx == 0 && dy == 0 { continue }
                                let nx = cx + dx
                                guard nx >= 0, nx < side else { continue }
                                let ni = ny * side + nx
                                guard compSet.contains(ni), !subVisited.contains(ni),
                                      synchronizedSaliency[ni] >= minS,
                                      abs(foregroundDepth[ni] - seedDepth) <= dGate else { continue }
                                if let limit = rLim {
                                    let px = (Double(nx) + 0.5) / Double(side)
                                    let py = (Double(ny) + 0.5) / Double(side)
                                    guard hypot(px - sx0, py - sy0) <= limit else { continue }
                                }
                                subVisited.insert(ni)
                                subQ.append(ni)
                            }
                        }
                    }
                    if subQ.count >= minPixels {
                        let m2 = componentStats(subQ)
                        let r2 = CGRect(x: max(0.01, m2.minX), y: max(0.01, m2.minY),
                                        width: min(0.98, m2.maxX - m2.minX), height: min(0.98, m2.maxY - m2.minY))
                        let a2 = Double(r2.width * r2.height)
                        if a2 >= 0.015 && a2 <= 0.56 {
                            comp = subQ
                            stats = m2
                            rect = r2
                            area = a2
                            break
                        }
                    }
                }
            }

            let peakVal = stats.peakVal, peakX = stats.peakX, peakY = stats.peakY
            let sumSync = stats.sumSync, sumDepth = stats.sumDepth
            let compMeanDepth = sumDepth / Double(comp.count)
            let compMeanSync = sumSync / Double(comp.count)
            guard area >= 0.015 && area <= 0.65 else { continue }
            // Only drop genuine thin border strips, never wide foreground subjects touching an edge
            let isSideStrip = (rect.minX <= 0.03 || rect.maxX >= 0.97) && rect.height >= 0.55 && rect.width <= 0.16
            let isBottomStrip = (rect.minY <= 0.03 || rect.maxY >= 0.97) && rect.width >= 0.55 && rect.height <= 0.18
            guard !isSideStrip && !isBottomStrip else { continue }

            // 5 iterations of Gaussian Mean-Shift around the component peak
            var shiftX = peakX
            var shiftY = peakY
            let bw = 0.10
            let twoBwSq = 2.0 * bw * bw
            for _ in 0..<5 {
                var numX = 0.0, numY = 0.0, denom = 0.0
                for idx in comp {
                    let px = (Double(idx % side) + 0.5) / Double(side)
                    let py = (Double(idx / side) + 0.5) / Double(side)
                    let dSq = (px - shiftX) * (px - shiftX) + (py - shiftY) * (py - shiftY)
                    let depthDiff = foregroundDepth[idx] - compMeanDepth
                    let w = synchronizedSaliency[idx] * exp(-dSq / twoBwSq) * exp(-(depthDiff * depthDiff) / 0.10)
                    numX += px * w
                    numY += py * w
                    denom += w
                }
                if denom > 0.0001 {
                    let nextX = numX / denom
                    let nextY = numY / denom
                    let moved = hypot(nextX - shiftX, nextY - shiftY)
                    shiftX = nextX
                    shiftY = nextY
                    if moved < 0.002 { break }
                } else { break }
            }
            let anchor = CGPoint(x: min(rect.maxX, max(rect.minX, shiftX)),
                                 y: min(rect.maxY, max(rect.minY, shiftY)))
            let dominance = min(1.0, (sumSync / max(0.01, totalSync)) * (0.55 + 0.45 * peakVal))
            let touchesBorder = rect.minX <= 0.025 || rect.maxX >= 0.975 || rect.minY <= 0.025 || rect.maxY >= 0.975
            let isCornerSliver = touchesBorder && (dominance < 0.085 ||
                (peakVal < 0.74 && (anchor.x < 0.10 || anchor.x > 0.90 || anchor.y < 0.10 || anchor.y > 0.90)))
            if isCornerSliver && components.count > 1 && dominance < 0.065 {
                continue
            }
            clusters.append(SynchronizedSaliencyCluster(
                bounds: rect, anchor: anchor, peakValue: peakVal,
                meanSync: compMeanSync, meanDepth: compMeanDepth,
                dominance: dominance, area: area
            ))
        }
        return clusters.sorted {
            let lhsCenter = max(0.45, 1.0 - 0.65 * Double(hypot($0.anchor.x - 0.5, $0.anchor.y - 0.5)))
            let rhsCenter = max(0.45, 1.0 - 0.65 * Double(hypot($1.anchor.x - 0.5, $1.anchor.y - 0.5)))
            let lhs = $0.dominance * (0.65 + 0.35 * $0.meanDepth) * (0.5 + 0.5 * $0.peakValue) * lhsCenter
            let rhs = $1.dominance * (0.65 + 0.35 * $1.meanDepth) * (0.5 + 0.5 * $1.peakValue) * rhsCenter
            return lhs > rhs
        }.prefix(maxClusters).map { $0 }
    }

    func evidence(in rect: CGRect) -> SubjectVisualEvidence? {
        guard isValid, rect.width > 0, rect.height > 0 else { return nil }
        var count = 0.0, light = 0.0, square = 0.0, detail = 0.0, mass = 0.0, fgSum = 0.0, syncSum = 0.0
        var outside = 0.0, outsideDepth = 0.0, outsideCount = 0.0
        let surround = rect.insetBy(dx: -0.08, dy: -0.08)
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let p = CGPoint(x: (Double(x) + 0.5) / Double(side), y: (Double(y) + 0.5) / Double(side))
                if rect.contains(p) {
                    count += 1; light += luminance[i]; square += luminance[i] * luminance[i]
                    mass += attention[i]; detail += edges[i]; fgSum += foregroundDepth[i]
                    syncSum += synchronizedSaliency[i]
                } else if surround.contains(p) {
                    outside += luminance[i]; outsideDepth += foregroundDepth[i]; outsideCount += 1
                }
            }
        }
        guard count > 0 else { return nil }
        let mean = light / count
        let meanDepth = fgSum / count
        let contrast = sqrt(max(0, square / count - mean * mean))
        let exposure = min(1, max(0, min(mean, 1 - mean) / 0.16))
        let dContrast = outsideCount > 0 ? min(1.0, abs(meanDepth - outsideDepth / outsideCount) * 2.5) : 0.0
        return SubjectVisualEvidence(attentionDensity: mass / count,
            attentionShare: mass / max(0.001, attention.reduce(0, +)),
            separation: min(1, abs(mean - outside / max(1, outsideCount)) * 3),
            detail: min(1, (max(0, detail / count - 0.015) + max(0, contrast - 0.01)) * 2),
            exposure: exposure, foregroundDepth: meanDepth,
            syncAttention: hasAttention ? (syncSum / count) : nil,
            depthContrast: dContrast)
    }

    var visualCenterOfMass: CGPoint? {
        guard isValid, hasAttention else { return nil }
        var totalWeight = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let w = attention[y * side + x]
                totalWeight += w
                sumX += (Double(x) + 0.5) / Double(side) * w
                sumY += (Double(y) + 0.5) / Double(side) * w
            }
        }
        guard totalWeight > 0.01 else { return nil }
        return CGPoint(x: sumX / totalWeight, y: sumY / totalWeight)
    }

    /// A line needs edge support across the image, not just a local bright patch.
    var horizon: (y: CGFloat, confidence: Double)? {
        guard isValid else { return nil }
        if let mh = measuredHorizon, mh.confidence >= 0.25, (0.12...0.88).contains(mh.y) {
            return mh
        }
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

    /// Hough/Radon accumulator grid 16x16 on [0.05...0.95]^2 fused with RANSAC VNDetectContoursRequest vanishing point.
    var vanishingPoint: (point: CGPoint, confidence: Double, rayAngles: [Double])? {
        guard isValid else { return nil }
        if let mvp = measuredVanishingPoint, mvp.confidence >= 0.32 {
            return mvp
        }
        guard !edgeAngles.isEmpty else { return measuredVanishingPoint }
        let gridRes = 16
        var accum = [Double](repeating: 0, count: gridRes * gridRes)
        var rayAnglesCollected = [Double]()
        let cellRadius = 0.055
        var totalEdgeWeight = 0.0

        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let e = edges[i]
                guard e >= 0.14 else { continue }
                totalEdgeWeight += e
                let theta = edgeAngles[i] + (.pi / 2.0)
                if rayAnglesCollected.count < 32 { rayAnglesCollected.append(theta) }
                let px = (Double(x) + 0.5) / Double(side)
                let py = (Double(y) + 0.5) / Double(side)
                let a = -sin(theta)
                let b = cos(theta)
                let c = -(a * px + b * py)

                for gy in 0..<gridRes {
                    let cy = 0.05 + (Double(gy) + 0.5) / Double(gridRes) * 0.90
                    for gx in 0..<gridRes {
                        let cx = 0.05 + (Double(gx) + 0.5) / Double(gridRes) * 0.90
                        let dist = abs(a * cx + b * cy + c)
                        if dist < cellRadius {
                            accum[gy * gridRes + gx] += e * (1.0 - dist / cellRadius)
                        }
                    }
                }
            }
        }
        guard totalEdgeWeight > 0.5, let maxVal = accum.max(), maxVal > 0 else { return nil }
        let confidence = min(1.0, maxVal / (totalEdgeWeight * 0.28))
        guard confidence >= 0.28, let bestIdx = accum.firstIndex(of: maxVal) else { return nil }
        let bestGx = bestIdx % gridRes
        let bestGy = bestIdx / gridRes
        let bestPoint = CGPoint(
            x: 0.05 + (Double(bestGx) + 0.5) / Double(gridRes) * 0.90,
            y: 0.05 + (Double(bestGy) + 0.5) / Double(gridRes) * 0.90
        )
        return (point: bestPoint, confidence: confidence, rayAngles: rayAnglesCollected)
    }

    /// Frame-in-frame structural aperture (inner opening surrounded by peripheral border).
    var frameInFrameAperture: (innerRect: CGRect, strength: Double)? {
        guard isValid else { return nil }
        var borderEdgeSum = 0.0, borderEdgeCount = 0.0
        var coreEdgeSum = 0.0, coreEdgeCount = 0.0
        var borderAttentionSum = 0.0, borderAttentionCount = 0.0
        var coreAttentionSum = 0.0, coreAttentionCount = 0.0

        let borderFraction = 0.20
        let minCore = Int(Double(side) * borderFraction)
        let maxCore = Int(Double(side) * (1.0 - borderFraction))

        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let isBorder = x < minCore || x >= maxCore || y < minCore || y >= maxCore
                if isBorder {
                    borderEdgeSum += edges[i]; borderEdgeCount += 1
                    borderAttentionSum += attention[i]; borderAttentionCount += 1
                } else {
                    coreEdgeSum += edges[i]; coreEdgeCount += 1
                    coreAttentionSum += attention[i]; coreAttentionCount += 1
                }
            }
        }
        guard borderEdgeCount > 0, coreEdgeCount > 0 else { return nil }
        let borderEdgeDensity = borderEdgeSum / borderEdgeCount
        let coreEdgeDensity = coreEdgeSum / coreEdgeCount
        let borderAttnDensity = borderAttentionSum / max(1.0, borderAttentionCount)
        let coreAttnDensity = coreAttentionSum / max(1.0, coreAttentionCount)

        let edgeRatio = borderEdgeDensity / max(0.01, coreEdgeDensity)
        let attnRatio = coreAttnDensity / max(0.01, borderAttnDensity)
        guard borderEdgeDensity >= 0.12 && (edgeRatio >= 1.25 || attnRatio >= 1.35) else { return nil }

        let strength = min(1.0, (edgeRatio * 0.4 + attnRatio * 0.6 - 1.0) * 0.8)
        guard strength >= 0.25 else { return nil }
        let innerRect = CGRect(x: 0.18, y: 0.18, width: 0.64, height: 0.64)
        return (innerRect: innerRect, strength: strength)
    }

    /// Negative space map negSpace[i] = (1.0 - attention[i]) * exp(-3.5 * edges[i])
    /// Returns the openness vector, dominant direction, and optimal anchor offset for lead room.
    func negativeSpaceVector(around anchor: CGPoint, gaze: CGFloat) -> (direction: CGVector, openness: Double, optimalAnchorOffset: CGPoint) {
        guard isValid else { return (CGVector.zero, 0, CGPoint.zero) }
        var leftNeg = 0.0, leftCount = 0.0
        var rightNeg = 0.0, rightCount = 0.0
        var topNeg = 0.0, topCount = 0.0
        var bottomNeg = 0.0, bottomCount = 0.0

        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let i = y * side + x
                let ns = (1.0 - attention[i]) * exp(-3.5 * edges[i])
                if px < Double(anchor.x) { leftNeg += ns; leftCount += 1 }
                else { rightNeg += ns; rightCount += 1 }
                if py < Double(anchor.y) { topNeg += ns; topCount += 1 }
                else { bottomNeg += ns; bottomCount += 1 }
            }
        }
        let leftMean = leftCount > 0 ? leftNeg / leftCount : 0
        let rightMean = rightCount > 0 ? rightNeg / rightCount : 0
        let topMean = topCount > 0 ? topNeg / topCount : 0
        let bottomMean = bottomCount > 0 ? bottomNeg / bottomCount : 0

        let dx = rightMean - leftMean
        let dy = bottomMean - topMean
        let openness = min(1.0, (leftMean + rightMean + topMean + bottomMean) * 0.25 * 2.0)

        var offsetX: CGFloat = 0.0
        if abs(gaze) > 0.10 {
            offsetX = gaze > 0 ? -0.10 : 0.10
        } else if abs(dx) > 0.08 {
            offsetX = dx > 0 ? -0.08 : 0.08
        }
        let offsetY: CGFloat = (dy > 0.10) ? -0.05 : 0.0
        return (direction: CGVector(dx: dx, dy: dy), openness: openness, optimalAnchorOffset: CGPoint(x: offsetX, y: offsetY))
    }

    /// Visual torque balance (Steelyard Visual Balance) inside cropRect.
    /// Returns balance score approaching 1.0 when visual moments balance around crop center.
    func visualTorqueBalance(heroRect: CGRect, cropRect: CGRect) -> Double {
        guard isValid, cropRect.width > 0, cropRect.height > 0 else { return 0.5 }
        let cx = Double(cropRect.midX)
        let cy = Double(cropRect.midY)
        var sumTorqueX = 0.0
        var sumTorqueY = 0.0
        var totalWeight = 0.0

        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let p = CGPoint(x: px, y: py)
                guard cropRect.contains(p) else { continue }
                let i = y * side + x
                let lumaContrast = abs(luminance[i] - 0.5) * 2.0
                let w = attention[i] * (0.6 + 0.4 * lumaContrast)
                let distNormX = (px - cx) / Double(cropRect.width)
                let distNormY = (py - cy) / Double(cropRect.height)
                sumTorqueX += distNormX * w
                sumTorqueY += distNormY * w
                totalWeight += w
            }
        }
        guard totalWeight > 0.01 else { return 0.5 }
        let torqueMagnitude = hypot(sumTorqueX / totalWeight, sumTorqueY / totalWeight)
        return max(0.0, 1.0 - min(1.0, torqueMagnitude * 2.8))
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
    var retainedAttention: Double = 1
    var recommendedEVBias: CGFloat = 0.0
    var outOfBoundsFraction: Double = 0.0
    var continuousFieldScore: Double = 0.0
    var gaicScore: Double = 0.5
    /// Subject area divided by the intent's target area. Below 1 the subject is smaller than the shot wants.
    var sizeRatio: Double = 1
    var excessTrimGain: Double = 0.0
    var frameWasteRatio: Double = 0.0
    var sceneWasteRatio: Double = 0.0
    var isAttentionSubject: Bool = false
    var semanticCropBonus: Double = 0.0
    var sceneCleanGain: Double = 0.0

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
        poseProfile: AnatomicalPoseProfile? = nil,
        sceneHints: CompositionSceneHints = .neutral,
        isCancelled: () -> Bool = { false }) -> [CompositionProposal] {
        let perIntent = max(8, proposalLimit / max(1, intents.count))
        let batches = intents.map { intent -> [CompositionProposal] in
            if !refining.isEmpty && !refining.contains(where: { $0.intent == intent }) { return [] }
            let bounds: CGRect
            if intent == .portrait, subject.kind == .person, let portraitBounds,
               subject.bounds.contains(portraitBounds), portraitBounds.contains(subject.anchor) {
                bounds = portraitBounds
            } else { bounds = subject.bounds }
            let framed = CompositionSubject(index: subject.index, bounds: bounds, anchor: subject.anchor,
                kind: subject.kind, confidence: subject.confidence, importance: subject.importance, gaze: subject.gaze,
                allowsAttentionCrop: subject.allowsAttentionCrop, verticalGaze: subject.verticalGaze,
                shotScaleBias: subject.shotScaleBias, contextPreservationWeight: subject.contextPreservationWeight,
                isAttentionOnly: subject.isAttentionOnly)
            return proposals(subjects: [framed], intents: [intent], raster: raster, calibration: calibration,
                currentZoom: currentZoom, allowedZooms: allowedZooms, protectedBounds: protectedBounds,
                incidentalBounds: incidentalBounds, proposalLimit: perIntent,
                refining: refining.filter { $0.intent == intent }, poseProfile: poseProfile,
                sceneHints: sceneHints, isCancelled: isCancelled)
        }
        let candidates = batches.flatMap { $0 }
        var result = diverse(candidates, limit: proposalLimit, raySeparation: 0.008, zoomSeparation: 0.018)
        if refining.isEmpty, let original = candidates.first(where: \.isUnchangedView),
           !result.contains(where: \.isUnchangedView) {
            result = Array(result.prefix(max(0, proposalLimit - 1))) + [original]
        }
        return result
    }

    private struct SampleCell {
        let point: CGPoint
        let attention: Double
        let sync: Double
        let depth: Double
        let edge: Double
    }

    private struct WindowEvaluation {
        let fieldScore: Double
        let gaicScore: Double
        let explanation: String
        let retainedAttention: Double
        let recommendedEVBias: CGFloat
        let oobFraction: Double
        let sizeRatio: Double
        let excessTrimGain: Double
        let wasteRatio: Double
        var sceneCleanGain: Double = 0.0
    }

    private static func desiredSubjectArea(intent: LocalCompositionIntent, kind: CompositionSubjectKind) -> Double {
        switch intent {
        case .portrait: return kind == .face ? CompositionTuning.desiredAreaFace : CompositionTuning.desiredAreaPortrait
        case .environmentalPortrait, .street: return CompositionTuning.desiredAreaStreet
        case .group: return CompositionTuning.desiredAreaGroup
        case .landscape: return CompositionTuning.desiredAreaLandscape
        case .architecture: return CompositionTuning.desiredAreaArchitecture
        case .closeUp, .food: return CompositionTuning.desiredAreaFood
        case .animal: return CompositionTuning.desiredAreaAnimal
        case .object: return CompositionTuning.desiredAreaObject
        }
    }

    private static func makeSampleCells(from raster: CompositionRaster) -> [SampleCell] {
        guard raster.isValid else { return [] }
        let cellStride = raster.side > 32 ? 2 : 1
        var cells: [SampleCell] = []
        cells.reserveCapacity((raster.side / cellStride + 1) * (raster.side / cellStride + 1))
        for sy in stride(from: 0, to: raster.side, by: cellStride) {
            let py = (Double(sy) + 0.5) / Double(raster.side)
            for sx in stride(from: 0, to: raster.side, by: cellStride) {
                let px = (Double(sx) + 0.5) / Double(raster.side)
                let i = sy * raster.side + sx
                cells.append(SampleCell(
                    point: CGPoint(x: px, y: py),
                    attention: raster.attention[i],
                    sync: raster.synchronizedSaliency[i],
                    depth: raster.foregroundDepth[i],
                    edge: raster.edges[i]
                ))
            }
        }
        return cells
    }

    private struct RasterBaselineProfile {
        let waste: Double
        let activeFill: Double
        let activeThreshold: Double
        let centroid: CGPoint
    }

    private static func rasterBaselineProfile(from raster: CompositionRaster) -> RasterBaselineProfile {
        let fallback = RasterBaselineProfile(waste: 0.0, activeFill: 0.5, activeThreshold: 0.14, centroid: CGPoint(x: 0.5, y: 0.5))
        guard raster.isValid, raster.side > 0 else { return fallback }
        let side = raster.side
        let count = side * side
        var infos = [Double](repeating: 0.0, count: count)
        var wSum = 0.0, wX = 0.0, wY = 0.0
        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let px = (Double(x) + 0.5) / Double(side)
                let i = y * side + x
                let info = 0.45 * raster.synchronizedSaliency[i] + 0.30 * raster.attention[i] + 0.25 * min(1.0, raster.edges[i] * 2.2)
                infos[i] = info
                if (0.08...0.92).contains(px) && (0.08...0.92).contains(py) {
                    wSum += info
                    wX += px * info
                    wY += py * info
                }
            }
        }
        let centroid = wSum > 1e-4 ? CGPoint(x: wX / wSum, y: wY / wSum) : CGPoint(x: 0.5, y: 0.5)
        let sorted = infos.sorted()
        let p90Idx = min(count - 1, max(0, Int(Double(count) * 0.90)))
        let peakInfo = max(0.20, sorted[p90Idx])
        let activeThreshold = max(0.14, 0.36 * peakInfo)
        let activeCount = infos.reduce(0) { $0 + ($1 >= activeThreshold ? 1 : 0) }
        let baseFill = Double(activeCount) / Double(max(1, count))
        guard raster.hasAttention, !raster.isDiffuseAttention else {
            return RasterBaselineProfile(waste: 0.0, activeFill: baseFill, activeThreshold: activeThreshold, centroid: centroid)
        }
        let lowCount = max(1, Int(Double(count) * 0.42))
        let lowQ = sorted.prefix(lowCount).reduce(0.0, +) / Double(lowCount)
        let highStart = min(count - 1, Int(Double(count) * 0.55))
        let highSlice = sorted[highStart..<count]
        let highQ = highSlice.reduce(0.0, +) / Double(max(1, highSlice.count))
        let stripY = max(1, Int(Double(side) * 0.22))
        let stripBot = min(side - 1, Int(Double(side) * 0.78))
        var topS = 0.0, topC = 0, botS = 0.0, botC = 0, leftS = 0.0, leftC = 0, rightS = 0.0, rightC = 0
        for y in 0..<side {
            for x in 0..<side {
                let v = infos[y * side + x]
                if y < stripY { topS += v; topC += 1 }
                if y >= stripBot { botS += v; botC += 1 }
                if x < stripY { leftS += v; leftC += 1 }
                if x >= stripBot { rightS += v; rightC += 1 }
            }
        }
        let minStrip = min(topS / Double(max(1, topC)), botS / Double(max(1, botC)),
                           leftS / Double(max(1, leftC)), rightS / Double(max(1, rightC)))
        let deadStripRatio = max(0.0, 1.0 - minStrip / max(0.08, highQ))
        let globalContrast = max(0.0, 1.0 - lowQ / max(0.08, highQ))
        let waste = min(1.0, 0.55 * globalContrast + 0.45 * deadStripRatio)
        return RasterBaselineProfile(waste: waste, activeFill: baseFill, activeThreshold: activeThreshold, centroid: centroid)
    }

    private static func fallbackPlacement(anchor: CGPoint, kind: CompositionSubjectKind,
                                          intent: LocalCompositionIntent) -> CGPoint {
        if intent == .architecture { return CGPoint(x: 0.5, y: 0.48) }
        let x: Double = anchor.x < 0.5 ? Double(CompositionTuning.goldenSectionLeft) : Double(CompositionTuning.goldenSectionRight)
        let person = kind == .person || kind == .face || kind == .group
        let y: Double = person ? CompositionTuning.portraitEyeLineY : (intent == .food || intent == .closeUp ? 0.48 : 0.45)
        return CGPoint(x: x, y: y)
    }

    private static func evaluateWindowScore(
        subject: CompositionSubject,
        intent: LocalCompositionIntent,
        desired: CGPoint,
        destination: CGPoint,
        aimPoint: CGPoint,
        box: CGRect,
        zoom: CGFloat,
        currentZoom: CGFloat,
        rawCornerPoints: [CGPoint],
        rotation: simd_quatd,
        calibration: TrackingCalibration,
        future: TrackingCalibration,
        raster: CompositionRaster?,
        sampleCells: [SampleCell],
        protectedPeople: [CompositionSubject],
        subjectDepth: Double,
        horizonHint: (y: CGFloat, confidence: Double)?,
        poseProfile: AnatomicalPoseProfile?,
        intentPrior: Double,
        cropAttention: Bool,
        unchanged: Bool,
        baselineProfile: RasterBaselineProfile? = nil,
        sceneHints: CompositionSceneHints = .neutral,
        baselineCleanliness: Double = 0.0,
        protectedMinVisibility: Double = 1.0
    ) -> WindowEvaluation? {
        let ratio = Double(zoom / currentZoom)
        let metrics: Metrics
        let hasAttention: Bool
        let evBias: CGFloat
        let torqueBalance: Double
        if let raster, raster.isValid, !sampleCells.isEmpty {
            metrics = measure(raster: raster, cells: sampleCells, subject: subject,
                              subjectDepth: subjectDepth, box: box,
                              calibration: calibration, future: future, rotation: rotation,
                              protectedPeople: protectedPeople,
                              activeThreshold: baselineProfile?.activeThreshold ?? 0.14)
            hasAttention = raster.hasAttention
            evBias = computeOptimalEVBias(raster: raster, heroRect: box, aimPoint: aimPoint, zoom: zoom, scene: intent)
            torqueBalance = raster.visualTorqueBalance(heroRect: box, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        } else {
            let retention = visibleFraction(box)
            let boxMargin = min(box.minX, box.minY, 1 - box.maxX, 1 - box.maxY)
            let cleanEdges = min(1.0, max(0.0, Double(boxMargin) / 0.08))
            let balance = 1.0 - min(1.0, hypot(Double(box.midX) - 0.5, Double(box.midY) - 0.5) * 2.0)
            let room = subject.gaze >= 0 ? Double(1 - box.maxX) : Double(box.minX)
            let opposite = subject.gaze >= 0 ? Double(box.minX) : Double(1 - box.maxX)
            let lookRoom = min(1.0, max(0.0, 0.5 + (room - opposite) * 1.5))
            metrics = Metrics(retention: retention, cleanEdges: cleanEdges, balance: balance,
                              lookRoom: lookRoom, separation: 0.5, symmetry: balance,
                              roiSyncFocus: 0.5, depthSeparation: 0.5,
                              wasteRatio: 0.0, excessTrimGain: 0.0, activeFill: 0.5,
                              balanceCentroid: CGPoint(x: 0.5, y: 0.5))
            hasAttention = false
            evBias = 0.0
            torqueBalance = balance
        }

        let desiredArea = desiredSubjectArea(intent: intent, kind: subject.kind)
        let rawSubjectArea = Double(subject.bounds.width * subject.bounds.height)
        let scaledDesiredArea = desiredArea * exp(0.24 * min(1.0, max(-1.0, subject.shotScaleBias)))
        let isPersonOrScenery = subject.kind == .person || subject.kind == .face || subject.kind == .group || subject.kind == .scenery
        let effectiveDesiredArea: Double
        if !isPersonOrScenery && !subject.allowsAttentionCrop {
            if rawSubjectArea < 0.006 {
                effectiveDesiredArea = min(scaledDesiredArea, max(0.024, rawSubjectArea * 4.0))
            } else if rawSubjectArea < 0.018 {
                effectiveDesiredArea = min(scaledDesiredArea, max(0.085, rawSubjectArea * 4.5))
            } else {
                effectiveDesiredArea = scaledDesiredArea
            }
        } else {
            effectiveDesiredArea = scaledDesiredArea
        }
        let area = Double(box.width * box.height)
        let sizeFit: Double
        let sizeRatio: Double
        if subject.kind == .scenery {
            sizeFit = 1.0
            sizeRatio = 1.0
        } else if subject.allowsAttentionCrop {
            let evalArea = rawSubjectArea > 0.16 ? min(area, max(effectiveDesiredArea * 1.15, rawSubjectArea * 1.15)) : area
            let rawLogRatio = log(max(0.004, evalArea) / effectiveDesiredArea)
            let boxSizeFit = 1.0 / (1.0 + 0.65 * rawLogRatio * rawLogRatio)
            let fillSizeFit: Double = metrics.activeFill >= 0.56
                ? max(0.0, 1.0 - max(0.0, metrics.activeFill - 0.90) * 1.2)
                : (1.0 / (1.0 + 3.2 * pow(metrics.activeFill - 0.56, 2)))
            sizeFit = rawSubjectArea > 0.16
                ? (0.40 * boxSizeFit + 0.60 * fillSizeFit)
                : (0.70 * boxSizeFit + 0.30 * fillSizeFit)
            sizeRatio = evalArea / max(0.001, effectiveDesiredArea)
        } else {
            let lr = log(max(0.004, area) / effectiveDesiredArea)
            sizeFit = 1.0 / (1.0 + 0.65 * lr * lr)
            sizeRatio = area / max(0.001, effectiveDesiredArea)
        }

        let effectiveDest: CGPoint = (subject.isAttentionOnly && rawSubjectArea > 0.16)
            ? CGPoint(x: 0.55 * destination.x + 0.45 * metrics.balanceCentroid.x,
                      y: 0.55 * destination.y + 0.45 * metrics.balanceCentroid.y)
            : destination
        let placement = exp(-8.0 * pow(Double(effectiveDest.x - desired.x), 2) -
                            7.0 * pow(Double(effectiveDest.y - desired.y), 2))
        let preservesContext = intent.preservesContext
        let wasteEase = metrics.wasteRatio
        let isDiffuse = raster?.isDiffuseAttention ?? true
        if !sceneHints.hasRichGuidance && cropAttention && !unchanged && (!subject.isAttentionOnly || isDiffuse) {
            guard metrics.retention >= 0.82 else { return nil }
        }
        let retDenom = subject.isAttentionOnly ? (wasteEase < 0.24 ? 0.80 : 0.68) : 0.55
        let retSoft = hasAttention ? min(1.0, metrics.retention / retDenom) : 1.0
        let context = (preservesContext && hasAttention) ? metrics.retention : retSoft
        let rawContextFit = min(1.0, 1.0 / (ratio * ratio * (preservesContext ? 0.72 : 0.65)))
        let contextFit = rawContextFit + (1.0 - rawContextFit) * (preservesContext ? 0.85 : 0.90) * wasteEase

        let cutFloor = subject.isAttentionOnly ? (wasteEase < 0.24 ? 0.76 : 0.62) : 0.48
        let attnCutPenalty = (hasAttention && !isDiffuse && metrics.retention < cutFloor && wasteEase < 0.55)
            ? 0.34 * (cutFloor - metrics.retention) : 0.0

        let space = abs(subject.gaze) > 0.12 ? metrics.lookRoom : metrics.balance
        let symmetry = intent == .architecture ? metrics.symmetry : metrics.balance
        let person = subject.kind == .person || subject.kind == .face || subject.kind == .group
        let applyHeadroom = person && (box.height >= 0.45 || (box.height >= 0.24 && Double(box.minY) < CompositionTuning.headroomTargetY))
        let headroom = applyHeadroom ? exp(-pow((Double(box.minY) - CompositionTuning.headroomTargetY) / CompositionTuning.headroomSigma, 2)) : 1.0
        let margin = min(box.minX, box.minY, 1 - box.maxX, 1 - box.maxY)
        let edgeSafety = subject.allowsAttentionCrop ? 1.0 : min(1.0, max(0.0, Double(margin) / 0.07))
        var horizonFit = 1.0
        if intent == .landscape, let horizon = horizonHint {
            let p = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: CGPoint(x: 0.5, y: horizon.y))))
            if p.isInFront {
                let distance = min(abs(Double(p.point.y) - 0.382), abs(Double(p.point.y) - 0.618))
                horizonFit = 1.0 - horizon.confidence * min(1.0, distance * 4.0)
            }
        }
        let oobSum = rawCornerPoints.reduce(0.0) { acc, pt in
            let dx = max(0.0, Double(-pt.x), Double(pt.x - 1.0))
            let dy = max(0.0, Double(-pt.y), Double(pt.y - 1.0))
            return acc + hypot(dx, dy)
        }
        let oobFraction = min(1.0, oobSum / 0.85)
        let thirdX = min(abs(Double(effectiveDest.x) - Double(CompositionTuning.goldenSectionLeft)),
                         abs(Double(effectiveDest.x) - Double(CompositionTuning.goldenSectionRight)))
        let thirdY = min(abs(Double(effectiveDest.y) - CompositionTuning.portraitEyeLineY),
                         abs(Double(effectiveDest.y) - Double(CompositionTuning.goldenSectionRight)))
        let ruleOfThirdsBonus = CompositionTuning.ruleOfThirdsBonusWeight * exp(-16 * (thirdX * thirdX + thirdY * thirdY))
        let ratioAdjustment = 0.008 * abs(log(max(0.25, ratio))) * (1.0 - 0.80 * wasteEase)
        let contextWeight = preservesContext ? 0.12 : (subject.isAttentionOnly ? 0.12 : 0.07)
        let contextFitWeight = preservesContext ? 0.09 : 0.04
        let baseFill = baselineProfile?.activeFill ?? 0.50
        let fillGain = max(0.0, metrics.activeFill - baseFill)
        let fillBonus = (ratio > 1.03 && metrics.wasteRatio >= 0.24 && !isDiffuse) ? 0.12 * fillGain : 0.0
        var anatomicalPenaltyValue = 0.0
        if let poseProfile {
            let cMinX = max(0.0, rawCornerPoints.map(\.x).min() ?? 0.0)
            let cMaxX = min(1.0, rawCornerPoints.map(\.x).max() ?? 1.0)
            let cMinY = max(0.0, rawCornerPoints.map(\.y).min() ?? 0.0)
            let cMaxY = min(1.0, rawCornerPoints.map(\.y).max() ?? 1.0)
            let sourceViewport = CGRect(x: cMinX, y: cMinY, width: max(0.05, cMaxX - cMinX), height: max(0.05, cMaxY - cMinY))
            let check = PortraitFramingEvidence.anatomicalPenalty(cropRect: sourceViewport, subjectBounds: subject.bounds, profile: poseProfile, intent: intent)
            if !unchanged && check.penalty >= 3.2 {
                return nil
            }
            anatomicalPenaltyValue = min(0.18, check.penalty * 0.08)
        }
        let oobPenalty = 0.22 * oobFraction

        if sceneHints.hasRichGuidance, let raster, raster.isValid {
            return evaluateV5Window(
                subject: subject,
                intent: intent,
                aimPoint: aimPoint,
                box: box,
                ratio: ratio,
                rawCornerPoints: rawCornerPoints,
                raster: raster,
                metrics: metrics,
                sceneHints: sceneHints,
                baselineCleanliness: baselineCleanliness,
                protectedMinVisibility: protectedMinVisibility,
                anatomicalPenaltyValue: anatomicalPenaltyValue,
                oobFraction: oobFraction,
                evBias: evBias,
                sizeRatio: sizeRatio,
                intentPrior: intentPrior,
                unchanged: unchanged
            )
        }

        let fieldScore = 0.29 * sizeFit + 0.31 * placement + 0.10 * headroom +
            0.08 * space + 0.06 * edgeSafety + contextWeight * context +
            contextFitWeight * contextFit + 0.03 * metrics.cleanEdges + 0.02 * symmetry +
            0.02 * horizonFit + 0.07 * torqueBalance - anatomicalPenaltyValue - oobPenalty +
            intentPrior + ruleOfThirdsBonus + metrics.excessTrimGain + fillBonus - attnCutPenalty - ratioAdjustment
        let fieldNorm = min(1.0, max(0.0, fieldScore))
        let gaicScore = min(1.0, max(0.0,
            0.44 * fieldNorm +
            0.22 * metrics.roiSyncFocus +
            0.14 * metrics.depthSeparation +
            0.12 * metrics.cleanEdges +
            0.08 * torqueBalance - anatomicalPenaltyValue * 0.5
        ))
        return WindowEvaluation(
            fieldScore: fieldScore,
            gaicScore: gaicScore,
            explanation: explanation(intent: intent, gaze: subject.gaze, cleanEdges: metrics.cleanEdges, context: hasAttention ? context : 0),
            retainedAttention: metrics.retention,
            recommendedEVBias: evBias,
            oobFraction: oobFraction,
            sizeRatio: sizeRatio,
            excessTrimGain: metrics.excessTrimGain,
            wasteRatio: metrics.wasteRatio,
            sceneCleanGain: 0.0
        )
    }

    private static func baselineV5Cleanliness(raster: CompositionRaster, sceneHints: CompositionSceneHints) -> Double {
        let count = raster.side * raster.side
        guard count > 0, sceneHints.clutterMap.count == count else { return 0.70 }
        let meanClut = sceneHints.clutterMap.reduce(0.0, +) / Double(count)
        let blankArr = sceneHints.blankSurface.count == count ? sceneHints.blankSurface : []
        let meanBlank = blankArr.isEmpty ? 0.0 : (blankArr.reduce(0.0, +) / Double(count))
        return max(0.0, 1.0 - 1.65 * meanClut - 0.65 * max(0.0, meanBlank - 0.12))
    }

    private static func evaluateV5Window(
        subject: CompositionSubject,
        intent: LocalCompositionIntent,
        aimPoint: CGPoint,
        box: CGRect,
        ratio: Double,
        rawCornerPoints: [CGPoint],
        raster: CompositionRaster,
        metrics: Metrics,
        sceneHints: CompositionSceneHints,
        baselineCleanliness: Double,
        protectedMinVisibility: Double,
        anatomicalPenaltyValue: Double,
        oobFraction: Double,
        evBias: CGFloat,
        sizeRatio: Double,
        intentPrior: Double,
        unchanged: Bool
    ) -> WindowEvaluation {
        let side = raster.side
        let count = side * side
        let vx0 = max(0.0, min(1.0, Double(rawCornerPoints.map(\.x).min() ?? 0.0)))
        let vx1 = max(0.0, min(1.0, Double(rawCornerPoints.map(\.x).max() ?? 1.0)))
        let vy0 = max(0.0, min(1.0, Double(rawCornerPoints.map(\.y).min() ?? 0.0)))
        let vy1 = max(0.0, min(1.0, Double(rawCornerPoints.map(\.y).max() ?? 1.0)))
        let vw = max(1e-4, vx1 - vx0)
        let vh = max(1e-4, vy1 - vy0)

        let cleanInt = sceneHints.cleanInterest.count == count ? sceneHints.cleanInterest : raster.synchronizedSaliency
        let clutMap = sceneHints.clutterMap.count == count ? sceneHints.clutterMap : [Double](repeating: 0.0, count: count)
        let blankMap = sceneHints.blankSurface.count == count ? sceneHints.blankSurface : [Double](repeating: 0.0, count: count)

        var totalCI = 0.0, keptCI = 0.0
        var totalClut = 0.0, keptClut = 0.0
        var totalBlank = 0.0, keptBlank = 0.0
        var insideCount = 0
        var wSum = 0.0, wXSum = 0.0, wYSum = 0.0

        for y in 0..<side {
            let py = (Double(y) + 0.5) / Double(side)
            let yIn = (py >= vy0 && py <= vy1)
            let row = y * side
            for x in 0..<side {
                let i = row + x
                let ci = cleanInt[i]
                let cl = clutMap[i]
                let bl = blankMap[i]
                totalCI += ci
                totalClut += cl
                totalBlank += bl
                if yIn {
                    let px = (Double(x) + 0.5) / Double(side)
                    if px >= vx0 && px <= vx1 {
                        insideCount += 1
                        keptCI += ci
                        keptClut += cl
                        keptBlank += bl
                        let iw = 0.05 + ci
                        wSum += iw
                        wXSum += px * iw
                        wYSum += py * iw
                    }
                }
            }
        }

        let retCI = totalCI > 1e-4 ? min(1.0, keptCI / totalCI) : 1.0
        let exclClutFrac = totalClut > 1.5 ? (1.0 - keptClut / totalClut) : 0.0
        let inClutDensity = keptClut / Double(max(1, insideCount))
        let exclBlankFrac = totalBlank > 2.0 ? (1.0 - keptBlank / totalBlank) : 0.0
        let inBlankDensity = keptBlank / Double(max(1, insideCount))

        let avoid = sceneHints.avoid
        var dirTrimReward = 0.0
        var dirWeightSum = 0.0
        if avoid.left > 0.20 { dirTrimReward += avoid.left * min(1.0, vx0 / 0.16); dirWeightSum += avoid.left }
        if avoid.right > 0.20 { dirTrimReward += avoid.right * min(1.0, (1.0 - vx1) / 0.16); dirWeightSum += avoid.right }
        if avoid.top > 0.20 { dirTrimReward += avoid.top * min(1.0, vy0 / 0.14); dirWeightSum += avoid.top }
        if avoid.bottom > 0.20 { dirTrimReward += avoid.bottom * min(1.0, (1.0 - vy1) / 0.16); dirWeightSum += avoid.bottom }
        let dirTrimScore = dirWeightSum > 0.22 ? (dirTrimReward / max(0.35, dirWeightSum)) : 0.0

        let exclScore = min(1.0, 0.50 * dirTrimScore + 0.30 * exclClutFrac + 0.20 * exclBlankFrac)
        let clutterCleanliness = max(0.0, 1.0 - 1.65 * inClutDensity - 0.65 * max(0.0, inBlankDensity - 0.12))

        let hx0 = Double(box.minX), hy0 = Double(box.minY), hx1 = Double(box.maxX), hy1 = Double(box.maxY)
        let cxP = (Double(subject.anchor.x) - vx0) / vw
        let cyP = (Double(subject.anchor.y) - vy0) / vh

        let role = sceneHints.role
        let minProtVis = min(1.0, max(0.0, protectedMinVisibility))

        // Architectural roof & skyline protection
        var archRoofScore = 0.85
        if role == .architecture {
            if let roofY = sceneHints.archRoofTopY {
                let roofInY = (roofY - vy0) / vh
                if roofInY < 0.025 {
                    archRoofScore = max(0.0, 0.15 + roofInY * 12.0)
                } else {
                    archRoofScore = exp(-pow((roofInY - 0.14) / 0.16, 2))
                }
            } else if vy0 > 0.08 && sceneHints.skyFraction > 0.06 {
                archRoofScore = max(0.25, 1.0 - (vy0 - 0.08) * 3.0)
            }
        }

        // Horizon rule of thirds
        var horizonScore = 0.80
        if let hy = sceneHints.estimatedHorizonY,
           (role == .landscapeSky || role == .architecture || role == .streetLeading) {
            let hyIn = (hy - vy0) / vh
            if hyIn < 0.08 || hyIn > 0.92 {
                horizonScore = 0.15
            } else {
                let d3 = min(abs(hyIn - 0.333), abs(hyIn - 0.667), abs(hyIn - 0.50) + 0.08)
                horizonScore = exp(-(d3 * d3) / (2.0 * 0.14 * 0.14))
            }
        }

        // Vanishing point leading-lines alignment
        var vpScore = 0.75
        if let vp = sceneHints.refinedVanishingPoint {
            let vpInX = (Double(vp.point.x) - vx0) / vw
            let vpInY = (Double(vp.point.y) - vy0) / vh
            if (0.12...0.88).contains(vpInX) && (0.12...0.85).contains(vpInY) {
                let dGold = min(
                    hypot(vpInX - 0.382, vpInY - 0.382),
                    hypot(vpInX - 0.618, vpInY - 0.382),
                    hypot(vpInX - 0.382, vpInY - 0.333),
                    hypot(vpInX - 0.618, vpInY - 0.333)
                )
                vpScore = 0.40 + 0.60 * exp(-(dGold * dGold) / (2.0 * 0.16 * 0.16))
            } else {
                vpScore = 0.25
            }
        }

        // Chromatic focal accent placement
        var accentScore = 0.65
        if let fa = sceneHints.focalAccent {
            let faInX = (Double(fa.point.x) - vx0) / vw
            let faInY = (Double(fa.point.y) - vy0) / vh
            if (0.06...0.94).contains(faInX) && (0.06...0.94).contains(faInY) {
                let marginFA = min(faInX, min(1.0 - faInX, min(faInY, 1.0 - faInY)))
                let dFA = min(
                    hypot(faInX - 0.382, faInY - 0.382),
                    hypot(faInX - 0.618, faInY - 0.382),
                    hypot(faInX - 0.382, faInY - 0.618),
                    hypot(faInX - 0.618, faInY - 0.618),
                    hypot(faInX - 0.500, faInY - 0.480) + 0.04
                )
                accentScore = 0.35 + 0.65 * exp(-(dFA * dFA) / (2.0 * 0.18 * 0.18)) * min(1.0, marginFA / 0.16)
            } else {
                accentScore = 0.15
            }
        }

        // Clamped subject scale & breathing margin
        let vhx0 = max(0.0, min(1.0, hx0)), vhy0 = max(0.0, min(1.0, hy0))
        let vhx1 = max(0.0, min(1.0, hx1)), vhy1 = max(0.0, min(1.0, hy1))
        let areaIn = max(0.01, (vhx1 - vhx0) * (vhy1 - vhy0))
        let origArea = max(0.01, Double(subject.bounds.width * subject.bounds.height))
        let targetArea: Double = {
            switch role {
            case .portrait: return 0.30
            case .animal: return 0.28
            case .deskWorkspace: return 0.44
            case .tabletopEnsemble: return 0.46
            case .indoorRoom: return 0.56
            case .architecture: return 0.46
            case .streetLeading: return 0.44
            case .landscapeSky: return 0.42
            case .apertureView: return 0.50
            case .foliageGarden: return 0.52
            default: return 0.34
            }
        }()
        let scaleFit: Double
        if role.isWideRole && origArea >= targetArea * 0.90 {
            if (0.38...0.98).contains(areaIn) && minProtVis >= 0.78 {
                scaleFit = 0.96
            } else {
                let lr = log(areaIn / targetArea)
                scaleFit = exp(-(lr * lr) / 1.40)
            }
        } else {
            let lr = log(areaIn / targetArea)
            scaleFit = exp(-(lr * lr) / 1.15)
        }

        let hb0 = Double(subject.bounds.minX), hb1 = Double(subject.bounds.minY)
        let hbMaxX = Double(subject.bounds.maxX), hbMaxY = Double(subject.bounds.maxY)
        let origMarginMin = min(hb0, min(hb1, min(1.0 - hbMaxX, 1.0 - hbMaxY)))
        let subjMargin = min(hx0, min(hy0, min(1.0 - hx1, 1.0 - hy1)))
        var cleanClipPen = 0.0
        let edgeBreath: Double
        if origMarginMin < 0.02 {
            let cL = max(0.0, -min(0.0, hx0 - hb0)) * (avoid.left < 0.25 ? 1.25 : 0.35)
            let cR = max(0.0, -min(0.0, (1.0 - hx1) - (1.0 - hbMaxX))) * (avoid.right < 0.25 ? 1.25 : 0.35)
            let cT = max(0.0, -min(0.0, hy0 - hb1)) * (avoid.top < 0.25 ? 1.25 : 0.35)
            let cB = max(0.0, -min(0.0, (1.0 - hy1) - (1.0 - hbMaxY))) * (avoid.bottom < 0.25 ? 1.25 : 0.35)
            let clippedTight = max(cL, max(cR, max(cT, cB)))
            let discrete = role.isDiscreteRole && ratio > 1.01
            edgeBreath = discrete ? max(0.30, 1.0 - clippedTight * 3.2) : 0.92
            cleanClipPen = discrete ? min(0.12, clippedTight * 0.45) : 0.0
        } else {
            edgeBreath = (role == .landscapeSky) ? 0.85 : min(1.0, max(0.0, (subjMargin + 0.02) / 0.09))
        }

        // Role-specific placement rule
        let ruleFit: Double
        if role == .indoorRoom || role == .tabletopEnsemble || role == .deskWorkspace {
            let dRule = hypot(cxP - 0.50, cyP - 0.50) * 0.65
            let dThird = min(hypot(cxP - 0.382, cyP - 0.48), min(hypot(cxP - 0.618, cyP - 0.48), hypot(cxP - 0.50, cyP - 0.50)))
            let md = min(dRule, dThird)
            ruleFit = exp(-(md * md) / (2.0 * 0.18 * 0.18))
        } else if role == .architecture {
            let dArch = min(hypot(cxP - 0.50, cyP - 0.50), min(hypot(cxP - 0.42, cyP - 0.50), hypot(cxP - 0.58, cyP - 0.50)))
            ruleFit = exp(-(dArch * dArch) / (2.0 * 0.18 * 0.18))
        } else {
            let dGold = min(
                hypot(cxP - 0.382, cyP - 0.382),
                min(hypot(cxP - 0.618, cyP - 0.382),
                    min(hypot(cxP - 0.382, cyP - 0.618),
                        min(hypot(cxP - 0.618, cyP - 0.618),
                            hypot(cxP - 0.500, cyP - 0.420) + 0.04)))
            )
            ruleFit = exp(-(dGold * dGold) / (2.0 * 0.18 * 0.18))
        }

        // Visual balance of clean interest
        let mx = wSum > 1e-6 ? ((wXSum / wSum) - vx0) / vw : 0.5
        let my = wSum > 1e-6 ? ((wYSum / wSum) - vy0) / vh : 0.5
        let balanceScore = max(0.0, 1.0 - 1.75 * hypot(mx - 0.50, my - 0.50))

        // Clean border edge energy
        let ix0 = max(0, min(side - 1, Int(vx0 * Double(side))))
        let ix1 = max(ix0, min(side - 1, Int(vx1 * Double(side))))
        let iy0 = max(0, min(side - 1, Int(vy0 * Double(side))))
        let iy1 = max(iy0, min(side - 1, Int(vy1 * Double(side))))
        var edgeSum = 0.0, edgeCnt = 0
        for x in ix0...ix1 {
            edgeSum += raster.edges[iy0 * side + x] + raster.edges[iy1 * side + x]
            edgeCnt += 2
        }
        for y in iy0...iy1 {
            edgeSum += raster.edges[y * side + ix0] + raster.edges[y * side + ix1]
            edgeCnt += 2
        }
        let borderClean = max(0.0, 1.0 - 1.3 * (edgeSum / Double(max(1, edgeCnt))))

        // Minimum-necessary zoom discipline
        var necPen = cleanClipPen
        let maxAvoid = avoid.maxAvoid
        let cleanGain = clutterCleanliness - baselineCleanliness
        if ratio < 1.03 && maxAvoid >= 0.38 {
            necPen += 0.11 * (maxAvoid - 0.25)
        } else if ratio > 1.02 {
            if ratio > 1.24 && cleanGain < 0.03 && exclScore < 0.35 && areaIn > 0.35 {
                necPen += 0.14 * (ratio - 1.24)
            }
            if role == .indoorRoom && ratio > 1.44 {
                necPen += 0.42 * (ratio - 1.44)
            } else if (role == .architecture || role == .apertureView || role == .streetLeading) && ratio > 1.44 {
                necPen += 0.22 * (ratio - 1.44)
            }
            if (role == .tabletopEnsemble || role == .deskWorkspace) && ratio > 1.28 && minProtVis < 0.90 {
                necPen += 0.25 * (ratio - 1.25)
            }
            if ratio > 1.75 && exclClutFrac < 0.25 && exclBlankFrac < 0.25 {
                necPen += 0.12 * (ratio - 1.75)
            }
        }

        let wExcl = avoid.directionalWeightSum > 0.25 ? 0.30 : 0.15
        let wArch = role == .architecture ? 0.14 : 0.03
        let wHor = (role == .landscapeSky || role == .architecture || role == .streetLeading) ? 0.14 : 0.04
        let wVP = (role == .streetLeading && sceneHints.refinedVanishingPoint != nil) ? 0.15 : 0.04
        let wAcc = sceneHints.focalAccent != nil ? 0.12 : 0.03

        let v5Field = 0.16 * ruleFit +
            0.14 * scaleFit +
            wExcl * (0.58 * exclScore + 0.42 * clutterCleanliness) +
            0.13 * minProtVis +
            0.09 * retCI +
            0.09 * balanceScore +
            0.06 * borderClean +
            0.05 * edgeBreath +
            wArch * archRoofScore +
            wHor * horizonScore +
            wVP * vpScore +
            wAcc * accentScore -
            necPen - 0.22 * oobFraction - anatomicalPenaltyValue +
            (unchanged ? 0.0 : 0.35 * intentPrior)

        let fieldNorm = min(1.0, max(0.0, v5Field))
        let gaicScore = min(1.0, max(0.0,
            0.44 * fieldNorm +
            0.22 * metrics.roiSyncFocus +
            0.14 * metrics.depthSeparation +
            0.12 * borderClean +
            0.08 * balanceScore - anatomicalPenaltyValue * 0.5
        ))
        let trimGain = max(metrics.excessTrimGain, max(0.0, exclScore * 0.12 + max(0.0, cleanGain)))
        let v5Reason = buildV5Explanation(sceneHints: sceneHints, vx0: vx0, vy0: vy0, vx1: vx1, vy1: vy1,
                                          aimPoint: aimPoint, zoomRatio: ratio)
        return WindowEvaluation(
            fieldScore: v5Field,
            gaicScore: gaicScore,
            explanation: v5Reason,
            retainedAttention: retCI,
            recommendedEVBias: evBias,
            oobFraction: oobFraction,
            sizeRatio: sizeRatio,
            excessTrimGain: trimGain,
            wasteRatio: max(metrics.wasteRatio, inClutDensity * 0.7 + inBlankDensity * 0.3),
            sceneCleanGain: cleanGain
        )
    }

    private static func buildV5Explanation(sceneHints: CompositionSceneHints,
                                           vx0: Double, vy0: Double, vx1: Double, vy1: Double,
                                           aimPoint: CGPoint, zoomRatio: Double) -> String {
        var parts: [String] = []
        if !sceneHints.reasonSubject.isEmpty {
            parts.append(sceneHints.reasonSubject)
        }
        let dx = Double(aimPoint.x) - 0.5
        let dy = Double(aimPoint.y) - 0.5
        if abs(dx) >= 0.04 || abs(dy) >= 0.04 {
            var dirs: [String] = []
            if dx <= -0.04 { dirs.append("trái") } else if dx >= 0.04 { dirs.append("phải") }
            if dy <= -0.04 { dirs.append("lên") } else if dy >= 0.04 { dirs.append("xuống") }
            if !dirs.isEmpty { parts.append("Lia khung \(dirs.joined(separator: "-"))") }
        }
        var avoids: [String] = []
        if sceneHints.avoid.left > 0.25 && vx0 > 0.04 { avoids.append("vật cản rìa trái") }
        if sceneHints.avoid.right > 0.25 && vx1 < 0.96 { avoids.append("tường/cột rìa phải") }
        if sceneHints.avoid.top > 0.25 && vy0 > 0.04 { avoids.append("dây/tường trống trên") }
        if sceneHints.avoid.bottom > 0.25 && vy1 < 0.96 { avoids.append("sàn/mái dưới") }
        if !avoids.isEmpty { parts.append("bỏ " + avoids.joined(separator: ", ")) }
        if sceneHints.role == .architecture && sceneHints.archRoofTopY != nil {
            parts.append("giữ trọn mái & khoảng trời")
        } else if sceneHints.role == .streetLeading && sceneHints.refinedVanishingPoint != nil {
            parts.append("căn đường tụ 1/3")
        } else if sceneHints.role == .landscapeSky {
            parts.append("cân đường chân trời 1/3")
        }
        if zoomRatio > 1.05 {
            parts.append(String(format: "zoom %.2fx", zoomRatio))
        } else {
            parts.append("giữ góc 1.0x")
        }
        return parts.isEmpty ? "Tối ưu khung hình theo ngữ cảnh" : parts.joined(separator: " · ")
    }

    static func proposals(subjects: [CompositionSubject], intents: [LocalCompositionIntent],
                          raster: CompositionRaster, calibration: TrackingCalibration,
                          currentZoom: CGFloat, allowedZooms: [CGFloat], protectedBounds: [CGRect] = [],
                          incidentalBounds: [CGRect] = [],
                          proposalLimit: Int = 6, refining: [CompositionProposal] = [],
                          poseProfile: AnatomicalPoseProfile? = nil,
                          sceneHints: CompositionSceneHints = .neutral,
                          isCancelled: () -> Bool = { false }) -> [CompositionProposal] {
        guard raster.isValid, calibration.isValid, currentZoom.isFinite, currentZoom > 0 else { return [] }
        let horizonHint = raster.horizon
        let isHighMemory = ProcessInfo.processInfo.physicalMemory >= 6_000_000_000
        let validSubjects = subjects.filter {
            valid($0.bounds) && inside($0.anchor, margin: 0) && $0.bounds.contains($0.anchor) &&
                $0.confidence.isFinite && $0.importance.isFinite && $0.gaze.isFinite
        }
        let protectedPeople = validSubjects.filter { $0.kind == .person || $0.kind == .face || $0.kind == .group }
        let incidentalRects = incidentalBounds.filter { valid($0) }
        let hardwareMax = allowedZooms.filter { $0.isFinite && $0 > 0 }.max() ?? currentZoom
        // Unlock dense multi-scale zoom ceiling up to 5.0x / currentZoom * 3.5 within hardware capability.
        let maxZoom = max(currentZoom, min(5.0, hardwareMax, max(currentZoom * 3.5, allowedZooms.filter { $0.isFinite && $0 <= currentZoom * 3.5 }.max() ?? currentZoom)))

        // Precompute compact raster cells (~1024 on 64x64, exact on <=32x32) so 512-1024 geometric evals stay fast.
        let sampleCells = makeSampleCells(from: raster)
        let baselineProfile = rasterBaselineProfile(from: raster)
        let baselineV5Cleanliness = sceneHints.hasRichGuidance ? baselineV5Cleanliness(raster: raster, sceneHints: sceneHints) : 0.0

        var result: [CompositionProposal] = []
        for subject in validSubjects.prefix(4) {
            let cropAttention = subject.allowsAttentionCrop && subject.kind == .object && raster.hasAttention
            let protectedAnchor = CompositionCropProtection.bounds(body: subject.bounds, portrait: nil,
                intent: .object, anchor: subject.anchor, attentionRegion: cropAttention)
            let subjectDepthStats = raster.depthStats(in: subject.bounds)
            let rawHeroArea = Double(subject.bounds.width * subject.bounds.height)
            let isNonPersonOrAnimal = subject.kind != .person && subject.kind != .face && subject.kind != .group && subject.kind != .animal
            for intent in applicableIntents(subject: subject, preferred: intents, people: protectedPeople) {
                if isCancelled() { return [] }
                let protectedRects: [CGRect] = intent == .group
                    ? (protectedPeople.map(\.bounds) + protectedBounds.filter { valid($0) })
                    : ([protectedAnchor] + protectedBounds.filter { valid($0) })
                let desired = preferredPlacement(subject: subject, intent: intent, raster: raster)
                let allowHeroCrop = subject.kind == .person && intent == .portrait
                func evaluate(_ destination: CGPoint, zoom: CGFloat) -> CompositionProposal? {
                    let unchanged = zoom == currentZoom && hypot(destination.x - subject.anchor.x,
                                                                  destination.y - subject.anchor.y) < 0.000001
                    let origAnchorMargin = min(Double(subject.anchor.x), Double(1.0 - subject.anchor.x),
                                               Double(subject.anchor.y), Double(1.0 - subject.anchor.y))
                    let destMargin = (subject.allowsAttentionCrop || subject.kind == .scenery || sceneHints.hasRichGuidance)
                        ? 0.025
                        : min(0.08, max(0.025, origAnchorMargin * 0.70))
                    guard inside(destination, margin: unchanged ? 0 : CGFloat(destMargin)), zoom.isFinite,
                          zoom >= currentZoom, zoom <= maxZoom else { return nil }
                    let ratio = Double(zoom / currentZoom)
                    let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                        cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect, isMeasured: false)
                    let rotation = simd_quatd(from: future.deviceRay(at: destination),
                                             to: calibration.deviceRay(at: subject.anchor))
                    let sourceCorners = corners.map {
                        calibration.project(deviceRay: rotation.act(future.deviceRay(at: $0)))
                    }
                    // Thực pixel 100%: tuyệt đối không sinh góc ngoài [0, 1] gây viền đen hoặc sai lệch hình học khi xoay/zoom
                    let cornerOOBMargin = CGFloat(unchanged ? -0.00001 : -0.000005)
                    let aimMargin = CGFloat(unchanged ? 0.0 : 0.032)
                    guard sourceCorners.allSatisfy({ $0.isInFront && inside($0.point, margin: cornerOOBMargin) }),
                          let box = project(subject.bounds, from: calibration, to: future, rotation: rotation),
                          let anchorBox = project(protectedAnchor, from: calibration, to: future, rotation: rotation),
                          safe(anchorBox, original: protectedAnchor, allowCrop: allowHeroCrop || (sceneHints.hasRichGuidance && isNonPersonOrAnimal) || (subject.allowsAttentionCrop && (protectedAnchor.minX <= 0.055 || protectedAnchor.maxX >= 0.945 || protectedAnchor.minY <= 0.055 || protectedAnchor.maxY >= 0.945))),
                          (!cropAttention || sceneHints.hasRichGuidance || visibleFraction(box) >= 0.35) else { return nil }

                    var minProtVis = visibleFraction(box)
                    let protectedOK = protectedRects.allSatisfy { original in
                        guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return false }
                        let vis = visibleFraction(rect)
                        if vis < minProtVis { minProtVis = vis }
                        if sceneHints.hasRichGuidance && isNonPersonOrAnimal && !unchanged {
                            if sceneHints.role == .tabletopEnsemble || sceneHints.role == .deskWorkspace {
                                return safe(rect, original: original, allowCrop: true) && vis >= 0.88
                            }
                            if sceneHints.role.isWideRole {
                                let minReq = (rawHeroArea > 0.45 && sceneHints.avoid.maxAvoid >= 0.35) ? 0.66 : 0.74
                                return safe(rect, original: original, allowCrop: true) && vis >= minReq
                            }
                        }
                        let touchesEdge = original.minX <= 0.035 || original.maxX >= 0.965 || original.minY <= 0.035 || original.maxY >= 0.965
                        let nonPersonEdge = touchesEdge && original.width < 0.78 && original.height < 0.78 &&
                            subject.kind != .person && subject.kind != .face && subject.kind != .group
                        let safeOK = safe(rect, original: original, allowCrop: (allowHeroCrop && original == protectedAnchor) || nonPersonEdge)
                        return nonPersonEdge ? (safeOK && vis >= 0.981) : safeOK
                    }
                    guard protectedOK, incidentalRects.allSatisfy({ original in
                        guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return true }
                        let fraction = visibleFraction(rect)
                        return fraction <= 0.02 || fraction >= 0.98
                    }) else { return nil }
                    let aim = calibration.project(deviceRay: rotation.act(SIMD3(0, 0, -1)))
                    guard aim.isInFront, inside(aim.point, margin: aimMargin) else { return nil }
                    let rawCornerPoints = sourceCorners.map(\.point)
                    let intentPrior = intent == intents.first ? 0.045 : (intents.contains(intent) ? 0.02 : 0)
                    guard let evalResult = evaluateWindowScore(
                        subject: subject,
                        intent: intent,
                        desired: desired,
                        destination: destination,
                        aimPoint: aim.point,
                        box: box,
                        zoom: zoom,
                        currentZoom: currentZoom,
                        rawCornerPoints: rawCornerPoints,
                        rotation: rotation,
                        calibration: calibration,
                        future: future,
                        raster: raster,
                        sampleCells: sampleCells,
                        protectedPeople: protectedPeople,
                        subjectDepth: subjectDepthStats.meanDepth,
                        horizonHint: horizonHint,
                        poseProfile: poseProfile,
                        intentPrior: intentPrior,
                        cropAttention: cropAttention,
                        unchanged: unchanged,
                        baselineProfile: baselineProfile,
                        sceneHints: sceneHints,
                        baselineCleanliness: baselineV5Cleanliness,
                        protectedMinVisibility: minProtVis
                    ) else { return nil }
                    let combinedScore = evalResult.fieldScore + 0.06 * (evalResult.gaicScore - 0.5)
                    return CompositionProposal(subjectIndex: subject.index, intent: intent,
                        subjectPoint: subject.anchor, aimPoint: aim.point, expectedSubjectRect: box,
                        sourceCorners: rawCornerPoints, rotation: rotation, zoom: zoom,
                        evidenceConfidence: min(1, max(0, subject.confidence)), score: combinedScore,
                        explanation: evalResult.explanation,
                        usesCenter: abs(destination.x - 0.5) < 0.055, retainedAttention: evalResult.retainedAttention,
                        recommendedEVBias: evalResult.recommendedEVBias, outOfBoundsFraction: evalResult.oobFraction,
                        continuousFieldScore: evalResult.fieldScore, gaicScore: evalResult.gaicScore,
                        sizeRatio: evalResult.sizeRatio,
                        excessTrimGain: evalResult.excessTrimGain,
                        frameWasteRatio: evalResult.wasteRatio,
                        sceneWasteRatio: baselineProfile.waste,
                        isAttentionSubject: subject.isAttentionOnly,
                        sceneCleanGain: evalResult.sceneCleanGain)
                }
                if !refining.isEmpty {
                    for seed in refining where seed.subjectIndex == subject.index && seed.intent == intent {
                        let ratio = Double(seed.zoom / currentZoom)
                        let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                            cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect)
                        let p = future.project(deviceRay: seed.rotation.inverse.act(calibration.deviceRay(at: subject.anchor)))
                        guard p.isInFront else { continue }
                        for stepScale in [1.0, 0.5] {
                            for axis in 0..<3 { for sign in [-1.0, 1.0] {
                                if isCancelled() { return [] }
                                let panStep = 0.018 * stepScale
                                let zoomStep = 0.045 * stepScale
                                let destination = CGPoint(x: p.point.x + (axis == 0 ? sign * panStep : 0),
                                                          y: p.point.y + (axis == 1 ? sign * panStep : 0))
                                let zoom = axis == 2 ? seed.zoom * CGFloat(exp(sign * zoomStep)) : seed.zoom
                                if let neighbour = evaluate(destination, zoom: zoom) { result.append(neighbour) }
                            } }
                        }
                    }
                    continue
                }
                var seeds: [CompositionProposal] = []
                let placements = dynamicPlacements(subject: subject, intent: intent, desired: desired,
                                                   raster: raster, highMemory: isHighMemory,
                                                   sceneHints: sceneHints)
                let subjectZooms = dynamicZooms(subject: subject, intent: intent, desired: desired,
                                                currentZoom: currentZoom, maxZoom: maxZoom,
                                                allowedZooms: allowedZooms, highMemory: isHighMemory,
                                                sceneHints: sceneHints)
                let rawEvaluationCap = isHighMemory ? 1024 : 512
                // Iterate placements outer and zooms inner so priority anchors explore the FULL zoom ladder evenly.
                outer: for destination in placements {
                    for zoom in subjectZooms {
                        if isCancelled() { return [] }
                        if let plan = evaluate(destination, zoom: zoom) {
                            seeds.append(plan)
                            if seeds.count >= rawEvaluationCap { break outer }
                        }
                    }
                }
                // Refine top diverse candidates in continuous pan/tilt/log-focal-length space.
                for seed in diverse(seeds, limit: isHighMemory ? 8 : 5) {
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
                result.append(contentsOf: seeds)
            }
        }
        guard !isCancelled() else { return [] }
        if !refining.isEmpty {
            return diverse(result, limit: proposalLimit, raySeparation: 0.008, zoomSeparation: 0.018)
        }
        var perSubjectBest: [Int: CompositionProposal] = [:]
        var perZoomBest: [Int: CompositionProposal] = [:]
        for proposal in result {
            if proposal.score > (perSubjectBest[proposal.subjectIndex]?.score ?? -.infinity) {
                perSubjectBest[proposal.subjectIndex] = proposal
            }
            let zBin = Int((log(Double(proposal.zoom / currentZoom)) * 12).rounded())
            if proposal.score > (perZoomBest[zBin]?.score ?? -.infinity) {
                perZoomBest[zBin] = proposal
            }
        }
        let subjectChampions = perSubjectBest.values.sorted { $0.score > $1.score }
        if proposalLimit <= 6 {
            let topDiverse = diverse(result, limit: proposalLimit, raySeparation: 0.04, zoomSeparation: 0.08)
            guard proposalLimit > 1, let leader = topDiverse.first else {
                return topDiverse
            }
            var compact: [CompositionProposal] = [leader]
            for candidate in subjectChampions where candidate.subjectIndex != leader.subjectIndex {
                guard compact.count < proposalLimit else { break }
                compact.append(candidate)
            }
            let zoomSlots = min(proposalLimit, max(compact.count + 2, proposalLimit / 2 + 2))
            for candidate in perZoomBest.values.sorted(by: { $0.score > $1.score }) {
                guard compact.count < zoomSlots else { break }
                if !compact.contains(where: { $0.subjectIndex == candidate.subjectIndex &&
                    abs(log(Double($0.zoom / candidate.zoom))) < 0.045 &&
                    hypot($0.aimPoint.x - candidate.aimPoint.x, $0.aimPoint.y - candidate.aimPoint.y) < 0.020 }) {
                    compact.append(candidate)
                }
            }
            for candidate in topDiverse {
                guard compact.count < proposalLimit else { break }
                if !compact.contains(where: { $0.subjectIndex == candidate.subjectIndex &&
                    abs(log(Double($0.zoom / candidate.zoom))) < 0.045 &&
                    hypot($0.aimPoint.x - candidate.aimPoint.x, $0.aimPoint.y - candidate.aimPoint.y) < 0.040 }) {
                    compact.append(candidate)
                }
            }
            return compact.sorted { $0.score > $1.score }
        }
        // Preserve a no-change baseline and a nearby gentle alternative, guarantee per-subject and
        // per-zoom-rung coverage, retain top GAIC+Field winners, and stratify multi-scale buckets.
        var selected = result.filter(\.isUnchangedView).prefix(1).map { $0 }
        if let nearOriginal = result
            .filter({ !$0.isUnchangedView && abs(log(Double($0.zoom / currentZoom))) < 0.14 &&
                hypot($0.aimPoint.x - 0.5, $0.aimPoint.y - 0.5) < 0.06 })
            .max(by: { $0.score < $1.score }) {
            selected.append(nearOriginal)
        }
        selected.append(contentsOf: subjectChampions)
        let zoomChampions = perZoomBest.keys.sorted().compactMap { perZoomBest[$0] }
        let zoomBudget = max(3, proposalLimit / 4)
        if !zoomChampions.isEmpty {
            let count = min(zoomBudget, zoomChampions.count)
            for idx in 0..<count {
                selected.append(zoomChampions[min(zoomChampions.count - 1, idx * zoomChampions.count / count)])
            }
        }
        let directTopCount = max(4, proposalLimit / 4)
        selected += diverse(result, limit: directTopCount, raySeparation: 0.032, zoomSeparation: 0.065)
        struct BucketKey: Hashable, Comparable {
            let z: Int
            let x: Int
            let y: Int
            let intent: String
            static func < (lhs: Self, rhs: Self) -> Bool {
                (lhs.z, lhs.x, lhs.y, lhs.intent) < (rhs.z, rhs.x, rhs.y, rhs.intent)
            }
        }
        var buckets: [BucketKey: CompositionProposal] = [:]
        for proposal in result {
            let z = Int((log(Double(proposal.zoom / currentZoom)) * 12).rounded())
            let x = Int((proposal.aimPoint.x * 6).rounded())
            let y = Int((proposal.aimPoint.y * 6).rounded())
            let key = BucketKey(z: z, x: x, y: y, intent: proposal.intent.rawValue)
            if proposal.score > (buckets[key]?.score ?? -.infinity) { buckets[key] = proposal }
        }
        let explored = buckets.keys.sorted().compactMap { buckets[$0] }
        if !explored.isEmpty {
            let exploreCount = min(explored.count, max(6, proposalLimit - selected.count + 4))
            for index in 0..<exploreCount {
                selected.append(explored[min(explored.count - 1, index * explored.count / exploreCount)])
            }
        }
        var unique: [CompositionProposal] = []
        for proposal in selected + result.sorted(by: { $0.score > $1.score }) {
            if !unique.contains(where: { $0.subjectIndex == proposal.subjectIndex &&
                hypot($0.aimPoint.x - proposal.aimPoint.x, $0.aimPoint.y - proposal.aimPoint.y) < 0.020 &&
                abs(log(Double($0.zoom / proposal.zoom))) < 0.045 }) { unique.append(proposal) }
            if unique.count == proposalLimit { break }
        }
        return unique
    }

    private static func preferredPlacement(subject: CompositionSubject, intent: LocalCompositionIntent,
                                           raster: CompositionRaster) -> CGPoint {
        if intent == .architecture { return CGPoint(x: 0.5, y: 0.48) }
        let cx = Double(subject.anchor.x)
        let cy = Double(subject.anchor.y)
        let person = subject.kind == .person || subject.kind == .face || subject.kind == .group

        // Trường Thế Năng Thị Giác Liên Tục (Continuous Visual Potential Field):
        let negSpace = raster.negativeSpaceVector(around: subject.anchor, gaze: subject.gaze)
        let comX = Double(raster.visualCenterOfMass?.x ?? 0.5)
        let lead = min(1.0, max(-1.0, Double(subject.gaze)))

        // 1. Phân định hướng nhìn & khoảng thở (Gaze Lead Room):
        let targetX: Double
        if abs(lead) > 0.08 {
            // Nhìn sang phải (lead > 0) -> Đặt trên trục 1/3 trái (0.36 - 0.382) để mắt nhìn xuyên qua không gian mở
            // Nhìn sang trái (lead < 0) -> Đặt trên trục 1/3 phải (0.618 - 0.64)
            targetX = lead > 0 ? (0.382 - 0.02 * min(1.0, lead)) : (0.618 - 0.02 * max(-1.0, lead))
        } else if intent == .closeUp || intent == .food {
            // Ảnh đặc tả ẩm thực / tĩnh vật: nếu nằm rất gần giữa thì giữ tâm đối xứng tự nhiên
            targetX = abs(cx - 0.5) < 0.06 ? 0.50 : (cx < 0.5 ? 0.382 : 0.618)
        } else {
            // Khi hướng nhìn trung tính hoặc nhìn thẳng vào ống kính (chân dung, đường phố, thú cưng):
            // Quy tắc nhiếp ảnh kinh điển: Không bao giờ ép chủ thể vào tâm chết 0.5 trừ ảnh kỷ yếu!
            let spatialFlow = tanh(2.2 * (cx - 0.5))
            let openSpaceFlow = -tanh(1.8 * Double(negSpace.direction.dx))
            let counterbalance = -0.28 * tanh(1.8 * (comX - cx))
            let lateralSignal = 0.52 * spatialFlow + 0.30 * openSpaceFlow + 0.18 * counterbalance

            let sign: Double
            if abs(lateralSignal) > 0.05 {
                sign = lateralSignal < 0 ? -1.0 : 1.0
            } else {
                // Nếu tín hiệu ngang trung tính, phân bổ vào trục 1/3 gần vị trí chủ thể nhất hoặc trục trái (0.382)
                sign = cx < 0.50 ? -1.0 : (cx > 0.50 ? 1.0 : -1.0)
            }
            targetX = 0.5 + 0.118 * sign * (0.85 + 0.15 * min(1.0, abs(lateralSignal)))
        }
        let x = min(0.68, max(0.32, targetX))

        if intent == .landscape {
            let hY = raster.horizon.map { Double($0.y) } ?? cy
            let y = min(0.62, max(0.34, 0.5 + 0.118 * tanh(2.8 * (hY - 0.5))))
            return CGPoint(x: x, y: y)
        }

        let vGazeBias = -0.035 * tanh(2.0 * Double(subject.verticalGaze))
        var finalX = x
        var finalY: Double
        if person {
            let isFullBody = subject.bounds.height > 0.55
            let eyeLine = isFullBody ? 0.32 : (subject.kind == .face ? 0.35 : 0.36)
            finalY = min(0.44, max(0.30, eyeLine + 0.03 * tanh(1.8 * (cy - 0.42)) + vGazeBias))
        } else if intent == .food || intent == .closeUp {
            finalY = min(0.56, max(0.42, 0.48 + 0.08 * tanh(2.0 * (cy - 0.48)) + vGazeBias))
        } else {
            finalY = min(0.62, max(0.36, 0.46 + 0.12 * tanh(2.2 * (cy - 0.48)) + vGazeBias))
        }
        if let vp = raster.vanishingPoint, vp.confidence >= 0.55 {
            let vpWeight = min(0.08, vp.confidence * 0.10)
            finalX = min(0.68, max(0.32, (1.0 - vpWeight) * finalX + vpWeight * Double(vp.point.x)))
            finalY = min(0.64, max(0.32, (1.0 - vpWeight * 0.7) * finalY + (vpWeight * 0.7) * Double(vp.point.y)))
        }
        return CGPoint(x: finalX, y: finalY)
    }

    static func computeOptimalEVBias(
        raster: CompositionRaster,
        heroRect: CGRect,
        aimPoint: CGPoint,
        zoom: CGFloat,
        scene: LocalCompositionIntent
    ) -> CGFloat {
        guard raster.isValid else { return 0.0 }
        let targetLuma: Double
        switch scene {
        case .portrait: targetLuma = 0.54
        case .animal: targetLuma = 0.53
        case .food, .closeUp: targetLuma = 0.50
        case .landscape, .street: targetLuma = 0.44
        case .architecture: targetLuma = 0.46
        case .environmentalPortrait, .group, .object: targetLuma = 0.48
        }

        var heroLumaSum = 0.0, heroCount = 0.0
        var centerLumaSum = 0.0, centerCount = 0.0
        let centerRadius = 0.22

        for y in 0..<raster.side {
            let py = (Double(y) + 0.5) / Double(raster.side)
            for x in 0..<raster.side {
                let px = (Double(x) + 0.5) / Double(raster.side)
                let p = CGPoint(x: px, y: py)
                let luma = raster.luminance[y * raster.side + x]
                if heroRect.contains(p) {
                    heroLumaSum += luma; heroCount += 1
                }
                if hypot(px - Double(aimPoint.x), py - Double(aimPoint.y)) < centerRadius {
                    centerLumaSum += luma; centerCount += 1
                }
            }
        }
        let heroLuma = heroCount > 0 ? heroLumaSum / heroCount : 0.48
        let centerLuma = centerCount > 0 ? centerLumaSum / centerCount : 0.48
        let measuredLuma = heroCount > 0 ? (0.65 * heroLuma + 0.35 * centerLuma) : centerLuma

        let evDelta = log2(targetLuma / max(0.08, measuredLuma))
        return CGFloat(min(1.5, max(-1.5, evDelta)))
    }

    private static func dynamicPlacements(subject: CompositionSubject, intent: LocalCompositionIntent,
                                          desired: CGPoint, raster: CompositionRaster,
                                          highMemory: Bool = false,
                                          sceneHints: CompositionSceneHints = .neutral) -> [CGPoint] {
        var points: [CGPoint] = [desired, subject.anchor]
        if intent == .architecture || intent == .group || intent == .closeUp ||
           (sceneHints.hasRichGuidance && (sceneHints.role == .indoorRoom || sceneHints.role == .tabletopEnsemble || sceneHints.role == .deskWorkspace)) {
            points.append(CGPoint(x: 0.5, y: 0.5))
        }
        if sceneHints.hasRichGuidance {
            let avoid = sceneHints.avoid
            let pushX = (avoid.left > 0.25 ? 0.08 * avoid.left : 0.0) - (avoid.right > 0.25 ? 0.08 * avoid.right : 0.0)
            let pushY = (avoid.top > 0.25 ? 0.08 * avoid.top : 0.0) - (avoid.bottom > 0.25 ? 0.08 * avoid.bottom : 0.0)
            if abs(pushX) > 0.01 || abs(pushY) > 0.01 {
                for basePt in [CGPoint(x: 0.5, y: 0.5), desired] {
                    for mult in [0.7, 1.2, 1.8] {
                        points.append(CGPoint(
                            x: min(0.84, max(0.16, Double(basePt.x) - pushX * mult)),
                            y: min(0.84, max(0.16, Double(basePt.y) - pushY * mult))
                        ))
                    }
                }
            }
            if let fa = sceneHints.focalAccent {
                points.append(fa.point)
                points.append(CGPoint(x: 0.382, y: Double(fa.point.y)))
                points.append(CGPoint(x: 0.618, y: Double(fa.point.y)))
            }
            if let vp = sceneHints.refinedVanishingPoint {
                points.append(vp.point)
            }
        }

        // Strategy A: Vanishing Point Alignment (Leading Lines convergence)
        if let vp = raster.vanishingPoint, vp.confidence >= 0.55 {
            let dx = subject.anchor.x - vp.point.x
            let dy = subject.anchor.y - vp.point.y
            let len = hypot(dx, dy)
            if len > 0.08 {
                let linePoint1 = CGPoint(
                    x: min(0.85, max(0.15, vp.point.x + dx * 0.65)),
                    y: min(0.85, max(0.15, vp.point.y + dy * 0.65))
                )
                let linePoint2 = CGPoint(
                    x: min(0.85, max(0.15, vp.point.x + dx * 0.35)),
                    y: min(0.85, max(0.15, vp.point.y + dy * 0.35))
                )
                points.append(linePoint1)
                points.append(linePoint2)
            }
        }

        // Strategy B: Frame-in-Frame Aperture
        if let aperture = raster.frameInFrameAperture, aperture.strength >= 0.30 {
            let inner = aperture.innerRect
            let centerInAperture = CGPoint(x: inner.midX, y: inner.midY)
            points.append(centerInAperture)
            let thirdInAperture = CGPoint(
                x: inner.minX + inner.width * (subject.anchor.x < 0.5 ? 0.382 : 0.618),
                y: inner.minY + inner.height * 0.382
            )
            points.append(thirdInAperture)
        }

        // Strategy C: Negative Space & Look Space Vector
        let negSpace = raster.negativeSpaceVector(around: desired, gaze: subject.gaze)
        if negSpace.openness > 0.15 {
            let leadOffset = negSpace.optimalAnchorOffset
            let leadPoint = CGPoint(
                x: min(0.82, max(0.18, desired.x + leadOffset.x)),
                y: min(0.82, max(0.18, desired.y + leadOffset.y))
            )
            points.append(leadPoint)
        }

        // Strategy D: Dynamic visual mass equilibrium (counterbalance environmental saliency)
        if let com = raster.visualCenterOfMass {
            let dx = Double(com.x - 0.5)
            let dy = Double(com.y - 0.5)
            let balancePoint = CGPoint(
                x: min(0.78, max(0.22, desired.x - CGFloat(dx * 0.16))),
                y: min(0.78, max(0.22, desired.y - CGFloat(dy * 0.14)))
            )
            points.append(balancePoint)
        }

        // Dynamic gaze extension along line of sight
        let lead = Double(subject.gaze)
        if abs(lead) > 0.08 {
            let gazeExtend = CGPoint(
                x: min(0.78, max(0.22, desired.x - CGFloat(lead * 0.08))),
                y: desired.y
            )
            points.append(gazeExtend)
        }

        // Dynamic Golden Section / Rule of Thirds power intersections
        let goldenX = [0.382, 0.618]
        let goldenY = [0.382, 0.618]
        for gx in goldenX {
            for gy in goldenY {
                points.append(CGPoint(x: gx, y: gy))
            }
        }
        points.append(CGPoint(x: 0.382, y: 0.5))
        points.append(CGPoint(x: 0.618, y: 0.5))
        points.append(CGPoint(x: 0.5, y: 0.382))

        // Intent-specific compositional framing points
        switch intent {
        case .landscape, .architecture:
            if let h = raster.horizon {
                points.append(CGPoint(x: desired.x, y: h.y))
            }
        case .portrait, .environmentalPortrait:
            points.append(CGPoint(x: desired.x, y: min(0.65, max(0.28, subject.anchor.y - 0.08))))
        default:
            break
        }

        // Subtle continuous micro-variations + dense multi-scale composition anchor lattice
        let offsets = highMemory ? [-0.08, -0.04, 0.04, 0.08] : [-0.06, -0.03, 0.03, 0.06]
        for dx in offsets {
            for dy in offsets {
                let p = CGPoint(x: min(0.82, max(0.18, desired.x + CGFloat(dx))),
                                y: min(0.82, max(0.18, desired.y + CGFloat(dy))))
                points.append(p)
            }
        }

        let gridX: [Double] = highMemory
            ? [0.22, 0.28, 0.34, 0.382, 0.44, 0.50, 0.56, 0.618, 0.66, 0.72, 0.78]
            : [0.22, 0.30, 0.382, 0.46, 0.50, 0.56, 0.618, 0.70, 0.78]
        let gridY: [Double] = highMemory
            ? [0.24, 0.30, 0.382, 0.44, 0.50, 0.58, 0.66]
            : [0.24, 0.34, 0.382, 0.48, 0.58, 0.66]
        for gy in gridY {
            for gx in gridX {
                points.append(CGPoint(x: gx, y: gy))
            }
        }

        var deduplicated: [CGPoint] = []
        deduplicated.reserveCapacity(points.count)
        for p in points {
            if !deduplicated.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 0.014 }) {
                deduplicated.append(p)
            }
        }
        return deduplicated
    }

    private static func dynamicZooms(subject: CompositionSubject, intent: LocalCompositionIntent,
                                     desired: CGPoint,
                                     currentZoom: CGFloat, maxZoom: CGFloat, allowedZooms: [CGFloat],
                                     highMemory: Bool = false,
                                     sceneHints: CompositionSceneHints = .neutral) -> [CGFloat] {
        let area = Double(subject.bounds.width * subject.bounds.height)
        let desiredArea = desiredSubjectArea(intent: intent, kind: subject.kind)

        var options: Set<CGFloat> = [currentZoom]

        // Với phong cảnh (landscape) hoặc chủ thể chỉ là mảng vân bề mặt (scenery anchor), giữ góc rộng trừ khi V5 phát hiện rìa thừa cần cắt gọn
        let wideHasClutter = sceneHints.hasRichGuidance && (sceneHints.avoid.maxAvoid >= 0.25 || sceneHints.role == .foliageGarden || sceneHints.role == .apertureView)
        if (subject.kind != .scenery && intent != .landscape) || wideHasClutter {
            let idealZoom = CGFloat(CompositionPureCalculations.calculateContinuousIdealZoom(
                currentZoom: Double(currentZoom),
                currentArea: area,
                desiredArea: desiredArea,
                maxZoom: Double(maxZoom),
                targetPoint: desired,
                boxWidth: Double(subject.bounds.width),
                boxHeight: Double(subject.bounds.height),
                safetyMargin: CompositionTuning.edgeSafetyMargin
            ))
            options.insert(idealZoom)

            let mults: [CGFloat] = (subject.kind == .scenery || intent == .landscape)
                ? [1.06, 1.13, 1.21, 1.30, 1.40, 1.52]
                : [1.06, 1.13, 1.21, 1.30, 1.40, 1.52, 1.66, 1.82, 2.02, 2.28, 2.65, 3.10]
            for mult in mults {
                let candidate = currentZoom * mult
                if candidate >= currentZoom && candidate <= maxZoom {
                    options.insert(candidate)
                }
            }

            if idealZoom > currentZoom {
                for factor in [0.85, 0.92, 1.08, 1.15] as [CGFloat] {
                    options.insert(max(currentZoom, min(maxZoom, idealZoom * factor)))
                }
            }
        }

        if maxZoom > currentZoom {
            options.insert(min(maxZoom, currentZoom * 1.05))
            options.insert(min(maxZoom, currentZoom * 1.08))
            if maxZoom > currentZoom * 1.25 {
                options.insert(sqrt(currentZoom * maxZoom))
            }
        }

        for h in allowedZooms where h.isFinite && h >= currentZoom && h <= maxZoom {
            options.insert(h)
        }

        // Dense logarithmic zoom sweep from currentZoom to maxZoom
        let logSteps = highMemory ? 14 : 10
        if maxZoom > currentZoom * 1.01 {
            let logSpan = log(Double(maxZoom / currentZoom))
            for k in 1...logSteps {
                let fraction = Double(k) / Double(logSteps)
                let z = currentZoom * CGFloat(exp(logSpan * fraction))
                if z >= currentZoom && z <= maxZoom { options.insert(z) }
            }
        }

        return Array(options).sorted()
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
            if !others.isEmpty {
                return preferred.contains(.group) ? [.group, .portrait] : [.portrait, .environmentalPortrait, .group]
            }
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
        let roiSyncFocus: Double
        let depthSeparation: Double
        let wasteRatio: Double
        let excessTrimGain: Double
        let activeFill: Double
        let balanceCentroid: CGPoint
    }

    private static func measure(raster: CompositionRaster, cells: [SampleCell],
                                subject: CompositionSubject, subjectDepth: Double, box: CGRect,
                                calibration: TrackingCalibration,
                                future: TrackingCalibration, rotation: simd_quatd,
                                protectedPeople: [CompositionSubject],
                                activeThreshold: Double = 0.14) -> Metrics {
        var total = 0.0, retained = 0.0
        var inInfoSum = 0.0, outInfoSum = 0.0
        var inCount = 0, outCount = 0, inActiveCount = 0
        for cell in cells {
            let weight = cell.attention
            total += weight
            let info = 0.45 * cell.sync + 0.30 * cell.attention + 0.25 * min(1.0, cell.edge * 2.2)
            let mapped = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: cell.point)))
            if mapped.isInFront && inside(mapped.point, margin: 0) {
                retained += weight
                inInfoSum += info
                inCount += 1
                if info >= activeThreshold { inActiveCount += 1 }
            } else {
                outInfoSum += info
                outCount += 1
            }
        }
        var weightSum = 0.0, weightedX = 0.0, weightedY = 0.0
        var border = 0.0, borderCount = 0.0, subjectLight = 0.0, subjectCount = 0.0
        var surroundLight = 0.0, surroundCount = 0.0, symmetryError = 0.0
        var innerSyncSum = 0.0, innerSyncCount = 0.0, outerSyncSum = 0.0, outerSyncCount = 0.0
        var roiBorderDepthSum = 0.0, roiBorderDepthCount = 0.0
        let side = 12
        for y in 0..<side {
            for x in 0..<side {
                let p = CGPoint(x: (Double(x) + 0.5) / Double(side), y: (Double(y) + 0.5) / Double(side))
                let original = calibration.project(deviceRay: rotation.act(future.deviceRay(at: p))).point
                let attention = raster.value(raster.attention, at: original)
                let syncVal = raster.value(raster.synchronizedSaliency, at: original)
                let depthVal = raster.value(raster.foregroundDepth, at: original)
                let edge = raster.value(raster.edges, at: original)
                let luma = raster.value(raster.luminance, at: original)
                let weight = 0.1 + attention
                weightSum += weight; weightedX += Double(p.x) * weight; weightedY += Double(p.y) * weight
                if box.contains(p) { subjectLight += luma; subjectCount += 1 }
                else if box.insetBy(dx: -0.12, dy: -0.12).contains(p) {
                    surroundLight += luma; surroundCount += 1
                }
                if (0.16...0.84).contains(p.x) && (0.16...0.84).contains(p.y) {
                    innerSyncSum += syncVal
                    innerSyncCount += 1
                } else {
                    outerSyncSum += syncVal
                    outerSyncCount += 1
                }
                if x == 0 || y == 0 || x == side - 1 || y == side - 1 {
                    if !subject.bounds.contains(original) && !protectedPeople.contains(where: { $0.bounds.contains(original) }) {
                        border += 0.5 * attention + 0.3 * edge + 0.2 * syncVal
                        roiBorderDepthSum += depthVal
                        roiBorderDepthCount += 1
                    }
                    borderCount += 1
                }
                let mirror = CGPoint(x: 1 - p.x, y: p.y)
                let mirroredSource = calibration.project(deviceRay: rotation.act(future.deviceRay(at: mirror))).point
                symmetryError += abs(luma - raster.value(raster.luminance, at: mirroredSource))
            }
        }
        let mx = weightedX / max(weightSum, 0.001)
        let my = weightedY / max(weightSum, 0.001)
        let centerDistance = hypot(mx - 0.5, my - 0.5)
        let room = subject.gaze >= 0 ? Double(1 - box.maxX) : Double(box.minX)
        let opposite = subject.gaze >= 0 ? Double(box.minX) : Double(1 - box.maxX)
        let separation = subjectCount > 0 && surroundCount > 0 ?
            abs(subjectLight / subjectCount - surroundLight / surroundCount) : 0
        let innerMean = innerSyncCount > 0 ? innerSyncSum / innerSyncCount : 0
        let outerMean = outerSyncCount > 0 ? outerSyncSum / outerSyncCount : 0
        let roiSyncFocus = min(1.0, max(0.0, 0.5 + (innerMean - outerMean) * 1.6))
        let borderDepth = roiBorderDepthCount > 0 ? roiBorderDepthSum / roiBorderDepthCount : subjectDepth
        let depthSep = min(1.0, max(0.0, 0.5 + (subjectDepth - borderDepth) * 1.4))
        let retention = total > 0.001 ? min(1.0, retained / total) : 1.0
        let activeFill = inCount > 0 ? Double(inActiveCount) / Double(inCount) : 0.5
        var wasteRatio = 0.0
        var excessTrimGain = 0.0
        if outCount > 0 && inCount > 0 && !raster.isDiffuseAttention {
            let inMeanInfo = inInfoSum / Double(inCount)
            let outMeanInfo = outInfoSum / Double(outCount)
            wasteRatio = max(0.0, 1.0 - outMeanInfo / max(0.06, inMeanInfo))
            let trimmedFrac = Double(outCount) / Double(max(1, cells.count))
            let retGate = min(1.0, max(0.0, (retention - 0.54) / 0.30))
            let trimShare = min(1.0, trimmedFrac / 0.52)
            let sharpWaste = max(0.0, (wasteRatio - 0.15) / 0.85)
            excessTrimGain = 0.26 * sharpWaste * trimShare * retGate
        }
        return Metrics(retention: retention,
            cleanEdges: 1 - min(1, border / max(1, borderCount)),
            balance: 1 - min(1, centerDistance * 2),
            lookRoom: min(1, max(0, 0.5 + (room - opposite) * 1.5)),
            separation: min(1, separation * 3),
            symmetry: 1 - min(1, symmetryError / Double(side * side) * 3),
            roiSyncFocus: roiSyncFocus,
            depthSeparation: depthSep,
            wasteRatio: wasteRatio,
            excessTrimGain: excessTrimGain,
            activeFill: activeFill,
            balanceCentroid: CGPoint(x: mx, y: my))
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
        rect.width > 0.005 && rect.height > 0.005 &&
        rect.minX >= -0.005 && rect.minY >= -0.005 &&
        rect.maxX <= 1.005 && rect.maxY <= 1.005
    }

    private static func inside(_ point: CGPoint, margin: CGFloat) -> Bool {
        point.x.isFinite && point.y.isFinite && point.x >= margin && point.y >= margin &&
        point.x <= 1 - margin && point.y <= 1 - margin
    }

    /// Builds a clean, zero-OOB dense multi-scale window pool (up to 256 windows) anchored in real
    /// 3D `TrackingCalibration` + `simd_quatd` rays so `GAICCompositionScorer` can evaluate rich
    /// scene-wide and tight compositions even when heuristics propose few windows (e.g. scenery/street).
    static func denseCompositionalWindows(
        existing: [CompositionProposal],
        calibration: TrackingCalibration,
        currentZoom: CGFloat,
        allowedZooms: [CGFloat],
        subjectAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
        subjectBounds: CGRect? = nil,
        protectedBounds: [CGRect] = [],
        incidentalBounds: [CGRect] = [],
        intent: LocalCompositionIntent = .object,
        confidence: Double = 0.72,
        raster: CompositionRaster? = nil,
        maxCount: Int = 256,
        subject explicitSubject: CompositionSubject? = nil,
        poseProfile: AnatomicalPoseProfile? = nil,
        sceneryFallback: Bool = false,
        sceneHints: CompositionSceneHints = .neutral
    ) -> [CompositionProposal] {
        guard maxCount > 0, calibration.isValid, currentZoom.isFinite, currentZoom > 0 else {
            return Array(existing.prefix(max(0, maxCount)))
        }
        let hardMax = allowedZooms.filter { $0.isFinite && $0 >= currentZoom }.max() ?? currentZoom
        let baseline = existing.first(where: \.isUnchangedView)
        let baseAnchor = (subjectAnchor.x.isFinite && subjectAnchor.y.isFinite &&
            (0.02...0.98).contains(subjectAnchor.x) && (0.02...0.98).contains(subjectAnchor.y))
            ? subjectAnchor : (baseline?.subjectPoint ?? CGPoint(x: 0.5, y: 0.5))
        let heroBounds = subjectBounds.flatMap { valid($0) ? $0 : nil } ??
            baseline?.expectedSubjectRect ??
            CGRect(x: max(0.0, baseAnchor.x - 0.10), y: max(0.0, baseAnchor.y - 0.12), width: 0.20, height: 0.24)
        let safeProtected = protectedBounds.filter { valid($0) }
        let safeIncidentals = incidentalBounds.filter { valid($0) }
        let refIntent = baseline?.intent ?? intent
        let refConfidence = baseline?.evidenceConfidence ?? min(1, max(0, confidence))
        let refSubjectIndex = baseline?.subjectIndex ?? 0
        let inferredKind: CompositionSubjectKind = {
            switch refIntent {
            case .portrait, .environmentalPortrait: return .person
            case .group: return .group
            case .animal: return .animal
            case .landscape: return .scenery
            default: return .object
            }
        }()
        let evalSubject = explicitSubject ?? CompositionSubject(
            index: refSubjectIndex,
            bounds: heroBounds,
            anchor: baseAnchor,
            kind: inferredKind,
            confidence: refConfidence,
            importance: 1.0,
            gaze: 0.0
        )
        let isScenery = evalSubject.kind == .scenery || sceneryFallback
        let zoomCapMultiplier: CGFloat = (sceneryFallback && !sceneHints.hasRichGuidance)
            ? 1.32
            : (sceneHints.hasRichGuidance && sceneHints.role.isWideRole ? 1.55 : (isScenery ? 1.50 : 2.80))
        let maxZoom = max(currentZoom, min(hardMax, max(currentZoom, currentZoom * zoomCapMultiplier)))
        let validRaster = raster.flatMap { $0.isValid ? $0 : nil }
        let sampleCells = validRaster.map { makeSampleCells(from: $0) } ?? []
        let baselineProfile = validRaster.map { rasterBaselineProfile(from: $0) }
        let baselineV5Cleanliness = (sceneHints.hasRichGuidance && validRaster != nil)
            ? baselineV5Cleanliness(raster: validRaster!, sceneHints: sceneHints) : 0.0
        let actPt = baselineProfile?.centroid ?? baseAnchor
        let horizonHint = validRaster?.horizon
        let subjectDepth = validRaster?.depthStats(in: heroBounds).meanDepth ?? 0.5
        let desired = validRaster.map { preferredPlacement(subject: evalSubject, intent: refIntent, raster: $0) }
            ?? fallbackPlacement(anchor: baseAnchor, kind: evalSubject.kind, intent: refIntent)
        let cropAttention = evalSubject.allowsAttentionCrop && evalSubject.kind == .object && (validRaster?.hasAttention ?? false)
        let protectedPeople: [CompositionSubject] =
            (evalSubject.kind == .person || evalSubject.kind == .face || evalSubject.kind == .group) ? [evalSubject] : []

        var pool: [CompositionProposal] = []
        pool.reserveCapacity(maxCount)
        var seenSignatures = Set<Int>()
        seenSignatures.reserveCapacity(maxCount * 2)

        func signature(for corners: [CGPoint], unchanged: Bool) -> Int {
            if unchanged { return -1 }
            let xs = corners.map { Double($0.x) }
            let ys = corners.map { Double($0.y) }
            let x1 = Int(((xs.min() ?? 0.0) * 36.0).rounded())
            let y1 = Int(((ys.min() ?? 0.0) * 36.0).rounded())
            let x2 = Int(((xs.max() ?? 1.0) * 36.0).rounded())
            let y2 = Int(((ys.max() ?? 1.0) * 36.0).rounded())
            return (((x1 * 64 + y1) * 64 + x2) * 64 + y2)
        }

        func appendIfNovel(_ proposal: CompositionProposal) -> Bool {
            guard pool.count < maxCount, proposal.sourceCorners.count == 4,
                  proposal.sourceCorners.allSatisfy({ (-0.00001...1.00001).contains($0.x) && (-0.00001...1.00001).contains($0.y) }) else {
                return false
            }
            let sig = signature(for: proposal.sourceCorners, unchanged: proposal.isUnchangedView)
            guard !seenSignatures.contains(sig) else { return false }
            seenSignatures.insert(sig)
            pool.append(proposal)
            return true
        }

        if let baseline { _ = appendIfNovel(baseline) }
        for candidate in existing.sorted(by: { $0.score > $1.score }) {
            if pool.count >= min(maxCount, 72) { break }
            _ = appendIfNovel(candidate)
        }

        let multipliers: [CGFloat] = [1.06, 1.13, 1.21, 1.30, 1.40, 1.52, 1.66, 1.82, 2.02, 2.28]
        let zoomLevels: [CGFloat] = multipliers
            .map { currentZoom * $0 }
            .filter { $0 > currentZoom * 1.01 && $0 <= maxZoom + 0.001 }

        var generated: [CompositionProposal] = []
        generated.reserveCapacity(maxCount)

        let origAnchorMargin = min(Double(baseAnchor.x), Double(1.0 - baseAnchor.x),
                                   Double(baseAnchor.y), Double(1.0 - baseAnchor.y))
        let destMargin = CGFloat(min(0.08, max(0.025, origAnchorMargin * 0.70)))
        let isNonPersonSubject = evalSubject.kind != .person && evalSubject.kind != .face && evalSubject.kind != .group
        let isNonPersonOrAnimal = isNonPersonSubject && evalSubject.kind != .animal
        let rawHeroArea = Double(heroBounds.width * heroBounds.height)

        for zoom in zoomLevels {
            let ratio = Double(zoom / currentZoom)
            let halfSpan = 0.5 / ratio
            let minC = min(0.5, max(0.02, halfSpan * 1.022 + 0.005))
            let maxC = max(0.5, min(0.98, 1.0 - halfSpan * 1.022 - 0.005))
            let xSteps: [Double] = maxC - minC < 0.03 ? [0.5] : (0..<5).map { i in
                minC + (maxC - minC) * Double(i) / 4.0
            }
            let ySteps: [Double] = maxC - minC < 0.03 ? [0.5] : (0..<5).map { j in
                minC + (maxC - minC) * Double(j) / 4.0
            }

            var centers: [CGPoint] = []
            for cy in ySteps {
                for cx in xSteps {
                    centers.append(CGPoint(x: cx, y: cy))
                }
            }
            // Include windows placing the hero anchor onto Rule-of-Thirds / edge-clamped intersections
            for gx in [0.26, 0.36, 0.382, 0.50, 0.618, 0.64, 0.74] {
                for gy in [0.28, 0.36, 0.45, 0.50, 0.62, 0.72] {
                    let cx = min(maxC, max(minC, Double(baseAnchor.x) - (gx - 0.5) / ratio))
                    let cy = min(maxC, max(minC, Double(baseAnchor.y) - (gy - 0.5) / ratio))
                    centers.append(CGPoint(x: cx, y: cy))
                }
            }
            for seedPt in [actPt, CGPoint(x: 0.5 * (actPt.x + baseAnchor.x), y: 0.5 * (actPt.y + baseAnchor.y))] {
                centers.append(CGPoint(x: min(maxC, max(minC, Double(seedPt.x))),
                                       y: min(maxC, max(minC, Double(seedPt.y)))))
            }
            if sceneHints.hasRichGuidance {
                let avoid = sceneHints.avoid
                let shiftX = (avoid.left > 0.22 ? avoid.left : 0.0) - (avoid.right > 0.22 ? avoid.right : 0.0)
                let shiftY = (avoid.top > 0.22 ? avoid.top : 0.0) - (avoid.bottom > 0.22 ? avoid.bottom : 0.0)
                if abs(shiftX) > 0.05 || abs(shiftY) > 0.05 {
                    for strength in [0.06, 0.12, 0.18] {
                        centers.append(CGPoint(
                            x: min(maxC, max(minC, 0.50 + shiftX * strength)),
                            y: min(maxC, max(minC, 0.50 + shiftY * strength))
                        ))
                    }
                }
                if let fa = sceneHints.focalAccent {
                    centers.append(CGPoint(x: min(maxC, max(minC, Double(fa.point.x))),
                                           y: min(maxC, max(minC, Double(fa.point.y)))))
                }
                if let vp = sceneHints.refinedVanishingPoint {
                    centers.append(CGPoint(x: min(maxC, max(minC, Double(vp.point.x))),
                                           y: min(maxC, max(minC, Double(vp.point.y)))))
                }
            }

            let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                                             cx: calibration.cx, cy: calibration.cy,
                                             aspect: calibration.aspect, isMeasured: false)
            for center in centers {
                let rotation = simd_quatd(from: SIMD3(0, 0, -1), to: calibration.deviceRay(at: center))
                let cornerProjs = corners.map { calibration.project(deviceRay: rotation.act(future.deviceRay(at: $0))) }
                guard cornerProjs.allSatisfy({ $0.isInFront && inside($0.point, margin: -0.000005) }) else { continue }
                let aim = calibration.project(deviceRay: rotation.act(SIMD3(0, 0, -1)))
                guard aim.isInFront, inside(aim.point, margin: 0.032) else { continue }
                if sceneryFallback && !sceneHints.hasRichGuidance && hypot(Double(aim.point.x) - 0.5, Double(aim.point.y) - 0.5) > 0.18 { continue }
                let destProj = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: baseAnchor)))
                guard destProj.isInFront else { continue }
                if !isScenery && !evalSubject.allowsAttentionCrop && !sceneHints.hasRichGuidance && !inside(destProj.point, margin: destMargin) { continue }

                var minProtVis = 1.0
                let protectedOK = safeProtected.allSatisfy { rect in
                    guard let proj = project(rect, from: calibration, to: future, rotation: rotation) else { return false }
                    let vis = visibleFraction(proj)
                    if vis < minProtVis { minProtVis = vis }
                    if sceneHints.hasRichGuidance && isNonPersonOrAnimal {
                        if sceneHints.role == .tabletopEnsemble || sceneHints.role == .deskWorkspace {
                            return safe(proj, original: rect, allowCrop: true) && vis >= 0.88
                        }
                        if sceneHints.role.isWideRole {
                            let minReq = (rawHeroArea > 0.45 && sceneHints.avoid.maxAvoid >= 0.35) ? 0.66 : 0.74
                            return safe(proj, original: rect, allowCrop: true) && vis >= minReq
                        }
                    }
                    let touchesEdge = rect.minX <= 0.035 || rect.maxX >= 0.965 || rect.minY <= 0.035 || rect.maxY >= 0.965
                    let edgeRelaxed = touchesEdge && isNonPersonSubject && rect.width < 0.78 && rect.height < 0.78
                    let visThreshold = edgeRelaxed ? 0.981 : 0.985
                    return safe(proj, original: rect, allowCrop: edgeRelaxed) && vis >= visThreshold
                }
                guard protectedOK else { continue }
                let incidentalsOK = safeIncidentals.allSatisfy { rect in
                    guard let proj = project(rect, from: calibration, to: future, rotation: rotation) else { return true }
                    let frac = visibleFraction(proj)
                    return frac <= 0.02 || frac >= 0.98
                }
                guard incidentalsOK else { continue }

                let projSubject = project(heroBounds, from: calibration, to: future, rotation: rotation)
                    ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
                let rawCornerPoints = cornerProjs.map(\.point)
                guard let evalResult = evaluateWindowScore(
                    subject: evalSubject,
                    intent: refIntent,
                    desired: desired,
                    destination: destProj.point,
                    aimPoint: aim.point,
                    box: projSubject,
                    zoom: zoom,
                    currentZoom: currentZoom,
                    rawCornerPoints: rawCornerPoints,
                    rotation: rotation,
                    calibration: calibration,
                    future: future,
                    raster: validRaster,
                    sampleCells: sampleCells,
                    protectedPeople: protectedPeople,
                    subjectDepth: subjectDepth,
                    horizonHint: horizonHint,
                    poseProfile: poseProfile,
                    intentPrior: 0.0,
                    cropAttention: cropAttention,
                    unchanged: false,
                    baselineProfile: baselineProfile,
                    sceneHints: sceneHints,
                    baselineCleanliness: baselineV5Cleanliness,
                    protectedMinVisibility: minProtVis
                ) else { continue }

                let combinedScore = evalResult.fieldScore + 0.06 * (evalResult.gaicScore - 0.5)
                let candidate = CompositionProposal(
                    subjectIndex: refSubjectIndex,
                    intent: refIntent,
                    subjectPoint: baseAnchor,
                    aimPoint: aim.point,
                    expectedSubjectRect: projSubject,
                    sourceCorners: rawCornerPoints,
                    rotation: rotation,
                    zoom: zoom,
                    evidenceConfidence: refConfidence,
                    score: combinedScore,
                    explanation: evalResult.explanation,
                    usesCenter: abs(destProj.point.x - 0.5) < 0.055,
                    retainedAttention: evalResult.retainedAttention,
                    recommendedEVBias: evalResult.recommendedEVBias,
                    outOfBoundsFraction: evalResult.oobFraction,
                    continuousFieldScore: evalResult.fieldScore,
                    gaicScore: evalResult.gaicScore,
                    sizeRatio: evalResult.sizeRatio,
                    excessTrimGain: evalResult.excessTrimGain,
                    frameWasteRatio: evalResult.wasteRatio,
                    sceneWasteRatio: baselineProfile?.waste ?? 0.0,
                    isAttentionSubject: evalSubject.isAttentionOnly,
                    sceneCleanGain: evalResult.sceneCleanGain
                )
                generated.append(candidate)
            }
        }
        for candidate in generated.sorted(by: { $0.continuousFieldScore > $1.continuousFieldScore }) {
            if pool.count >= maxCount { break }
            _ = appendIfNovel(candidate)
        }
        return pool
    }

    private static func safe(_ rect: CGRect, original: CGRect, allowCrop: Bool = false) -> Bool {
        let minAllowedX = allowCrop ? -0.15 : (min(0.025, original.minX) - 0.00001)
        let maxAllowedX = allowCrop ? 1.15 : (max(0.975, original.maxX) + 0.00001)
        let maxAllowedY = allowCrop ? 3.0 : (max(0.975, original.maxY) + 0.00001)
        return rect.minX >= minAllowedX &&
            rect.minY >= min(0.025, original.minY) - 0.00001 &&
            rect.maxX <= maxAllowedX &&
            rect.maxY <= maxAllowedY
    }
}
