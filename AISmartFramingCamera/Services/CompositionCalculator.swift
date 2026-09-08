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
    public let aestheticScore: Double        // 1.0 - 10.0 score based on photographic harmony
    
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
        aestheticScore: Double = 8.5
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
        self.aestheticScore = aestheticScore
    }
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
        
        // Auto-Zoom evaluation based on subject bounding box scale
        if let dominantRect = detection.dominantSubjectRect {
            recommendedZoom = computeOptimalZoom(subjectRect: dominantRect, currentZoom: currentZoom)
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
        
        // Aesthetic Scoring (Candidate Aesthetic Ranking 1.0 - 10.0)
        let aestheticScore = computeAestheticScore(
            targetPoint: targetPoint,
            detection: detection,
            rule: resolvedRule
        )
        
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
            guideDescription: advice,
            aestheticScore: aestheticScore
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
    
    // MARK: - Determining Visual Focal Anchor
    private func determineFocalPoint(detection: SubjectDetectionResult) -> CGPoint {
        if let eye = detection.primaryEyePosition {
            return eye
        }
        if let face = detection.faceRectangles.first {
            return CGPoint(x: face.midX, y: face.minY + face.height * 0.35)
        }
        if let subject = detection.dominantSubjectRect {
            return CGPoint(x: subject.midX, y: subject.midY)
        }
        if let attention = detection.attentionCentroid {
            return attention
        }
        if let objectness = detection.objectnessCentroid {
            return objectness
        }
        return CGPoint(x: 0.5, y: 0.5)
    }
    
    // MARK: - Rule of Thirds Calculation
    private func computeRuleOfThirdsTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let thirdsX: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        let thirdsY: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]
        
        let focal = determineFocalPoint(detection: detection)
        
        // 1. Leading Room / Looking Room:
        // If subject is gazing right, place subject on the left third to provide open leading space on the right.
        var targetX: CGFloat = focal.x < 0.5 ? thirdsX[0] : thirdsX[1]
        if detection.lookingDirection.dx > 0.08 {
            targetX = thirdsX[0] // Look right -> place left
        } else if detection.lookingDirection.dx < -0.08 {
            targetX = thirdsX[1] // Look left -> place right
        }
        
        // 2. Headroom & Eye-level alignment:
        var targetY: CGFloat = thirdsY[0]
        var advice = "Đặt mắt / chủ thể lên đường 1/3 phía trên"
        
        if let face = detection.faceRectangles.first {
            // Calculate ideal headroom based on face size:
            // Large face (close-up) -> tighter headroom (~10-12%)
            // Small face (full shot) -> generous headroom (~15-18%)
            let idealHeadroom = max(0.09, min(0.18, 0.20 - face.height * 0.25))
            let currentHeadroom = max(0.0, face.minY)
            let headroomDelta = idealHeadroom - currentHeadroom
            
            // Adjust target Y to achieve ideal headroom
            targetY = max(0.20, min(0.45, thirdsY[0] + headroomDelta * 0.5))
            advice = "Căn đỉnh đầu chuẩn khoảng thở (Headroom \(Int(idealHeadroom * 100))%)"
        } else if detection.detectedScene.isSkyOrInfiniteHorizon {
            // Horizon: place at upper 1/3 if emphasizing ground, or lower 1/3 if emphasizing sky
            targetY = focal.y < 0.5 ? thirdsY[0] : thirdsY[1]
            advice = "Căn đường chân trời theo đường 1/3"
        } else {
            targetY = focal.y < 0.5 ? thirdsY[0] : thirdsY[1]
        }
        
        return (CGPoint(x: targetX, y: targetY), advice)
    }
    
    // MARK: - Golden Ratio Calculation (1:1.618)
    private func computeGoldenRatioTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let goldX: [CGFloat] = [phiInverseRatio, phiRatio] // 0.382, 0.618
        let goldY: [CGFloat] = [phiInverseRatio, phiRatio] // 0.382, 0.618
        
        let focal = determineFocalPoint(detection: detection)
        
        var targetX = focal.x < 0.5 ? goldX[0] : goldX[1]
        if detection.lookingDirection.dx > 0.08 {
            targetX = goldX[0] // Look right -> golden left
        } else if detection.lookingDirection.dx < -0.08 {
            targetX = goldX[1] // Look left -> golden right
        }
        
        var targetY = goldY[0]
        var advice = "Căn chỉnh chủ thể vào giao điểm tỷ lệ vàng"
        
        if let face = detection.faceRectangles.first {
            let idealHeadroom = max(0.09, min(0.18, 0.20 - face.height * 0.25))
            let currentHeadroom = max(0.0, face.minY)
            let headroomDelta = idealHeadroom - currentHeadroom
            targetY = max(0.22, min(0.48, goldY[0] + headroomDelta * 0.5))
            advice = "Giao điểm tỷ lệ vàng • Chuẩn khoảng thở chân dung"
        } else {
            targetY = focal.y < 0.5 ? goldY[0] : goldY[1]
        }
        
        return (CGPoint(x: targetX, y: targetY), advice)
    }
    
    // MARK: - Golden Spiral Calculation
    private func computeGoldenSpiralTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let focal = determineFocalPoint(detection: detection)
        let spiralX = focal.x < 0.5 ? phiInverseRatio : phiRatio
        let spiralY = phiInverseRatio
        return (CGPoint(x: spiralX, y: spiralY), "Uốn lượn bố cục theo xoắn ốc Fibonacci")
    }
    
    // MARK: - Auto-Zoom Computation
    private func computeOptimalZoom(subjectRect: CGRect, currentZoom: CGFloat) -> CGFloat {
        let subjectArea = subjectRect.width * subjectRect.height
        
        if subjectArea < 0.04 {
            // Subject is very far
            return min(5.0, max(currentZoom, 3.0))
        } else if subjectArea < 0.12 {
            // Medium shot, recommend 2x or 2.3x
            return 2.0
        } else if subjectArea > 0.50 {
            // Subject too close, zoom out
            return 1.0
        } else {
            return currentZoom
        }
    }
    
    // MARK: - Deterministic Aesthetic Scoring (1.0 to 10.0)
    public func computeAestheticScore(
        targetPoint: CGPoint,
        detection: SubjectDetectionResult,
        rule: CompositionRule
    ) -> Double {
        let focal = determineFocalPoint(detection: detection)
        
        // 1. Rule Adherence Score (0 - 10): Distance from visual focal point to ideal target
        let dx = focal.x - targetPoint.x
        let dy = focal.y - targetPoint.y
        let dist = sqrt(dx * dx + dy * dy)
        let ruleAdherenceScore = 10.0 * exp(-4.0 * Double(dist * dist))
        
        // 2. Visual Balance Score (0 - 10): Weighs visual mass distribution
        let centerDist = sqrt(pow(focal.x - 0.5, 2) + pow(focal.y - 0.5, 2))
        let balanceScore: Double
        if rule == .centerSymmetry {
            balanceScore = 10.0 * max(0.0, 1.0 - Double(centerDist) * 3.0)
        } else {
            // For thirds and golden ratio, balanced offset from center is desirable (~0.15 - 0.25)
            let optimalOffset: CGFloat = 0.20
            let offsetError = abs(centerDist - optimalOffset)
            balanceScore = 10.0 * max(0.0, 1.0 - Double(offsetError) * 3.5)
        }
        
        // 3. Headroom Score (0 - 10)
        let headroomScore: Double
        if let face = detection.faceRectangles.first {
            let idealHeadroom = max(0.09, min(0.18, 0.20 - face.height * 0.25))
            let currentHeadroom = max(0.0, face.minY)
            let err = abs(currentHeadroom - idealHeadroom)
            headroomScore = 10.0 * max(0.0, 1.0 - Double(err / 0.15))
        } else {
            headroomScore = 9.0 // Non-portrait scenes default to harmonious score
        }
        
        // 4. Leading Room Score (0 - 10)
        let leadingRoomScore: Double
        if abs(detection.lookingDirection.dx) > 0.08 {
            let lookingRight = detection.lookingDirection.dx > 0
            let placedLeft = targetPoint.x < 0.5
            if (lookingRight && placedLeft) || (!lookingRight && !placedLeft) {
                leadingRoomScore = 9.6 // Perfect looking space
            } else {
                leadingRoomScore = 5.5 // Cramped gaze against frame edge
            }
        } else {
            leadingRoomScore = 8.8
        }
        
        // 5. Scene Simplicity Score (0 - 10): Fewer distracting salient clusters = cleaner composition
        let clutterCount = detection.saliencyPoints.count
        let simplicityScore: Double
        if clutterCount <= 2 {
            simplicityScore = 9.5
        } else if clutterCount <= 5 {
            simplicityScore = 8.6
        } else if clutterCount <= 8 {
            simplicityScore = 7.4
        } else {
            simplicityScore = 6.2
        }
        
        // Weighted composite aesthetic formula
        let rawScore = (
            ruleAdherenceScore * 0.35 +
            balanceScore * 0.25 +
            headroomScore * 0.20 +
            leadingRoomScore * 0.10 +
            simplicityScore * 0.10
        )
        
        // Clamp to a natural professional range (6.0 - 9.8) and round to 1 decimal place
        let clampedScore = max(6.0, min(9.8, rawScore))
        return (clampedScore * 10.0).rounded() / 10.0
    }
}
