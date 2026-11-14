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
            return CGRect(x: min(body.maxX - width, max(body.minX, anchor.x - width / 2)),
                          y: min(body.maxY - height, max(body.minY, anchor.y - height / 2)),
                          width: width, height: height)
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
        let tierMultiplier: Double
        switch kind {
        case .person, .group:
            let syncLow = evidence?.syncAttention.map { $0 < 0.16 && (evidence?.foregroundDepth ?? 0.5) < 0.42 } ?? false
            let distantBystander = !hasFace && (area < 0.045 || (evidence?.foregroundDepth ?? 0.5) < 0.28 || syncLow) && bounds.maxY < 0.60
            tierMultiplier = hasFace ? 1.30 : (distantBystander ? 0.52 : 1.12)
        case .face: tierMultiplier = 1.20
        case .animal:
            let backgroundPet = area < 0.025 && (evidence?.foregroundDepth ?? 0.5) < 0.30 && bounds.maxY < 0.56
            tierMultiplier = backgroundPet ? 0.68 : 1.10
        case .object:
            let bloatedRegion = area > 0.46
            let crispForegroundObject = (0.02...0.38).contains(area) && hypot(Double(bounds.midX - 0.5), Double(bounds.midY - 0.52)) < 0.34
            tierMultiplier = bloatedRegion ? 0.52 : (crispForegroundObject ? 1.04 : 0.88)
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

        let highThresh = min(globalPeak * 0.72, max(minPeak, meanSync + 0.45 * stdSync))
        let lowThresh = max(0.08, highThresh * 0.46)
        let minPixels = max(3, count / 160)

        var visited = [Bool](repeating: false, count: count)
        var components: [[Int]] = []
        let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for startIdx in 0..<count {
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
                    if abs(foregroundDepth[nIdx] - seedDepth) <= 0.30 || synchronizedSaliency[nIdx] >= highThresh {
                        visited[nIdx] = true
                        queue.append(nIdx)
                    }
                }
            }
            if comp.count >= minPixels {
                components.append(comp)
            }
        }

        var clusters: [SynchronizedSaliencyCluster] = []
        for comp in components {
            var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
            var peakVal = 0.0, peakX = 0.5, peakY = 0.5
            var sumSync = 0.0, sumDepth = 0.0
            for idx in comp {
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
                }
            }
            let compMeanDepth = sumDepth / Double(comp.count)
            let compMeanSync = sumSync / Double(comp.count)
            let rect = CGRect(x: max(0.01, minX), y: max(0.01, minY),
                              width: min(0.98, maxX - minX), height: min(0.98, maxY - minY))
            let area = Double(rect.width * rect.height)
            guard area >= 0.015 && area <= 0.80 else { continue }
            let isSideStrip = (rect.minX <= 0.03 || rect.maxX >= 0.97) && (rect.height >= 0.60 || rect.width >= 0.60)
            let isBottomStrip = rect.maxY >= 0.96 && rect.height <= 0.30 && rect.width >= 0.55
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
            clusters.append(SynchronizedSaliencyCluster(
                bounds: rect, anchor: anchor, peakValue: peakVal,
                meanSync: compMeanSync, meanDepth: compMeanDepth,
                dominance: dominance, area: area
            ))
        }
        return clusters.sorted {
            let lhs = $0.dominance * (0.65 + 0.35 * $0.meanDepth) * (0.5 + 0.5 * $0.peakValue)
            let rhs = $1.dominance * (0.65 + 0.35 * $1.meanDepth) * (0.5 + 0.5 * $1.peakValue)
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
                shotScaleBias: subject.shotScaleBias, contextPreservationWeight: subject.contextPreservationWeight)
            return proposals(subjects: [framed], intents: [intent], raster: raster, calibration: calibration,
                currentZoom: currentZoom, allowedZooms: allowedZooms, protectedBounds: protectedBounds,
                incidentalBounds: incidentalBounds, proposalLimit: perIntent,
                refining: refining.filter { $0.intent == intent }, poseProfile: poseProfile, isCancelled: isCancelled)
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
    }

    static func proposals(subjects: [CompositionSubject], intents: [LocalCompositionIntent],
                          raster: CompositionRaster, calibration: TrackingCalibration,
                          currentZoom: CGFloat, allowedZooms: [CGFloat], protectedBounds: [CGRect] = [],
                          incidentalBounds: [CGRect] = [],
                          proposalLimit: Int = 6, refining: [CompositionProposal] = [],
                          poseProfile: AnatomicalPoseProfile? = nil,
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

        // Precompute compact downsampled raster cells (~256 samples) so 256-1024 geometric evaluations run in a few ms.
        let cellSide = min(raster.side, 16)
        var sampleCells: [SampleCell] = []
        sampleCells.reserveCapacity(cellSide * cellSide)
        for cy in 0..<cellSide {
            let py = (Double(cy) + 0.5) / Double(cellSide)
            let sy = min(raster.side - 1, max(0, Int(py * Double(raster.side))))
            for cx in 0..<cellSide {
                let px = (Double(cx) + 0.5) / Double(cellSide)
                let sx = min(raster.side - 1, max(0, Int(px * Double(raster.side))))
                let i = sy * raster.side + sx
                sampleCells.append(SampleCell(
                    point: CGPoint(x: px, y: py),
                    attention: raster.attention[i],
                    sync: raster.synchronizedSaliency[i],
                    depth: raster.foregroundDepth[i]
                ))
            }
        }

        var result: [CompositionProposal] = []
        for subject in validSubjects.prefix(4) {
            let cropAttention = subject.allowsAttentionCrop && subject.kind == .object && raster.hasAttention
            let protectedAnchor = CompositionCropProtection.bounds(body: subject.bounds, portrait: nil,
                intent: .object, anchor: subject.anchor, attentionRegion: cropAttention)
            let subjectDepthStats = raster.depthStats(in: subject.bounds)
            for intent in applicableIntents(subject: subject, preferred: intents, people: protectedPeople) {
                if isCancelled() { return [] }
                let protectedRects: [CGRect] = intent == .group
                    ? (protectedPeople.map(\.bounds) + protectedBounds.filter { valid($0) })
                    : ([protectedAnchor] + protectedBounds.filter { valid($0) })
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
                    // Cho phép xoay camera 3D ở 1.0x vượt biên khung ảnh gốc tới 0.36 để đưa chủ thể vào điểm mạnh bố cục
                    guard sourceCorners.allSatisfy({ $0.isInFront && inside($0.point, margin: -0.36) }),
                          let box = project(subject.bounds, from: calibration, to: future, rotation: rotation),
                          let anchorBox = project(protectedAnchor, from: calibration, to: future, rotation: rotation),
                          safe(anchorBox, original: protectedAnchor, isHero: true),
                          (!cropAttention || visibleFraction(box) >= 0.40),
                          protectedRects.allSatisfy({ original in
                              guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return false }
                              return safe(rect, original: original, isHero: original == protectedAnchor)
                          }), incidentalRects.allSatisfy({ original in
                              guard let rect = project(original, from: calibration, to: future, rotation: rotation) else { return true }
                              let fraction = visibleFraction(rect)
                              return fraction <= 0.02 || fraction >= 0.98
                          }) else { return nil }
                    let aim = calibration.project(deviceRay: rotation.act(SIMD3(0, 0, -1)))
                    guard aim.isInFront, inside(aim.point, margin: -0.28) else { return nil }
                    let metrics = measure(raster: raster, cells: sampleCells, subject: subject,
                        subjectDepth: subjectDepthStats.meanDepth, box: box,
                        calibration: calibration, future: future, rotation: rotation, protectedPeople: protectedPeople)
                    guard !cropAttention || unchanged || metrics.retention >= 0.82 else { return nil }
                    let desiredArea: Double
                    switch intent {
                    case .portrait: desiredArea = subject.kind == .face ? CompositionTuning.desiredAreaFace : CompositionTuning.desiredAreaPortrait
                    case .environmentalPortrait, .street: desiredArea = CompositionTuning.desiredAreaStreet
                    case .group: desiredArea = CompositionTuning.desiredAreaGroup
                    case .landscape: desiredArea = CompositionTuning.desiredAreaLandscape
                    case .architecture: desiredArea = CompositionTuning.desiredAreaArchitecture
                    case .closeUp, .food: desiredArea = CompositionTuning.desiredAreaFood
                    case .animal, .object: desiredArea = CompositionTuning.desiredAreaAnimal
                    }
                    let effectiveDesiredArea = desiredArea * exp(0.24 * min(1.0, max(-1.0, subject.shotScaleBias)))
                    let area = Double(box.width * box.height)
                    let sizeFit = subject.kind == .scenery ? 1 : exp(-pow(log(max(0.001, area) / effectiveDesiredArea), 2) / 1.5)
                    let placement = exp(-8.0 * pow(Double(destination.x - desired.x), 2) -
                                        7.0 * pow(Double(destination.y - desired.y), 2))
                    let context = intent.preservesContext && raster.hasAttention ? metrics.retention : 1
                    let contextFit = intent.preservesContext ? min(1, 1 / (ratio * ratio * 0.72)) : 1
                    let space = abs(subject.gaze) > 0.12 ? metrics.lookRoom : metrics.balance
                    let symmetry = intent == .architecture ? metrics.symmetry : metrics.balance
                    let person = subject.kind == .person || subject.kind == .face || subject.kind == .group
                    let headroom = (person && box.height >= 0.45) ? exp(-pow((Double(box.minY) - CompositionTuning.headroomTargetY) / CompositionTuning.headroomSigma, 2)) : 1.0
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
                    let rawCornerPoints = sourceCorners.map(\.point)
                    let oobSum = rawCornerPoints.reduce(0.0) { acc, pt in
                        let dx = max(0.0, Double(-pt.x), Double(pt.x - 1.0))
                        let dy = max(0.0, Double(-pt.y), Double(pt.y - 1.0))
                        return acc + hypot(dx, dy)
                    }
                    let oobFraction = min(1.0, oobSum / 0.85)
                    let observedCornerPoints = observedSourceQuad(
                        rawCornerPoints,
                        unchanged: unchanged,
                        oobSum: oobSum,
                        oobFraction: oobFraction
                    )
                    let intentPrior = intent == intents.first ? 0.045 : (intents.contains(intent) ? 0.02 : 0)
                    let thirdX = min(abs(Double(destination.x) - Double(CompositionTuning.goldenSectionLeft)),
                                     abs(Double(destination.x) - Double(CompositionTuning.goldenSectionRight)))
                    let thirdY = min(abs(Double(destination.y) - CompositionTuning.portraitEyeLineY),
                                     abs(Double(destination.y) - Double(CompositionTuning.goldenSectionRight)))
                    let ruleOfThirdsBonus = CompositionTuning.ruleOfThirdsBonusWeight * exp(-16 * (thirdX * thirdX + thirdY * thirdY))
                    let deadCenterDestPenalty = (intent != .architecture && intent != .group && !unchanged &&
                        hypot(Double(destination.x - 0.5), Double(destination.y - 0.5)) < 0.04) ? 0.20 : 0.0
                    let zoomProminenceBonus = (subject.kind != .scenery && intent != .landscape && area < effectiveDesiredArea && ratio > 1.08) ? 0.08 * min(1.0, log(ratio) / log(2.5)) : 0.0
                    let ratioAdjustment = (subject.kind != .scenery && intent != .landscape && area < effectiveDesiredArea) ? -0.055 * min(1.0, max(0.0, log(ratio))) : 0.02 * abs(log(ratio))
                    let contextWeight = intent.preservesContext ? 0.11 : 0.05
                    let contextFitWeight = intent.preservesContext ? 0.09 : 0.04
                    let evBias = computeOptimalEVBias(raster: raster, heroRect: box, aimPoint: aim.point, zoom: zoom, scene: intent)
                    let torqueBalance = raster.visualTorqueBalance(heroRect: box, cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
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
                    let fieldScore = 0.29 * sizeFit + 0.35 * placement + 0.10 * headroom +
                        0.09 * space + 0.06 * edgeSafety + contextWeight * context +
                        contextFitWeight * contextFit + 0.03 * metrics.cleanEdges + 0.02 * symmetry +
                        0.02 * horizonFit + 0.07 * torqueBalance - anatomicalPenaltyValue +
                        intentPrior + ruleOfThirdsBonus + zoomProminenceBonus - deadCenterDestPenalty - ratioAdjustment
                    let fieldNorm = min(1.0, max(0.0, fieldScore))
                    // Grid-Anchor RoI Pre-Screen score (RoI inner S_sync focus + depth separation + clean edges + continuous field + anatomy)
                    let gaicScore = min(1.0, max(0.0,
                        0.44 * fieldNorm +
                        0.22 * metrics.roiSyncFocus +
                        0.14 * metrics.depthSeparation +
                        0.12 * metrics.cleanEdges +
                        0.08 * torqueBalance - anatomicalPenaltyValue * 0.5
                    ))
                    let combinedScore = fieldScore + 0.06 * (gaicScore - 0.5)
                    return CompositionProposal(subjectIndex: subject.index, intent: intent,
                        subjectPoint: subject.anchor, aimPoint: aim.point, expectedSubjectRect: box,
                        sourceCorners: observedCornerPoints, rotation: rotation, zoom: zoom,
                        evidenceConfidence: min(1, max(0, subject.confidence)), score: combinedScore,
                        explanation: explanation(intent: intent, gaze: subject.gaze,
                            cleanEdges: metrics.cleanEdges, context: raster.hasAttention ? context : 0),
                        usesCenter: abs(destination.x - 0.5) < 0.055, retainedAttention: metrics.retention,
                        recommendedEVBias: evBias, outOfBoundsFraction: oobFraction,
                        continuousFieldScore: fieldScore, gaicScore: gaicScore,
                        sizeRatio: subject.kind == .scenery ? 1 : area / max(0.001, effectiveDesiredArea))
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
                                                   raster: raster, highMemory: isHighMemory)
                let subjectZooms = dynamicZooms(subject: subject, intent: intent, desired: desired,
                                                currentZoom: currentZoom, maxZoom: maxZoom,
                                                allowedZooms: allowedZooms, highMemory: isHighMemory)
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
                if proposalLimit > 6 {
                    result.append(contentsOf: seeds)
                } else {
                    result.append(contentsOf: diverse(seeds, limit: 6, raySeparation: 0.03, zoomSeparation: 0.06))
                }
            }
        }
        guard !isCancelled() else { return [] }
        if !refining.isEmpty {
            return diverse(result, limit: proposalLimit, raySeparation: 0.008, zoomSeparation: 0.018)
        }
        guard proposalLimit > 6 else { return diverse(result, limit: proposalLimit, raySeparation: 0.04, zoomSeparation: 0.08) }
        // Preserve a no-change baseline, prioritize top GAIC+Field winners, and stratify multi-scale focal exploration.
        var selected = result.filter(\.isUnchangedView).prefix(1).map { $0 }
        let directTopCount = max(4, (proposalLimit * 2) / 3)
        selected += diverse(result, limit: directTopCount, raySeparation: 0.028, zoomSeparation: 0.055)
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
        var unique: [CompositionProposal] = []
        for proposal in selected + result.sorted(by: { $0.score > $1.score }) {
            if !unique.contains(where: { hypot($0.aimPoint.x - proposal.aimPoint.x, $0.aimPoint.y - proposal.aimPoint.y) < 0.020 &&
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
                                          highMemory: Bool = false) -> [CGPoint] {
        var points: [CGPoint] = [desired, subject.anchor]
        if intent == .architecture || intent == .group || intent == .closeUp {
            points.append(CGPoint(x: 0.5, y: 0.5))
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
            ? [0.28, 0.34, 0.382, 0.44, 0.50, 0.56, 0.618, 0.66, 0.72]
            : [0.30, 0.382, 0.46, 0.54, 0.618, 0.70]
        let gridY: [Double] = highMemory
            ? [0.28, 0.34, 0.382, 0.44, 0.50, 0.58, 0.65]
            : [0.30, 0.382, 0.48, 0.58, 0.65]
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
                                     highMemory: Bool = false) -> [CGFloat] {
        let area = Double(subject.bounds.width * subject.bounds.height)
        let desiredArea: Double
        switch intent {
        case .portrait: desiredArea = subject.kind == .face ? CompositionTuning.desiredAreaFace : CompositionTuning.desiredAreaPortrait
        case .environmentalPortrait, .street: desiredArea = CompositionTuning.desiredAreaStreet
        case .group: desiredArea = CompositionTuning.desiredAreaGroup
        case .landscape: desiredArea = CompositionTuning.desiredAreaLandscape
        case .architecture: desiredArea = CompositionTuning.desiredAreaArchitecture
        case .closeUp, .food: desiredArea = CompositionTuning.desiredAreaFood
        case .animal, .object: desiredArea = CompositionTuning.desiredAreaAnimal
        }

        var options: Set<CGFloat> = [currentZoom]

        // Với phong cảnh (landscape) hoặc chủ thể chỉ là mảng vân bề mặt (scenery anchor), giữ nguyên góc rộng tự nhiên
        if subject.kind != .scenery && intent != .landscape {
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

            for prime in [1.2, 1.5, 1.8, 2.0, 2.5, 3.0, 3.5, 4.0] as [CGFloat] {
                if prime >= currentZoom && prime <= maxZoom {
                    options.insert(prime)
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
    }

    private static func measure(raster: CompositionRaster, cells: [SampleCell],
                                subject: CompositionSubject, subjectDepth: Double, box: CGRect,
                                calibration: TrackingCalibration,
                                future: TrackingCalibration, rotation: simd_quatd,
                                protectedPeople: [CompositionSubject]) -> Metrics {
        var total = 0.0, retained = 0.0
        for cell in cells {
            let weight = cell.attention
            total += weight
            let mapped = future.project(deviceRay: rotation.inverse.act(calibration.deviceRay(at: cell.point)))
            if mapped.isInFront && inside(mapped.point, margin: 0) { retained += weight }
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
        let centerDistance = hypot(weightedX / max(weightSum, 0.001) - 0.5,
                                   weightedY / max(weightSum, 0.001) - 0.5)
        let room = subject.gaze >= 0 ? Double(1 - box.maxX) : Double(box.minX)
        let opposite = subject.gaze >= 0 ? Double(box.minX) : Double(1 - box.maxX)
        let separation = subjectCount > 0 && surroundCount > 0 ?
            abs(subjectLight / subjectCount - surroundLight / surroundCount) : 0
        let innerMean = innerSyncCount > 0 ? innerSyncSum / innerSyncCount : 0
        let outerMean = outerSyncCount > 0 ? outerSyncSum / outerSyncCount : 0
        let roiSyncFocus = min(1.0, max(0.0, 0.5 + (innerMean - outerMean) * 1.6))
        let borderDepth = roiBorderDepthCount > 0 ? roiBorderDepthSum / roiBorderDepthCount : subjectDepth
        let depthSep = min(1.0, max(0.0, 0.5 + (subjectDepth - borderDepth) * 1.4))
        return Metrics(retention: total > 0.001 ? retained / total : 1,
            cleanEdges: 1 - min(1, border / max(1, borderCount)),
            balance: 1 - min(1, centerDistance * 2),
            lookRoom: min(1, max(0, 0.5 + (room - opposite) * 1.5)),
            separation: min(1, separation * 3),
            symmetry: 1 - min(1, symmetryError / Double(side * side) * 3),
            roiSyncFocus: roiSyncFocus,
            depthSeparation: depthSep)
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

    private static func observedSourceQuad(_ rawPoints: [CGPoint], unchanged: Bool,
                                           oobSum: Double, oobFraction: Double) -> [CGPoint] {
        guard !unchanged && oobSum > 0.000001, rawPoints.count == 4 else { return rawPoints }
        var minX = rawPoints[0].x, maxX = rawPoints[0].x
        var minY = rawPoints[0].y, maxY = rawPoints[0].y
        for pt in rawPoints {
            if pt.x < minX { minX = pt.x }
            if pt.x > maxX { maxX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.y > maxY { maxY = pt.y }
        }
        let spanX = maxX - minX
        let spanY = maxY - minY
        let span = max(0.001, max(spanX, spanY))
        let maxAllowedSpan: CGFloat = max(0.76, 0.93 - 0.14 * CGFloat(oobFraction))
        let scale: CGFloat = min(1.0, maxAllowedSpan / span)
        let cx: CGFloat = (minX + maxX) * 0.5
        let cy: CGFloat = (minY + maxY) * 0.5
        var scaled: [CGPoint] = []
        scaled.reserveCapacity(4)
        var sMinX: CGFloat = 10.0, sMaxX: CGFloat = -10.0
        var sMinY: CGFloat = 10.0, sMaxY: CGFloat = -10.0
        for pt in rawPoints {
            let sx = cx + (pt.x - cx) * scale
            let sy = cy + (pt.y - cy) * scale
            scaled.append(CGPoint(x: sx, y: sy))
            if sx < sMinX { sMinX = sx }
            if sx > sMaxX { sMaxX = sx }
            if sy < sMinY { sMinY = sy }
            if sy > sMaxY { sMaxY = sy }
        }
        let shiftX: CGFloat = sMinX < 0.002 ? (0.002 - sMinX) : (sMaxX > 0.998 ? (0.998 - sMaxX) : 0)
        let shiftY: CGFloat = sMinY < 0.002 ? (0.002 - sMinY) : (sMaxY > 0.998 ? (0.998 - sMaxY) : 0)
        var out: [CGPoint] = []
        out.reserveCapacity(4)
        for pt in scaled {
            let ox = min(0.999, max(0.001, pt.x + shiftX))
            let oy = min(0.999, max(0.001, pt.y + shiftY))
            out.append(CGPoint(x: ox, y: oy))
        }
        return out
    }

    private static func safe(_ rect: CGRect, original: CGRect, isHero: Bool = false) -> Bool {
        let minAllowedX = isHero ? -0.15 : (min(0.025, original.minX) - 0.00001)
        let maxAllowedX = isHero ? 1.15 : (max(0.975, original.maxX) + 0.00001)
        let maxAllowedY = isHero ? 3.0 : (max(0.975, original.maxY) + 0.00001)
        return rect.minX >= minAllowedX &&
            rect.minY >= min(0.025, original.minY) - 0.00001 &&
            rect.maxX <= maxAllowedX &&
            rect.maxY <= maxAllowedY
    }
}
