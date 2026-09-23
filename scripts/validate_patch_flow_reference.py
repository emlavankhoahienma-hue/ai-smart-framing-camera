"""Independent synthetic reference check; this does not execute Swift/Vision."""
import json
import math
from pathlib import Path

import numpy as np


def frame(texture, dx, dy):
    image = np.full((480, 320), 28, dtype=np.uint8)
    image[192 + dy:288 + dy, 112 + dx:208 + dx] = texture
    return image


def correlation(source, target):
    a = source.astype(np.float64).ravel()
    b = target.astype(np.float64).ravel()
    a -= a.mean(); b -= b.mean()
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.dot(a, b) / norm) if norm > 1 else -1.0


def match(old, new, point, expected):
    x, y = point
    patch = old[y - 3:y + 4, x - 3:x + 4]
    best = (-1.0, None)
    for ny in range(expected[1] - 10, expected[1] + 11):
        for nx in range(expected[0] - 10, expected[0] + 11):
            if nx < 4 or ny < 4 or nx >= 316 or ny >= 476:
                continue
            score = correlation(patch, new[ny - 3:ny + 4, nx - 3:nx + 4])
            if score > best[0]:
                best = score, (nx, ny)
    return best[1] if best[0] >= 0.78 else None


def main(output):
    rng = np.random.default_rng(226)
    texture = rng.integers(35, 221, size=(96, 96), dtype=np.uint8)
    features = [(x, y) for y in (207, 225, 243, 261) for x in (127, 145, 163, 181)]
    previous = frame(texture, 0, 0)
    estimate = np.array([160.0, 240.0])
    old_box = np.array([160.0, 240.0])
    bbox_errors, flow_errors = [], []
    matched_frames = 0
    for index in range(1, 61):
        dx = round(6 * math.sin(index / 8))
        dy = round(4 * math.sin(index / 11))
        current = frame(texture, dx, dy)
        jitter = rng.normal(0, 3, 2)
        box = np.array([160.0 + dx, 240.0 + dy]) + jitter
        coarse = np.rint(box - old_box).astype(int)
        motions = []
        updated = []
        for x, y in features:
            found = match(previous, current, (x, y), (x + coarse[0], y + coarse[1]))
            if found is not None:
                motions.append((found[0] - x, found[1] - y))
                updated.append(found)
        if len(motions) >= 5:
            motion = np.median(motions, axis=0)
            if np.sum(np.linalg.norm(np.array(motions) - motion, axis=1) <= 2.5) >= 5:
                estimate += motion
                matched_frames += 1
                features = updated
            else:
                estimate = box.copy()
        else:
            estimate = box.copy()
        truth = np.array([160.0 + dx, 240.0 + dy])
        bbox_errors.append(np.linalg.norm(box - truth) ** 2)
        flow_errors.append(np.linalg.norm(estimate - truth) ** 2)
        previous, old_box = current, box
    flat = np.full((480, 320), 90, dtype=np.uint8)
    negative = match(previous, flat, features[0], features[0]) is None
    result = {
        'scope': 'Python synthetic reference; does not execute Swift or Apple Vision',
        'frames': 60,
        'matched_frames': matched_frames,
        'bbox_rmse_pixels': math.sqrt(float(np.mean(bbox_errors))),
        'feature_flow_rmse_pixels': math.sqrt(float(np.mean(flow_errors))),
        'flat_replacement_rejected': negative,
    }
    assert matched_frames >= 54, result
    assert result['feature_flow_rmse_pixels'] < result['bbox_rmse_pixels'] * 0.5, result
    assert negative, result
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result))


if __name__ == '__main__':
    main(Path(__file__).resolve().parents[1] / 'patch_flow_reference_results.json')
