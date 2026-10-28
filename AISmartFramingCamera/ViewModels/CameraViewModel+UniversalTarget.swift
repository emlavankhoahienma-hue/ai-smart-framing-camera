import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation
import SwiftUI

extension CameraViewModel {
    
    /// Kích hoạt chuỗi phân tích vạn vật không gò bó (Universal Target T* -> Zoom Z* -> Bù sáng EV*)
    @MainActor
    public func analyzeUniversalHeroComposition(pixelBuffer: CVPixelBuffer) {
        // Thu thập các nhận diện có sẵn (YOLO, Face, Pose)
        let knownDetections: [(rect: CGRect, label: String, confidence: Float)] = detectedSubjects.map { sub in
            let label = sub.category.rawValue
            return (sub.normalizedRect, label, Float(sub.confidence))
        }
        
        UniversalSalientTargetEngine.shared.analyzeFrame(
            pixelBuffer: pixelBuffer,
            knownDetections: knownDetections
        ) { [weak self] heroTarget in
            guard let self = self, let hero = heroTarget else { return }
            
            // Tính toán kế hoạch hợp nhất (Aesthetic Zoom + EV*)
            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            
            // Lấy histogram độ sáng hiện tại từ RealtimeHistogramEngine nếu có
            let histogram = RealtimeHistogramEngine.shared.latestLuminanceHistogram
            
            let unifiedPlan = AestheticZoomPlanner.shared.planUnifiedComposition(
                target: hero,
                frameSize: frameSize,
                currentZoom: self.displayZoom,
                luminanceHistogram: histogram
            )
            
            self.applyUnifiedAestheticPlan(unifiedPlan, heroTarget: hero)
        }
    }
    
    /// Áp dụng kế hoạch hợp nhất lên ViewModel và Kính ngắm HUD
    @MainActor
    public func applyUnifiedAestheticPlan(_ plan: UnifiedAestheticPlan, heroTarget: UniversalHeroTarget) {
        // 1. Cập nhật Target Aim Point (Điểm căn tâm tối ưu bố cục thay vì dính ở 0.5, 0.5)
        self.initialTargetPoint = plan.targetAimPoint
        self.currentTargetPoint = plan.targetAimPoint
        self.activeCompositionGuide = .ruleOfThirds
        
        // 2. Cập nhật mức Zoom tối ưu Z* được đề xuất
        self.pendingSuggestedZoom = plan.recommendedZoomFactor
        self.aiSuggestedZoom = plan.recommendedZoomFactor
        
        // 3. Khởi tạo bộ bám siêu nhẹ Local Search ROI (Lấy cảm hứng từ Doka Camera)
        LocalPatchTrackingOptimizer.shared.startTracking(with: heroTarget.boundingBox)
        
        // 4. Lưu bù sáng EV* dự kiến cho pha Hard Lock
        self.plannedEVBias = plan.targetExposureBias
        
        // 5. Cập nhật thông tin phân tích lên giao diện
        self.geminiExplanation = "Bố cục \(heroTarget.compositionAnchor.rawValue.capitalized) • \(plan.rationale)"
        self.activeModelUsedName = "Universal Saliency & Aesthetic Zoom"
    }
    
    /// Chuyển đổi mượt mà sang mức Zoom tối ưu và bù sáng EV* khi có Hard Lock
    @MainActor
    public func executeHardLockAestheticSequence() {
        guard isTargetLocked else { return }
        
        let targetZoom = pendingSuggestedZoom
        if isAutoZoomEnabled && abs(displayZoom - targetZoom) > 0.10 {
            self.applyAISuggestedZoom(targetZoom)
        }
        
        // Sau khi điều chỉnh zoom, áp dụng bù sáng môi trường EV* chống cháy sáng/tối mù
        self.applyPlannedEVBiasIfNeeded()
    }
}
