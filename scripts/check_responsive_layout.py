"""Portable point-space checks for the camera layout and tap projection.

The results are calculated scenarios, not screenshots from iOS Simulator.
"""
from pathlib import Path
import json
import math

ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / 'AISmartFramingCamera/Views/CameraMainView.swift').read_text(encoding='utf-8')
OVERLAY = (ROOT / 'AISmartFramingCamera/Views/ARFramingOverlayView.swift').read_text(encoding='utf-8')
CONTROLS = (ROOT / 'AISmartFramingCamera/Views/CameraControlsView.swift').read_text(encoding='utf-8')
SCREENS = [
    ('iPhone SE 2/3', 375, 667, 20, 0),
    ('iPhone 12/13 mini', 375, 812, 47, 34),
    ('iPhone tiêu chuẩn', 393, 852, 59, 34),
    ('iPhone Pro Max', 430, 932, 59, 34),
]


def geometry(name, width, height, safe_top, safe_bottom):
    safe_height = height - safe_top - safe_bottom
    compact = safe_height < 700 or width < 375
    horizontal = 8 if width < 375 else 14
    top_padding = 2 if compact else min(18, max(4, (safe_height - 700) * .12))
    top_bottom = 4 if compact else 6
    deck = 148 if compact else 156
    gap = 4 if compact else 8
    comfort = (8 if compact else 14) if safe_bottom >= 20 else (6 if compact else 10)
    preview_height = min((width - 12) * 4 / 3,
                         safe_height - 44 - top_padding - top_bottom - deck - comfort - gap)
    preview_width = preview_height * 3 / 4
    histogram = max(100, min(140, width - 2 * horizontal - 184 - 12))
    slack = safe_height - (44 + top_padding + top_bottom + preview_height + deck + comfort + gap)
    assert preview_height > 0 and preview_width > 0
    assert math.isclose(preview_width / preview_height, 3 / 4, abs_tol=1e-9)
    assert preview_width + 12 <= width + 1e-9
    assert slack >= -1e-9
    assert histogram + 184 + 12 <= width - 2 * horizontal + 1e-9
    # Three zoom buttons, two viewfinder side buttons and 44 pt touch regions.
    assert 3 * 44 + 2 * 44 + 2 * 8 + 2 * max(8, min(14, preview_width * .04)) <= preview_width
    assert deck >= 80 + (6 if compact else 10) + 50 + 6 + (2 if compact else 4) + (4 if compact else 6)
    for px, py in ((0, 0), (.5, .5), (1, 1), (.2, .8), (.9, .1)):
        aspect = 4 / 3
        scale = max(preview_width / aspect, preview_height)
        sx = (px - .5) * scale * aspect + preview_width / 2
        sy = (py - .5) * scale + preview_height / 2
        bx = (sx - preview_width / 2) / (scale * aspect) + .5
        by = (sy - preview_height / 2) / scale + .5
        assert math.isclose(px, bx, abs_tol=1e-9)
        assert math.isclose(py, by, abs_tol=1e-9)
    return {'device': name, 'screen_pt': [width, height], 'safe_top_bottom_pt': [safe_top, safe_bottom],
            'viewfinder_pt': [round(preview_width, 1), round(preview_height, 1)],
            'control_deck_pt': deck, 'home_clearance_pt': safe_bottom + comfort,
            'spare_vertical_pt': round(slack, 1), 'histogram_pt': histogram}


assert 'CameraFormFactorLayout(availableSize: geometry.size' in MAIN
assert 'safeAreaInsets: geometry.safeAreaInsets' in MAIN
assert '.frame(width: layout.viewfinderSize.width,' in MAIN
assert 'CameraPreviewView(viewModel: viewModel)' in MAIN
assert 'ARFramingOverlayView(viewModel: viewModel)' in MAIN
assert 'TrackingGeometry.screenPoint' in OVERLAY
assert 'TrackingGeometry.bufferPoint' in OVERLAY
assert '.frame(width: 82, height: 44)' in CONTROLS
report = {'scope': 'calculated point-space layouts and projection round trips, not device rendering',
          'screens': [geometry(*screen) for screen in SCREENS], 'passed': len(SCREENS)}
(ROOT / 'validation/responsive-layout-report.json').write_text(
    json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
print(json.dumps(report, ensure_ascii=True, indent=2))
