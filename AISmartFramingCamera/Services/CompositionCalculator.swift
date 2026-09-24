import Foundation
import CoreGraphics
import simd

/// The optical tracker follows subjectPoint. The yellow guide follows aimWorldRay.
/// These are different bearings whenever the requested composition is off centre.
struct LocalFramingPlan {
    let subjectPoint: CGPoint
    let subjectRect: CGRect
    let aimPointInSource: CGPoint
    let aimWorldRay: SIMD3<Double>
    let zoom: CGFloat
    let expectedSubjectRect: CGRect
    let confidence: Double
}

enum LocalAutoselectCalibration {
    private static let thresholds: [String: Double] = {
        guard let url = Bundle.main.url(forResource: "LocalAutoselectThresholds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return values.filter { $0.value.isFinite && (0.55...1.0).contains($0.value) }
    }()
    static func threshold(scene: DetectedSceneType,
                          category: NeuralSubjectCategory) -> Double? {
        thresholds[scene.rawValue + "|" + category.rawValue] ?? 0.60
    }
}

/// Only coarse composition features are written. No image, location, or face
/// landmarks leave memory. The learned term can move ranking by at most 15%.
final class CompositionPreferenceStore {
    static let shared = CompositionPreferenceStore()
    private struct Feature: Codable {
        let category: String
        let x: Int
        let y: Int
        let area: Int
    }
    private struct Choice: Codable {
        let scene: String
        let candidates: [Feature]
        let selectedIndex: Int
        let actualZoomTenths: Int
    }
    private let url: URL
    private var selected: [String: Int] = [:]
    private var considered: [String: Int] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("AlignAI Camera", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true)
        url = directory.appendingPathComponent("composition_feedback.jsonl")
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n").suffix(1000) {
                if let choice = try? JSONDecoder().decode(Choice.self, from: Data(line.utf8)) {
                    learn(choice)
                }
            }
        }
    }

    private func feature(_ candidate: NeuralSubjectCandidate) -> Feature {
        let r = candidate.boundingBox
        if candidate.category == .face {
            return Feature(category: NeuralSubjectCategory.human.rawValue,
                           x: 0, y: 0, area: 0)
        }
        return Feature(category: candidate.category.rawValue,
            x: Int((r.midX * 10).rounded()), y: Int((r.midY * 10).rounded()),
            area: Int((candidate.areaRatio * 20).rounded()))
    }
    private func keys(scene: String, feature: Feature) -> [String] {
        let base = scene + "|" + feature.category
        // Face candidates are reduced to a generic human label; never infer
        // a position or size preference from their omitted coordinates.
        guard feature.x != 0 || feature.y != 0 || feature.area != 0 else {
            return [base]
        }
        return [base, base + "|horizontal:" + String(feature.x / 3),
                base + "|size:" + String(feature.area / 4)]
    }
    private func learn(_ choice: Choice) {
        for (index, candidate) in choice.candidates.enumerated() {
            for key in keys(scene: choice.scene, feature: candidate) {
                considered[key, default: 0] += 1
                if index == choice.selectedIndex { selected[key, default: 0] += 1 }
            }
        }
    }
    func bonus(scene: DetectedSceneType, candidate: NeuralSubjectCandidate) -> Double {
        let candidateKeys = keys(scene: scene.rawValue, feature: feature(candidate))
        let weights = candidateKeys.count == 1 ? [1.0] : [0.50, 0.30, 0.20]
        var learned = 0.0
        for (key, weight) in zip(candidateKeys, weights) {
            let n = considered[key, default: 0]
            guard n >= 3 else { continue }
            let wins = selected[key, default: 0]
            learned += weight * (Double(wins + 1) / Double(n + 2) - 0.5)
        }
        return max(-0.15, min(0.15, learned * 0.3))
    }
    func record(scene: DetectedSceneType, candidates: [NeuralSubjectCandidate],
                selectedIndex: Int, actualZoom: CGFloat) {
        guard candidates.indices.contains(selectedIndex), actualZoom.isFinite else { return }
        let choice = Choice(scene: scene.rawValue, candidates: candidates.map(feature),
            selectedIndex: selectedIndex,
            actualZoomTenths: Int((actualZoom * 10).rounded()))
        guard let encoded = try? JSONEncoder().encode(choice) else { return }
        var line = encoded; line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? line.write(to: url, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do { _ = try handle.seekToEnd(); try handle.write(contentsOf: line) } catch { return }
        }
        learn(choice)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > 1_000_000,
           let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            let recent = text.split(separator: "\n").suffix(1000).joined(separator: "\n") + "\n"
            try? Data(recent.utf8).write(to: url, options: .atomic)
        }
    }
    var exportURL: URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }
    func deleteAll() {
        try? FileManager.default.removeItem(at: url)
        selected.removeAll(); considered.removeAll()
    }
}

enum LocalFramingGeometry {
    private static let forward = SIMD3<Double>(0, 0, -1)

    /// Simulates a camera rotation and digital crop against the exact source calibration.
    /// A physical lens handoff is still provisional and must be checked on a new frame.
    static func plan(subject: NeuralSubjectCandidate, companions: [CGRect],
                     scene: DetectedSceneType, gaze: CGVector,
                     frame: TrackingFrameContext, pose: simd_quatd,
                     currentZoom: CGFloat, allowedZooms: [CGFloat]) -> LocalFramingPlan? {
        let k = frame.calibration
        let box = subject.boundingBox
        guard k.isValid, valid(box), currentZoom.isFinite, currentZoom > 0 else { return nil }
        let s = subject.center
        let subjectRay = k.deviceRay(at: s)
        let portrait = subject.category == .human || subject.category == .face
        let preserveScene = portrait && (scene == .landscape || scene == .architecture || scene == .sunset)
        let places: [CGPoint]
        if scene == .architecture {
            places = [CGPoint(x: 0.5, y: 0.45), CGPoint(x: 0.5, y: 0.38),
                      CGPoint(x: 0.38, y: 0.45), CGPoint(x: 0.62, y: 0.45),
                      CGPoint(x: 0.5, y: 0.5)]
        } else if scene == .landscape || scene == .sky || scene == .water || scene == .sunset {
            places = [CGPoint(x: 0.38, y: 0.382), CGPoint(x: 0.62, y: 0.382),
                      CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.38)]
        } else {
            let preferredX: CGFloat = gaze.dx > 0.12 ? 0.38 : (gaze.dx < -0.12 ? 0.62 : 0.38)
            places = [CGPoint(x: preferredX, y: portrait ? 0.38 : 0.45),
                      CGPoint(x: 1 - preferredX, y: portrait ? 0.38 : 0.45),
                      CGPoint(x: 0.5, y: 0.5)]
        }
        let availableOptions = allowedZooms.isEmpty ? [1.0, 2.0, 3.0] : allowedZooms
        let zooms = Array(Set(([1.0, 2.0, 3.0, currentZoom] + availableOptions).filter {
            $0.isFinite && $0 >= 0.5 && $0 <= 5
        })).sorted()
        var best: (LocalFramingPlan, Double)?
        for zoom in zooms {
            let ratio = Double(zoom / currentZoom)
            guard ratio.isFinite, ratio > 0 else { continue }
            let future = TrackingCalibration(fx: k.fx * ratio, fy: k.fy * ratio,
                                             cx: k.cx, cy: k.cy, aspect: k.aspect,
                                             isMeasured: false)
            for d in places {
                // R maps the desired final subject ray into the current subject ray.
                // The future optical axis is R * forward, expressed in source axes.
                let rotation = simd_quatd(from: future.deviceRay(at: d), to: subjectRay)
                let aimDeviceRay = rotation.act(forward)
                let aim = k.project(deviceRay: aimDeviceRay)
                guard aim.isInFront, aim.point.x.isFinite, aim.point.y.isFinite,
                      (0...1).contains(aim.point.x), (0...1).contains(aim.point.y),
                      let projected = project(box, from: k, to: future, rotation: rotation),
                      safe(projected, margin: 0.035) else { continue }
                var companionsSafe = true
                for other in companions where valid(other) {
                    let distToSubject = hypot(other.midX - box.midX, other.midY - box.midY)
                    guard distToSubject < 0.50 else { continue }
                    guard let expected = project(other, from: k, to: future,
                                                 rotation: rotation),
                          safe(expected, margin: 0.025) else {
                        companionsSafe = false; break
                    }
                }
                guard companionsSafe else { continue }
                let targetArea = preserveScene ? 0.14 : (portrait ? 0.26 :
                    (scene == .architecture ? 0.38 : (scene == .food || scene == .macro ? 0.32 : 0.25)))
                let area = Double(projected.width * projected.height)
                let sizeFit = 1 - min(1, abs(log(max(0.001, area) / targetArea)) / 2.5)
                let motion = hypot(Double(aim.point.x - 0.5), Double(aim.point.y - 0.5))
                let zoomCost = abs(log(ratio))
                let spaceBonus = gaze.dx > 0.12 ? Double(0.5 - d.x) * 0.16 :
                    (gaze.dx < -0.12 ? Double(d.x - 0.5) * 0.16 : 0)
                let score = 0.65 * sizeFit - 0.10 * motion - 0.08 * zoomCost + spaceBonus
                let ray = pose.act(aimDeviceRay)
                let plan = LocalFramingPlan(subjectPoint: s, subjectRect: box,
                    aimPointInSource: aim.point, aimWorldRay: ray, zoom: zoom,
                    expectedSubjectRect: projected,
                    confidence: min(1, max(0, Double(subject.confidence) * (0.55 + 0.45 * sizeFit))))
                if let previous = best {
                    if score > previous.1 { best = (plan, score) }
                } else { best = (plan, score) }
            }
        }
        return best?.0
    }

    private static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) &&
            r.width > 0.01 && r.height > 0.01 && r.minX >= 0 && r.minY >= 0 &&
            r.maxX <= 1 && r.maxY <= 1
    }
    private static func safe(_ r: CGRect, margin: CGFloat) -> Bool {
        r.minX >= margin && r.minY >= margin && r.maxX <= 1 - margin && r.maxY <= 1 - margin
    }
    private static func project(_ rect: CGRect, from source: TrackingCalibration,
                                to output: TrackingCalibration, rotation: simd_quatd) -> CGRect? {
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        let projected = points.map { output.project(deviceRay: rotation.inverse.act(source.deviceRay(at: $0))) }
        guard projected.allSatisfy({ $0.isInFront && $0.point.x.isFinite && $0.point.y.isFinite }) else { return nil }
        let xs = projected.map(\.point.x), ys = projected.map(\.point.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public struct FramingTargetResult {
    public let targetPoint: CGPoint          // Normalized coordinate (0.0...1.0)
    public let currentCenter: CGPoint        // Camera optical center (0.5, 0.5)
    public let offsetVector: CGVector        // Vector from optical center to target
    public let distance: CGFloat             // Euclidean distance
    public let angleDegrees: CGFloat         // Angle in degrees for compass indicator
    public let alignmentScore: Double        // 0.0 (far) to 1.0 (perfectly aligned)
    public let isAligned: Bool               // True when distance <= tolerance
    public let recommendedZoomFactor: CGFloat// Recommended zoom (1.0x, 2.0x, 3.0x...)
    public let optimalRule: CompositionRule  // Active or auto-selected rule
    public let guideDescription: String      // Actionable advice for the photographer
}

public final class CompositionCalculator {
    public static let shared = CompositionCalculator()
    
    // Golden ratio constant
    private let phiRatio: CGFloat = 0.61803398875
    private let phiInverseRatio: CGFloat = 0.38196601125
    
    // Alignment tolerance threshold (normalized coordinate space)
    public var alignmentTolerance: CGFloat = 0.038
    
    public init() {}
    
    // MARK: - Main Calculation Pipeline
    public func calculateTarget(
        from detection: SubjectDetectionResult,
        rule: CompositionRule,
        currentZoom: CGFloat = 1.0,
        viewfinderAspect: CGFloat = 4.0 / 3.0
    ) -> FramingTargetResult {
        let center = CGPoint(x: 0.5, y: 0.5)
        let resolvedRule = resolveDynamicRule(requestedRule: rule, detection: detection)
        
        let targetPoint: CGPoint
        var recommendedZoom: CGFloat = currentZoom
        var advice = "Căn chỉnh camera vào điểm vàng"
        
        switch resolvedRule {
        case .ruleOfThirds:
            let (point, text) = computeRuleOfThirdsTarget(detection: detection)
            targetPoint = point
            advice = text
            
        case .goldenRatio:
            let (point, text) = computeGoldenRatioTarget(detection: detection)
            targetPoint = point
            advice = text
            
        case .goldenSpiral:
            let (point, text) = computeGoldenSpiralTarget(detection: detection)
            targetPoint = point
            advice = text
            
        case .centerSymmetry:
            targetPoint = CGPoint(x: 0.5, y: 0.5)
            advice = "Giữ chủ thể đối xứng ngay chính giữa khung hình"
            
        case .dynamicAI:
            let (point, text) = computeRuleOfThirdsTarget(detection: detection)
            targetPoint = point
            advice = text
        }
        
        // Auto-Zoom evaluation based on subject bounding box scale & scene context (2-Tier Analysis)
        let isGroupPhoto = detection.faceRectangles.count > 1
        if let dominantRect = detection.dominantSubjectRect {
            recommendedZoom = computeOptimalZoom(subjectRect: dominantRect, currentZoom: currentZoom, isGroup: isGroupPhoto, scene: detection.detectedScene)
        } else if let faceRect = detection.faceRectangles.first {
            recommendedZoom = computeOptimalZoom(subjectRect: faceRect, currentZoom: currentZoom, isGroup: isGroupPhoto, scene: detection.detectedScene)
        } else if detection.detectedScene == .landscape || isGroupPhoto {
            recommendedZoom = 1.0
        }
        
        // Calculate offset vector and metrics
        let dx = targetPoint.x - center.x
        let dy = targetPoint.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let radians = atan2(dy, dx)
        var degrees = radians * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }
        
        // Alignment score calculation (1.0 = perfect lock, 0.0 = edge of screen)
        let maxSearchRadius: CGFloat = 0.40
        let rawScore = max(0.0, 1.0 - (distance / maxSearchRadius))
        let alignmentScore = Double(min(1.0, rawScore))
        let isAligned = distance <= alignmentTolerance
        
        if isAligned {
            advice = "Bố cục hoàn hảo! Chạm nút chụp ngay"
        }
        
        return FramingTargetResult(
            targetPoint: targetPoint,
            currentCenter: center,
            offsetVector: CGVector(dx: dx, dy: dy),
            distance: distance,
            angleDegrees: degrees,
            alignmentScore: alignmentScore,
            isAligned: isAligned,
            recommendedZoomFactor: recommendedZoom,
            optimalRule: resolvedRule,
            guideDescription: advice
        )
    }
    
    // MARK: - Dynamic Rule Selection based on Scene
    private func resolveDynamicRule(requestedRule: CompositionRule, detection: SubjectDetectionResult) -> CompositionRule {
        guard requestedRule == .dynamicAI else { return requestedRule }
        
        switch detection.detectedScene {
        case .portrait, .pet:
            return .goldenRatio
        case .landscape, .sunset, .macro, .sky, .water, .foliage:
            return .ruleOfThirds
        case .architecture, .food:
            return .centerSymmetry
        case .street, .night, .general:
            return detection.faceRectangles.isEmpty ? .ruleOfThirds : .goldenRatio
        }
    }
    
    // MARK: - Rule of Thirds Calculation
    private func computeRuleOfThirdsTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let thirdsX: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        let thirdsY: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]

        guard let subject = detection.dominantSubjectRect else {
            return (CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0), "Hướng góc chụp về điểm 1/3 góc trên")
        }
        let subjectCenter = detection.primaryEyePosition ?? CGPoint(x: subject.midX, y: subject.midY)

        let preferredX: CGFloat
        if abs(detection.lookingDirection.dx) > 0.15 {
            preferredX = detection.lookingDirection.dx > 0 ? thirdsX[1] : thirdsX[0]
        } else {
            preferredX = thirdsX.min(by: { abs($0 - subjectCenter.x) < abs($1 - subjectCenter.x) }) ?? thirdsX[0]
        }
        let preferredY = thirdsY.min(by: { abs($0 - subjectCenter.y) < abs($1 - subjectCenter.y) }) ?? thirdsY[0]

        let targetPoint = CGPoint(x: preferredX, y: preferredY)
        let advice = abs(detection.lookingDirection.dx) > 0.15
            ? "Đưa tâm trắng để chừa khoảng trống phía chủ thể đang nhìn"
            : "Đưa tâm trắng vào giao điểm 1/3 gần chủ thể nhất"
        return (targetPoint, advice)
    }

    // MARK: - Golden Ratio Calculation (1:1.618)
    private func computeGoldenRatioTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let goldenPointsX: [CGFloat] = [phiInverseRatio, phiRatio]
        let goldenPointsY: [CGFloat] = [phiInverseRatio, phiRatio]

        guard let subject = detection.dominantSubjectRect else {
            return (CGPoint(x: phiRatio, y: phiInverseRatio), "Căn chỉnh theo tỷ lệ vàng 1.618")
        }
        let subjectCenter = detection.primaryEyePosition ?? CGPoint(x: subject.midX, y: subject.midY)

        let preferredX: CGFloat
        if abs(detection.lookingDirection.dx) > 0.15 {
            preferredX = detection.lookingDirection.dx > 0 ? goldenPointsX[1] : goldenPointsX[0]
        } else {
            preferredX = goldenPointsX.min(by: { abs($0 - subjectCenter.x) < abs($1 - subjectCenter.x) }) ?? goldenPointsX[0]
        }
        let preferredY = goldenPointsY.min(by: { abs($0 - subjectCenter.y) < abs($1 - subjectCenter.y) }) ?? goldenPointsY[0]

        return (CGPoint(x: preferredX, y: preferredY), "Đưa tâm trắng vào điểm vàng gần chủ thể nhất")
    }

    // MARK: - Golden Spiral Calculation
    private func computeGoldenSpiralTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        // 4 tâm xoắn ốc Fibonacci ứng với 4 hướng cuộn của đường xoắn (góc phần tư màn hình)
        let spiralFoci: [CGPoint] = [
            CGPoint(x: phiRatio, y: phiInverseRatio),
            CGPoint(x: phiInverseRatio, y: phiInverseRatio),
            CGPoint(x: phiRatio, y: phiRatio),
            CGPoint(x: phiInverseRatio, y: phiRatio)
        ]
        guard let subject = detection.dominantSubjectRect else {
            return (spiralFoci[0], "Uốn lượn bố cục theo xoắn ốc Fibonacci")
        }
        let subjectCenter = detection.primaryEyePosition ?? CGPoint(x: subject.midX, y: subject.midY)
        let nearest = spiralFoci.min(by: {
            hypot($0.x - subjectCenter.x, $0.y - subjectCenter.y) < hypot($1.x - subjectCenter.x, $1.y - subjectCenter.y)
        }) ?? spiralFoci[0]
        return (nearest, "Đưa tâm trắng vào tiêu điểm xoắn ốc Fibonacci gần chủ thể nhất")
    }
    
    // MARK: - Auto-Zoom Computation (2-Tier Context Understanding: 1x, 2x, 3x)
    public func computeOptimalZoom(
        subjectRect: CGRect,
        currentZoom: CGFloat,
        isGroup: Bool = false,
        scene: DetectedSceneType = .general
    ) -> CGFloat {
        // Tier 2: Bối cảnh cảnh quan & Nhóm đông người
        // Nhóm đông người hoặc phong cảnh rộng: giữ 1x (hoặc zoom out về 1x nếu đang zoom)
        if isGroup || scene == .landscape || scene == .sky || scene == .water {
            return 1.0
        }

        // Kiểm tra khoảng cách mép khung hình:
        // Nếu chủ thể sát mép khung hình: không tự zoom vào để tránh cắt cụt chủ thể
        let margin: CGFloat = 0.08
        let isNearEdge = subjectRect.minX < margin ||
                         subjectRect.maxX > (1.0 - margin) ||
                         subjectRect.minY < margin ||
                         subjectRect.maxY > (1.0 - margin)
        if isNearEdge {
            return 1.0
        }

        // Tier 2: Phân tích tỉ lệ diện tích & vị trí đối xứng so với tâm
        let subjectArea = subjectRect.width * subjectRect.height
        let isNearCenter = abs(subjectRect.midX - 0.5) < 0.28 && abs(subjectRect.midY - 0.5) < 0.28

        // 1. Chủ thể ở xa hoặc chi tiết nhỏ (chiếm < 8% khung hình và nằm gần trung tâm): gợi ý / zoom lên 3x
        if subjectArea < 0.08 && isNearCenter {
            return 3.0
        }

        // 2. Chân dung bán thân (1 người, chiếm 10-25% khung hình, nới lỏng 8%-28%): gợi ý / zoom lên 2x để tỉ lệ đẹp
        if subjectArea >= 0.08 && subjectArea <= 0.28 {
            return 2.0
        }

        // 3. Chủ thể đã chiếm diện tích lớn (> 28% khung hình) hoặc bối cảnh toàn cảnh: giữ 1.0x
        return 1.0
    }
}
