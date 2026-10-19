import math
import sys
import unittest
from pathlib import Path

def calculate_continuous_ideal_zoom(
    current_zoom: float,
    current_area: float,
    desired_area: float,
    max_zoom: float,
    target_x: float = 0.5,
    target_y: float = 0.5,
    box_w: float = 0.2,
    box_h: float = 0.3,
    safety_margin: float = 0.06
) -> float:
    if current_area <= 0.0001 or desired_area <= 0 or current_zoom <= 0:
        return current_zoom
    
    # 1. Quadratic area scaling factor k = sqrt(A_desired / A_0)
    ideal_ratio = math.sqrt(desired_area / current_area)
    zoom_candidate = current_zoom * ideal_ratio
    
    # 2. Edge safety margin constraints
    if box_w > 0 and box_h > 0:
        max_ratio_x = (2.0 * min(target_x - safety_margin, 1.0 - safety_margin - target_x)) / box_w
        max_ratio_y = (2.0 * min(target_y - safety_margin, 1.0 - safety_margin - target_y)) / box_h
        max_allowed_ratio = max(1.0, min(max_ratio_x, max_ratio_y))
        zoom_candidate = min(zoom_candidate, current_zoom * max_allowed_ratio)
        
    # 3. Clamp within [current_zoom, max_zoom]
    return max(current_zoom, min(max_zoom, zoom_candidate))

class TestContinuousIdealZoom(unittest.TestCase):

    def test_ideal_zoom_formula_centered(self):
        # 1. Current area 0.04 (e.g. 0.2 x 0.2), desired 0.16 -> ratio 4.0 -> k = 2.0
        z = calculate_continuous_ideal_zoom(1.0, 0.04, 0.16, 5.0, 0.5, 0.5, 0.2, 0.2, 0.06)
        self.assertAlmostEqual(z, 2.0, places=6)

        # 2. Current zoom 1.5x, current area 0.09, desired 0.36 -> k = 2.0 -> target 3.0x
        z2 = calculate_continuous_ideal_zoom(1.5, 0.09, 0.36, 5.0, 0.5, 0.5, 0.3, 0.3, 0.06)
        self.assertAlmostEqual(z2, 3.0, places=6)

    def test_edge_safety_margin_prevents_cutting_subject(self):
        # Subject near the right edge: center x = 0.85, width = 0.20
        # Right edge of box = 0.85 + 0.10 = 0.95.
        # With safety margin 0.06, allowed right edge is 0.94 -> already close to boundary!
        # max_ratio_x = 2 * (1.0 - 0.06 - 0.85) / 0.20 = 2 * 0.09 / 0.20 = 0.90
        # Even though desired area wants k = 2.0x, edge margin caps ratio at 1.0x (no zoom in)
        z = calculate_continuous_ideal_zoom(1.0, 0.04, 0.16, 5.0, 0.85, 0.5, 0.2, 0.2, 0.06)
        self.assertAlmostEqual(z, 1.0, places=6)

    def test_max_zoom_clamping(self):
        # Desired area wants k = 4.0 (zoom 4x), but max_zoom is 3.0
        z = calculate_continuous_ideal_zoom(1.0, 0.01, 0.16, 3.0, 0.5, 0.5, 0.1, 0.1, 0.06)
        self.assertAlmostEqual(z, 3.0, places=6)

    def test_source_code_contracts(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        planning_file = root / 'Services/CompositionPlanning.swift'
        code = planning_file.read_text(encoding='utf-8')
        
        self.assertIn('calculateContinuousIdealZoom', code, 
                      "CompositionPlanning must utilize calculateContinuousIdealZoom for edge-safe zoom")
        self.assertIn('CompositionTuning.desiredAreaPortrait', code,
                      "CompositionPlanning must reference CompositionTuning.desiredAreaPortrait")

if __name__ == '__main__':
    unittest.main()
