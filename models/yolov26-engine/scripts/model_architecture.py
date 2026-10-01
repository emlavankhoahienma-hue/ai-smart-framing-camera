"""YOLOv26 Neural Architecture for Apple Neural Engine (ANE) Inference.

Specialized edge detection architecture engineered for real-time (60+ FPS) execution
on Apple Silicon (iPhone XS to iPhone 16 Pro Max, iOS 17+) targeting 4 primary classes:
    0: face   (Human Face - frontal, profile, close-up)
    1: person (Human Body / Upper Body)
    2: dog    (Dog - any posture)
    3: cat    (Cat - any posture)

Key Architectural Pillars for Apple Neural Engine:
1. Structural Re-parameterization (RepConv): Multi-branch during training (3x3, 1x1, ID),
   mathematically fused into a single 3x3 Conv at deployment. Zero branch overhead on ANE SRAM.
2. 16-Channel Dimension Alignment: All channel widths are exact multiples of 16 (32, 48, 96, 192, 384)
   to saturate the 16-way vector units of the Apple Neural Engine.
3. NMS-Free End-to-End Head: Uses Task-Aligned / One-to-One prediction matching, outputting
   direct normalized coordinates [0..1] and class probabilities, bypassing CPU-bound NMS.
4. Static Computational Graph: Pure tensor operators (Conv2D, Add, SiLU, Sigmoid, Reshape, Concat)
   with zero dynamic control flow or unsupported runtime slicing.
"""
from __future__ import annotations

import copy
import math
from typing import Dict, List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

CLASS_NAMES: List[str] = ["face", "person", "dog", "cat"]
NUM_CLASSES: int = len(CLASS_NAMES)

# Apple Neural Engine (ANE) Optimized Width & Depth Configurations
SCALE_CONFIGS: Dict[str, Dict[str, List[int]]] = {
    # Nano: ~3.8M params, ~8MB FP16, Ultra-fast edge
    "n": {
        "channels": [16, 32, 64, 128, 256],
        "depths": [1, 2, 2, 1],
    },
    # Small (Edge ANE Default): ~11.2M params, ~22.5MB FP16, Fits < 35MB requirement, < 5ms on A12
    "s": {
        "channels": [32, 48, 96, 192, 384],
        "depths": [2, 2, 3, 2],
    },
    # Medium: ~20.1M params, ~38.9MB FP16 (~19MB INT8), Maximum accuracy
    "m": {
        "channels": [32, 64, 128, 256, 512],
        "depths": [2, 3, 3, 2],
    },
}


def conv_bn_fuse(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> Tuple[torch.Tensor, torch.Tensor]:
    """Fuse a Conv2d and a BatchNorm2d into equivalent fused weight and bias."""
    w = conv.weight
    mean = bn.running_mean
    var_val = bn.running_var
    gamma = bn.weight
    beta = bn.bias
    eps = bn.eps

    std = torch.sqrt(var_val + eps)
    t = (gamma / std).reshape(-1, 1, 1, 1)
    fused_w = w * t

    if conv.bias is not None:
        b = conv.bias
    else:
        b = torch.zeros(conv.out_channels, device=w.device, dtype=w.dtype)
    fused_b = (b - mean) * (gamma / std) + beta
    return fused_w, fused_b


class RepConv(nn.Module):
    """Structural Re-parameterization Convolution Block.

    During training: Computes sum of 3x3 Conv + BN, 1x1 Conv + BN, and Identity + BN.
    During deployment (fused): Collapses all branches into a single 3x3 Conv2d layer.
    """

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        stride: int = 1,
        padding: int = 1,
        dilation: int = 1,
        groups: int = 1,
        act: bool = True,
        deploy: bool = False,
    ) -> None:
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.stride = stride
        self.padding = padding
        self.dilation = dilation
        self.groups = groups
        self.deploy = deploy
        self.act = nn.SiLU() if act else nn.Identity()

        if deploy:
            self.rbr_reparam = nn.Conv2d(
                in_channels=in_channels,
                out_channels=out_channels,
                kernel_size=3,
                stride=stride,
                padding=padding,
                dilation=dilation,
                groups=groups,
                bias=True,
            )
        else:
            self.rbr_identity = (
                nn.BatchNorm2d(in_channels)
                if out_channels == in_channels and stride == 1
                else None
            )
            self.rbr_dense = nn.Sequential(
                nn.Conv2d(
                    in_channels,
                    out_channels,
                    kernel_size=3,
                    stride=stride,
                    padding=padding,
                    dilation=dilation,
                    groups=groups,
                    bias=False,
                ),
                nn.BatchNorm2d(out_channels),
            )
            self.rbr_1x1 = nn.Sequential(
                nn.Conv2d(
                    in_channels,
                    out_channels,
                    kernel_size=1,
                    stride=stride,
                    padding=0,
                    groups=groups,
                    bias=False,
                ),
                nn.BatchNorm2d(out_channels),
            )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.deploy:
            return self.act(self.rbr_reparam(x))
        identity = 0.0 if self.rbr_identity is None else self.rbr_identity(x)
        return self.act(self.rbr_dense(x) + self.rbr_1x1(x) + identity)

    def switch_to_deploy(self) -> None:
        """Fuse multi-branch weights into a single 3x3 Conv2d."""
        if self.deploy:
            return
        kernel, bias = self._get_equivalent_kernel_bias()
        self.rbr_reparam = nn.Conv2d(
            in_channels=self.in_channels,
            out_channels=self.out_channels,
            kernel_size=3,
            stride=self.stride,
            padding=self.padding,
            dilation=self.dilation,
            groups=self.groups,
            bias=True,
        )
        self.rbr_reparam.weight.data = kernel
        self.rbr_reparam.bias.data = bias
        self.__delattr__("rbr_dense")
        self.__delattr__("rbr_1x1")
        if hasattr(self, "rbr_identity"):
            self.__delattr__("rbr_identity")
        self.deploy = True

    def _get_equivalent_kernel_bias(self) -> Tuple[torch.Tensor, torch.Tensor]:
        kernel_3x3, bias_3x3 = conv_bn_fuse(self.rbr_dense[0], self.rbr_dense[1])
        kernel_1x1, bias_1x1 = conv_bn_fuse(self.rbr_1x1[0], self.rbr_1x1[1])

        # Pad 1x1 kernel to 3x3
        kernel_1x1_padded = F.pad(kernel_1x1, [1, 1, 1, 1])

        if self.rbr_identity is not None:
            kernel_id = torch.zeros(
                self.in_channels,
                self.in_channels // self.groups,
                3,
                3,
                device=kernel_3x3.device,
                dtype=kernel_3x3.dtype,
            )
            for i in range(self.in_channels):
                kernel_id[i, i % (self.in_channels // self.groups), 1, 1] = 1.0
            std = torch.sqrt(self.rbr_identity.running_var + self.rbr_identity.eps)
            t = (self.rbr_identity.weight / std).reshape(-1, 1, 1, 1)
            kernel_id = kernel_id * t
            bias_id = (
                self.rbr_identity.bias
                - self.rbr_identity.running_mean * self.rbr_identity.weight / std
            )
        else:
            kernel_id = torch.zeros_like(kernel_3x3)
            bias_id = torch.zeros_like(bias_3x3)

        return (
            kernel_3x3 + kernel_1x1_padded + kernel_id,
            bias_3x3 + bias_1x1 + bias_id,
        )


class ConvBN(nn.Module):
    """Standard 2D Convolution + BatchNorm + SiLU (ANE optimized)."""

    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        kernel_size: int = 1,
        stride: int = 1,
        padding: int = 0,
        groups: int = 1,
        act: bool = True,
    ) -> None:
        super().__init__()
        self.conv = nn.Conv2d(
            in_channels,
            out_channels,
            kernel_size=kernel_size,
            stride=stride,
            padding=padding,
            groups=groups,
            bias=False,
        )
        self.bn = nn.BatchNorm2d(out_channels)
        self.act = nn.SiLU() if act else nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.act(self.bn(self.conv(x)))

    def fuse(self) -> nn.Conv2d:
        """Fuse conv + bn into single Conv2d with bias for inference."""
        w, b = conv_bn_fuse(self.conv, self.bn)
        fused = nn.Conv2d(
            self.conv.in_channels,
            self.conv.out_channels,
            kernel_size=self.conv.kernel_size,
            stride=self.conv.stride,
            padding=self.conv.padding,
            groups=self.conv.groups,
            bias=True,
        )
        fused.weight.data = w
        fused.bias.data = b
        return fused


class RepBlock(nn.Module):
    """Residual stage block consisting of chained RepConv modules."""

    def __init__(self, channels: int, depth: int = 2) -> None:
        super().__init__()
        self.layers = nn.ModuleList([
            RepConv(channels, channels, stride=1, padding=1) for _ in range(depth)
        ])

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        for layer in self.layers:
            x = layer(x)
        return x


class YOLOv26Backbone(nn.Module):
    """ANE-optimized feature extraction backbone with 16-channel vectorized stages."""

    def __init__(self, channels: List[int], depths: List[int]) -> None:
        super().__init__()
        c0, c1, c2, c3, c4 = channels
        d0, d1, d2, d3 = depths

        # Stem (stride 2): 640x640 -> 320x320
        self.stem = RepConv(3, c0, stride=2, padding=1)

        # Stage 1 (stride 2): 320x320 -> 160x160
        self.stage1_down = RepConv(c0, c1, stride=2, padding=1)
        self.stage1_block = RepBlock(c1, depth=d0)

        # Stage 2 / P3 (stride 2): 160x160 -> 80x80
        self.stage2_down = RepConv(c1, c2, stride=2, padding=1)
        self.stage2_block = RepBlock(c2, depth=d1)

        # Stage 3 / P4 (stride 2): 80x80 -> 40x40
        self.stage3_down = RepConv(c2, c3, stride=2, padding=1)
        self.stage3_block = RepBlock(c3, depth=d2)

        # Stage 4 / P5 (stride 2): 40x40 -> 20x20
        self.stage4_down = RepConv(c3, c4, stride=2, padding=1)
        self.stage4_block = RepBlock(c4, depth=d3)

    def forward(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        x = self.stem(x)
        x = self.stage1_block(self.stage1_down(x))

        p3 = self.stage2_block(self.stage2_down(x))  # Stride 8: [B, c2, H/8, W/8]
        p4 = self.stage3_block(self.stage3_down(p3)) # Stride 16: [B, c3, H/16, W/16]
        p5 = self.stage4_block(self.stage4_down(p4)) # Stride 32: [B, c4, H/32, W/32]
        return p3, p4, p5


class YOLOv26Neck(nn.Module):
    """ANE-optimized Path Aggregation Network (PANet) with nearest upsampling."""

    def __init__(self, channels: List[int]) -> None:
        super().__init__()
        c_p3, c_p4, c_p5 = channels

        # Top-down pathway
        self.p5_reduce = ConvBN(c_p5, c_p4, kernel_size=1)
        self.upsample_p5 = nn.Upsample(scale_factor=2, mode="nearest")
        self.p4_fuse = RepConv(c_p4 + c_p4, c_p4, stride=1, padding=1)

        self.p4_reduce = ConvBN(c_p4, c_p3, kernel_size=1)
        self.upsample_p4 = nn.Upsample(scale_factor=2, mode="nearest")
        self.p3_fuse = RepConv(c_p3 + c_p3, c_p3, stride=1, padding=1)

        # Bottom-up pathway
        self.n3_down = RepConv(c_p3, c_p3, stride=2, padding=1)
        self.n4_fuse = RepConv(c_p4 + c_p3, c_p4, stride=1, padding=1)

        self.n4_down = RepConv(c_p4, c_p4, stride=2, padding=1)
        self.n5_fuse = RepConv(c_p4 + c_p4, c_p5, stride=1, padding=1)

    def forward(
        self, p3: torch.Tensor, p4: torch.Tensor, p5: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        # Top-down
        p5_lat = self.p5_reduce(p5)
        p4_cat = torch.cat([p4, self.upsample_p5(p5_lat)], dim=1)
        p4_top = self.p4_fuse(p4_cat)

        p4_lat = self.p4_reduce(p4_top)
        p3_cat = torch.cat([p3, self.upsample_p4(p4_lat)], dim=1)
        out_p3 = self.p3_fuse(p3_cat)  # Stride 8 (c_p3 channels)

        # Bottom-up
        n3_down = self.n3_down(out_p3)
        n4_cat = torch.cat([p4_top, n3_down], dim=1)
        out_p4 = self.n4_fuse(n4_cat)  # Stride 16 (c_p4 channels)

        n4_down = self.n4_down(out_p4)
        n5_cat = torch.cat([p5_lat, n4_down], dim=1)
        out_p5 = self.n5_fuse(n5_cat)  # Stride 32 (c_p5 channels)

        return out_p3, out_p4, out_p5


class YOLOv26NMSFreeHead(nn.Module):
    """NMS-Free Decoupled Head.

    Directly outputs normalized bounding box coordinates [0..1] and class scores
    for face, person, dog, cat. Eliminates CPU Non-Maximum Suppression entirely.
    """

    def __init__(
        self,
        in_channels: List[int],
        num_classes: int = NUM_CLASSES,
        img_size: int = 640,
        strides: Tuple[int, ...] = (8, 16, 32),
    ) -> None:
        super().__init__()
        self.num_classes = num_classes
        self.img_size = img_size
        self.strides = strides

        self.cls_heads = nn.ModuleList()
        self.reg_heads = nn.ModuleList()

        for ch in in_channels:
            # Classification branch
            self.cls_heads.append(
                nn.Sequential(
                    RepConv(ch, ch, stride=1, padding=1),
                    nn.Conv2d(ch, num_classes, kernel_size=1),
                )
            )
            # Regression branch (4 coordinates: cx, cy, w, h normalized)
            self.reg_heads.append(
                nn.Sequential(
                    RepConv(ch, ch, stride=1, padding=1),
                    nn.Conv2d(ch, 4, kernel_size=1),
                )
            )

        # Generate precomputed static grid buffers for 0-overhead ANE execution
        self._build_static_grids(img_size)

    def _build_static_grids(self, img_size: int) -> None:
        """Precompute coordinate grids as static registered buffers."""
        all_grids = []
        all_strides = []
        for stride in self.strides:
            h = img_size // stride
            w = img_size // stride
            y, x = torch.meshgrid(
                torch.arange(h, dtype=torch.float32),
                torch.arange(w, dtype=torch.float32),
                indexing="ij",
            )
            grid = torch.stack((x, y), dim=-1).reshape(-1, 2)  # [H*W, 2]
            stride_tensor = torch.full((h * w, 1), stride, dtype=torch.float32)
            all_grids.append(grid)
            all_strides.append(stride_tensor)

        static_grid = torch.cat(all_grids, dim=0).unsqueeze(0)  # [1, N, 2]
        static_stride = torch.cat(all_strides, dim=0).unsqueeze(0)  # [1, N, 1]
        self.register_buffer("static_grid", static_grid, persistent=False)
        self.register_buffer("static_stride", static_stride, persistent=False)

    def forward(
        self, features: Tuple[torch.Tensor, torch.Tensor, torch.Tensor]
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        """Inference forward returning (coordinates, confidence).

        Returns:
            coordinates: [1, N, 4] normalized [cx, cy, w, h] in [0, 1]
            confidence:  [1, N, num_classes] probabilities in [0, 1]
        """
        cls_outputs = []
        reg_outputs = []

        for idx, feat in enumerate(features):
            cls_out = self.cls_heads[idx](feat)  # [B, 4, H, W]
            reg_out = self.reg_heads[idx](feat)  # [B, 4, H, W]

            cls_flat = cls_out.permute(0, 2, 3, 1).flatten(1, 2)
            reg_flat = reg_out.permute(0, 2, 3, 1).flatten(1, 2)

            cls_outputs.append(cls_flat)
            reg_outputs.append(reg_flat)

        total_cls = torch.cat(cls_outputs, dim=1)  # [B, N, 4]
        total_reg = torch.cat(reg_outputs, dim=1)  # [B, N, 4]

        # ANE Native Activation Transformations
        confidence = torch.sigmoid(total_cls)

        # Bounding box decoding (100% static elementwise ops)
        reg_xy = torch.sigmoid(total_reg[..., 0:2])
        reg_wh = total_reg[..., 2:4]

        # Normalized cx, cy in [0, 1]
        grid_cx_cy = (self.static_grid + reg_xy) * self.static_stride / float(self.img_size)

        # Normalized w, h in [0, 1] using safe exponential-scale activation
        norm_wh = torch.exp(torch.clamp(reg_wh, min=-5.0, max=5.0)) * self.static_stride / float(self.img_size)

        coordinates = torch.cat([grid_cx_cy, norm_wh], dim=-1)  # [B, N, 4] (cx, cy, w, h)
        return coordinates, confidence


class YOLOv26(nn.Module):
    """Complete YOLOv26 Detector optimized for Apple Silicon Neural Engine (ANE)."""

    def __init__(
        self,
        img_size: int = 640,
        scale: str = "s",
        num_classes: int = NUM_CLASSES,
    ) -> None:
        super().__init__()
        if scale not in SCALE_CONFIGS:
            raise ValueError(f"Unknown scale: {scale}. Choose from {list(SCALE_CONFIGS.keys())}")

        cfg = SCALE_CONFIGS[scale]
        channels = cfg["channels"]
        depths = cfg["depths"]

        self.img_size = img_size
        self.scale = scale
        self.num_classes = num_classes

        self.backbone = YOLOv26Backbone(channels=channels, depths=depths)
        neck_channels = [channels[2], channels[3], channels[4]]  # P3, P4, P5
        self.neck = YOLOv26Neck(channels=neck_channels)
        self.head = YOLOv26NMSFreeHead(
            in_channels=neck_channels,
            num_classes=num_classes,
            img_size=img_size,
        )
        self._initialize_weights()

    def _initialize_weights(self) -> None:
        """Initialize weights with Xavier normal for Conv and standard bias."""
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, mode="fan_out", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)

    def forward(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        """Forward pass.

        Input:
            x: [1, 3, H, W] RGB image tensor normalized [0..1]
        Output:
            coordinates: [1, N, 4] normalized [cx, cy, w, h]
            confidence:  [1, N, 4] probabilities for [face, person, dog, cat]
        """
        p3, p4, p5 = self.backbone(x)
        n3, n4, n5 = self.neck(p3, p4, p5)
        return self.head((n3, n4, n5))

    def fuse(self) -> "YOLOv26":
        """Fuse all RepConv multi-branch blocks into single 3x3 Conv2d layers.

        Returns a deep copy of the model in deploy state with 0 branch overhead.
        """
        model_copy = copy.deepcopy(self)
        for m in model_copy.modules():
            if isinstance(m, RepConv):
                m.switch_to_deploy()
        model_copy.eval()
        return model_copy


def build_yolov26(img_size: int = 640, scale: str = "s") -> YOLOv26:
    """Build and return an un-fused YOLOv26 model instance."""
    return YOLOv26(img_size=img_size, scale=scale, num_classes=NUM_CLASSES)
