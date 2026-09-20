"""Synthetic CNN training with measured held-out metrics and optional CoreML export.

Not run as part of the tracking refactor. Synthetic validation is not evidence of
real-world identity robustness. No raw .bin export and no fabricated scores.
Requires: torch, numpy, pillow; export additionally requires coremltools on macOS.
"""
import argparse
import json
import random
from pathlib import Path
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

class SyntheticLightingSimulator:
    """Mô phỏng chân thực các điều kiện ánh sáng khắc nghiệt ngoài trời và trong nhà"""
    
    @staticmethod
    def apply_sun_flare(img):
        """Giả lập mặt trời chiếu chói lóa trực tiếp vào ống kính"""
        draw = ImageDraw.Draw(img)
        w, h = img.size
        center_x = random.randint(0, w)
        center_y = random.randint(0, int(h * 0.4))
        radius = random.randint(30, 80)
        # Quầng sáng mặt trời
        draw.ellipse([center_x - radius, center_y - radius, center_x + radius, center_y + radius], 
                     fill=(255, 250, 220, 180))
        return img.filter(ImageFilter.GaussianBlur(radius=random.randint(4, 10)))
    
    @staticmethod
    def apply_harsh_shadow(img):
        """Giả lập bóng đổ gắt cắt ngang chủ thể lúc giữa trưa"""
        w, h = img.size
        shadow_mask = Image.new("L", (w, h), 255)
        draw = ImageDraw.Draw(shadow_mask)
        split_x = random.randint(int(w * 0.2), int(w * 0.8))
        draw.polygon([(0, 0), (split_x, 0), (max(0, split_x - 30), h), (0, h)], fill=80)
        img_np = np.array(img, dtype=np.float32)
        mask_np = np.array(shadow_mask, dtype=np.float32) / 255.0
        mask_np = np.expand_dims(mask_np, axis=2)
        result = np.clip(img_np * (0.4 + 0.6 * mask_np), 0, 255).astype(np.uint8)
        return Image.fromarray(result)
    
    @staticmethod
    def apply_color_temperature(img):
        """Giả lập nhiệt độ màu thay đổi: 2500K hoàng hôn vàng ấm <-> 9000K trời râm lạnh"""
        enhancer = ImageEnhance.Color(img)
        img = enhancer.enhance(random.uniform(0.5, 1.6))
        img_np = np.array(img, dtype=np.float32)
        # Warm vs Cool shift
        if random.random() > 0.5:
            # Warm: tăng đỏ, vàng
            img_np[:, :, 0] = np.clip(img_np[:, :, 0] * random.uniform(1.05, 1.25), 0, 255)
            img_np[:, :, 2] = np.clip(img_np[:, :, 2] * random.uniform(0.75, 0.95), 0, 255)
        else:
            # Cool: tăng xanh lam
            img_np[:, :, 0] = np.clip(img_np[:, :, 0] * random.uniform(0.75, 0.95), 0, 255)
            img_np[:, :, 2] = np.clip(img_np[:, :, 2] * random.uniform(1.05, 1.25), 0, 255)
        return Image.fromarray(img_np.astype(np.uint8))
    
    @staticmethod
    def apply_extreme_backlight(img):
        """Giả lập ngược sáng cực mạnh (Silhouette & Highlight Blowout)"""
        enhancer_b = ImageEnhance.Brightness(img)
        img = enhancer_b.enhance(random.uniform(0.5, 1.7))
        enhancer_c = ImageEnhance.Contrast(img)
        return enhancer_c.enhance(random.uniform(1.2, 1.8))
    
    @staticmethod
    def apply_motion_blur(img):
        """Giả lập lia máy chuyển động nhanh"""
        return img.filter(ImageFilter.BoxBlur(radius=random.choice([1, 2, 3])))

    @classmethod
    def random_augment(cls, img):
        aug = img.copy()
        if random.random() < 0.4: aug = cls.apply_sun_flare(aug)
        if random.random() < 0.4: aug = cls.apply_harsh_shadow(aug)
        if random.random() < 0.5: aug = cls.apply_color_temperature(aug)
        if random.random() < 0.4: aug = cls.apply_extreme_backlight(aug)
        if random.random() < 0.3: aug = cls.apply_motion_blur(aug)
        return aug

class SyntheticTargetDataset(Dataset):
    """Tạo các cặp Anchor - Positive - Negative với hàng ngàn biến thể ánh sáng"""
    def __init__(self, num_samples=600, img_size=128, identity_offset=0):
        self.num_samples = num_samples
        self.identity_offset = identity_offset
        self.img_size = img_size
        self.simulator = SyntheticLightingSimulator()
        
    def __len__(self):
        return self.num_samples
    
    def _create_base_subject(self, subject_id):
        img = Image.new("RGB", (self.img_size, self.img_size), color=(20, 20, 20))
        draw = ImageDraw.Draw(img)
        rng = random.Random(subject_id)
        
        # Nền phong cảnh / tường ngẫu nhiên
        bg_r = rng.randint(40, 220)
        bg_g = rng.randint(40, 220)
        bg_b = rng.randint(40, 220)
        draw.rectangle([0, 0, self.img_size, self.img_size], fill=(bg_r, bg_g, bg_b))
        
        # Vật thể / Hình khối đặc trưng (Khuôn mặt, người, túi xách, biển hiệu)
        obj_r = rng.randint(30, 240)
        obj_g = rng.randint(30, 240)
        obj_b = rng.randint(30, 240)
        
        shape_type = subject_id % 4
        if shape_type == 0:
            # Mặt người / tròn
            draw.ellipse([30, 25, 98, 103], fill=(obj_r, obj_g, obj_b))
            draw.ellipse([45, 45, 55, 55], fill=(20, 20, 20))
            draw.ellipse([73, 45, 83, 55], fill=(20, 20, 20))
            draw.arc([48, 65, 80, 85], start=0, end=180, fill=(180, 50, 50), width=3)
        elif shape_type == 1:
            # Túi xách / Hình hộp
            draw.rectangle([32, 40, 96, 105], fill=(obj_r, obj_g, obj_b))
            draw.arc([45, 20, 83, 50], start=180, end=360, fill=(50, 50, 50), width=4)
        elif shape_type == 2:
            # Biển hiệu / Tam giác / Cây cối
            draw.polygon([(64, 20), (25, 105), (103, 105)], fill=(obj_r, obj_g, obj_b))
        else:
            # Đồ vật đa giác phức hợp
            draw.rectangle([25, 30, 103, 95], fill=(obj_r, obj_g, obj_b))
            draw.line([(25, 30), (103, 95)], fill=(255, 255, 255), width=3)
            
        return img
    
    def _to_tensor(self, pil_img):
        arr = np.array(pil_img, dtype=np.float32) / 255.0
        # Chuẩn hóa ImageNet
        mean = np.array([0.485, 0.456, 0.406], dtype=np.float32)
        std = np.array([0.229, 0.224, 0.225], dtype=np.float32)
        arr = (arr - mean) / std
        tensor = torch.from_numpy(arr).permute(2, 0, 1).float()
        return tensor
    
    def __getitem__(self, idx):
        anchor_id = self.identity_offset + idx % 50
        neg_id = self.identity_offset + (idx + random.randint(1, 49)) % 50
        
        base_anchor = self._create_base_subject(anchor_id)
        base_neg = self._create_base_subject(neg_id)
        
        anchor_img = self.simulator.random_augment(base_anchor)
        positive_img = self.simulator.random_augment(base_anchor)
        negative_img = self.simulator.random_augment(base_neg)
        
        return (
            self._to_tensor(anchor_img),
            self._to_tensor(positive_img),
            self._to_tensor(negative_img)
        )

class ConvBlock(nn.Module):
    def __init__(self, in_c, out_c, stride=1):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_c, out_c, kernel_size=3, stride=stride, padding=1, bias=False),
            nn.BatchNorm2d(out_c),
            nn.ReLU6(inplace=True)
        )
    def forward(self, x):
        return self.conv(x)

class RobustTargetEmbedder(nn.Module):
    """128-dimensional CNN. Device throughput is not measured here."""
    def __init__(self, embedding_dim=128):
        super().__init__()
        self.stem = ConvBlock(3, 16, stride=2)    # 128x128 -> 64x64
        self.layer1 = ConvBlock(16, 32, stride=2) # 64x64   -> 32x32
        self.layer2 = ConvBlock(32, 64, stride=2) # 32x32   -> 16x16
        self.layer3 = ConvBlock(64, 96, stride=2) # 16x16   -> 8x8
        self.pool = nn.AdaptiveAvgPool2d(1)       # 8x8     -> 1x1
        
        self.head = nn.Sequential(
            nn.Linear(96, 64),
            nn.ReLU(inplace=True),
            nn.Linear(64, embedding_dim)
        )
        
    def forward(self, x):
        feat = self.stem(x)
        feat = self.layer1(feat)
        feat = self.layer2(feat)
        feat = self.layer3(feat)
        feat = self.pool(feat)
        feat = torch.flatten(feat, 1)
        emb = self.head(feat)
        # Chuẩn hóa L2 về hình cầu đơn vị (Unit Sphere)
        return nn.functional.normalize(emb, p=2, dim=1)

class ImageInputEmbedder(nn.Module):
    """The CoreML image adapter supplies RGB [0,1]; normalize inside the graph."""
    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer('mean', torch.tensor([.485, .456, .406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([.229, .224, .225]).view(1, 3, 1, 1))

    def forward(self, image):
        return self.model((image - self.mean) / self.std)


@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    positive, negative = [], []
    for a, p, n in loader:
        ea, ep, en = [model(x.to(device)) for x in (a, p, n)]
        positive.extend((ea * ep).sum(1).cpu().tolist())
        negative.extend((ea * en).sum(1).cpu().tolist())
    return {'positive_cosine_mean': float(np.mean(positive)),
            'negative_cosine_mean': float(np.mean(negative)),
            'true_accept_rate_at_0_75': float(np.mean(np.array(positive) >= .75)),
            'false_accept_rate_at_0_75': float(np.mean(np.array(negative) >= .75)),
            'pairs_per_class': len(positive)}


def export_coreml(model, directory):
    import coremltools as ct
    wrapped = ImageInputEmbedder(model.cpu().eval()).eval()
    example = torch.rand(1, 3, 128, 128)
    traced = torch.jit.trace(wrapped, example)
    converted = ct.convert(traced, convert_to='mlprogram',
        minimum_deployment_target=ct.target.iOS17,
        inputs=[ct.ImageType(name='image', shape=example.shape, scale=1 / 255.,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name='embedding')])
    converted.user_defined_metadata['tracking_schema'] = 'rgb128_imagenet_in_graph_l2_128_v1'
    converted.save(str(directory / 'RobustTargetEmbedder.mlpackage'))
    # On macOS compare the converted model against PyTorch using the exact bytes.
    pixels = np.random.default_rng(226).integers(0, 256, (128, 128, 3), dtype=np.uint8)
    pil = Image.fromarray(pixels)
    tensor = torch.from_numpy(pixels.astype(np.float32) / 255).permute(2, 0, 1).unsqueeze(0)
    with torch.no_grad():
        expected = wrapped(tensor).numpy().reshape(-1)
    actual = np.asarray(converted.predict({'image': pil})['embedding']).reshape(-1)
    cosine = float(np.dot(expected, actual) / (np.linalg.norm(expected) * np.linalg.norm(actual)))
    if not np.isfinite(cosine) or cosine < .999:
        raise RuntimeError(f'CoreML/PyTorch preprocessing parity failed: {cosine}')
    return cosine


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--epochs', type=int, default=15)
    parser.add_argument('--samples', type=int, default=480)
    parser.add_argument('--output-dir', type=Path, default=Path('training_artifacts'))
    parser.add_argument('--export-coreml', action='store_true')
    args = parser.parse_args()
    if args.epochs < 1 or args.samples < 16:
        parser.error('epochs >= 1 and samples >= 16 are required')
    random.seed(226); np.random.seed(226); torch.manual_seed(226)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model = RobustTargetEmbedder().to(device)
    train = DataLoader(SyntheticTargetDataset(args.samples), batch_size=16, shuffle=True, drop_last=True)
    # Identity IDs do not overlap training. Evaluation augmentation is seeded.
    validation = DataLoader(SyntheticTargetDataset(256, identity_offset=1000), batch_size=16)
    optimizer = torch.optim.AdamW(model.parameters(), lr=.002, weight_decay=1e-4)
    criterion = nn.TripletMarginLoss(margin=.4)
    losses = []
    for epoch in range(args.epochs):
        model.train()
        total, count = 0., 0
        for a, p, n in train:
            optimizer.zero_grad()
            ea, ep, en = [model(x.to(device)) for x in (a, p, n)]
            loss = criterion(ea, ep, en)
            loss.backward(); optimizer.step()
            total += loss.item(); count += 1
        losses.append(total / count)
        print(f'epoch={epoch + 1} triplet_loss={losses[-1]:.6f}', flush=True)
    random.seed(1226); np.random.seed(1226); torch.manual_seed(1226)
    metrics = evaluate(model, validation, device)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    torch.save({'state_dict': model.cpu().state_dict(), 'architecture': 'RobustTargetEmbedder_v1',
                'normalization': 'ImageNet_RGB', 'seed': 226}, args.output_dir / 'embedder.pt')
    report = {'scope': 'synthetic disjoint-identity validation only', 'losses': losses,
              'validation': metrics, 'real_device_validated': False}
    if args.export_coreml:
        report['coreml_pytorch_cosine'] = export_coreml(model, args.output_dir)
    (args.output_dir / 'training_report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
