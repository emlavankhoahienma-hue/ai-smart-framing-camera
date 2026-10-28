import Foundation
import CoreGraphics
import AVFoundation

/// Kế hoạch bố cục hợp nhất 3 bước: Target + Mức Zoom + Độ sáng EV*
public struct UnifiedAestheticPlan: Sendable {
    public let targetAimPoint: CGPoint // Điểm căn tâm mục tiêu trên kính ngắm
    public let recommendedZoomFactor: CGFloat // Mức zoom tối ưu Z*
    public let targetOpticalLens: AVCaptureDevice.DeviceType // Ống kính phần cứng phù hợp nhất
    public let targetExposureBias: Float // Bù sáng môi trường EV* (-2.0 EV đến +2.0 EV)
    public let dynamicFillRatio: CGFloat // Tỷ lệ lấp đầy vàng đã áp dụng
    public let isAmputationSafe: Bool // Đã qua màng lọc chống cắt cụt khớp
    public let lightingCondition: AestheticLightingCondition
    public let rationale: String
    
    public init(
        targetAimPoint: CGPoint,
        recommendedZoomFactor: CGFloat,
        targetOpticalLens: AVCaptureDevice.DeviceType,
        targetExposureBias: Float,
        dynamicFillRatio: CGFloat,
        isAmputationSafe: Bool,
        lightingCondition: AestheticLightingCondition,
        rationale: String
    ) {
        self.targetAimPoint = targetAimPoint
        self.recommendedZoomFactor = recommendedZoomFactor
        self.targetOpticalLens = targetOpticalLens
        self.targetExposureBias = targetExposureBias
        self.dynamicFillRatio = dynamicFillRatio
        self.isAmputationSafe = isAmputationSafe
        self.lightingCondition = lightingCondition
        self.rationale = rationale
    }
}

public enum AestheticLightingCondition: String, Codable, Sendable {
    case normalBalanced
    case backlitSilhouette // Ngược sáng mạnh
    case highContrastHarshSun // Nắng gắt tương phản cao
    case lowLightNight // Thiếu sáng ban đêm
}

/// Bộ điều phối Zoom thẩm mỹ phi tùy tiện & Độ sáng môi trường (Aesthetic Zoom Planner)
public final class AestheticZoomPlanner: Sendable {
    public static let shared = AestheticZoomPlanner()
    
    private init() {}
    
    /// Tính toán kế hoạch hợp nhất (Target, Zoom Z*, Độ sáng EV*)
    public func planUnifiedComposition(
        target: UniversalHeroTarget,
        frameSize: CGSize,
        currentZoom: CGFloat,
        averageLuminance: Float = 0.5,
        availableLenses: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
    ) -> UnifiedAestheticPlan {
        let box = target.boundingBox
        let targetHeight = max(0.05, box.height)
        
        // 1. Tính toán Tỷ lệ lấp đầy động rho* biến thiên trong [0.20 .. 0.60]
        // Dựa trên Background Context Score và Edge Clutter Score
        let dynamicRho: CGFloat = self.calculateDynamicFillRatio(
            category: target.category,
            contextScore: CGFloat(target.backgroundContextScore),
            clutterScore: CGFloat(target.edgeClutterScore)
        )
        
        // 2. Tính mức Zoom thô theo tỷ lệ lấp đầy vàng
        var calculatedZoom = dynamicRho / targetHeight
        
        // Giới hạn trong khoảng an toàn quang học di động [0.5x .. 10.0x]
        calculatedZoom = max(0.5, min(10.0, calculatedZoom))
        
        // 3. Áp dụng Màng lọc No-Amputation (Chống cắt cụt khớp xương & Chân trời)
        let (safeZoom, isSafe) = self.enforceNoAmputationRule(
            candidateZoom: calculatedZoom,
            target: target,
            frameSize: frameSize
        )
        
        // 4. Lựa chọn Ống kính quang học vật lý tốt nhất của máy
        let selectedLens = self.resolveOptimalOpticalLens(for: safeZoom, availableLenses: availableLenses)
        
        // 5. Phân tích Độ sáng môi trường & Tính toán EV* tối ưu
        let (lightingCond, evBias) = self.calculateEnvironmentalEV(
            target: target,
            averageLuminance: averageLuminance
        )
        
        let rationale = "Dynamic rho=\(String(format: "%.2f", dynamicRho)), Zoom=\(String(format: "%.2fx", safeZoom)), EV=\(String(format: "%+.1f", evBias)) EV"
        
        return UnifiedAestheticPlan(
            targetAimPoint: target.targetAimPoint,
            recommendedZoomFactor: safeZoom,
            targetOpticalLens: selectedLens,
            targetExposureBias: evBias,
            dynamicFillRatio: dynamicRho,
            isAmputationSafe: isSafe,
            lightingCondition: lightingCond,
            rationale: rationale
        )
    }
    
    /// Tính toán tỷ lệ lấp đầy động rho*
    private func calculateDynamicFillRatio(
        category: UniversalSubjectCategory,
        contextScore: CGFloat,
        clutterScore: CGFloat
    ) -> CGFloat {
        // Mốc cơ bản theo thể loại
        var baseRho: CGFloat
        switch category {
        case .person:
            baseRho = 0.42
        case .animal:
            baseRho = 0.38
        case .architecture:
            baseRho = 0.50
        case .natureLandscape:
            baseRho = 0.30
        case .stillLifeObject, .unknownSalient:
            baseRho = 0.36
        }
        
        // Điều chỉnh động:
        // - Khi bối cảnh đẹp (contextScore cao) và ít rác mép (clutterScore thấp):
        //   Hạ rho* xuống (mở rộng góc rộng để giữ phong cảnh hùng vĩ)
        if contextScore > 0.70 && clutterScore < 0.30 {
            baseRho -= 0.14 // Giảm xuống 0.22 - 0.28
        }
        // - Khi rìa khung hình lộn xộn/nhiều rác (clutterScore cao):
        //   Nâng rho* lên để zoom cắt rác viền
        else if clutterScore > 0.60 {
            baseRho += 0.15 // Nâng lên 0.48 - 0.58
        }
        
        return max(0.20, min(0.60, baseRho))
    }
    
    /// Màng lọc No-Amputation (Bảo toàn giải phẫu khớp & Chân trời)
    private func enforceNoAmputationRule(
        candidateZoom: CGFloat,
        target: UniversalHeroTarget,
        frameSize: CGSize
    ) -> (safeZoom: CGFloat, isSafe: Bool) {
        var finalZoom = candidateZoom
        var isSafe = true
        
        // Nếu có toạ độ khớp xương
        if !target.keypointJoints.isEmpty {
            for joint in target.keypointJoints {
                // Kiểm tra xem khớp có bị đường biên cắt cúp đè trúng không
                let distToEdgeY = min(joint.y, 1.0 - joint.y)
                if distToEdgeY < 0.04 { // Nằm sát mép cắt nguy hiểm < 4%
                    finalZoom *= 0.85
                    isSafe = false
                    break
                }
            }
        }
        
        // Đối với phong cảnh / kiến trúc: Không để đỉnh chóp hoặc đường chân trời bị chạm mép
        if target.category == .architecture || target.category == .natureLandscape {
            let topMargin = target.boundingBox.minY
            if topMargin < 0.05 {
                finalZoom *= 0.88 // Lùi zoom để không cắt đỉnh tháp
                isSafe = false
            }
        }
        
        return (finalZoom, isSafe)
    }
    
    /// Ánh xạ ống kính quang học vật lý
    private func resolveOptimalOpticalLens(
        for zoomFactor: CGFloat,
        availableLenses: [AVCaptureDevice.DeviceType]
    ) -> AVCaptureDevice.DeviceType {
        if zoomFactor < 0.85 && availableLenses.contains(.builtInUltraWideCamera) {
            return .builtInUltraWideCamera // 0.5x
        } else if zoomFactor >= 3.2 && availableLenses.contains(.builtInTelephotoCamera) {
            return .builtInTelephotoCamera // 3x hoặc 5x
        } else {
            return .builtInWideAngleCamera // 1.0x hoặc 2.0x In-Sensor Quad-Bayer
        }
    }
    
    /// Tính toán độ sáng môi trường EV* chống cháy sáng và tối mù
    private func calculateEnvironmentalEV(
        target: UniversalHeroTarget,
        averageLuminance: Float
    ) -> (AestheticLightingCondition, Float) {
        if averageLuminance < 0.22 {
            return (.lowLightNight, +0.3)
        } else if averageLuminance > 0.72 {
            return (.highContrastHarshSun, -0.4)
        } else if target.backgroundContextScore > 0.75 && target.edgeClutterScore < 0.35 && averageLuminance > 0.50 {
            return (.backlitSilhouette, +0.7)
        } else {
            return (.normalBalanced, 0.0)
        }
    }
}
