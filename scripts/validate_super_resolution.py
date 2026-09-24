"""Portable checks for the super-resolution package.

These checks exercise the arithmetic and guard against known source regressions.
They do not compile Metal or replace an iPhone capture/colour test.
"""

from pathlib import Path
import math
import sys
import unittest


ROOT = Path(__file__).resolve().parent

def load_file(name: str) -> str:
    # Check current directory (package mode)
    p = ROOT / name
    if p.exists():
        return p.read_text(encoding="utf-8")
    # Check repo paths (workspace mode)
    repo_root = ROOT.parent
    for candidate in [
        repo_root / "AISmartFramingCamera" / "Services" / name,
        repo_root / "AISmartFramingCamera" / "ViewModels" / name,
        repo_root / "AISmartFramingCamera" / "Views" / name,
        repo_root / "AISmartFramingCamera" / "Models" / name,
    ]:
        if candidate.exists():
            return candidate.read_text(encoding="utf-8")
    raise FileNotFoundError(f"Could not find {name} in {ROOT} or repo subdirectories")

ENGINE = load_file("SuperResolutionRAWEngine.swift")
SHADERS = load_file("SuperResolutionMetalShaders.swift")
CAPTURE = load_file("CameraService.swift")
VIEW_MODEL = load_file("CameraViewModel.swift")



def decode_channel(value: float) -> float:
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def encode_channel(value: float) -> float:
    return value * 12.92 if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055


def blend_p3(anchor: float, candidates: list[tuple[float, float]]) -> float:
    weighted = 0.55 * decode_channel(anchor)
    weight = 0.55
    for pixel, contribution in candidates:
        weighted += contribution * decode_channel(pixel)
        weight += contribution
    return encode_channel(weighted / weight)


def predicted_bytes(width: int, height: int, scale: float, raw_bytes: int) -> float:
    pixels = width * height * scale * scale
    return pixels * 24 + width * height * 12 + raw_bytes + 150_000_000


def select_scale(width: int, height: int, ram: int, raw_bytes: int) -> float | None:
    ram_scale = 2.0 if ram >= 7_000_000_000 else (
        1.5 if ram >= 5_000_000_000 else (
            1.25 if ram >= 3_500_000_000 else 1.0))
    scale = max(1.0, min(ram_scale, math.sqrt(48_000_000 / (width * height))))
    budget = min(ram * 0.20, 1_700_000_000)
    while scale > 1.0 and predicted_bytes(width, height, scale, raw_bytes) > budget:
        scale = 1.5 if scale > 1.5 else (1.25 if scale > 1.25 else 1.0)
    return scale if predicted_bytes(width, height, scale, raw_bytes) <= budget else None


class SuperResolutionValidation(unittest.TestCase):
    def test_no_second_exposure_or_filmic_curve(self):
        self.assertEqual(ENGINE.count("rawFilter.exposure = 0"), 2)
        for forbidden in (
            "rawFilter.exposure = max(1.0",
            "applyAppleFilmicTone",
            "exposureGain",
            "avgLuma < 0.25",
        ):
            self.assertNotIn(forbidden, ENGINE + SHADERS)
        self.assertIn("linearize(rgb)", SHADERS)
        self.assertIn("encodeP3(linearRGB)", SHADERS)

    def test_brightness_and_highlight_preservation(self):
        for level in (0.02, 0.05, 0.18, 0.48, 0.90):
            self.assertAlmostEqual(blend_p3(level, [(level, 1.0)]), level, places=6)
        result = blend_p3(0.48, [(0.50, 0.9), (0.47, 0.5)])
        self.assertGreater(result, 0.47)
        self.assertLess(result, 0.51)
        dark = blend_p3(0.07, [(0.08, 0.8)])
        self.assertGreater(dark, 0.07)
        self.assertLess(dark, 0.09)

    def test_motion_sign_and_fractional_registration(self):
        self.assertIn("float2 source = p + vector.xy", SHADERS)
        self.assertNotIn("p - vector.xy", SHADERS)
        self.assertIn("patchError(anchor, candidate, center", SHADERS)
        self.assertIn("float2 residual = source - rounded", SHADERS)
        self.assertIn("float kalmanGain = priorVariance / (priorVariance + measurementVariance)", SHADERS)
        # An anchor pixel at x maps to candidate x + 0.4 when the camera
        # image shifted by +0.4. Reversing the sign doubles the error.
        anchor_x, offset = 10.0, 0.4
        self.assertAlmostEqual((anchor_x + offset) - 10.4, 0.0)
        self.assertAlmostEqual((anchor_x - offset) - 10.4, -0.8)

    def test_tremor_projection_and_sample_diversity(self):
        focal = 0.5 / math.tan(math.radians(65 / 2)) * 3024
        shift = focal * math.tan(0.0004)
        self.assertGreater(shift, 0.5)
        self.assertLess(shift, 1.5)
        phases = set()
        for i in range(8):
            time = i * 0.025
            x = 0.7 * math.sin(2 * math.pi * 9.5 * time)
            y = 0.7 * math.cos(2 * math.pi * 9.5 * time)
            phases.add((int((x % 1.0) >= 0.5), int((y % 1.0) >= 0.5)))
        self.assertGreaterEqual(len(phases), 3)

    def test_deghost_suppresses_moving_subject(self):
        def weight(luma_difference: float, color_difference: float) -> float:
            return math.exp(-(luma_difference ** 2) / 0.015
                            -(color_difference ** 2) / 0.035)
        self.assertGreater(weight(0.02, 0.02), 0.95)
        self.assertLess(weight(0.5, 0.5), 1e-8)
        self.assertIn("float deghost = exp(", SHADERS)

    def test_memory_budget_and_fallback(self):
        width, height = 3024, 4032
        for ram, raw_bytes in (
            (3_000_000_000, 160_000_000),
            (4_000_000_000, 160_000_000),
            (6_000_000_000, 160_000_000),
            (8_000_000_000, 80_000_000),
            (8_000_000_000, 240_000_000),
        ):
            scale = select_scale(width, height, ram, raw_bytes)
            if scale is not None:
                self.assertLessEqual(predicted_bytes(width, height, scale, raw_bytes),
                                     min(ram * 0.20, 1_700_000_000))
        self.assertGreater(select_scale(width, height, 8_000_000_000, 80_000_000), 1.98)
        self.assertIsNone(select_scale(6048, 8064, 4_000_000_000, 350_000_000))
        self.assertIn("if predictedBytes(scale) > budget", ENGINE)
        self.assertIn("var anchorTexture: MTLTexture?", ENGINE)
        self.assertNotIn("var textures: [MTLTexture] = []", ENGINE)

    def test_capture_uses_frame_time_and_one_payload(self):
        self.assertIn("pose(at: timestamp)", CAPTURE)
        self.assertIn("CMSyncConvertTime(", CAPTURE)
        self.assertIn("pixelBuffer: nil", CAPTURE)
        self.assertIn("photoSettings.flashMode = .off", CAPTURE)
        self.assertIn("else if let payload = photo.fileDataRepresentation()", CAPTURE)
        self.assertIn("didFinishCaptureFor resolvedSettings", CAPTURE)
        self.assertIn("svc.dispatchSingleBurstFrame(delegate: self)", CAPTURE)
        self.assertIn("selectedPhotoFormat == .dng && item.rawPhotoData == nil ? .heif", VIEW_MODEL)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SuperResolutionValidation)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
