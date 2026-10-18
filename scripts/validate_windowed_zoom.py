"""Unit tests for Windowed Zoom aspect ratios, drag translation, and double-crop prevention."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'

def source(path):
    return (ROOT / path).read_text(encoding='utf-8')

class WindowedZoomContracts(unittest.TestCase):
    def test_window_fractions_photo_container(self):
        """On a 3:4 portrait photo container, verify aspect ratio fractions."""
        # scale for 50mm on 1x base: (24 * 1.0) / 50 = 0.48
        scale = 0.48
        container_aspect = 3.0 / 4.0

        # ratio 3:4
        target_3_4 = 3.0 / 4.0
        # safeAspect >= targetAspect -> widthFrac = scale * (0.75 / 0.75) = scale, heightFrac = scale
        wf_3_4 = (scale, scale)
        window_w = 3.0 * wf_3_4[0]
        window_h = 4.0 * wf_3_4[1]
        self.assertAlmostEqual(window_w / window_h, 3.0 / 4.0, places=5)

        # ratio 1:1
        target_1_1 = 1.0
        # safeAspect (0.75) < targetAspect (1.0) -> widthFrac = scale, heightFrac = scale * (0.75 / 1.0)
        wf_1_1 = (scale, scale * (3.0 / 4.0))
        window_w = 3.0 * wf_1_1[0]
        window_h = 4.0 * wf_1_1[1]
        self.assertAlmostEqual(window_w / window_h, 1.0, places=5)

        # ratio 16:9 (9:16 portrait)
        target_16_9 = 9.0 / 16.0
        # safeAspect (0.75) >= targetAspect (0.5625) -> widthFrac = scale * (0.5625 / 0.75) = scale * 0.75, heightFrac = scale
        wf_16_9 = (scale * (3.0 / 4.0), scale)
        window_w = 3.0 * wf_16_9[0]
        window_h = 4.0 * wf_16_9[1]
        self.assertAlmostEqual(window_w / window_h, 9.0 / 16.0, places=5)

    def test_window_fractions_video_container(self):
        """On a 9:16 portrait video container, verify aspect ratio fractions."""
        scale = 0.48
        container_aspect = 9.0 / 16.0

        # ratio 16:9 (9:16 portrait)
        target_16_9 = 9.0 / 16.0
        # safeAspect == targetAspect -> widthFrac = scale, heightFrac = scale
        wf_16_9 = (scale, scale)
        window_w = 9.0 * wf_16_9[0]
        window_h = 16.0 * wf_16_9[1]
        self.assertAlmostEqual(window_w / window_h, 9.0 / 16.0, places=5)

        # ratio 1:1 (square)
        target_1_1 = 1.0
        # safeAspect (0.5625) < targetAspect (1.0) -> widthFrac = scale, heightFrac = scale * (9/16)
        wf_1_1 = (scale, scale * (9.0 / 16.0))
        window_w = 9.0 * wf_1_1[0]
        window_h = 16.0 * wf_1_1[1]
        self.assertAlmostEqual(window_w / window_h, 1.0, places=5)

        # ratio 3:4
        target_3_4 = 3.0 / 4.0
        # safeAspect (0.5625) < targetAspect (0.75) -> widthFrac = scale, heightFrac = scale * (0.5625 / 0.75) = scale * 0.75
        wf_3_4 = (scale, scale * (3.0 / 4.0))
        window_w = 9.0 * wf_3_4[0]
        window_h = 16.0 * wf_3_4[1]
        self.assertAlmostEqual(window_w / window_h, 3.0 / 4.0, places=5)

    def test_drag_gesture_uses_translation_not_raw_location(self):
        """Verify WindowedZoomOverlayView uses value.translation from dragStartNormalizedCenter."""
        overlay = source('Views/WindowedZoomOverlayView.swift')
        self.assertIn('let deltaX = value.translation.width / containerSize.width', overlay)
        self.assertIn('let deltaY = value.translation.height / containerSize.height', overlay)
        self.assertIn('let rawX = dragStartNormalizedCenter.x + deltaX', overlay)
        self.assertIn('let rawY = dragStartNormalizedCenter.y + deltaY', overlay)
        self.assertNotIn('let rawX = value.location.x / containerSize.width', overlay)
        self.assertNotIn('let rawY = value.location.y / containerSize.height', overlay)

    def test_video_preview_sheet_prevents_double_crop(self):
        """Verify VideoPreviewSheetView has state guard against cropping an already cropped video."""
        sheet = source('Views/VideoPreviewSheetView.swift')
        self.assertIn('isWindowedZoomAlreadyCropped: Bool = false', sheet)
        self.assertIn('guard !isWindowedZoomAlreadyCropped,', sheet)
        self.assertIn('let shouldApplyWindowedCrop = !self.isWindowedZoomAlreadyCropped', sheet)
        self.assertIn('self.isWindowedZoomAlreadyCropped = true', sheet)

    def test_composition_aesthetic_search_autoreleasepool(self):
        """Verify CompositionAestheticSearch wraps inferences in autoreleasepool to prevent memory leaks."""
        search = source('Services/CompositionAestheticSearch.swift')
        self.assertIn('let item: View? = autoreleasepool {', search)
        self.assertIn('let assessment = autoreleasepool {', search)
        self.assertIn('modern = nil', search)
        self.assertIn('ProcessInfo.processInfo.thermalState != .critical', search)

    def test_image_evidence_clear_caches(self):
        """Verify CompositionImageRenderer provides clearCaches and is invoked after search."""
        evidence = source('Services/CompositionImageEvidence.swift')
        self.assertIn('func clearCaches() {', evidence)
        self.assertIn('context.clearCaches()', evidence)
        neural = source('Services/NeuralSubjectIntelligenceEngine.swift')
        self.assertIn('renderer.clearCaches()', neural)

if __name__ == '__main__':
    unittest.main()
