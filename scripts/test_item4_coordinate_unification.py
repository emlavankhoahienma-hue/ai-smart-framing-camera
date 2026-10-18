"""Test chung minh va kiem thu muc #4: Dong nhat he toa do giua cac nguon Vision, YOLO, Apple Metadata.
Tat ca nguon phai quy doi ve chuan 'upright' (0,0 o goc tren-trai, y huong xuong) voi IoU > 0.99.
"""
import unittest

def vision_to_upright(vision_rect):
    # vision_rect: (x, y, w, h) voi (0,0) goc duoi-trai, y huong len
    vx, vy, vw, vh = vision_rect
    return (vx, 1.0 - (vy + vh), vw, vh)

def upright_to_vision(upright_rect):
    ux, uy, uw, uh = upright_rect
    return (ux, 1.0 - (uy + uh), uw, uh)

def yolo_to_upright(cx, cy, w, h):
    return (cx - w / 2.0, cy - h / 2.0, w, h)

def apple_metadata_to_upright(meta_bounds):
    # meta_bounds: (x, y, w, h) trong sensor coordinate space (landscape rear cam)
    mx, my, mw, mh = meta_bounds
    return (my, 1.0 - mx - mw, mh, mw)

def compute_iou(box_a, box_b):
    ax, ay, aw, ah = box_a
    bx, by, bw, bh = box_b
    
    inter_x0 = max(ax, bx)
    inter_y0 = max(ay, by)
    inter_x1 = min(ax + aw, bx + bw)
    inter_y1 = min(ay + ah, by + bh)
    
    if inter_x1 <= inter_x0 or inter_y1 <= inter_y0:
        return 0.0
    
    inter_area = (inter_x1 - inter_x0) * (inter_y1 - inter_y0)
    area_a = aw * ah
    area_b = bw * bh
    union_area = area_a + area_b - inter_area
    return inter_area / union_area if union_area > 0 else 0.0

class TestCoordinateUnification(unittest.TestCase):

    def test_all_sources_unify_to_identical_upright_box(self):
        # 1. Vat the mau gia lap o toa do Upright: x=0.20, y=0.30, w=0.40, h=0.50
        ground_truth_upright = (0.20, 0.30, 0.40, 0.50)

        # 2. Toa do ma nguon YOLO sinh ra cho vat the nay:
        # cx = 0.20 + 0.40/2 = 0.40, cy = 0.30 + 0.50/2 = 0.55
        yolo_box = yolo_to_upright(0.40, 0.55, 0.40, 0.50)

        # 3. Toa do ma nguon Vision sinh ra cho vat the nay (goc duoi-trai):
        # vy = 1.0 - (0.30 + 0.50) = 0.20
        vision_raw = (0.20, 0.20, 0.40, 0.50)
        vision_box = vision_to_upright(vision_raw)

        # 4. Toa do ma nguon Apple AVCaptureMetadataOutput sinh ra cho vat the nay:
        # mx = 1.0 - (0.30 + 0.50) = 0.20, my = 0.20, mw = 0.50, mh = 0.40
        apple_meta_raw = (0.20, 0.20, 0.50, 0.40)
        apple_box = apple_metadata_to_upright(apple_meta_raw)

        # Kiem tra IoU giua ca 3 nguon
        iou_yolo_gt = compute_iou(yolo_box, ground_truth_upright)
        iou_vision_gt = compute_iou(vision_box, ground_truth_upright)
        iou_apple_gt = compute_iou(apple_box, ground_truth_upright)
        iou_yolo_vision = compute_iou(yolo_box, vision_box)
        iou_yolo_apple = compute_iou(yolo_box, apple_box)

        self.assertGreater(iou_yolo_gt, 0.9999)
        self.assertGreater(iou_vision_gt, 0.9999)
        self.assertGreater(iou_apple_gt, 0.9999)
        self.assertGreater(iou_yolo_vision, 0.9999)
        self.assertGreater(iou_yolo_apple, 0.9999)

        # Kiem tra round-trip Upright <-> Vision
        round_trip_vision = vision_to_upright(upright_to_vision(ground_truth_upright))
        for v1, v2 in zip(round_trip_vision, ground_truth_upright):
            self.assertAlmostEqual(v1, v2, places=12)

if __name__ == '__main__':
    unittest.main()
