"""Test chung minh loi #3: Vision .scaleFit tao vien den (letterbox), neu khong unpad thi toa do bi co vao giua.
"""
import unittest

def unpad_letterbox(norm_x, norm_y, norm_w, norm_h, source_w, source_h, model_size=640.0):
    scale = min(model_size / source_w, model_size / source_h)
    valid_w = source_w * scale
    valid_h = source_h * scale
    pad_x = (model_size - valid_w) / 2.0
    pad_y = (model_size - valid_h) / 2.0
    
    pixel_x = norm_x * model_size
    pixel_y = norm_y * model_size
    pixel_w = norm_w * model_size
    pixel_h = norm_h * model_size
    
    unpadded_x = (pixel_x - pad_x) / valid_w
    unpadded_y = (pixel_y - pad_y) / valid_h
    unpadded_w = pixel_w / valid_w
    unpadded_h = pixel_h / valid_h
    
    return (
        max(0.0, min(1.0, unpadded_x)),
        max(0.0, min(1.0, unpadded_y)),
        max(0.0, min(1.0, unpadded_w)),
        max(0.0, min(1.0, unpadded_h))
    )

class TestLetterboxUnpaddingBug(unittest.TestCase):

    def setUp(self):
        # Buffer anh doc 3:4 (3000 x 4000)
        self.source_w = 3000.0
        self.source_h = 4000.0
        self.model_size = 640.0
        # Ty le scale = 640 / 4000 = 0.16
        # valid_w = 480, valid_h = 640, pad_x = (640 - 480)/2 = 80, pad_y = 0

    def test_buggy_code_distorts_and_shrinks_subject_coordinates(self):
        # Gia su chu the nam o 1/3 ben trai anh camera thuc te: real_x = 1/3 ≈ 0.333333, real_w = 0.25
        real_x = 1.0 / 3.0
        real_w = 0.25
        
        # Khi Vision scaleFit vao 640x640:
        # Pixel tren model: x_pix = pad_x + real_x * valid_w = 80 + (1/3) * 480 = 240
        # w_pix = real_w * valid_w = 0.25 * 480 = 120
        # Vision tra ve toa do chuan hoa:
        vision_x = 240.0 / 640.0 # = 0.3750
        vision_w = 120.0 / 640.0 # = 0.1875
        
        # 1. Code loi cu: lay truc tiep toa do tu Vision ma khong unpad
        buggy_x = vision_x
        buggy_w = vision_w
        
        # Chu the bi dich lech sang phai (ve huong tam) tu 0.3333 thanh 0.3750
        self.assertNotEqual(buggy_x, real_x, "Code cu khong unpad bi lech vi tri chu the!")
        self.assertAlmostEqual(buggy_x - real_x, 0.041666, places=5)
        # Chieu rong chu the bi co hep tu 0.2500 xuong 0.1875 (-25% kich thuoc!)
        self.assertNotEqual(buggy_w, real_w, "Code cu khong unpad lam chu the bi teo nho 25%!")
        self.assertAlmostEqual(buggy_w, 0.1875, places=4)

    def test_unpad_letterbox_restores_exact_coordinates(self):
        real_x = 1.0 / 3.0
        real_w = 0.25
        real_y = 0.20
        real_h = 0.40
        
        # Tinh toa do do Vision .scaleFit tao ra
        scale = 640.0 / self.source_h
        valid_w = self.source_w * scale # 480
        valid_h = self.source_h * scale # 640
        pad_x = (640.0 - valid_w) / 2.0 # 80
        pad_y = 0.0
        
        vision_x = (pad_x + real_x * valid_w) / 640.0
        vision_y = (pad_y + real_y * valid_h) / 640.0
        vision_w = (real_w * valid_w) / 640.0
        vision_h = (real_h * valid_h) / 640.0
        
        # 2. Code moi: ap dung unpadLetterbox
        restored_x, restored_y, restored_w, restored_h = unpad_letterbox(
            vision_x, vision_y, vision_w, vision_h,
            self.source_w, self.source_h, self.model_size
        )
        
        self.assertAlmostEqual(restored_x, real_x, places=6, msg="Unpad phai khoi phuc 100% toa do X goc!")
        self.assertAlmostEqual(restored_y, real_y, places=6, msg="Unpad phai khoi phuc 100% toa do Y goc!")
        self.assertAlmostEqual(restored_w, real_w, places=6, msg="Unpad phai khoi phuc 100% chieu rong W goc!")
        self.assertAlmostEqual(restored_h, real_h, places=6, msg="Unpad phai khoi phuc 100% chieu cao H goc!")

if __name__ == '__main__':
    unittest.main()
