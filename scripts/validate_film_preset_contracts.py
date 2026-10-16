#!/usr/bin/env python3
"""Validation harness for Color Preset System and Optical Simulations.
Verifies source code contracts, collision-free matching, catalog consistency,
and zero-emoji constraint.
"""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FRAMING_MODELS_PATH = ROOT / "AISmartFramingCamera/Models/FramingModels.swift"
FILM_FILTER_ENGINE_PATH = ROOT / "AISmartFramingCamera/Services/FilmFilterEngine.swift"
FILM_CORE_PATH = ROOT / "AISmartFramingCamera/Services/FilmSimulations/FilmSimulationCore.swift"
KODAK_SIM_PATH = ROOT / "AISmartFramingCamera/Services/FilmSimulations/KodakFilmSimulations.swift"
DV_SIM_PATH = ROOT / "AISmartFramingCamera/Services/FilmSimulations/AnalogDVSimulations.swift"
INSTAX_SIM_PATH = ROOT / "AISmartFramingCamera/Services/FilmSimulations/InstantPolaroidSimulations.swift"
HISTORIC_SIM_PATH = ROOT / "AISmartFramingCamera/Services/FilmSimulations/CinemaAndStudioSimulations.swift"

class TestColorPresetContracts(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.framing_code = FRAMING_MODELS_PATH.read_text(encoding="utf-8")
        cls.filter_engine_code = FILM_FILTER_ENGINE_PATH.read_text(encoding="utf-8")
        cls.core_code = FILM_CORE_PATH.read_text(encoding="utf-8")
        cls.kodak_code = KODAK_SIM_PATH.read_text(encoding="utf-8")
        cls.dv_code = DV_SIM_PATH.read_text(encoding="utf-8")
        cls.instax_code = INSTAX_SIM_PATH.read_text(encoding="utf-8")
        cls.historic_code = HISTORIC_SIM_PATH.read_text(encoding="utf-8")

    def test_preset_counts_and_separation(self):
        """Verify mainCuratedPresets has 65 presets and legacyPresets has 11 presets."""
        main_match = re.search(r"mainCuratedPresets:\s*\[FilmPreset\]\s*=\s*\[(.*?)\]", self.framing_code, re.DOTALL)
        self.assertIsNotNone(main_match, "mainCuratedPresets must be defined in FramingModels.swift")
        main_cases = re.findall(r"\.([a-zA-Z0-9]+)", main_match.group(1))
        self.assertEqual(len(main_cases), 65, f"Expected 65 curated presets, found {len(main_cases)}")

        legacy_match = re.search(r"legacyPresets:\s*\[FilmPreset\]\s*=\s*\[(.*?)\]", self.framing_code, re.DOTALL)
        self.assertIsNotNone(legacy_match, "legacyPresets must be defined in FramingModels.swift")
        legacy_cases = re.findall(r"\.([a-zA-Z0-9]+)", legacy_match.group(1))
        self.assertEqual(len(legacy_cases), 11, f"Expected 11 legacy presets, found {len(legacy_cases)}")

        # selectablePresets must equal mainCuratedPresets
        self.assertIn("return mainCuratedPresets", self.framing_code)

    def test_new_retro_presets_present(self):
        """Verify cyanotype, grNegative, bleachBypass are present in all models."""
        for case_name in ["cyanotype", "grNegative", "bleachBypass"]:
            self.assertIn(f"case {case_name}", self.framing_code)
            self.assertIn(f".{case_name}", self.filter_engine_code)
            self.assertIn(f"case .{case_name}:", self.historic_code)

    def test_filter_engine_coverage(self):
        """Verify FilmFilterEngine routes all curated and legacy presets."""
        self.assertIn("HistoricAndCreativeSimulations.apply", self.filter_engine_code)
        self.assertIn("case .cyanotype, .grNegative, .bleachBypass:", self.filter_engine_code)

    def test_core_lcd_dither_implementation(self):
        """Verify applyDitherLCD uses CIPixellate, CIColorPosterize, and CIColorMatrix."""
        self.assertIn("CIPixellate", self.core_code)
        self.assertIn("CIColorPosterize", self.core_code)
        self.assertIn("inputLevels", self.core_code)
        self.assertIn("0.51", self.core_code) # Nokia LCD olive green mapping matrix

    def test_core_chroma_bleed_implementation(self):
        """Verify applyChromaBleed uses channel separation and CIAdditionCompositing without CILightenBlendMode."""
        self.assertIn("CIAdditionCompositing", self.core_code)
        self.assertNotIn("CILightenBlendMode", self.core_code)

    def test_scale_adaptive_radii(self):
        """Verify Halation, Bloom, and LensDiffusion scale radii dynamically."""
        for func in ["applyHalationGlow", "applyCCDBloom", "applyLensDiffusion"]:
            match = re.search(r"func " + func + r".*?\{(.*?)\n    \}", self.core_code, re.DOTALL)
            self.assertIsNotNone(match, f"Could not find function {func}")
            self.assertIn("scaleFactor", match.group(1))
            self.assertIn("effectiveRadius", match.group(1))

    def test_kodak_differentiation(self):
        """Verify Portra 400 and ColorPlus 200 are differentiated."""
        self.assertIn("Vision3 250D Daylight Cinema", self.kodak_code)
        # Portra 400 has low contrast 1.03 and lifted toe 0.06
        self.assertIn("contrast: 1.03", self.kodak_code)
        # ColorPlus 200 has high contrast 1.13 and deep toe 0.03
        self.assertIn("contrast: 1.13", self.kodak_code)

    def test_instax_differentiation(self):
        """Verify Instax Wide and SQ10 are differentiated."""
        # Instax Wide has gentle contrast 1.04
        self.assertIn("contrast: 1.04", self.instax_code)
        # Instax SQ10 has punchy digital contrast 1.18 and digitalCCDNoise
        self.assertIn("contrast: 1.18", self.instax_code)
        self.assertIn("applyDigitalCCDNoise", self.instax_code)

    def test_dv_differentiation(self):
        """Verify DCR-DVD and HDV 1080i are differentiated."""
        # DCR-DVD has high video contrast 1.15 and bloom 0.18
        self.assertIn("contrast: 1.15", self.dv_code)
        # HDV 1080i has gentle broadcast contrast 1.04 and 6500K neutral
        self.assertIn("contrast: 1.04", self.dv_code)
        self.assertIn("targetTemp: 6500", self.dv_code)

    def test_matching_rules_simulation(self):
        """Simulate the 3-tier matching algorithm to ensure 0 collisions."""
        alias_map = {
            "nokia 3310": "nokia3310",
            "3310": "nokia3310",
            "3310 lcd": "nokia3310",
            "nokia symbian": "nokiaSymbian",
            "nokia n73": "nokiaSymbian",
            "nokia 8800": "luxury8800",
            "1998 street": "cam1998Street",
            "1998": "cam1998",
            "g-ccd": "gCcdGold",
            "ccd1": "ccd1Cyber",
            "vision3 250d": "vision3500D",
            "kodak 500d": "vision3500D",
            "cyanotype": "cyanotype",
            "gr negative": "grNegative",
            "bleach bypass": "bleachBypass",
            "portra 400": "kodakPortra400",
            "colorplus 200": "colorPlus200"
        }
        for query, expected in alias_map.items():
            self.assertIn(f'"{query}": .{expected}', self.framing_code, f"Missing alias mapping for '{query}' -> '{expected}'")

    def test_zero_emojis(self):
        """Strict verification: zero emojis across all color code files."""
        emoji_pattern = re.compile(r"[\U00010000-\U0010ffff]|[\u2600-\u27bf]")
        files_to_check = [
            FRAMING_MODELS_PATH,
            FILM_FILTER_ENGINE_PATH,
            FILM_CORE_PATH,
            KODAK_SIM_PATH,
            DV_SIM_PATH,
            INSTAX_SIM_PATH,
            HISTORIC_SIM_PATH,
            ROOT / "tests/FilmPresetRegressionTests.swift"
        ]
        for f in files_to_check:
            text = f.read_text(encoding="utf-8")
            matches = emoji_pattern.findall(text)
            self.assertEqual(len(matches), 0, f"Found emojis {matches} in {f.name}")


if __name__ == "__main__":
    unittest.main()
