import Foundation
import CoreGraphics
import simd

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
        (luminance + attention + edges).allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func value(_ values: [Double], at point: CGPoint) -> Double {
        let x = min(side - 1, max(0, Int(point.x * CGFloat(side))))
        let y = min(side - 1, max(0, Int(point.y * CGFloat(side))))
        return values[y * side + x]
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

    static func proposals(subjects: [CompositionSubject], intents: [LocalCompositionIntent],
                          raster: CompositionRaster, calibration: TrackingCalibration,
                          currentZoom: CGFloat, allowedZooms: [CGFloat], protectedBounds: [CGRect] = [],
                          isCancelled: () -> Bool = { false }) -> [CompositionProposal] {
        guard raster.isValid, calibration.isValid, currentZoom.isFinite, currentZoom > 0 else { return [] }
        let validSubjects = subjects.filter {
            valid($0.bounds) && $0.anchor.x.isFinite && $0.anchor.y.isFinite &&
            $0.bounds.contains($0.anchor) && $0.confidence.isFinite && $0.importance.isFinite
        }
        let protectedPeople = validSubjects.filter { $0.kind == .person || $0.kind == .face || $0.kind == .group }
        let protectedRects = protectedPeople.map(\.bounds) + protectedBounds.filter { valid($0) }
        let maxZoom = max(currentZoom, min(5, allowedZooms.filter { $0.isFinite }.max() ?? currentZoom))
        let zooms = Array(Set(([currentZoom, currentZoom * 1.15, currentZoom * 1.35,
                               currentZoom * 1.65] + allowedZooms).filter {
            $0.isFinite && $0 >= currentZoom && $0 <= maxZoom
        })).sorted()
        var result: [CompositionProposal] = []
        for subject in validSubjects.prefix(14) {
            if isCancelled() { return [] }
            let options = applicableIntents(subject: subject, preferred: intents,
                                           people: protectedPeople)
            for intent in options {
                for zoom in zooms {
                    let ratio = Double(zoom / currentZoom)
                    let future = TrackingCalibration(fx: calibration.fx * ratio, fy: calibration.fy * ratio,
                        cx: calibration.cx, cy: calibration.cy, aspect: calibration.aspect, isMeasured: false)
                    let y: CGFloat = subject.kind == .face || subject.kind == .person || subject.kind == .group ? 0.36 : 0.5
                    let placements = [subject.anchor, CGPoint(x: 0.5, y: 0.5),
                        CGPoint(x: 0.5, y: y), CGPoint(x: 1 / 3, y: y), CGPoint(x: 2 / 3, y: y),
                        CGPoint(x: 1 / 3, y: 2 / 3), CGPoint(x: 2 / 3, y: 2 / 3)]
                    for destination in placements {
                        if isCancelled() { return [] }
                        let rotation = simd_quatd(from: future.deviceRay(at: destination),
                                                 to: calibration.deviceRay(at: subject.anchor))
                        let sourceCorners = corners.map {
                            calibration.project(deviceRay: rotation.act(future.deviceRay(at: $0)))
                        }
                        // A single image cannot judge scenery outside its field of view.
                        guard sourceCorners.allSatisfy({ $0.isInFront && inside($0.point, margin: -0.00001) }),
                              let box = project(subject.bounds, from: calibration, to: future, rotation: rotation),
                              safe(box, original: subject.bounds),
                              protectedRects.allSatisfy({ original in
                                  guard let rect = project(original, from: calibration, to: future,
                                                           rotation: rotation) else { return false }
                                  return safe(rect, original: original)
                              }) else { continue }
                        let aim = calibration.project(deviceRay: rotation.act(SIMD3(0, 0, -1)))
                        guard aim.isInFront, inside(aim.point, margin: 0) else { continue }
                        let metrics = measure(raster: raster, subject: subject, box: box,
                            calibration: calibration, future: future, rotation: rotation,
                            protectedPeople: protectedPeople)
                        let area = Double(box.width * box.height)
                        let desiredArea: Double
                        switch intent {
                        case .portrait: desiredArea = subject.kind == .face ? 0.13 : 0.34
                        case .environmentalPortrait, .street: desiredArea = 0.12
                        case .group: desiredArea = 0.24
                        case .landscape: desiredArea = 0.15
                        case .architecture: desiredArea = 0.45
                        case .closeUp, .food: desiredArea = 0.38
                        case .animal, .object: desiredArea = 0.30
                        }
                        let sizeFit = subject.kind == .scenery ? 1 :
                            1 - min(1, abs(log(max(0.001, area) / desiredArea)) / 2.3)
                        let context = intent.preservesContext && raster.hasAttention ? metrics.retention : 1
                        let visibleArea = 1 / (ratio * ratio)
                        let contextFit = intent.preservesContext ? min(1, visibleArea / 0.72) : 1
                        let space = abs(subject.gaze) > 0.12 ? metrics.lookRoom : metrics.balance
                        let symmetry = intent == .architecture ? metrics.symmetry : metrics.balance
                        let motion = hypot(Double(aim.point.x - 0.5), Double(aim.point.y - 0.5))
                        let intentPrior = intents.contains(intent) ? 0.04 : 0
                        let score = 0.23 * sizeFit + 0.18 * context + 0.12 * contextFit +
                            0.14 * metrics.cleanEdges + 0.10 * space + 0.08 * symmetry +
                            0.07 * metrics.separation + 0.04 * min(1, max(0, subject.importance)) +
                            intentPrior - 0.04 * motion - 0.025 * abs(log(ratio))
                        let explanation = explanation(intent: intent, gaze: subject.gaze,
                            cleanEdges: metrics.cleanEdges, context: raster.hasAttention ? context : 0)
                        result.append(CompositionProposal(subjectIndex: subject.index, intent: intent,
                            subjectPoint: subject.anchor, aimPoint: aim.point, expectedSubjectRect: box,
                            sourceCorners: sourceCorners.map(\.point), rotation: rotation, zoom: zoom,
                            evidenceConfidence: min(1, max(0, subject.confidence)),
                            score: score, explanation: explanation,
                            usesCenter: abs(destination.x - 0.5) < 0.06))
                    }
                }
            }
        }
        return diverse(result, limit: 6)
    }

    static func diverse(_ proposals: [CompositionProposal], limit: Int) -> [CompositionProposal] {
        var selected: [CompositionProposal] = []
        for proposal in proposals.filter({ $0.score.isFinite }).sorted(by: { $0.score > $1.score }) {
            let duplicate = selected.contains { previous in
                let rayDistance = hypot(previous.aimPoint.x - proposal.aimPoint.x,
                                        previous.aimPoint.y - proposal.aimPoint.y)
                return previous.subjectIndex == proposal.subjectIndex && rayDistance < 0.065 &&
                    abs(log(Double(previous.zoom / proposal.zoom))) < 0.15
            }
            if !duplicate { selected.append(proposal) }
            if selected.count == limit { break }
        }
        return selected
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
                return [.environmentalPortrait, .portrait]
            }
            return [.portrait, .environmentalPortrait]
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
