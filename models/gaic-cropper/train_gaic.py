"""
Train GAICCompositionScorer (RoI + RoD + Multi-Scale FPN) on official GAIC train split (1,036 images)
using a clean 936-train / 100-val internal split with zero test leakage from GAIC/images/test (200 images).

Two-stage training on CPU:
- Stage 1: Cache ImageNet backbone features (orig + H-flip) and warm up FPN + RoI/RoD + Scorer head (~14 epochs, ~2 min)
- Stage 2: End-to-end fine-tuning across entire network with image + box augmentation (~5 epochs, ~12-15 min)
"""
from __future__ import annotations

import os
import sys
import json
import time
import math
import ctypes
import hashlib
import argparse
from pathlib import Path

EDGE_DIR = r"C:\Program Files (x86)\Microsoft\Edge\Application\157.0.4341.46"
for _dll in ("vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"):
    _p = os.path.join(EDGE_DIR, _dll)
    if os.path.exists(_p) and hasattr(ctypes, "CDLL"):
        ctypes.CDLL(_p)

import numpy as np
from PIL import Image, ImageOps
from scipy.stats import spearmanr, pearsonr
import torch
import torch.nn as nn
import torch.nn.functional as F

THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

from model import GAICCompositionScorer, IMAGE_SIZE


def load_gaic_split(gaic_root: Path, val_count: int = 100, seed: int = 42):
    train_img_dir = gaic_root / "images" / "train"
    test_img_dir = gaic_root / "images" / "test"
    ann_dir = gaic_root / "annotations"

    train_files = sorted([p.name for p in train_img_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png")])
    test_files = sorted([p.name for p in test_img_dir.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png")])
    overlap = set(train_files) & set(test_files)
    assert not overlap, f"Train/Test filename overlap detected: {overlap}"

    rng = np.random.default_rng(seed)
    perm = rng.permutation(len(train_files))
    val_idx = set(perm[:val_count].tolist())
    tr_list, va_list = [], []
    for i, fname in enumerate(train_files):
        stem = os.path.splitext(fname)[0]
        ann_p = ann_dir / f"{stem}.txt"
        if not ann_p.exists():
            continue
        im_p = train_img_dir / fname
        (va_list if i in val_idx else tr_list).append((fname, im_p, ann_p))
    return tr_list, va_list


def parse_sample(im_p: Path, ann_p: Path):
    im = ImageOps.exif_transpose(Image.open(im_p)).convert("RGB")
    w, h = im.size
    im_r = im.resize((IMAGE_SIZE, IMAGE_SIZE), Image.Resampling.BILINEAR)
    arr = np.asarray(im_r, dtype=np.uint8)  # [H, W, 3]
    boxes = []
    scores = []
    for ln in ann_p.read_text(encoding="utf-8").splitlines():
        parts = ln.strip().split()
        if len(parts) < 5:
            continue
        y1, x1, y2, x2, sc = map(float, parts[:5])
        if sc < 0.0:
            continue
        nx1 = max(0.0, min(1.0, x1 / w))
        ny1 = max(0.0, min(1.0, y1 / h))
        nx2 = max(nx1 + 0.01, min(1.0, x2 / w))
        ny2 = max(ny1 + 0.01, min(1.0, y2 / h))
        boxes.append([nx1, ny1, nx2, ny2])
        scores.append(sc)
    return {
        "name": im_p.name,
        "rgb_u8": arr,
        "boxes": np.asarray(boxes, dtype=np.float32),
        "scores": np.asarray(scores, dtype=np.float32),
    }


def flip_sample_data(rgb_tensor: torch.Tensor, boxes_tensor: torch.Tensor):
    rgb_f = torch.flip(rgb_tensor, dims=[3])  # [1, 3, H, W]
    b_f = boxes_tensor.clone()
    x1 = b_f[..., 0].clone()
    x2 = b_f[..., 2].clone()
    b_f[..., 0] = 1.0 - x2
    b_f[..., 2] = 1.0 - x1
    return rgb_f, b_f


def gaic_loss(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """
    pred: [1, K], target: [1, K]
    Combines SmoothL1 regression + listwise Pearson correlation + weighted pairwise margin ranking.
    """
    p = pred[0]
    y = target[0]
    loss_reg = F.smooth_l1_loss(p, y, beta=0.35)

    p_c = p - p.mean()
    y_c = y - y.mean()
    denom = torch.sqrt((p_c.pow(2).sum() + 1e-6) * (y_c.pow(2).sum() + 1e-6))
    corr = (p_c * y_c).sum() / denom
    loss_corr = 1.0 - corr

    # Pairwise margin ranking: y_i - y_j >= 0.25 -> pred_i - pred_j >= 0.65 * (y_i - y_j)
    y_diff = y.unsqueeze(1) - y.unsqueeze(0)  # [K, K]
    p_diff = p.unsqueeze(1) - p.unsqueeze(0)
    mask = y_diff >= 0.25
    if mask.any():
        weights = torch.where(y.unsqueeze(1) >= 3.8, 2.0, 1.0).expand_as(y_diff)
        hinge = F.relu(0.65 * y_diff - p_diff)
        loss_rank = (hinge[mask] * weights[mask]).mean()
    else:
        loss_rank = p.new_tensor(0.0)

    return 0.45 * loss_reg + 1.0 * loss_corr + 1.25 * loss_rank


@torch.no_grad()
def evaluate(model: GAICCompositionScorer, val_samples: list[dict]) -> dict:
    model.eval()
    srccs, plccs, top1_moss, best_moss, acc5, acc10 = [], [], [], [], [], []
    for s in val_samples:
        img = torch.from_numpy(s["rgb_u8"]).permute(2, 0, 1).unsqueeze(0).float() / 255.0
        bxs = torch.from_numpy(s["boxes"]).unsqueeze(0)
        y = s["scores"]
        pred = model(img, bxs)[0].cpu().numpy()
        sr = float(spearmanr(pred, y).statistic)
        pr = float(pearsonr(pred, y).statistic)
        if not math.isfinite(sr):
            sr = 0.0
        if not math.isfinite(pr):
            pr = 0.0
        order_pred = np.argsort(-pred)
        order_gt = np.argsort(-y)
        best_idx = int(order_gt[0])
        srccs.append(sr)
        plccs.append(pr)
        top1_moss.append(float(y[order_pred[0]]))
        best_moss.append(float(y[best_idx]))
        acc5.append(1.0 if best_idx in set(order_pred[:5].tolist()) else 0.0)
        acc10.append(1.0 if best_idx in set(order_pred[:10].tolist()) else 0.0)
    return {
        "val_srcc": float(np.mean(srccs)),
        "val_plcc": float(np.mean(plccs)),
        "val_top1_mos": float(np.mean(top1_moss)),
        "val_gt_best_mos": float(np.mean(best_moss)),
        "val_acc1_5": float(np.mean(acc5)) * 100.0,
        "val_acc1_10": float(np.mean(acc10)) * 100.0,
    }


def save_checkpoint(model: GAICCompositionScorer, out_pt: Path, meta: dict):
    out_pt.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"state_dict": model.state_dict(), "meta": meta}, out_pt)
    sha = hashlib.sha256(out_pt.read_bytes()).hexdigest()
    (out_pt.parent / "weights_sha256.txt").write_text(f"{sha}  {out_pt.name}\n", encoding="utf-8")
    (out_pt.parent / "train_summary.json").write_text(json.dumps({**meta, "sha256": sha}, indent=2), encoding="utf-8")
    return sha


def freeze_batchnorms(module: nn.Module):
    """Keep BatchNorm2d running stats & affine behavior stable during B=1 fine-tuning."""
    for m in module.modules():
        if isinstance(m, nn.BatchNorm2d):
            m.eval()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gaic-root", type=Path, default=Path(r"C:\Users\admin\Downloads\GAIC\GAIC"))
    parser.add_argument("--out-dir", type=Path, default=THIS_DIR)
    parser.add_argument("--stage1-epochs", type=int, default=14)
    parser.add_argument("--stage2-epochs", type=int, default=3)
    parser.add_argument("--backbone", type=str, default="mobilenetv3_large_100")
    args = parser.parse_args()

    torch.set_num_threads(4)
    torch.manual_seed(42)
    rng = np.random.default_rng(42)

    t0 = time.time()
    print("[GAIC-Train] Loading 1,036 train images & annotations (leak-free split)...", flush=True)
    tr_files, va_files = load_gaic_split(args.gaic_root, val_count=100, seed=42)
    tr_samples = [parse_sample(im_p, ann_p) for _, im_p, ann_p in tr_files]
    va_samples = [parse_sample(im_p, ann_p) for _, im_p, ann_p in va_files]
    print(f"[GAIC-Train] Loaded train={len(tr_samples)}, val={len(va_samples)} in {time.time()-t0:.1f}s", flush=True)

    model = GAICCompositionScorer(backbone_name=args.backbone, pretrained=True)
    init_eval = evaluate(model, va_samples)
    print(f"[GAIC-Train] Init (random head): {json.dumps(init_eval)}", flush=True)

    # ------------------------------------------------------------------
    # Stage 1: Cache backbone features (orig + flipped) and train head/FPN
    # ------------------------------------------------------------------
    print("[GAIC-Train] Stage 1: Extracting backbone feature maps...", flush=True)
    t1 = time.time()
    model.eval()
    cached_feats = []
    with torch.no_grad():
        for s in tr_samples:
            img = torch.from_numpy(s["rgb_u8"]).permute(2, 0, 1).unsqueeze(0).float() / 255.0
            bxs = torch.from_numpy(s["boxes"]).unsqueeze(0)
            y = torch.from_numpy(s["scores"]).unsqueeze(0)

            img_n = (img - model.mean) / model.std
            f3, f4, f5 = model.backbone(img_n)
            img_f, bxs_f = flip_sample_data(img, bxs)
            img_fn = (img_f - model.mean) / model.std
            f3f, f4f, f5f = model.backbone(img_fn)
            cached_feats.append({
                "f_orig": (f3.half(), f4.half(), f5.half()),
                "b_orig": bxs,
                "f_flip": (f3f.half(), f4f.half(), f5f.half()),
                "b_flip": bxs_f,
                "y": y,
            })
    print(f"[GAIC-Train] Cached {len(cached_feats)}x2 feature pyramids in {time.time()-t1:.1f}s", flush=True)

    for p in model.backbone.parameters():
        p.requires_grad = False
    head_params = [p for n, p in model.named_parameters() if not n.startswith("backbone.")]
    opt1 = torch.optim.AdamW(head_params, lr=1.2e-3, weight_decay=2e-4)
    sched1 = torch.optim.lr_scheduler.CosineAnnealingLR(opt1, T_max=args.stage1_epochs, eta_min=1e-4)

    best_score = -1.0
    out_pt = args.out_dir / "gaic_cropper.pt"

    def run_fpn_on_cached(f3, f4, f5, boxes, scores):
        h3, w3 = int(f3.shape[-2]), int(f3.shape[-1])
        p3 = model.p3_lat(f3.float())
        p4 = F.interpolate(model.p4_lat(f4.float()), size=(h3, w3), mode="bilinear", align_corners=False)
        p5 = F.interpolate(model.p5_lat(f5.float()), size=(h3, w3), mode="bilinear", align_corners=False)
        fused = model.fpn_fuse(torch.cat([p3, p4, p5], dim=1))
        roi_map = model.roi_spatial_proj(fused)
        rod_map = model.rod_spatial_proj(fused)
        sem_map = model.sem_proj(fused)
        g_vec = model.global_proj(f5.float().mean(dim=(2, 3)))
        # Mild box coordinate jitter during warmup regularization
        b_jit = (boxes + (torch.rand_like(boxes) - 0.5) * 0.012).clamp(0.0, 1.0)
        b_jit[..., 2] = torch.maximum(b_jit[..., 2], b_jit[..., 0] + 0.02)
        b_jit[..., 3] = torch.maximum(b_jit[..., 3], b_jit[..., 1] + 0.02)
        pred = model.score_boxes(roi_map, rod_map, sem_map, g_vec, b_jit)
        return gaic_loss(pred, scores)

    for ep in range(1, args.stage1_epochs + 1):
        te = time.time()
        model.train()
        order = rng.permutation(len(cached_feats))
        losses = []
        opt1.zero_grad()
        accum = 16
        for step, idx in enumerate(order):
            c = cached_feats[idx]
            use_flip = bool(rng.integers(0, 2))
            f3, f4, f5 = c["f_flip"] if use_flip else c["f_orig"]
            bxs = c["b_flip"] if use_flip else c["b_orig"]
            loss = run_fpn_on_cached(f3, f4, f5, bxs, c["y"]) / accum
            loss.backward()
            losses.append(float(loss.item() * accum))
            if (step + 1) % accum == 0 or (step + 1) == len(order):
                torch.nn.utils.clip_grad_norm_(head_params, 2.0)
                opt1.step()
                opt1.zero_grad()
        sched1.step()
        m = evaluate(model, va_samples)
        comb = m["val_srcc"] + 0.15 * (m["val_top1_mos"] - 3.5)
        if comb > best_score:
            best_score = comb
            save_checkpoint(model, out_pt, {"stage": 1, "epoch": ep, **m})
        print(
            f"[Stage1 Ep {ep:02d}/{args.stage1_epochs}] loss={np.mean(losses):.4f} "
            f"val_srcc={m['val_srcc']:.4f} val_plcc={m['val_plcc']:.4f} "
            f"top1_mos={m['val_top1_mos']:.3f} acc1/5={m['val_acc1_5']:.1f}% ({time.time()-te:.1f}s)",
            flush=True,
        )

    del cached_feats  # free cached feature tensors before end-to-end tuning

    # ------------------------------------------------------------------
    # Stage 2: End-to-End Fine-Tuning with Image + Box Augmentation
    # ------------------------------------------------------------------
    if args.stage2_epochs > 0:
        ckpt = torch.load(out_pt, map_location="cpu", weights_only=True)
        model.load_state_dict(ckpt["state_dict"])
        for p in model.backbone.parameters():
            p.requires_grad = True
        bb_params = [p for n, p in model.named_parameters() if n.startswith("backbone.")]
        hd_params = [p for n, p in model.named_parameters() if not n.startswith("backbone.")]
        opt2 = torch.optim.AdamW([
            {"params": bb_params, "lr": 1.8e-4},
            {"params": hd_params, "lr": 4.0e-4},
        ], weight_decay=2e-4)
        sched2 = torch.optim.lr_scheduler.CosineAnnealingLR(opt2, T_max=args.stage2_epochs, eta_min=2e-5)

        for ep in range(1, args.stage2_epochs + 1):
            te = time.time()
            model.train()
            freeze_batchnorms(model)
            order = rng.permutation(len(tr_samples))
            losses = []
            opt2.zero_grad()
            accum = 12
            for step, idx in enumerate(order):
                s = tr_samples[idx]
                img = torch.from_numpy(s["rgb_u8"]).permute(2, 0, 1).unsqueeze(0).float() / 255.0
                bxs = torch.from_numpy(s["boxes"]).unsqueeze(0)
                y = torch.from_numpy(s["scores"]).unsqueeze(0)

                if rng.random() < 0.5:
                    img, bxs = flip_sample_data(img, bxs)
                # Mild brightness & contrast augmentation
                alpha = float(rng.uniform(0.90, 1.10))
                beta = float(rng.uniform(-0.04, 0.04))
                img = (img * alpha + beta).clamp(0.0, 1.0)
                bxs = (bxs + (torch.rand_like(bxs) - 0.5) * 0.010).clamp(0.0, 1.0)
                bxs[..., 2] = torch.maximum(bxs[..., 2], bxs[..., 0] + 0.02)
                bxs[..., 3] = torch.maximum(bxs[..., 3], bxs[..., 1] + 0.02)

                pred = model(img, bxs)
                loss = gaic_loss(pred, y) / accum
                loss.backward()
                losses.append(float(loss.item() * accum))
                if (step + 1) % accum == 0 or (step + 1) == len(order):
                    torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                    opt2.step()
                    opt2.zero_grad()
            sched2.step()
            m = evaluate(model, va_samples)
            comb = m["val_srcc"] + 0.15 * (m["val_top1_mos"] - 3.5)
            if comb > best_score:
                best_score = comb
                save_checkpoint(model, out_pt, {"stage": 2, "epoch": ep, **m})
            print(
                f"[Stage2 Ep {ep:02d}/{args.stage2_epochs}] loss={np.mean(losses):.4f} "
                f"val_srcc={m['val_srcc']:.4f} val_plcc={m['val_plcc']:.4f} "
                f"top1_mos={m['val_top1_mos']:.3f} acc1/5={m['val_acc1_5']:.1f}% ({time.time()-te:.1f}s)",
                flush=True,
            )

    summary = json.loads((args.out_dir / "train_summary.json").read_text(encoding="utf-8"))
    print(f"[GAIC-Train] Finished! Best checkpoint summary: {json.dumps(summary)}", flush=True)


if __name__ == "__main__":
    main()
