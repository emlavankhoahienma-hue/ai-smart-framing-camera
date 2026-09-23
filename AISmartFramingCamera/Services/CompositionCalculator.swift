import Foundation
import CoreGraphics

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
            recommendedZoom = computeOptimalZoom(subjectRect: dominantRect, currentZoom: currentZoom,
                isGroup: isGroupPhoto, scene: detection.detectedScene,
                category: detection.dominantSubjectCategory)
        } else if let faceRect = detection.faceRectangles.first {
            recommendedZoom = computeOptimalZoom(subjectRect: faceRect, currentZoom: currentZoom,
                isGroup: isGroupPhoto, scene: detection.detectedScene, category: .face)
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
        scene: DetectedSceneType = .general,
        category: NeuralSubjectCategory = .general
    ) -> CGFloat {
        if isGroup || scene == .landscape || scene == .sky || scene == .water {
            return 1.0
        }
        guard subjectRect.width > 0, subjectRect.height > 0,
              subjectRect.minX >= 0, subjectRect.minY >= 0,
              subjectRect.maxX <= 1, subjectRect.maxY <= 1,
              currentZoom.isFinite, currentZoom > 0 else { return 1.0 }

        // Zoom is centered on the optical axis. Bound the recommendation by
        // both desired subject size and room to every edge, so a small subject
        // near the edge cannot be cut off by an automatic lens change.
        let desiredHeight: CGFloat
        switch category {
        case .human: desiredHeight = 0.70
        case .face: desiredHeight = 0.34
        case .animal: desiredHeight = 0.55
        case .foregroundObject: desiredHeight = 0.46
        case .general: desiredHeight = scene == .portrait ? 0.62 : 0.48
        }
        let desiredWidth: CGFloat = category == .face ? 0.44 : 0.65
        let sizeScale = min(desiredHeight / subjectRect.height,
                            desiredWidth / subjectRect.width)
        let extentX = max(abs(subjectRect.minX - 0.5), abs(subjectRect.maxX - 0.5))
        let extentY = max(abs(subjectRect.minY - 0.5), abs(subjectRect.maxY - 0.5))
        let safeScale = min(0.46 / max(extentX, 0.001),
                            0.46 / max(extentY, 0.001))
        let requested = min(3.0, currentZoom * min(sizeScale, safeScale))
        if requested < 1.75 { return 1.0 }
        if requested < 2.75 { return 2.0 }
        return 3.0
    }
}
