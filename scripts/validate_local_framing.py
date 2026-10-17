"""Reference geometry and source-contract checks for the local AI path.

These legacy checks do not execute Swift or replace an Xcode/device build.
Production composition geometry/rendering is exercised by CompositionPlanningRegression.swift.
"""
from __future__ import annotations

import math
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "AISmartFramingCamera"
COMPOSITION = (ROOT / "Services/CompositionCalculator.swift").read_text(encoding="utf-8")
PLANNER = (ROOT / "Services/CompositionPlanning.swift").read_text(encoding="utf-8")
SPATIAL = (ROOT / "Services/SpatialTrackingEngine.swift").read_text(encoding="utf-8")
NEURAL = (ROOT / "Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
VM = (ROOT / "ViewModels/CameraViewModel.swift").read_text(encoding="utf-8")
READINESS = (ROOT / "Services/CaptureReadinessPolicy.swift").read_text(encoding="utf-8")
VISION = (ROOT / "Services/VisionFramingEngine.swift").read_text(encoding="utf-8")
YOLO = (ROOT / "Services/YOLODetectionEngine.swift").read_text(encoding="utf-8")
workflow_path = ROOT.parent / ".github/workflows/ios-build.yml"
WORKFLOW = workflow_path.read_text(encoding="utf-8") if workflow_path.exists() else None
bundle_path = ROOT.parent / "scripts/verify_model_bundle.py"
BUNDLE_CHECK = bundle_path.read_text(encoding="utf-8") if bundle_path.exists() else None


def aim_x(subject_x: float, desired_x: float, fx: float, zoom_ratio: float) -> float:
    subject_angle = math.atan((subject_x - 0.5) / fx)
    desired_angle = math.atan((desired_x - 0.5) / (fx * zoom_ratio))
    return 0.5 + fx * math.tan(subject_angle - desired_angle)


class LocalFramingTests(unittest.TestCase):
    def test_subject_to_aim_conversion(self):
        subject, desired, fx, ratio = 0.66, 0.38, 0.75, 2.0
        aim = aim_x(subject, desired, fx, ratio)
        self.assertGreater(aim, subject)
        camera_turn = math.atan((aim - 0.5) / fx)
        final_subject = 0.5 + fx * ratio * math.tan(
            math.atan((subject - 0.5) / fx) - camera_turn)
        self.assertAlmostEqual(final_subject, desired, places=9)
        self.assertIn("simd_quatd(from: future.deviceRay(at: destination)", PLANNER)
        self.assertIn("trackedPoint: plan.subjectPoint, pinnedGuideRay: plan.aimWorldRay", VM)
        self.assertIn("subjectPoint: hero.trackingPoint ?? proposal.subjectPoint", NEURAL)
        self.assertIn("group.trackingPoint = hero.eyePosition ?? hero.center", NEURAL)

    def test_pan_right_moves_guide_left(self):
        original = aim_x(0.66, 0.38, 0.75, 1.0)
        turn = math.atan((original - 0.5) / 0.75)
        pan_right = 0.10
        projected = 0.5 + 0.75 * math.tan(turn - pan_right)
        self.assertLess(projected, original)
        self.assertIn("worldRay = guideFromSubject.act(corrected)", SPATIAL)
        self.assertIn("let ray = subjectWorldRay ?? worldRay", SPATIAL)

    def test_zoom_crop_rejects_cut_subject_and_companions(self):
        def crop(box, center, ratio):
            return (0.5 + (box[0] - center) * ratio,
                    0.5 + (box[1] - center) * ratio)
        subject = crop((0.48, 0.60), 0.55, 2.0)
        face = crop((0.87, 0.94), 0.55, 2.0)
        self.assertGreaterEqual(subject[0], 0.035)
        self.assertLessEqual(subject[1], 0.965)
        self.assertGreater(face[1], 0.975)
        self.assertIn("protectedRects.allSatisfy", PLANNER)
        self.assertIn("safe(projected, margin: 0.035)", COMPOSITION)

    def test_lens_change_requires_real_frame_and_calibration(self):
        self.assertIn("latestOpticalFrameTimestamp >", VM)
        self.assertIn("hasSettledZoomEvidence(since: settledAt)", VM)
        self.assertIn("opticalTimestamp > reachedAt + 0.05", READINESS)
        self.assertIn("latestOpticalCalibration?.isValid == true", VM)
        self.assertIn("latestOpticalBox", VM)
        self.assertIn("subjectBox: box", VISION)

    def test_missing_model_uses_native_detector(self):
        self.assertIn("guard let model, !prompts.isEmpty, !cancellation.isCancelled else { return [:] }", NEURAL)
        self.assertIn("physicalMemory >= 4_000_000_000", NEURAL)
        self.assertIn("VNGenerateAttentionBasedSaliencyImageRequest", NEURAL)
        self.assertIn("YOLODetectionEngine.shared.detectPhotographicObjects", NEURAL)
        quality = YOLO.split("func detectPhotographicObjects", 1)[1].split("private func detectWithVisionCoreML", 1)[0]
        self.assertIn("return detectObjects", quality)

    def test_ambiguous_result_requires_selection(self):
        self.assertIn("if result.count == 12 { break }", NEURAL)
        self.assertIn("first.plan.confidence >= first.plan.minimumAutoselectConfidence", VM)
        self.assertIn("localSuggestionRects = localEvidenceCandidates.map", VM)
        self.assertIn("reprojectSuggestion($0.boundingBox, from: source", VM)
        self.assertIn("allowsAutoCaptureForCurrentTarget = false", VM)
        self.assertIn("postZoomFaceCount = output.primaryFaceCount", VM)
        self.assertNotIn("consolidateLocalAnalysisAndLockTarget", VM)

    def test_cancel_capture_during_zoom_ramp(self):
        zoom = VM.split("public func triggerZoomRevealAnimation", 1)[1].split(
            "public func cancelAIZoomForGesture", 1)[0]
        self.assertNotIn("displayZoom = targetZoom", zoom)
        self.assertNotIn("currentZoom = targetDeviceZoom", zoom)
        self.assertIn("zoomAwaitingVerification = true", zoom)
        self.assertIn("autoCaptureTask?.cancel()", VM)
        self.assertIn("cameraService.cancelZoomRamp()", VM)
        self.assertIn("!self.zoomAwaitingVerification && self.zoomVerified", VM)
        self.assertIn("settledAt: manualZoomSettledAt", VM)
        self.assertIn("timestamp > settledAt + 0.05", READINESS)
        self.assertIn("CaptureReadinessPolicy.hasOpticalLock", VM)
        self.assertIn("(0...0.45).contains(now - timestamp)", READINESS)

    def test_visible_aim_and_shutter_share_the_projection(self):
        self.assertIn("trackedPoint: plan.subjectPoint, pinnedGuideRay: plan.aimWorldRay", VM)
        self.assertIn("localCompositionAim = aim", VM)
        self.assertIn("let aim = compositionAlignmentPoint(fallback: point)", VM)
        overlay = (ROOT / "Views/ARFramingOverlayView.swift").read_text(encoding="utf-8")
        self.assertEqual(overlay.count("let targetPoint = viewModel.viewfinderTargetPoint"), 2)
        self.assertNotIn("localCompositionNeedsLevel", VM)

    def test_zoom_cannot_fabricate_a_tracking_observation(self):
        verification = VM.split("private func verifyZoomAfterRamp", 1)[1].split(
            "private func restoreOriginalZoomAfterVerificationFailure", 1)[0]
        self.assertNotIn("latestOpticalFrameTimestamp =", verification)
        self.assertNotIn("latestOpticalBox =", verification)
        self.assertNotIn("latestOpticalPoint =", verification)
        self.assertIn("hasSettledZoomEvidence", verification)
        self.assertIn("CaptureReadinessPolicy.preservesSubject", VM)

    def test_moved_camera_gets_a_new_model_analysis(self):
        self.assertIn("CompositionSceneFreshness.accepts(sourcePose: source.pose", VM)
        self.assertIn("localAnalysisReplans < 2", VM)
        self.assertIn("self.beginLocalCompositionAnalysis(source: AITrackingSource", VM)
        self.assertIn("analysis.canAutoselectComposition", VM)

    def test_unobserved_camera_margins_are_verified_before_capture(self):
        self.assertIn("return await verifyNewlyObservedMargins()", VM)
        self.assertIn("plan.observedFraction < 0.9999", VM)
        self.assertIn("verifyFinalFraming(pixelBuffer: held.buffer", VM)
        self.assertIn("minimumPeople: plan.expectedPeople", VM)
        self.assertIn("generation == targetPinGeneration", VM)

    def test_pinning_cannot_override_manual_only_evidence(self):
        pin = VM.split("private func pinTargetAndStartMotion", 1)[1].split(
            "private func ", 1)[0]
        self.assertNotIn("allowsAutoCaptureForCurrentTarget = true", pin)

    def test_stronger_detector_has_matching_old_device_fallback_assets(self):
        if WORKFLOW is None or BUNDLE_CHECK is None:
            self.skipTest("Workflow and model-bundle validator were not supplied")
        for name in ("yolo12n", "yolo12s"):
            self.assertIn(name + ".pt", WORKFLOW)
            self.assertIn(name + ".mlmodelc", WORKFLOW)
            self.assertIn('"' + name + '"', YOLO)
            self.assertIn('"' + name + '"', BUNDLE_CHECK)
        self.assertIn("physicalMemory >= 6_000_000_000", YOLO)
        self.assertIn("Vision remains the fallback", YOLO)


if __name__ == "__main__":
    unittest.main(verbosity=2)
