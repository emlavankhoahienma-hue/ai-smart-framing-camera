"""Reference geometry and source-contract checks for the local AI path.

These tests do not execute Swift or replace an Xcode/device build.
"""
from __future__ import annotations

import math
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1] / "AISmartFramingCamera"
COMPOSITION = (ROOT / "Services/CompositionCalculator.swift").read_text(encoding="utf-8")
SPATIAL = (ROOT / "Services/SpatialTrackingEngine.swift").read_text(encoding="utf-8")
NEURAL = (ROOT / "Services/NeuralSubjectIntelligenceEngine.swift").read_text(encoding="utf-8")
VM = (ROOT / "ViewModels/CameraViewModel.swift").read_text(encoding="utf-8")
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
        self.assertIn("simd_quatd(from: future.deviceRay(at: d), to: subjectRay)", COMPOSITION)
        self.assertIn("trackedPoint: plan.subjectPoint, pinnedGuideRay: plan.aimWorldRay", VM)

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
        self.assertIn("guard companionsSafe else { continue }", COMPOSITION)
        self.assertIn("safe(projected, margin: 0.035)", COMPOSITION)

    def test_lens_change_requires_real_frame_and_calibration(self):
        self.assertIn("latestOpticalFrameTimestamp >", VM)
        self.assertIn("(reachedAt ?? .infinity) + 0.05", VM)
        self.assertIn("latestOpticalCalibration?.isValid == true", VM)
        self.assertIn("latestOpticalBox", VM)
        self.assertIn("subjectBox: box", VISION)

    def test_missing_model_uses_native_detector(self):
        self.assertIn("guard let model, !prompts.isEmpty else { return candidates }", NEURAL)
        self.assertIn("physicalMemory >= 4_000_000_000", NEURAL)
        self.assertIn("VNGenerateAttentionBasedSaliencyImageRequest", NEURAL)
        self.assertIn("YOLODetectionEngine.shared.detectObjects", NEURAL)

    def test_ambiguous_result_requires_selection(self):
        self.assertIn("if distinct.count == 12 { break }", VM)
        self.assertIn("best.confidence >= max(0.72, measuredThreshold)", VM)
        self.assertIn("localSuggestionRects = localEvidenceCandidates.map", VM)
        self.assertIn("reprojectSuggestion($0.boundingBox, from: source", VM)
        self.assertIn("allowsAutoCaptureForCurrentTarget = false", VM)
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
        self.assertIn("trackingQuality == .locked", VM)

    def test_stronger_detector_has_matching_old_device_fallback_assets(self):
        if WORKFLOW is None or BUNDLE_CHECK is None:
            self.skipTest("Workflow and model-bundle validator were not supplied")
        for name in ("yolo11n", "yolo11s"):
            self.assertIn(name + ".pt", WORKFLOW)
            self.assertIn(name + ".mlmodelc", WORKFLOW)
            self.assertIn('"' + name + '"', YOLO)
            self.assertIn('"' + name + '"', BUNDLE_CHECK)
        self.assertIn("physicalMemory >= 6_000_000_000", YOLO)
        self.assertIn("Vision remains the fallback", YOLO)


if __name__ == "__main__":
    unittest.main(verbosity=2)
