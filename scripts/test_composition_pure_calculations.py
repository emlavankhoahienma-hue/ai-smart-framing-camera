"""Deterministic tests mirroring CompositionPureCalculationsTests.swift for the Windows environment.
Runs purely with standard Python library (math, unittest).
"""
import math
import unittest

def decode_yolo_raw_box(cx, cy, w, h):
    return (cx - w / 2.0, cy - h / 2.0, w, h)

def compute_inside_unit_ratio(x, y, w, h):
    unit_min_x, unit_min_y = 0.0, 0.0
    unit_max_x, unit_max_y = 1.0, 1.0
    inter_min_x = max(x, unit_min_x)
    inter_min_y = max(y, unit_min_y)
    inter_max_x = min(x + w, unit_max_x)
    inter_max_y = min(y + h, unit_max_y)
    if inter_max_x <= inter_min_x or inter_max_y <= inter_min_y:
        return 0.0
    inter_area = (inter_max_x - inter_min_x) * (inter_max_y - inter_min_y)
    total_area = w * h
    return inter_area / total_area if total_area > 0 else 0.0

def validate_and_clip_box(x, y, w, h, min_dimension=0.04, max_dimension=0.95, min_aspect=0.15, max_aspect=6.5, min_visible=0.75):
    inside_ratio = compute_inside_unit_ratio(x, y, w, h)
    if inside_ratio < min_visible:
        return None
    inter_min_x = max(x, 0.0)
    inter_min_y = max(y, 0.0)
    inter_max_x = min(x + w, 1.0)
    inter_max_y = min(y + h, 1.0)
    clip_w = inter_max_x - inter_min_x
    clip_h = inter_max_y - inter_min_y
    if clip_w < min_dimension or clip_h < min_dimension or clip_w > max_dimension or clip_h > max_dimension:
        return None
    aspect = clip_w / max(1e-4, clip_h)
    if aspect < min_aspect or aspect > max_aspect:
        return None
    return (inter_min_x, inter_min_y, clip_w, clip_h)

def unpad_letterbox(x, y, w, h, source_w, source_h, model_size=640.0):
    scale = min(model_size / source_w, model_size / source_h)
    valid_w = source_w * scale
    valid_h = source_h * scale
    pad_x = (model_size - valid_w) / 2.0
    pad_y = (model_size - valid_h) / 2.0
    pixel_x = x * model_size
    pixel_y = y * model_size
    pixel_w = w * model_size
    pixel_h = h * model_size
    unpadded_x = (pixel_x - pad_x) / valid_w
    unpadded_y = (pixel_y - pad_y) / valid_h
    unpadded_w = pixel_w / valid_w
    unpadded_h = pixel_h / valid_h
    return (max(0.0, min(1.0, unpadded_x)), max(0.0, min(1.0, unpadded_y)),
            max(0.0, min(1.0, unpadded_w)), max(0.0, min(1.0, unpadded_h)))

def calculate_intrinsics(fov_long_deg, aspect=0.75, zoom=1.0):
    fov_rad = fov_long_deg * math.pi / 180.0
    effective_zoom = max(0.1, zoom)
    fy = (0.5 / math.tan(fov_rad / 2.0)) * effective_zoom
    fx = fy / max(1e-3, aspect)
    return fx, fy, 0.5, 0.5

def point_to_device_ray(px, py, fx, fy, cx=0.5, cy=0.5):
    rx = (px - cx) / fx
    ry = -(py - cy) / fy
    rz = -1.0
    length = math.sqrt(rx * rx + ry * ry + rz * rz)
    return (rx / length, ry / length, rz / length)

def device_ray_to_screen_point(rx, ry, rz, fx, fy, cx=0.5, cy=0.5):
    forward = -rz
    if forward > 1e-6:
        px = cx + fx * rx / forward
        py = cy - fy * ry / forward
        return px, py, True
    return cx, cy, False

def quat_mult(q1, q2):
    # q = (x, y, z, w)
    x1, y1, z1, w1 = q1
    x2, y2, z2, w2 = q2
    return (
        w1*x2 + x1*w2 + y1*z2 - z1*y2,
        w1*y2 - x1*z2 + y1*w2 + z1*x2,
        w1*z2 + x1*y2 - y1*x2 + z1*w2,
        w1*w2 - x1*x2 - y1*y2 - z1*z2
    )

def quat_inv(q):
    x, y, z, w = q
    return (-x, -y, -z, w)

def quat_act(q, v):
    # v = (x, y, z) -> as pure quaternion (x, y, z, 0)
    vq = (v[0], v[1], v[2], 0.0)
    res = quat_mult(quat_mult(q, vq), quat_inv(q))
    return (res[0], res[1], res[2])

def calculate_continuous_ideal_zoom(current_zoom, current_area, desired_area, max_zoom, target_x=0.5, target_y=0.5, box_w=0.2, box_h=0.25, safety_margin=0.06):
    ideal_ratio = math.sqrt(desired_area / current_area)
    candidate = current_zoom * ideal_ratio
    max_ratio_x = (2.0 * min(target_x - safety_margin, 1.0 - safety_margin - target_x)) / box_w
    max_ratio_y = (2.0 * min(target_y - safety_margin, 1.0 - safety_margin - target_y)) / box_h
    max_allowed = max(1.0, min(max_ratio_x, max_ratio_y))
    candidate = min(candidate, current_zoom * max_allowed)
    return max(current_zoom, min(max_zoom, candidate))

class TestCompositionPureCalculations(unittest.TestCase):

    def test_yolo_raw_box_decoding_without_clamp(self):
        # Spec Test: cx=0.05, cy=0.5, w=0.2, h=0.3 -> rect.minX = -0.05; insideRatio = 0.75; clipped = (0, 0.35, 0.15, 0.3)
        cx, cy, w, h = 0.05, 0.5, 0.2, 0.3
        raw_x, raw_y, raw_w, raw_h = decode_yolo_raw_box(cx, cy, w, h)
        self.assertAlmostEqual(raw_x, -0.05, places=6)
        self.assertAlmostEqual(raw_y, 0.35, places=6)
        self.assertAlmostEqual(raw_w, 0.2, places=6)
        self.assertAlmostEqual(raw_h, 0.3, places=6)

        inside_ratio = compute_inside_unit_ratio(raw_x, raw_y, raw_w, raw_h)
        self.assertAlmostEqual(inside_ratio, 0.75, places=6)

        clipped = validate_and_clip_box(raw_x, raw_y, raw_w, raw_h)
        self.assertIsNotNone(clipped)
        cx_c, cy_c, cw, ch = clipped
        self.assertAlmostEqual(cx_c, 0.0, places=6)
        self.assertAlmostEqual(cy_c, 0.35, places=6)
        self.assertAlmostEqual(cw, 0.15, places=6)
        self.assertAlmostEqual(ch, 0.3, places=6)

    def test_letterbox_unpadding(self):
        source_w, source_h = 3000.0, 4000.0
        model_size = 640.0
        # Box centered in model
        norm_x, norm_y, norm_w, norm_h = 0.125, 0.0, 0.75, 1.0
        unpadded = unpad_letterbox(norm_x, norm_y, norm_w, norm_h, source_w, source_h, model_size)
        self.assertAlmostEqual(unpadded[0], 0.0, places=6)
        self.assertAlmostEqual(unpadded[1], 0.0, places=6)
        self.assertAlmostEqual(unpadded[2], 1.0, places=6)
        self.assertAlmostEqual(unpadded[3], 1.0, places=6)

    def test_camera_intrinsics_calculation(self):
        # Spec Test: fovLong=69 degrees, buffer 4:3 -> fy≈0.7275, fx≈0.970
        fov_long = 69.0
        aspect = 0.75
        fx, fy, cx, cy = calculate_intrinsics(fov_long, aspect, zoom=1.0)
        self.assertAlmostEqual(fy, 0.7275, places=3)
        self.assertAlmostEqual(fx, 0.9700, places=3)
        self.assertEqual(cx, 0.5)
        self.assertEqual(cy, 0.5)

    def test_pan_right_projection_shift_and_round_trip(self):
        # Spec Test: Pose quay phai 10 deg quanh truc +y -> vat the (0,0,-1) len man hinh tai x = 0.5 - fx * tan(10 deg)
        fx, fy = 1.15, 0.8625
        angle_rad = -10.0 * math.pi / 180.0
        # Axis (0, 1, 0)
        half = angle_rad / 2.0
        q_right = (0.0, math.sin(half), 0.0, math.cos(half))
        world_ray = (0.0, 0.0, -1.0)
        # device_ray = q.inverse.act(world_ray)
        device_ray = quat_act(quat_inv(q_right), world_ray)
        px, py, in_front = device_ray_to_screen_point(device_ray[0], device_ray[1], device_ray[2], fx, fy)
        self.assertTrue(in_front)
        expected_x = 0.5 - fx * math.tan(10.0 * math.pi / 180.0)
        self.assertAlmostEqual(px, expected_x, places=4)
        self.assertAlmostEqual(px, 0.2972, delta=0.0005)

        # Round trip test
        ray = point_to_device_ray(0.35, 0.65, fx, fy)
        back_x, back_y, _ = device_ray_to_screen_point(ray[0], ray[1], ray[2], fx, fy)
        self.assertAlmostEqual(back_x, 0.35, places=9)
        self.assertAlmostEqual(back_y, 0.65, places=9)

    def test_continuous_ideal_zoom(self):
        # Spec Test: A0=0.05, desired=0.34 -> k≈2.6077
        ideal_zoom = calculate_continuous_ideal_zoom(1.0, 0.05, 0.34, 5.0)
        self.assertAlmostEqual(ideal_zoom, 2.6077, places=3)

    def test_coordinate_unification_across_sources(self):
        # Spec Test #4: Cung mot vat the qua YOLO, Vision, Apple Metadata phai cho ra rect upright giong nhau
        expected_upright = (0.20, 0.30, 0.40, 0.50)

        # 1. YOLO
        yolo_box = decode_yolo_raw_box(0.40, 0.55, 0.40, 0.50)

        # 2. Vision
        vision_obs = (0.20, 0.20, 0.40, 0.50)
        vision_box = (vision_obs[0], 1.0 - (vision_obs[1] + vision_obs[3]), vision_obs[2], vision_obs[3])

        # 3. Apple Metadata
        apple_meta = (0.20, 0.20, 0.50, 0.40)
        apple_box = (apple_meta[1], 1.0 - apple_meta[0] - apple_meta[2], apple_meta[3], apple_meta[2])

        for box in [yolo_box, vision_box, apple_box]:
            for v1, v2 in zip(box, expected_upright):
                self.assertAlmostEqual(v1, v2, places=6)

    def test_upright_to_metadata_output_rect_matches_spec(self):
        # Spec Test #5: rect (x:0.1, y:0.2, w:0.3, h:0.4) -> metadataRect (x:0.2, y:0.6, w:0.4, h:0.3)
        ux, uy, uw, uh = 0.1, 0.2, 0.3, 0.4
        meta_x = max(0.0, min(1.0, uy))
        meta_y = max(0.0, min(1.0, 1.0 - (ux + uw)))
        meta_w = max(0.0, min(1.0 - meta_x, uh))
        meta_h = max(0.0, min(1.0 - meta_y, uw))
        self.assertAlmostEqual(meta_x, 0.2, places=6)
        self.assertAlmostEqual(meta_y, 0.6, places=6)
        self.assertAlmostEqual(meta_w, 0.4, places=6)
        self.assertAlmostEqual(meta_h, 0.3, places=6)

if __name__ == '__main__':
    unittest.main()
