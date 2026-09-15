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
        
        // Auto-Zoom evaluation based on subject bounding box scale
        let isGroupPhoto = detection.faceRectangles.count > 1
        if let dominantRect = detection.dominantSubjectRect {
            recommendedZoom = computeOptimalZoom(subjectRect: dominantRect, currentZoom: currentZoom, isGroup: isGroupPhoto)
        } else if let faceRect = detection.faceRectangles.first {
            recommendedZoom = computeOptimalZoom(subjectRect: faceRect, currentZoom: currentZoom, isGroup: isGroupPhoto)
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
        
        let subjectCenter = CGPoint(x: subject.midX, y: subject.midY)
        
        // 1. Chế độ chụp nhóm (Group Photo Framing)
        if detection.faceRectangles.count > 1 {
            let targetX: CGFloat = (subject.width > 0.42) ? 0.5 : (subjectCenter.x < 0.5 ? thirdsX[0] : thirdsX[1])
            let targetY: CGFloat = thirdsY[0]
            return (CGPoint(x: targetX, y: targetY), "Bố cục chụp nhóm: Giữ trọn các thành viên trong khung hình")
        }
        
        // 2. Chế độ chụp đơn thể với Không gian thở hướng nhìn (Gaze Lead Room)
        var targetX: CGFloat = subjectCenter.x < 0.5 ? thirdsX[0] : thirdsX[1]
        if detection.lookingDirection.dx > 0.10 {
            targetX = thirdsX[0] // Chủ thể nhìn sang phải -> Đặt chủ thể ở 1/3 bên trái để chừa khoảng thở bên phải
        } else if detection.lookingDirection.dx < -0.10 {
            targetX = thirdsX[1] // Chủ thể nhìn sang trái -> Đặt chủ thể ở 1/3 bên phải để chừa khoảng thở bên trái
        }
        
        // Căn chỉnh đường mắt (Eye Level) trực tiếp lên đường 1/3 trên
        let targetY: CGFloat = (detection.primaryEyePosition != nil || !detection.faceRectangles.isEmpty)
            ? thirdsY[0]
            : (subjectCenter.y < 0.5 ? thirdsY[0] : thirdsY[1])
            
        let advice = "Đặt mắt / chủ thể lên đường 1/3 phía trên"
        return (CGPoint(x: targetX, y: targetY), advice)
    }
    
    // MARK: - Golden Ratio Calculation (1:1.618)
    private func computeGoldenRatioTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        let goldX: [CGFloat] = [phiInverseRatio, phiRatio]
        let goldY: [CGFloat] = [phiInverseRatio, phiRatio]
        
        guard let subject = detection.dominantSubjectRect else {
            return (CGPoint(x: phiRatio, y: phiInverseRatio), "Căn chỉnh theo tỷ lệ vàng 1.618")
        }
        
        let subjectCenter = CGPoint(x: subject.midX, y: subject.midY)
        
        if detection.faceRectangles.count > 1 {
            let targetX: CGFloat = (subject.width > 0.42) ? 0.5 : (subjectCenter.x < 0.5 ? goldX[0] : goldX[1])
            let targetY: CGFloat = goldY[0]
            return (CGPoint(x: targetX, y: targetY), "Bố cục chụp nhóm tỷ lệ vàng")
        }

        var targetX = subjectCenter.x < 0.5 ? goldX[0] : goldX[1]
        
        if detection.lookingDirection.dx > 0.10 {
            targetX = goldX[0]
        } else if detection.lookingDirection.dx < -0.10 {
            targetX = goldX[1]
        }
        
        let targetY: CGFloat = (detection.primaryEyePosition != nil || !detection.faceRectangles.isEmpty)
            ? goldY[0]
            : (subjectCenter.y < 0.5 ? goldY[0] : goldY[1])
            
        let advice = "Căn chỉnh chủ thể vào giao điểm tỷ lệ vàng"
        return (CGPoint(x: targetX, y: targetY), advice)
    }
    
    // MARK: - Golden Spiral Calculation
    private func computeGoldenSpiralTarget(detection: SubjectDetectionResult) -> (CGPoint, String) {
        // Core vertex focus point of Fibonacci logarithmic spiral
        let spiralFocus = CGPoint(x: phiRatio, y: phiInverseRatio)
        return (spiralFocus, "Uốn lượn bố cục theo xoắn ốc Fibonacci")
    }
    
    // MARK: - Auto-Zoom Computation (Tối ưu độ phóng đại quang học mượt mà)
    private func computeOptimalZoom(subjectRect: CGRect, currentZoom: CGFloat, isGroup: Bool = false) -> CGFloat {
        if isGroup {
            // Chụp nhóm: Giữ góc rộng 1.0x - 1.2x để không ai bị mất góc
            return 1.0
        }
        let subjectArea = subjectRect.width * subjectRect.height
        
        if subjectArea < 0.025 {
            // Chủ thể ở xa: Zoom 2.5x nhẹ nhàng, tự nhiên
            return 2.5
        } else if subjectArea < 0.08 {
            // Cự ly trung bình: Zoom 2.0x chân dung chuẩn
            return 2.0
        } else if subjectArea < 0.18 {
            // Cự ly cận cảnh vừa: Zoom 1.5x
            return 1.5
        } else if subjectArea > 0.45 {
            // Chủ thể quá gần: Zoom 1.0x góc rộng
            return 1.0
        } else {
            return currentZoom
        }
    }
}
