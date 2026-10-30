import QuartzCore
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
    var recommendedEVBias: CGFloat = 0.0

    init(
        subjectPoint: CGPoint,
        subjectRect: CGRect,
        cropProtectionRect: CGRect,
        aimPointInSource: CGPoint,
        aimWorldRay: SIMD3<Double>,
        zoom: CGFloat,
        confidence: Double,
        minimumAutoselectConfidence: Double,
        intent: LocalCompositionIntent,
        score: Double,
        explanation: String,
        usesCenter: Bool,
        preferenceKey: String,
        recommendedEVBias: CGFloat = 0.0
    ) {
        self.subjectPoint = subjectPoint
        self.subjectRect = subjectRect
        self.cropProtectionRect = cropProtectionRect
        self.aimPointInSource = aimPointInSource
        self.aimWorldRay = aimWorldRay
        self.zoom = zoom
        self.confidence = confidence
        self.minimumAutoselectConfidence = minimumAutoselectConfidence
        self.intent = intent
        self.score = score
        self.explanation = explanation
        self.usesCenter = usesCenter
        self.preferenceKey = preferenceKey
        self.recommendedEVBias = recommendedEVBias
    }
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
        // Da vo hieu hoa: Khong tich luy thien vi lam triet tieu kha nang zoom va bo cuc dong
        return [:]
    }

    func record(keys: [String], selected: String) {
        // Da vo hieu hoa: Khong ghi de thien vi vao cac lan phan tich sau
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
    public let recommendedEVBias: Float      // Smart Scene-Aware EV Bias (-2.0...2.0)
    public let lightingScene: String         // "backlit", "night", "sunset", "harsh_sun", "normal"
    public let lightingRationale: String     // Detailed lighting rationale

    public init(
        targetPoint: CGPoint,
        currentCenter: CGPoint,
        offsetVector: CGVector,
        distance: CGFloat,
        angleDegrees: CGFloat,
        alignmentScore: Double,
        isAligned: Bool,
        recommendedZoomFactor: CGFloat,
        optimalRule: CompositionRule,
        guideDescription: String,
        recommendedEVBias: Float = 0.0,
        lightingScene: String = "normal",
        lightingRationale: String = ""
    ) {
        self.targetPoint = targetPoint
        self.currentCenter = currentCenter
        self.offsetVector = offsetVector
        self.distance = distance
        self.angleDegrees = angleDegrees
        self.alignmentScore = alignmentScore
        self.isAligned = isAligned
        self.recommendedZoomFactor = recommendedZoomFactor
        self.optimalRule = optimalRule
        self.guideDescription = guideDescription
        self.recommendedEVBias = recommendedEVBias
        self.lightingScene = lightingScene
        self.lightingRationale = lightingRationale
    }
}

// MARK: - Phase 3 & 4: AI Multi-Hypothesis Photographic Composition & Virtual Crop Zoom Scoring

/// Dữ liệu Bằng chứng Bố cục Toàn cảnh cho Phân tích Đa Tỷ Lệ (Phase 3 & Phase 4)
public struct SceneCompositionEvidence: Sendable {
    public let primarySubjectRect: CGRect
    public let focalAnchorPoint: CGPoint
    public let focalCategory: NeuralSubjectCategory
    public let focalSaliencyRatio: Double // [0.0...1.0] Tỷ lệ năng lượng Saliency hội tụ trong tâm điểm so với toàn khung
    public let edgeClutterScore: Double    // [0.0...1.0] Mức độ vật thể rác ở vùng rìa khung hình
    public let detectedScene: DetectedSceneType
    public let detectedHorizonY: CGFloat?
    public let timestamp: TimeInterval

    public init(
        primarySubjectRect: CGRect,
        focalAnchorPoint: CGPoint,
        focalCategory: NeuralSubjectCategory,
        focalSaliencyRatio: Double,
        edgeClutterScore: Double,
        detectedScene: DetectedSceneType,
        detectedHorizonY: CGFloat?,
        timestamp: TimeInterval
    ) {
        self.primarySubjectRect = primarySubjectRect
        self.focalAnchorPoint = focalAnchorPoint
        self.focalCategory = focalCategory
        self.focalSaliencyRatio = focalSaliencyRatio
        self.edgeClutterScore = edgeClutterScore
        self.detectedScene = detectedScene
        self.detectedHorizonY = detectedHorizonY
        self.timestamp = timestamp
    }
}

/// Kết quả Đấu loại Khung cắt Ảo Đa Tỷ lệ cho từng Mức Zoom (Phase 4)
public struct VirtualCropZoomScore: Sendable {
    public let zoom: CGFloat
    public let totalScore: Double
    public let focalSaliencyDensity: Double
    public let edgeClutterRemovalGain: Double
    public let subjectIntegrityPenalty: Double
    public let momentumBonus: Double
    public let virtualCropRect: CGRect
    public let rationale: String

    public init(
        zoom: CGFloat,
        totalScore: Double,
        focalSaliencyDensity: Double,
        edgeClutterRemovalGain: Double,
        subjectIntegrityPenalty: Double,
        momentumBonus: Double,
        virtualCropRect: CGRect,
        rationale: String
    ) {
        self.zoom = zoom
        self.totalScore = totalScore
        self.focalSaliencyDensity = focalSaliencyDensity
        self.edgeClutterRemovalGain = edgeClutterRemovalGain
        self.subjectIntegrityPenalty = subjectIntegrityPenalty
        self.momentumBonus = momentumBonus
        self.virtualCropRect = virtualCropRect
        self.rationale = rationale
    }
}

/// Quyết định Mức Zoom Chiến thắng qua Mô phỏng Khung cắt Ảo (Phase 4)
public struct VirtualCropZoomDecision: Sendable {
    public let optimalZoom: CGFloat
    public let winningScore: VirtualCropZoomScore
    public let allScores: [VirtualCropZoomScore]
    public let rationale: String

    public init(
        optimalZoom: CGFloat,
        winningScore: VirtualCropZoomScore,
        allScores: [VirtualCropZoomScore],
        rationale: String
    ) {
        self.optimalZoom = optimalZoom
        self.winningScore = winningScore
        self.allScores = allScores
        self.rationale = rationale
    }
}

/// Đa giả thuyết Bố cục Nhiếp ảnh Thông minh (Multi-Hypothesis Photographic Composition)
public struct CompositionHypothesis: Sendable {
    public let rule: CompositionRule
    public let gridPoint: CGPoint          // P_grid (Điểm mạnh trên lưới bố cục: 1/3, Golden Ratio, Center...)
    public let anchorPoint: CGPoint        // S_anchor (Điểm neo chủ thể: Mắt, Khuôn mặt, Trọng tâm thị giác)
    public let targetPoint: CGPoint        // Target = (0.5 + (S_anchor.x - P_grid.x), 0.5 + (S_anchor.y - P_grid.y))
    public let score: Double               // Tổng điểm cạnh tranh khách quan
    public let lookingRoomBonus: Double    // Điểm thưởng khoảng thở theo hướng nhìn (gaze/yaw)
    public let visualBalanceScore: Double  // Điểm cân bằng trọng lượng thị giác
    public let headroomFit: Double         // Độ khớp khoảng thở trên đầu (Headroom)
    public let rationale: String           // Diễn giải nghệ thuật nhiếp ảnh

    public init(
        rule: CompositionRule,
        gridPoint: CGPoint,
        anchorPoint: CGPoint,
        targetPoint: CGPoint,
        score: Double,
        lookingRoomBonus: Double,
        visualBalanceScore: Double,
        headroomFit: Double,
        rationale: String
    ) {
        self.rule = rule
        self.gridPoint = gridPoint
        self.anchorPoint = anchorPoint
        self.targetPoint = targetPoint
        self.score = score
        self.lookingRoomBonus = lookingRoomBonus
        self.visualBalanceScore = visualBalanceScore
        self.headroomFit = headroomFit
        self.rationale = rationale
    }
}

/// Kết quả Khám phá Điểm neo Chủ thể Thực sự (Evidence-Based Focal Discovery)
public struct FocalDiscoveryResult: Sendable {
    public let anchorPoint: CGPoint
    public let subjectRect: CGRect
    public let category: NeuralSubjectCategory
    public let gaze: CGFloat
    public let confidence: Double
    public let saliencyEnergy: Double
    public let label: String

    public init(
        anchorPoint: CGPoint,
        subjectRect: CGRect,
        category: NeuralSubjectCategory,
        gaze: CGFloat,
        confidence: Double,
        saliencyEnergy: Double,
        label: String
    ) {
        self.anchorPoint = anchorPoint
        self.subjectRect = subjectRect
        self.category = category
        self.gaze = gaze
        self.confidence = confidence
        self.saliencyEnergy = saliencyEnergy
        self.label = label
    }
}

/// Bộ theo dõi Quán tính Chủ thể (Subject Hysteresis Tracker) - Chống nhảy giật mục tiêu
public struct SubjectHysteresisTracker: Sendable {
    private var currentSubjectID: UUID?
    private var challengerID: UUID?
    private var consecutiveChallengerWins: Int = 0
    private var lastSwitchTime: TimeInterval = 0
    
    public init() {}

    public mutating func track(candidateID: UUID, candidateScore: Double, currentScore: Double, now: TimeInterval) -> UUID {
        guard let current = currentSubjectID else {
            currentSubjectID = candidateID
            lastSwitchTime = now
            return candidateID
        }
        if candidateID == current {
            challengerID = nil
            consecutiveChallengerWins = 0
            return current
        }
        if candidateScore > currentScore * 1.25 {
            if challengerID == candidateID {
                consecutiveChallengerWins += 1
                if consecutiveChallengerWins >= 3 && now - lastSwitchTime >= 0.35 {
                    currentSubjectID = candidateID
                    challengerID = nil
                    consecutiveChallengerWins = 0
                    lastSwitchTime = now
                    return candidateID
                }
            } else {
                challengerID = candidateID
                consecutiveChallengerWins = 1
            }
        } else {
            challengerID = nil
            consecutiveChallengerWins = 0
        }
        return current
    }

    public mutating func reset() {
        currentSubjectID = nil
        challengerID = nil
        consecutiveChallengerWins = 0
        lastSwitchTime = 0
    }
}

/// Alignment configuration and dynamic multi-hypothesis composition & virtual crop zoom engine.
public final class CompositionCalculator: @unchecked Sendable {
    public static let shared = CompositionCalculator()
    public var alignmentTolerance: CGFloat = 0.038
    
    // Quán tính thời gian (Hysteresis) cho Điểm mạnh Bố cục
    private let stateLock = NSLock()
    private var activeWinningRule: CompositionRule = .ruleOfThirds
    private var activeWinningGridPoint: CGPoint = CGPoint(x: 0.382, y: 0.382)
    private var lastWinningScore: Double = 0.5
    public var hysteresisTracker = SubjectHysteresisTracker()

    public init() {}

    /// Chấm điểm Trọng số Nhiếp ảnh cho từng Ứng viên (SubjectRelevanceScore)
    /// Tránh hoàn toàn việc bắt nhầm rác rìa khung làm chủ thể chính, bổ sung Quán tính Chủ thể (Subject Persistence)
    /// và ngăn chặn việc khuôn mặt người lạ ở xa cướp quyền chủ thể của đối tượng tiền cảnh.
    public static func calculateSubjectRelevance(
        rect: CGRect,
        category: NeuralSubjectCategory,
        confidence: Double,
        gaze: CGFloat = 0.0,
        hasFace: Bool = false,
        saliencyDensity: Double = 0.5,
        isForegroundMasked: Bool = false,
        previousWinningRect: CGRect? = nil,
        previousWinningAnchor: CGPoint? = nil,
        hasLargeForegroundSubject: Bool = false
    ) -> Double {
        guard rect.width > 0.02 && rect.height > 0.02 else { return 0.0 }
        
        let area = Double(rect.width * rect.height)

        // 1. Hệ số danh mục ngữ nghĩa (Semantic Tier) có điều chỉnh theo khoảng cách
        var tierMultiplier: Double
        switch category {
        case .face:
            // Nếu là khuôn mặt rất nhỏ ở xa mà đã có chủ thể to ở tiền/trung cảnh -> triệt tiêu ưu tiên cướp chủ thể
            if hasLargeForegroundSubject && area < 0.012 {
                tierMultiplier = 0.65
            } else {
                tierMultiplier = 1.35
            }
        case .human:
            tierMultiplier = hasFace ? 1.30 : 1.15
        case .animal:
            tierMultiplier = 1.12
        case .foregroundObject:
            tierMultiplier = isForegroundMasked ? 1.05 : 0.95
        case .general:
            tierMultiplier = 0.70
        }
        
        // 2. Phạt nặng vật thể ở sát rìa khung (Edge Clutter Penalty)
        let edgeMargin = min(rect.minX, min(rect.minY, min(1.0 - rect.maxX, 1.0 - rect.maxY)))
        let edgeClutterPenalty: Double
        if edgeMargin < 0.035 && saliencyDensity < 0.65 {
            edgeClutterPenalty = 0.25 // Vật thể rác chạm mép ngoài bị giảm 75% điểm
        } else if edgeMargin < 0.06 {
            edgeClutterPenalty = 0.70
        } else {
            edgeClutterPenalty = 1.0
        }
        
        // 3. Tỷ lệ diện tích hợp lý (Scale & Proportions)
        let optimalArea = category == .face ? 0.08 : (category == .human ? 0.25 : 0.15)
        let scaleFitness = exp(-pow(log(max(0.005, area) / optimalArea), 2) / 2.2)
        
        // 4. Mức độ tập trung năng lượng thị giác (Saliency Energy)
        let saliencyComponent = 0.40 * saliencyDensity + (isForegroundMasked ? 0.20 : 0.0)
        
        // 5. Quán tính Chủ thể (Subject Persistence Hysteresis)
        var persistenceBonus = 0.0
        if let prevRect = previousWinningRect {
            let inter = rect.intersection(prevRect)
            let interArea = (!inter.isNull && !inter.isEmpty) ? Double(inter.width * inter.height) : 0.0
            let unionArea = area + Double(prevRect.width * prevRect.height) - interArea
            let iou = unionArea > 0 ? (interArea / unionArea) : 0.0
            let dist = previousWinningAnchor.map { hypot(rect.midX - $0.x, rect.midY - $0.y) } ?? 1.0
            if iou > 0.30 || dist < 0.12 {
                persistenceBonus = 0.25 // Thưởng duy trì chủ thể đang được chọn
            }
        }
        
        let rawScore = confidence * tierMultiplier * edgeClutterPenalty * (0.35 * scaleFitness + 0.35 * saliencyComponent + 0.30) + persistenceBonus
        return max(0.0, min(1.0, rawScore))
    }

    /// Công thức quy đổi vị trí Target chính xác theo quang học (Pre-Zoom Target Projection - Sửa Lỗi 4):
    /// Bù tỷ lệ phóng đại zoom k = max(0.5, relativeScale) để khi zoom quang học mở rộng quanh tâm (0.5, 0.5),
    /// điểm neo chủ thể S_anchor sẽ rơi trúng phóc vào điểm mạnh P_grid*.
    /// Công thức: Target.x = S_anchor.x - (P_grid.x - 0.5) / k
    ///           Target.y = S_anchor.y - (P_grid.y - 0.5) / k
    /// (Kiểm chứng: Khi đưa 0.5 vào Target, neo dịch đến 0.5 + (P_grid - 0.5)/k. Phóng đại k quanh 0.5 -> rơi đúng P_grid!)
    public func calculateTargetPoint(anchor: CGPoint, gridPoint: CGPoint, relativeScale: CGFloat = 1.0) -> CGPoint {
        let k = max(0.5, relativeScale)
        let rawX = anchor.x - (gridPoint.x - 0.5) / k
        let rawY = anchor.y - (gridPoint.y - 0.5) / k
        // Kẹp an toàn trong vùng hoạt động của khung ngắm [0.05 ... 0.95]
        return CGPoint(
            x: max(0.05, min(0.95, rawX)),
            y: max(0.05, min(0.95, rawY))
        )
    }

    /// Đánh giá Đa Giả thuyết Bố cục Cạnh tranh Động (Multi-Hypothesis Composition Evaluation)
    /// AI tự tính toán cạnh tranh giữa các quy tắc: Rule of Thirds, Golden Ratio, Center/Symmetry, Horizon
    public func evaluateHypotheses(
        anchor: CGPoint,
        subjectRect: CGRect,
        category: NeuralSubjectCategory,
        gaze: CGFloat, // > 0 nhìn sang phải, < 0 nhìn sang trái
        sceneType: DetectedSceneType,
        currentZoom: CGFloat = 1.0,
        horizonY: CGFloat? = nil,
        activeRule: CompositionRule? = nil
    ) -> (winning: CompositionHypothesis, all: [CompositionHypothesis]) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var hypotheses: [CompositionHypothesis] = []

        // 1. Tập hợp các điểm mạnh bố cục (P_grid Candidates)
        // (a) Quy tắc 1/3 (Rule of Thirds)
        let thirdsPoints: [(CGPoint, String)] = [
            (CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0), "Quy tắc 1/3 · Góc trên-trái"),
            (CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0), "Quy tắc 1/3 · Góc trên-phải"),
            (CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0), "Quy tắc 1/3 · Góc dưới-trái"),
            (CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0), "Quy tắc 1/3 · Góc dưới-phải")
        ]

        // (b) Tỷ lệ vàng (Golden Ratio Phi = 0.618 / 0.382)
        let goldenPoints: [(CGPoint, String)] = [
            (CGPoint(x: 0.382, y: 0.382), "Tỷ lệ vàng · Tiêu điểm trên-trái"),
            (CGPoint(x: 0.618, y: 0.382), "Tỷ lệ vàng · Tiêu điểm trên-phải"),
            (CGPoint(x: 0.382, y: 0.618), "Tỷ lệ vàng · Tiêu điểm dưới-trái"),
            (CGPoint(x: 0.618, y: 0.618), "Tỷ lệ vàng · Tiêu điểm dưới-phải")
        ]

        // (c) Tâm đối xứng (Center Symmetry)
        let centerPoint = (CGPoint(x: 0.5, y: 0.5), "Tâm đối xứng · Cân bằng thị giác")

        // (d) Đường chân trời (Horizon / Landscape) - Lỗ hổng 4: Horizon X/Y Decoupling
        var horizonPoints: [(CGPoint, String)] = []
        if sceneType == .landscape || sceneType == .sky || sceneType == .water || horizonY != nil {
            let yTargets: [CGFloat] = [0.382, 0.618]

            // Kiểm tra nếu cảnh có điểm tụ ngang rõ rệt (mặt trời, cây đơn độc lệch bên, con thuyền)
            let hasHorizontalAnchor = (subjectRect.width * subjectRect.height > 0.02) || abs(anchor.x - 0.5) > 0.08

            if hasHorizontalAnchor {
                for yT in yTargets {
                    let descY = yT < 0.5 ? "Đường chân trời 1/3 trên" : "Đường chân trời 1/3 dưới"
                    horizonPoints.append((CGPoint(x: 0.382, y: yT), "Toàn cảnh · \(descY) · Tiêu điểm trái"))
                    horizonPoints.append((CGPoint(x: 0.618, y: yT), "Toàn cảnh · \(descY) · Tiêu điểm phải"))
                    horizonPoints.append((CGPoint(x: 0.500, y: yT), "Toàn cảnh · \(descY) · Tiêu điểm trung tâm"))
                }
            } else {
                // Cảnh biển / trời phẳng không có điểm tụ ngang: KHÔNG ép lia ngang (đặt P_grid.x = anchor.x => deltaX = 0)
                for yT in yTargets {
                    let descY = yT < 0.5 ? "Cân bằng chân trời 1/3 trên" : "Cân bằng chân trời 1/3 dưới"
                    horizonPoints.append((CGPoint(x: anchor.x, y: yT), "Toàn cảnh phẳng · \(descY)"))
                }
            }
        }

        // 2. Chấm điểm cạnh tranh từng giả thuyết (sử dụng relativeScale = 1.0 cho giai đoạn định vị lưới)
        let allCandidates: [(rule: CompositionRule, pt: CGPoint, desc: String)] =
            thirdsPoints.map { (.ruleOfThirds, $0.0, $0.1) } +
            goldenPoints.map { (.goldenRatio, $0.0, $0.1) } +
            [(.centerSymmetry, centerPoint.0, centerPoint.1)] +
            horizonPoints.map { (.ruleOfThirds, $0.0, $0.1) }

        for item in allCandidates {
            let pGrid = item.pt
            let target = calculateTargetPoint(anchor: anchor, gridPoint: pGrid, relativeScale: 1.0)

            // Yếu tố 1: Khoảng thở theo hướng nhìn (Looking Room / Lead Room)
            var lookingBonus = 0.0
            if abs(gaze) > 0.04 && (category == .human || category == .face || category == .animal) {
                let leadSpace = (0.5 - Double(pGrid.x))
                lookingBonus = max(-0.35, min(0.35, Double(gaze) * leadSpace * 2.8))
            }

            // Yếu tố 2: Khoảng thở trên đầu (Headroom & Eye line Fit) - Hệ tọa độ Upright (y=0 ở đỉnh trên)
            var headroomFit = 1.0
            if category == .human || category == .face {
                let targetEyeLine = 0.36
                headroomFit = exp(-pow((Double(pGrid.y) - targetEyeLine) / 0.16, 2))
                if pGrid.y > 0.55 {
                    headroomFit -= 0.35
                }
            }

            // Yếu tố 3 (Phản biện 3): Đánh giá vị trí đặt chủ thể đích P* (pGrid) thay vì khoảng cách dịch chuyển Target!
            // Nếu chủ thể đã nằm sẵn ở điểm mạnh P* (anchor ~ pGrid => target ~ 0.5), TUYỆT ĐỐI KHÔNG phạt mà phải giữ nguyên để xác nhận khóa nét!
            let gridDistFromCenter = hypot(Double(pGrid.x - 0.5), Double(pGrid.y - 0.5))
            let subjectToGridDist = hypot(Double(anchor.x - pGrid.x), Double(anchor.y - pGrid.y))
            let balanceScore: Double
            if sceneType == .architecture && item.rule == .centerSymmetry {
                balanceScore = exp(-6.0 * pow(gridDistFromCenter, 2))
            } else {
                let gridPowerFitness = exp(-12.0 * pow(gridDistFromCenter - 0.165, 2))
                let proximityFit = exp(-3.5 * pow(subjectToGridDist, 2))
                balanceScore = 0.72 * gridPowerFitness + 0.28 * proximityFit
            }

            // Chỉ phạt khi điểm đặt chủ thể đích P* (pGrid) nằm ở tâm chết (0.5, 0.5) với cảnh không đối xứng
            var centerTrapPenalty = 0.0
            if sceneType != .architecture {
                if item.rule == .centerSymmetry || gridDistFromCenter < 0.06 {
                    centerTrapPenalty += 0.36
                }
            }

            // Yếu tố 4: Ưu tiên thể loại cảnh & Quy tắc Tỷ lệ vàng / 1/3 (Scene Aesthetic Resonance)
            var sceneAestheticBonus = 0.0
            if sceneType == .architecture && item.rule == .centerSymmetry {
                sceneAestheticBonus += 0.22
            } else if item.rule == .goldenRatio {
                sceneAestheticBonus += 0.16
            } else if item.rule == .ruleOfThirds {
                sceneAestheticBonus += 0.14
            }

            // Yếu tố 5: Phạt Target tràn biên (Edge Clutter & Clipping Penalty)
            var edgePenalty = 0.0
            if target.x <= 0.06 || target.x >= 0.94 || target.y <= 0.06 || target.y >= 0.94 {
                edgePenalty = 0.30
            }

            // Yếu tố 6: Quán tính thời gian (Temporal Hysteresis / Stability Bonus)
            var temporalBonus = 0.0
            let activeRuleToMatch = activeRule ?? activeWinningRule
            if item.rule == activeRuleToMatch && item.rule != .centerSymmetry {
                temporalBonus += 0.08
            }
            let distToActiveGrid = hypot(Double(pGrid.x - activeWinningGridPoint.x), Double(pGrid.y - activeWinningGridPoint.y))
            if distToActiveGrid < 0.08 && gridDistFromCenter >= 0.08 {
                temporalBonus += 0.10
            }

            let totalScore = max(0.01,
                0.32 * headroomFit +
                0.28 * (lookingBonus + 0.35) / 0.70 +
                0.22 * balanceScore +
                sceneAestheticBonus +
                temporalBonus -
                edgePenalty -
                centerTrapPenalty
            )

            let hypothesis = CompositionHypothesis(
                rule: item.rule,
                gridPoint: pGrid,
                anchorPoint: anchor,
                targetPoint: target,
                score: totalScore,
                lookingRoomBonus: lookingBonus,
                visualBalanceScore: balanceScore,
                headroomFit: headroomFit,
                rationale: item.desc
            )
            hypotheses.append(hypothesis)
        }

        let sorted = hypotheses.sorted { $0.score > $1.score }
        let winning = sorted.first ?? hypotheses[0]

        if winning.score > lastWinningScore + 0.15 || hypot(winning.gridPoint.x - activeWinningGridPoint.x, winning.gridPoint.y - activeWinningGridPoint.y) < 0.05 {
            activeWinningRule = winning.rule
            activeWinningGridPoint = winning.gridPoint
            lastWinningScore = winning.score
        }

        return (winning: winning, all: sorted)
    }

    // MARK: - Phase 4: Virtual Multi-Scale Crop Scoring (1x, 2x, 3x)

    /// AI Tự Quyết định Mức Zoom bằng Mô phỏng Khung cắt Ảo (Virtual Multi-Scale Crop Scoring)
    /// Đã sửa triệt để 4 lỗi toán học:
    /// 1. Đánh giá occupancy theo Kích thước tuyến tính chuẩn hóa 1D (linearOccupancy) thay vì diện tích 2D.
    /// 2. Chuẩn hóa kích thước đo được về hệ quy chiếu gốc 1x qua currentZoomFactor.
    /// 3. Mô phỏng đúng vị trí chủ thể sau khi căn khớp vào P_grid* để kiểm tra Headroom và tràn biên.
    /// 4. Xuất mức zoom tối ưu Z* để bù tỷ lệ phóng đại quang học vào công thức Target.
    public func evaluateVirtualCropZooms(
        evidence: SceneCompositionEvidence,
        currentDisplayZoom: CGFloat,
        availableZooms: [CGFloat] = [1.0, 2.0, 3.0],
        aimPoint: CGPoint
    ) -> VirtualCropZoomDecision {
        return evaluateVirtualCropZooms(
            evidence: evidence,
            currentDisplayZoom: currentDisplayZoom,
            availableZooms: availableZooms,
            winningGridPoint: aimPoint
        )
    }

    public func evaluateVirtualCropZooms(
        evidence: SceneCompositionEvidence,
        currentDisplayZoom: CGFloat,
        availableZooms: [CGFloat] = [1.0, 2.0, 3.0],
        winningGridPoint: CGPoint = CGPoint(x: 0.382, y: 0.382)
    ) -> VirtualCropZoomDecision {
        stateLock.lock()
        defer { stateLock.unlock() }

        let currentZoom = max(0.5, currentDisplayZoom)
        let intermediateZooms: [CGFloat] = [1.0, 1.25, 1.5, 1.8, 2.0, 2.5, 3.0]
        let testZooms = Array(Set(availableZooms + [currentDisplayZoom] + intermediateZooms)).filter { $0.isFinite && $0 >= 0.5 && $0 <= 10.0 }.sorted()
        var scoredList: [VirtualCropZoomScore] = []

        // Sửa Lỗi 2: Chuẩn hóa kích thước đo được về hệ quy chiếu gốc 1x
        let baseWidth1x = evidence.primarySubjectRect.width / currentZoom
        let baseHeight1x = evidence.primarySubjectRect.height / currentZoom

        // Sửa Lỗi 1: Kích thước tuyến tính chuẩn hóa 1D (linearOccupancy)
        let baseLinearSize1x: Double
        if evidence.focalCategory == .human || evidence.focalCategory == .face {
            baseLinearSize1x = Double(baseHeight1x)
        } else {
            let area1x = Double(baseWidth1x * baseHeight1x)
            baseLinearSize1x = max(Double(max(baseWidth1x, baseHeight1x)), sqrt(max(0.0001, area1x)))
        }

        let pGrid = winningGridPoint

        for z in testZooms {
            let relativeScale = z / currentZoom
            let projectedLinearSize = baseLinearSize1x * Double(z)

            // Yếu tố 1: Mật độ và Độ lấp đầy Tuyến tính Hài hòa (Linear Occupancy Fitness)
            let focalDensityScore: Double
            if baseLinearSize1x < 0.06 {
                // Phong cảnh / thiên nhiên không có thực thể: dựa trên Saliency và Clutter
                if z <= 1.05 {
                    focalDensityScore = (1.0 - evidence.focalSaliencyRatio) * 0.45 + 0.20
                } else {
                    focalDensityScore = evidence.focalSaliencyRatio * min(1.0, sqrt(Double(z)) * 0.55) * 0.40
                }
            } else {
                let optimalLinearSize = (evidence.detectedScene == .landscape || evidence.detectedScene == .architecture) ? 0.28 : 0.52
                let sizeFitness = exp(-pow(log(max(0.02, projectedLinearSize) / optimalLinearSize), 2) / 0.55)
                let saliencyGain = min(1.0, evidence.focalSaliencyRatio * sqrt(Double(z)))
                focalDensityScore = 0.38 * sizeFitness + 0.12 * saliencyGain
            }

            // Yếu tố 2: Lợi ích Cắt bỏ Rác rìa khung (Edge Clutter Removal Gain)
            var clutterRemovalGain = 0.0
            if evidence.edgeClutterScore > 0.20 && z > 1.05 {
                clutterRemovalGain = evidence.edgeClutterScore * log(Double(z)) * 0.32
            } else if evidence.detectedScene == .landscape && evidence.edgeClutterScore < 0.12 && z > 1.2 {
                clutterRemovalGain = -0.18 * log(Double(z))
            }

            // Sửa Lỗi 3: Mô phỏng đúng vị trí chủ thể SAU KHI căn khớp vào P_grid* với tỷ lệ phóng đại relativeScale
            let topOffset = (evidence.focalAnchorPoint.y - evidence.primarySubjectRect.minY) * relativeScale
            let bottomOffset = (evidence.primarySubjectRect.maxY - evidence.focalAnchorPoint.y) * relativeScale
            let leftOffset = (evidence.focalAnchorPoint.x - evidence.primarySubjectRect.minX) * relativeScale
            let rightOffset = (evidence.primarySubjectRect.maxX - evidence.focalAnchorPoint.x) * relativeScale

            let placedMinY = pGrid.y - topOffset
            let placedMaxY = pGrid.y + bottomOffset
            let placedMinX = pGrid.x - leftOffset
            let placedMaxX = pGrid.x + rightOffset

            var integrityPenalty = 0.0
            // 1. Kiểm tra Headroom: Khoảng thở tối thiểu trên đỉnh đầu là 0.04 (4% khung hình) - Bắt buộc cho mọi chủ thể
            if placedMinY < 0.04 {
                integrityPenalty -= 2.2 * Double(0.04 - placedMinY) + 1.80
            }

            // 2. Kiểm tra Hai biên trái/phải [0.03 ... 0.97] - Bắt buộc cho mọi chủ thể (bảo vệ vai, thân và viền vật thể)
            if placedMinX < 0.03 {
                integrityPenalty -= 1.6 * Double(0.03 - placedMinX)
            }
            if placedMaxX > 0.97 {
                integrityPenalty -= 1.6 * Double(placedMaxX - 0.97)
            }

            // 3. Tinh chỉnh Cạnh dưới (placedMaxY > 0.97) - Quy tắc Chân dung Bán thân (Medium / Half-body Shot):
            let isHumanBody = (evidence.focalCategory == .human)
            if placedMaxY > 0.97 {
                if isHumanBody {
                    // Đối với Thân người toàn thân (human): Khi zoom 2x/3x để chụp chân dung bán thân (Medium Shot),
                    // phần chân của bounding box toàn thân sẽ tự nhiên nằm dưới đáy khung hình.
                    // Đảm bảo vùng từ đỉnh đầu đến ngực trên (placedMinY đến pGrid.y + 0.18) nằm gọn trong màn hình:
                    let upperChestY = pGrid.y + 0.18
                    if upperChestY > 0.96 {
                        // Nếu cả ngực trên cũng bị đẩy ra ngoài đáy màn hình thì mới phạt theo phần ngực bị cắt
                        integrityPenalty -= 2.0 * Double(upperChestY - 0.96)
                    }
                    // Miễn phạt tràn đáy cho phần chân để cho phép chuyển mượt từ ảnh toàn thân (1x) sang bán thân (2x/3x)
                } else {
                    // Với Khuôn mặt (Face), Động vật (Animal), Vật thể (Object): Phạt nặng để tránh cắt cằm hoặc cắt cụt vật thể
                    integrityPenalty -= 1.6 * Double(placedMaxY - 0.97)
                }
            }

            // 4. Phạt nếu chủ thể bị phình to vượt quá giới hạn khung hình
            if isHumanBody {
                // Với người toàn thân khi zoom bán thân: phần thân trên (đỉnh đầu tới thắt lưng ~45% chiều cao) không vượt quá 85% khung hình
                let upperBodyHeight = projectedLinearSize * 0.45
                if upperBodyHeight > 0.85 {
                    integrityPenalty -= 2.5 * Double(upperBodyHeight - 0.85)
                }
            } else {
                if projectedLinearSize > 0.82 {
                    integrityPenalty -= 2.5 * Double(projectedLinearSize - 0.82)
                }
            }

            // Phạt nếu chủ thể quá nhỏ tại mức zoom đang xét (khuyến khích Smart Zoom 1.5x / 2x / 3x khi chủ thể nhỏ/vừa)
            var underfillPenalty = 0.0
            if baseLinearSize1x >= 0.07 && evidence.detectedScene != .landscape && evidence.detectedScene != .architecture {
                if projectedLinearSize < 0.36 {
                    underfillPenalty = -0.34 * (0.36 - projectedLinearSize) / 0.36
                }
            }

            // Yếu tố 4: Quán tính nhẹ (tránh lỗi cũ 0.22 làm kẹt cứng ở 1x không bao giờ dám zoom)
            let momentumBonus = (abs(z - currentDisplayZoom) < 0.12) ? 0.025 : 0.0

            let totalScore = max(-10.0, focalDensityScore + clutterRemovalGain + integrityPenalty + underfillPenalty + momentumBonus)
            let rationale = String(format: "Zoom %.1fx · Mật độ: %.2f · Khử rác: %.2f · Phạt cắt: %.2f", z, focalDensityScore, clutterRemovalGain, integrityPenalty)

            let cropW = 1.0 / z
            let cropH = 1.0 / z
            let cropRect = CGRect(x: max(0.0, min(1.0 - cropW, pGrid.x - cropW / 2.0)),
                                  y: max(0.0, min(1.0 - cropH, pGrid.y - cropH / 2.0)),
                                  width: cropW, height: cropH)

            scoredList.append(VirtualCropZoomScore(
                zoom: z,
                totalScore: totalScore,
                focalSaliencyDensity: focalDensityScore,
                edgeClutterRemovalGain: clutterRemovalGain,
                subjectIntegrityPenalty: integrityPenalty,
                momentumBonus: momentumBonus,
                virtualCropRect: cropRect,
                rationale: rationale
            ))
        }

        let sorted = scoredList.sorted { $0.totalScore > $1.totalScore }
        let winning = sorted.first ?? scoredList[0]

        let decisionRationale = String(format: "AI chọn Zoom %.1fx (Điểm: %.2f) — %@", winning.zoom, winning.totalScore, winning.rationale)

        return VirtualCropZoomDecision(
            optimalZoom: winning.zoom,
            winningScore: winning,
            allScores: sorted,
            rationale: decisionRationale
        )
    }

    /// Tính toán đầy đủ kết quả căn chỉnh bố cục động kèm mức Zoom tối ưu và Pre-Zoom Target Projection
    public func evaluateFramingResult(
        anchor: CGPoint,
        subjectRect: CGRect,
        category: NeuralSubjectCategory,
        gaze: CGFloat,
        sceneType: DetectedSceneType,
        currentZoom: CGFloat,
        availableZooms: [CGFloat] = [1.0, 2.0, 3.0],
        horizonY: CGFloat? = nil,
        activeRule: CompositionRule? = nil,
        sceneEvidence: SceneCompositionEvidence? = nil,
        pixelBuffer: CVPixelBuffer? = nil,
        iso: Float? = nil,
        exposureDuration: Double? = nil,
        aperture: Float? = nil
    ) -> FramingTargetResult {
        // Bước 1: Đánh giá giả thuyết bố cục tìm điểm mạnh P_grid*
        let (winningHypothesis, _) = evaluateHypotheses(
            anchor: anchor,
            subjectRect: subjectRect,
            category: category,
            gaze: gaze,
            sceneType: sceneType,
            currentZoom: currentZoom,
            horizonY: horizonY,
            activeRule: activeRule
        )

        // Bước 2: Đánh giá đấu loại khung cắt ảo tìm mức Zoom tối ưu Z*
        let evidence = sceneEvidence ?? SceneCompositionEvidence(
            primarySubjectRect: subjectRect,
            focalAnchorPoint: anchor,
            focalCategory: category,
            focalSaliencyRatio: 0.50,
            edgeClutterScore: 0.0,
            detectedScene: sceneType,
            detectedHorizonY: horizonY,
            timestamp: CACurrentMediaTime()
        )

        let zoomDecision = evaluateVirtualCropZooms(
            evidence: evidence,
            currentDisplayZoom: currentZoom,
            availableZooms: availableZooms,
            winningGridPoint: winningHypothesis.gridPoint
        )

        let optimalZoom = zoomDecision.optimalZoom

        // Bước 3: Sửa Lỗi 4 - Tính Target với Pre-Zoom Target Projection (Bù tỷ lệ k = Z* / currentZoom)
        let k = max(0.5, optimalZoom / max(0.5, currentZoom))
        let finalTarget = calculateTargetPoint(anchor: anchor, gridPoint: winningHypothesis.gridPoint, relativeScale: k)

        let center = CGPoint(x: 0.5, y: 0.5)
        let dx = finalTarget.x - center.x
        let dy = finalTarget.y - center.y
        let distance = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        let isAligned = distance <= alignmentTolerance
        let score = max(0, min(1, 1 - Double(distance / 0.40)))

        // Bước 4: Trích xuất khung cắt ảo tương lai W(Z*) và tính toán Smart Scene Exposure EV*
        let futureCrop = SmartSceneExposureEngine.shared.calculateVirtualCropWindow(
            anchor: anchor,
            gridPoint: winningHypothesis.gridPoint,
            targetZoom: optimalZoom
        )
        let exposureDecision = SmartSceneExposureEngine.shared.evaluateExposure(
            pixelBuffer: pixelBuffer,
            virtualCrop: futureCrop,
            subjectRect: subjectRect,
            sceneContext: sceneType,
            iso: iso,
            exposureDuration: exposureDuration,
            aperture: aperture
        )

        let combinedGuide = winningHypothesis.rationale + " · " + zoomDecision.rationale + " · " + exposureDecision.rationale

        return FramingTargetResult(
            targetPoint: finalTarget,
            currentCenter: center,
            offsetVector: CGVector(dx: dx, dy: dy),
            distance: distance,
            angleDegrees: angle < 0 ? angle + 360 : angle,
            alignmentScore: score,
            isAligned: isAligned,
            recommendedZoomFactor: optimalZoom,
            optimalRule: winningHypothesis.rule,
            guideDescription: combinedGuide,
            recommendedEVBias: exposureDecision.recommendedEVBias,
            lightingScene: exposureDecision.sceneType.rawValue,
            lightingRationale: exposureDecision.rationale
        )
    }

    public func resetHysteresis() {
        stateLock.lock()
        defer { stateLock.unlock() }
        activeWinningRule = .ruleOfThirds
        activeWinningGridPoint = CGPoint(x: 0.382, y: 0.382)
        lastWinningScore = 0.5
        hysteresisTracker.reset()
    }
}
