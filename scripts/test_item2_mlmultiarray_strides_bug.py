"""Test chung minh loi #2: Doc truc tiep con tro voi stride mac dinh i * 4 gay doc rac khi ANE dem bo nho (padding).
"""
import unittest

def read_box_buggy(buffer, i):
    # Code cu: let coordOffset = i * 4
    offset = i * 4
    return (buffer[offset + 0], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])

def read_box_stride_aware(buffer, i, box_stride, elem_stride):
    # Code moi: let offset = i * boxStride + k * elemStride
    return (
        buffer[i * box_stride + 0 * elem_stride],
        buffer[i * box_stride + 1 * elem_stride],
        buffer[i * box_stride + 2 * elem_stride],
        buffer[i * box_stride + 3 * elem_stride],
    )

class TestMLMultiArrayStrideBug(unittest.TestCase):

    def setUp(self):
        # Gia lap MLMultiArray tu ANE voi 3 box, moi box 4 toa do nhung dem (padding) len 8 phan tu (SIMD alignment)
        # Stride thuc te: [8, 1]
        self.box_stride = 8
        self.elem_stride = 1
        PAD = 0.0 # Gia tri dem trong bo nho
        
        self.buffer = [
            # Box 0: (cx=0.1, cy=0.2, w=0.3, h=0.4) + 4 padding
            0.1, 0.2, 0.3, 0.4, PAD, PAD, PAD, PAD,
            # Box 1: (cx=0.5, cy=0.6, w=0.7, h=0.8) + 4 padding
            0.5, 0.6, 0.7, 0.8, PAD, PAD, PAD, PAD,
            # Box 2: (cx=0.9, cy=0.15, w=0.25, h=0.35) + 4 padding
            0.9, 0.15, 0.25, 0.35, PAD, PAD, PAD, PAD,
        ]

    def test_buggy_code_reads_padding_zeros_on_subsequent_boxes(self):
        # Box 0: i=0 * 4 = 0 -> doc dung box 0
        box0 = read_box_buggy(self.buffer, 0)
        self.assertEqual(box0, (0.1, 0.2, 0.3, 0.4))

        # Box 1: i=1 * 4 = 4 -> doc vi tri [4..7] la PADDING RAC!
        box1_buggy = read_box_buggy(self.buffer, 1)
        self.assertNotEqual(box1_buggy, (0.5, 0.6, 0.7, 0.8), "Code cu bi loi doc vung dem padding!")
        self.assertEqual(box1_buggy, (0.0, 0.0, 0.0, 0.0), "Code cu doc phai toan so 0 cua vung dem!")

        # Box 2: i=2 * 4 = 8 -> doc nham sang Box 1!
        box2_buggy = read_box_buggy(self.buffer, 2)
        self.assertNotEqual(box2_buggy, (0.9, 0.15, 0.25, 0.35), "Code cu doc sai box 2!")
        self.assertEqual(box2_buggy, (0.5, 0.6, 0.7, 0.8), "Code cu bi lech offset va doc nham du lieu cua Box 1!")

    def test_stride_aware_code_reads_all_boxes_correctly(self):
        box0 = read_box_stride_aware(self.buffer, 0, self.box_stride, self.elem_stride)
        box1 = read_box_stride_aware(self.buffer, 1, self.box_stride, self.elem_stride)
        box2 = read_box_stride_aware(self.buffer, 2, self.box_stride, self.elem_stride)

        self.assertEqual(box0, (0.1, 0.2, 0.3, 0.4))
        self.assertEqual(box1, (0.5, 0.6, 0.7, 0.8))
        self.assertEqual(box2, (0.9, 0.15, 0.25, 0.35))

if __name__ == '__main__':
    unittest.main()
