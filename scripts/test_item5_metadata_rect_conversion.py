"""Test kiem thu muc #5: Chuyen doi tu uprightRect sang metadataOutputRect cho AVCaptureVideoPreviewLayer.
Spec test: rect (x:0.1, y:0.2, w:0.3, h:0.4) -> metadataRect (x:0.2, y:0.6, w:0.4, h:0.3).
"""
import unittest

def upright_to_metadata_output_rect(upright_rect):
    ux, uy, uw, uh = upright_rect
    meta_x = max(0.0, min(1.0, uy))
    meta_y = max(0.0, min(1.0, 1.0 - (ux + uw)))
    meta_w = max(0.0, min(1.0 - meta_x, uh))
    meta_h = max(0.0, min(1.0 - meta_y, uw))
    return (meta_x, meta_y, meta_w, meta_h)

def upright_to_capture_device_point(upright_point):
    # Dành cho camera sau ở chế độ dọc (portrait orientation)
    # captureDevicePoint: (0,0) ở góc trên-trái của sensor ngang (landscape-right)
    # x_device = y_upright, y_device = 1.0 - x_upright
    ux, uy = upright_point
    return (uy, 1.0 - ux)

def capture_device_point_to_upright(device_point):
    dx, dy = device_point
    return (1.0 - dy, dx)

class TestMetadataRectConversion(unittest.TestCase):

    def test_upright_to_metadata_output_rect_matches_spec(self):
        # Spec Test: rect (x:0.1, y:0.2, w:0.3, h:0.4) -> metadataRect (x:0.2, y:0.6, w:0.4, h:0.3)
        upright = (0.1, 0.2, 0.3, 0.4)
        meta = upright_to_metadata_output_rect(upright)
        
        self.assertAlmostEqual(meta[0], 0.2, places=6)
        self.assertAlmostEqual(meta[1], 0.6, places=6)
        self.assertAlmostEqual(meta[2], 0.4, places=6)
        self.assertAlmostEqual(meta[3], 0.3, places=6)

    def test_capture_device_point_round_trip(self):
        pt = (0.35, 0.65)
        dev = upright_to_capture_device_point(pt)
        back = capture_device_point_to_upright(dev)
        self.assertAlmostEqual(back[0], pt[0], places=9)
        self.assertAlmostEqual(back[1], pt[1], places=9)

if __name__ == '__main__':
    unittest.main()
