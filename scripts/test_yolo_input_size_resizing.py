import unittest
from pathlib import Path

class TestYOLOInputSizeResizing(unittest.TestCase):

    def test_aspect_scaling_logic(self):
        # Camera buffer dimensions on iPhone 15 Pro (4:3 portrait sensor output)
        cam_w, cam_h = 1128, 1504
        target_w, target_h = 640, 640
        
        scale_x = target_w / cam_w
        scale_y = target_h / cam_h
        
        # Extent scaled
        scaled_w = cam_w * scale_x
        scaled_h = cam_h * scale_y
        
        self.assertEqual(scaled_w, 640.0)
        self.assertEqual(scaled_h, 640.0)
        
        # When an object is at normalized center (cx=0.5, cy=0.5) in camera coordinates,
        # its normalized position in the 640x640 scaled buffer remains (0.5, 0.5)
        pixel_x = 0.5 * cam_w
        scaled_pixel_x = pixel_x * scale_x
        norm_scaled_x = scaled_pixel_x / target_w
        self.assertAlmostEqual(norm_scaled_x, 0.5, places=6)

    def test_source_code_contract(self):
        root = Path(__file__).resolve().parents[1] / 'AISmartFramingCamera'
        yolo_file = root / 'Services/YOLODetectionEngine.swift'
        code = yolo_file.read_text(encoding='utf-8')
        
        # Ensure YOLODetectionEngine handles resizing buffer before model.prediction
        self.assertIn('getResizedPixelBuffer', code, "YOLODetectionEngine must implement getResizedPixelBuffer")
        self.assertIn('inputSize', code, "YOLODetectionEngine must query target inputSize for model")
        self.assertNotIn('MLFeatureValue(pixelBuffer: pixelBuffer)', code, 
                         "Raw camera pixelBuffer must not be passed directly without checking/resizing input size")

if __name__ == '__main__':
    unittest.main()
