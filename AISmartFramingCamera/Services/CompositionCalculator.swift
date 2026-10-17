import Foundation
import CoreGraphics
import simd

/// The optical tracker follows subjectPoint. The composition guide follows aimWorldRay.
/// These are different bearings whenever the requested composition is off centre.
struct LocalFramingPlan: Sendable {
    let subjectPoint: CGPoint
    let subjectRect: CGRect
    let cropProtectionRect: CGRect
    let aimPointInSource: CGPoint
    let aimWorldRay: SIMD3<Double>
    let zoom: CGFloat
    let confidence: Double
    let minimumAutoselectConfidence: Double
    let intent: LocalCompositionIntent
    let score: Double
    let explanation: String
    let usesCenter: Bool
    let preferenceKey: String
    var requiresSceneVerification = false
    var preservesOriginalFrame = false
    var subjectKind: CompositionSubjectKind = .object
    var expectedFaces = 0
    var expectedPeople = 0
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

/// Small local preference counts. All persistence runs on this actor, off MainActor.
/// No training claim is made: this only nudges otherwise safe layout rankings.
actor CompositionPreferenceStore {
    static let shared = CompositionPreferenceStore()
    private struct Choice: Codable {
        let keys: [String]
        let selected: String
    }
    private var loaded = false
    private var choices: [Choice] = []
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("AlignAI Camera", isDirectory: true) ?? FileManager.default.temporaryDirectory
    private var url: URL { directory.appendingPathComponent("composition_layout_feedback.json") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Choice].self, from: data) else { return }
        choices = Array(saved.suffix(500))
    }

    func bonuses() -> [String: Double] {
        load()
        var wins: [String: Int] = [:], counts: [String: Int] = [:]
        for choice in choices {
            for opponent in Set(choice.keys) where opponent != choice.selected {
                wins[choice.selected, default: 0] += 1
                counts[choice.selected, default: 0] += 1
                counts[opponent, default: 0] += 1
            }
        }
        return counts.reduce(into: [:]) { result, item in
            guard item.value >= 3 else { return }
            let preference = Double(wins[item.key, default: 0] + 1) / Double(item.value + 2)
            result[item.key] = (preference - 0.5) * 0.05
        }
    }

    func record(keys: [String], selected: String) {
        load()
        let distinct = Array(Set(keys)).sorted()
        guard distinct.count > 1, distinct.contains(selected) else { return }
        choices.append(Choice(keys: distinct, selected: selected))
        choices = Array(choices.suffix(500))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(choices).write(to: url, options: .atomic)
        } catch {
            CameraLogger.error("Không lưu được lựa chọn bố cục", error: error, category: .ai)
        }
    }

    func exportURL() -> URL? {
        load()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func deleteAll() -> Bool {
        choices = []
        loaded = true
        let files = [url, directory.appendingPathComponent("composition_feedback.jsonl")]
        for file in files
            where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { CameraLogger.error("Không xóa được lựa chọn bố cục", error: error, category: .ai) }
        }
        return files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum LocalFramingGeometry {
    private static let forward = SIMD3<Double>(0, 0, -1)

    /// Plan a direct user pin after rotating its selected ray to the centre.
    /// Evaluate entire subject/companion rectangles, not just their centroids.
    static func centeredZoom(subject: CGRect, aim: CGPoint, companions: [CGRect],
                             scene: DetectedSceneType, frame: TrackingFrameContext,
                             currentZoom: CGFloat, allowedZooms: [CGFloat]) -> CGFloat {
        let k = frame.calibration
        guard valid(subject), k.isValid, currentZoom.isFinite, currentZoom > 0 else { return currentZoom }
        let rotation = simd_quatd(from: forward, to: k.deviceRay(at: aim))
        let targetArea = scene == .landscape || scene == .sky || scene == .water ? 0.14 : 0.26
        var bestZoom = currentZoom
        var bestScore = -Double.infinity
        for zoom in Set(allowedZooms + [currentZoom]).sorted() where zoom.isFinite && zoom > 0 {
            let ratio = Double(zoom / currentZoom)
            let future = TrackingCalibration(fx: k.fx * ratio, fy: k.fy * ratio,
                cx: k.cx, cy: k.cy, aspect: k.aspect, isMeasured: false)
            guard let projected = project(subject, from: k, to: future, rotation: rotation),
                  safe(projected, margin: 0.035), companions.allSatisfy({ other in
                      guard valid(other), let p = project(other, from: k, to: future, rotation: rotation) else { return false }
                      return safe(p, margin: 0.025)
                  }) else { continue }
            let area = Double(projected.width * projected.height)
            let score = -abs(log(max(0.001, area) / targetArea)) - 0.12 * abs(log(ratio))
            if score > bestScore { bestScore = score; bestZoom = zoom }
        }
        return bestZoom
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

/// Alignment configuration shared by the existing target/capture pipeline.
/// Layout and focal-length optimization live exclusively in CompositionPlanner.
public final class CompositionCalculator {
    public static let shared = CompositionCalculator()
    public var alignmentTolerance: CGFloat = 0.038
    public init() {}
}
