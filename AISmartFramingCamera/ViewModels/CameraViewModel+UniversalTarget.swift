import Foundation

import CoreGraphics

import CoreMedia

import AVFoundation

import SwiftUI

extension CameraViewModel {

    /// Kích hoạt chuỗi phân tích vạn vật không gò bó (Universal Target T* -> Zoom Z* -> Bù sáng EV*)

    @MainActor

    public func analyzeUniversalHeroComposition(pixelBuffer: CVPixelBuffer) {

        // Thu thập các nhận diện có sẵn (YOLO, Face, Pose) từ ViewModel

        var knownDetections: [(rect: CGRect, label: String, confidence: Float)] = []

        for r in self.detectedSubjectRects {

            knownDetections.append((r, "subject", 0.90))

        }

        for f in self.detectedFaceRects {

            knownDetections.append((f, "person", 0.95))

        }

        UniversalSalientTargetEngine.shared.analyzeFrame(

            pixelBuffer: pixelBuffer,

            knownDetections: knownDetections

        ) { [weak self] heroTarget in

            guard let self = self, let hero = heroTarget else { return }

            // Tính toán kế hoạch hợp nhất (Aesthetic Zoom + EV*)

            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

            // Lấy độ sáng trung bình hiện tại từ RealtimeHistogramEngine

            let currentLuma = RealtimeHistogramEngine.shared.averageLuminance

            let unifiedPlan = AestheticZoomPlanner.shared.planUnifiedComposition(

                target: hero,

                frameSize: frameSize,

                currentZoom: self.displayZoom,

                averageLuminance: currentLuma

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

        self.activeCompositionRule = .ruleOfThirds

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

            self.postZoomFocusSettledTimestamp = CACurrentMediaTime() + 0.45

        }

        // Sau khi điều chỉnh zoom, áp dụng bù sáng môi trường EV* chống cháy sáng/tối mù

        self.applyPlannedEVBiasIfNeeded()

    }

}

