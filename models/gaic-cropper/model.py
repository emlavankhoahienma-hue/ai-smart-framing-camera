"""
CoreML-friendly RoI + RoD Image Cropping Scorer (GAICCompositionScorer).
Pure PyTorch standard ops (Conv2d, BatchNorm, SiLU/Hardswish, bilinear F.grid_sample, Linear, LayerNorm)
targeting iOS 17+ Apple Neural Engine via CoreML mlprogram (FP16).
"""
from __future__ import annotations

import math
from typing import Optional
import torch
import torch.nn as nn
import torch.nn.functional as F
import timm

MAX_EXPORT_BOXES = 256
IMAGE_SIZE = 256


class DSConvBlock(nn.Module):
    def __init__(self, in_ch: int, out_ch: int):
        super().__init__()
        self.proj = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, kernel_size=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.SiLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, kernel_size=3, padding=1, groups=out_ch, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.SiLU(inplace=True),
            nn.Conv2d(out_ch, out_ch, kernel_size=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.SiLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.proj(x)


class GAICCompositionScorer(nn.Module):
    """
    Scores N candidate crop boxes [x1, y1, x2, y2] in [0, 1] on a single RGB image [0, 1]
    in one forward pass using spatial RoI (4x4 layout), RoD (4x4 surrounding context),
    high-channel semantic RoI, global scene context, and geometric layout encoding.
    """

    def __init__(self, backbone_name: str = "mobilenetv3_large_100", pretrained: bool = True):
        super().__init__()
        self.backbone_name = backbone_name
        self.backbone = timm.create_model(
            backbone_name, pretrained=pretrained, features_only=True, out_indices=(2, 3, 4)
        )
        c3, c4, c5 = self.backbone.feature_info.channels()

        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406], dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225], dtype=torch.float32).view(1, 3, 1, 1))

        self.p3_lat = nn.Sequential(nn.Conv2d(c3, 64, 1, bias=False), nn.BatchNorm2d(64), nn.SiLU(inplace=True))
        self.p4_lat = nn.Sequential(nn.Conv2d(c4, 64, 1, bias=False), nn.BatchNorm2d(64), nn.SiLU(inplace=True))
        self.p5_lat = nn.Sequential(nn.Conv2d(c5, 64, 1, bias=False), nn.BatchNorm2d(64), nn.SiLU(inplace=True))

        self.fpn_fuse = DSConvBlock(192, 128)
        self.roi_spatial_proj = nn.Sequential(nn.Conv2d(128, 24, 1, bias=False), nn.BatchNorm2d(24), nn.SiLU(inplace=True))
        self.rod_spatial_proj = nn.Sequential(nn.Conv2d(128, 16, 1, bias=False), nn.BatchNorm2d(16), nn.SiLU(inplace=True))
        self.sem_proj = nn.Sequential(nn.Conv2d(128, 96, 1, bias=False), nn.BatchNorm2d(96), nn.SiLU(inplace=True))

        # 4x4 interior grid in [-0.75..0.75] (subcell centers inside box) and 4x4 RoD context grid in [-1.5..1.5]
        pts4 = torch.tensor([-0.75, -0.25, 0.25, 0.75], dtype=torch.float32)
        gy4, gx4 = torch.meshgrid(pts4, pts4, indexing="ij")
        self.register_buffer("grid_4x4", torch.stack([gx4, gy4], dim=-1))  # [4, 4, 2]

        pts3 = torch.tensor([-0.67, 0.0, 0.67], dtype=torch.float32)
        gy3, gx3 = torch.meshgrid(pts3, pts3, indexing="ij")
        self.register_buffer("grid_3x3", torch.stack([gx3, gy3], dim=-1))  # [3, 3, 2]

        self.global_proj = nn.Sequential(
            nn.Linear(c5, 64),
            nn.LayerNorm(64),
            nn.SiLU(inplace=True),
        )
        self.geom_proj = nn.Sequential(
            nn.Linear(12, 32),
            nn.LayerNorm(32),
            nn.SiLU(inplace=True),
        )
        # 24*16 (384) + 16*16 (256) + 96 + 64 + 32 = 832
        self.head = nn.Sequential(
            nn.Linear(832, 256),
            nn.LayerNorm(256),
            nn.SiLU(inplace=True),
            nn.Dropout(p=0.15),
            nn.Linear(256, 64),
            nn.SiLU(inplace=True),
            nn.Linear(64, 1),
        )

    def extract_image_maps(
        self, image: torch.Tensor, static_fpn_size: Optional[tuple[int, int]] = None
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        """Compute multi-scale spatial feature maps once per image."""
        x = (image - self.mean) / self.std
        f3, f4, f5 = self.backbone(x)
        if static_fpn_size is not None:
            out_hw = static_fpn_size
        else:
            out_hw = (int(f3.shape[-2]), int(f3.shape[-1]))
        p3 = self.p3_lat(f3)
        p4 = F.interpolate(self.p4_lat(f4), size=out_hw, mode="bilinear", align_corners=False)
        p5 = F.interpolate(self.p5_lat(f5), size=out_hw, mode="bilinear", align_corners=False)
        fused = self.fpn_fuse(torch.cat([p3, p4, p5], dim=1))
        roi_map = self.roi_spatial_proj(fused)
        rod_map = self.rod_spatial_proj(fused)
        sem_map = self.sem_proj(fused)
        g_vec = self.global_proj(f5.mean(dim=(2, 3)))  # [1, 64]
        return roi_map, rod_map, sem_map, g_vec

    def score_boxes(
        self,
        roi_map: torch.Tensor,
        rod_map: torch.Tensor,
        sem_map: torch.Tensor,
        g_vec: torch.Tensor,
        boxes: torch.Tensor,
        static_num_boxes: Optional[int] = None,
    ) -> torch.Tensor:
        """
        boxes: [1, N, 4] float32 [x1, y1, x2, y2] in [0, 1].
        Returns [1, N] predicted MOS scores.
        """
        n_boxes = static_num_boxes if static_num_boxes is not None else int(boxes.shape[1])

        b_norm = boxes * 2.0 - 1.0
        bx1 = b_norm[0:1, :, 0:1]
        by1 = b_norm[0:1, :, 1:2]
        bx2 = b_norm[0:1, :, 2:3]
        by2 = b_norm[0:1, :, 3:4]
        cx = 0.5 * (bx1 + bx2)
        cy = 0.5 * (by1 + by2)
        hw = 0.5 * (bx2 - bx1)
        hh = 0.5 * (by2 - by1)

        g4 = self.grid_4x4.view(1, 1, 4, 4, 2)
        roi_gx = cx.view(1, n_boxes, 1, 1) + hw.view(1, n_boxes, 1, 1) * g4[..., 0]
        roi_gy = cy.view(1, n_boxes, 1, 1) + hh.view(1, n_boxes, 1, 1) * g4[..., 1]
        roi_grid = torch.stack([roi_gx, roi_gy], dim=-1).view(1, n_boxes * 4, 4, 2)
        roi_samp = F.grid_sample(roi_map, roi_grid, mode="bilinear", padding_mode="border", align_corners=False)
        # [1, 24, n_boxes*4, 4] -> [n_boxes, 24*16]
        roi_flat = roi_samp.view(1, 24, n_boxes, 4, 4).squeeze(0).permute(1, 0, 2, 3).reshape(n_boxes, 384)

        # RoD expanded context (1.55x box around center, zero-padded outside image bounds)
        rod_gx = cx.view(1, n_boxes, 1, 1) + (hw * 1.55).view(1, n_boxes, 1, 1) * g4[..., 0]
        rod_gy = cy.view(1, n_boxes, 1, 1) + (hh * 1.55).view(1, n_boxes, 1, 1) * g4[..., 1]
        rod_grid = torch.stack([rod_gx, rod_gy], dim=-1).view(1, n_boxes * 4, 4, 2)
        rod_samp = F.grid_sample(rod_map, rod_grid, mode="bilinear", padding_mode="zeros", align_corners=False)
        rod_flat = rod_samp.view(1, 16, n_boxes, 4, 4).squeeze(0).permute(1, 0, 2, 3).reshape(n_boxes, 256)

        # High-channel semantic RoI 3x3 average
        g3 = self.grid_3x3.view(1, 1, 3, 3, 2)
        sem_gx = cx.view(1, n_boxes, 1, 1) + hw.view(1, n_boxes, 1, 1) * g3[..., 0]
        sem_gy = cy.view(1, n_boxes, 1, 1) + hh.view(1, n_boxes, 1, 1) * g3[..., 1]
        sem_grid = torch.stack([sem_gx, sem_gy], dim=-1).view(1, n_boxes * 3, 3, 2)
        sem_samp = F.grid_sample(sem_map, sem_grid, mode="bilinear", padding_mode="border", align_corners=False)
        sem_vec = sem_samp.view(1, 96, n_boxes, 9).mean(dim=-1).squeeze(0).transpose(0, 1)  # [n_boxes, 96]

        # Global scene vector expanded to [n_boxes, 64]
        g_exp = g_vec.expand(n_boxes, 64)

        # Box geometry in [0, 1]
        x1 = boxes[0, :, 0:1]
        y1 = boxes[0, :, 1:2]
        x2 = boxes[0, :, 2:3]
        y2 = boxes[0, :, 3:4]
        bw = (x2 - x1).clamp(min=1e-4)
        bh = (y2 - y1).clamp(min=1e-4)
        bcx = 0.5 * (x1 + x2)
        bcy = 0.5 * (y1 + y2)
        area = bw * bh
        log_ar = torch.log(bw / bh)
        min_x_edge = torch.minimum(x1, 1.0 - x2)
        min_y_edge = torch.minimum(y1, 1.0 - y2)
        geom_raw = torch.cat([x1, y1, x2, y2, bw, bh, bcx, bcy, area, log_ar, min_x_edge, min_y_edge], dim=-1)
        geom_vec = self.geom_proj(geom_raw)

        feat_all = torch.cat([roi_flat, rod_flat, sem_vec, g_exp, geom_vec], dim=-1)
        scores = self.head(feat_all).squeeze(-1).unsqueeze(0)  # [1, n_boxes]
        return scores

    def forward(self, image: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        roi_map, rod_map, sem_map, g_vec = self.extract_image_maps(image)
        return self.score_boxes(roi_map, rod_map, sem_map, g_vec, boxes, static_num_boxes=None)


class GAICExportWrapper(nn.Module):
    """Fixed-N CoreML-traceable wrapper with zero dynamic integer casts."""

    def __init__(self, core: GAICCompositionScorer, num_boxes: int = MAX_EXPORT_BOXES):
        super().__init__()
        self.core = core
        self.num_boxes = num_boxes

    def forward(self, image: torch.Tensor, boxes: torch.Tensor) -> torch.Tensor:
        roi_map, rod_map, sem_map, g_vec = self.core.extract_image_maps(
            image, static_fpn_size=(IMAGE_SIZE // 8, IMAGE_SIZE // 8)
        )
        return self.core.score_boxes(roi_map, rod_map, sem_map, g_vec, boxes, static_num_boxes=self.num_boxes)
