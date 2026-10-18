"""Test chung minh loi #1: YOLO Decode clamping sai lam lech tam va vo hieu hoa bo loc box.
"""
import unittest

def buggy_decode(cx, cy, w, h):
    x = max(0.0, cx - w / 2.0)
    y = max(0.0, cy - h / 2.0)
    return (x, y, w, h)

def correct_decode(cx, cy, w, h):
    return (cx - w / 2.0, cy - h / 2.0, w, h)

def compute_inside_ratio(x, y, w, h):
    inter_x0 = max(0.0, x)
    inter_y0 = max(0.0, y)
    inter_x1 = min(1.0, x + w)
    inter_y1 = min(1.0, y + h)
    if inter_x1 <= inter_x0 or inter_y1 <= inter_y0:
        return 0.0
    return ((inter_x1 - inter_x0) * (inter_y1 - inter_y0)) / (w * h)

class TestYOLOClampingBug(unittest.TestCase):

    def test_buggy_decode_shifts_box_center_and_corrupts_coordinates(self):
        cx, cy, w, h = 0.05, 0.5, 0.2, 0.3
        buggy_x, buggy_y, buggy_w, buggy_h = buggy_decode(cx, cy, w, h)
        buggy_center_x = buggy_x + buggy_w / 2.0
        
        # Voi code loi cu, tam bi dich tu 0.05 thanh 0.10 (+0.05 lech tam)
        self.assertNotEqual(buggy_center_x, cx, "Code cu bi lech tam chu the khi cham mep!")
        self.assertAlmostEqual(buggy_center_x, 0.10, places=6)

        # Voi code sua dung (CompositionPureCalculations.decodeYOLORawBox)
        correct_x, correct_y, correct_w, correct_h = correct_decode(cx, cy, w, h)
        correct_center_x = correct_x + correct_w / 2.0
        self.assertAlmostEqual(correct_center_x, cx, places=6, msg="Code dung giu nguyen tam vat the!")
        self.assertAlmostEqual(correct_x, -0.05, places=6)

    def test_buggy_decode_bypasses_min_visible_fraction_filter(self):
        # Chu the phan lon o ngoai man hinh: cx = -0.05, w = 0.20
        # Toa do thuc: [-0.15, 0.05], chi co 0.05 nam trong man hinh -> ty le thuc = 25% (< 75%)
        # Bo loc phai LOAI BO box nay.
        cx, cy, w, h = -0.05, 0.5, 0.2, 0.3
        
        # 1. Chay code loi cu:
        buggy_box = buggy_decode(cx, cy, w, h) # (0.0, 0.35, 0.2, 0.3)
        buggy_ratio = compute_inside_ratio(*buggy_box) # = 1.0 (100%)
        # Loi nghiem trong: code cu nhan dien 100% trong man hinh du vat the 75% o ngoai!
        self.assertGreaterEqual(buggy_ratio, 0.75, "Code cu lam sai lech inside_ratio!")

        # 2. Chay code dung:
        correct_box = correct_decode(cx, cy, w, h) # (-0.15, 0.35, 0.2, 0.3)
        correct_ratio = compute_inside_ratio(*correct_box) # = 0.05 / 0.20 = 25%
        self.assertAlmostEqual(correct_ratio, 0.25, places=6)
        self.assertLess(correct_ratio, 0.75, "Code dung chan thanh cong box khong du 75% dien tich!")

if __name__ == '__main__':
    unittest.main()
