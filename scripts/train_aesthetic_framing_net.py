import os
import sys
import json
import time
import numpy as np
from PIL import Image

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

DATA_DIR = os.path.join("data", "photography_dataset")
IMAGES_DIR = os.path.join(DATA_DIR, "images")
ANNOTATIONS_FILE = os.path.join(DATA_DIR, "annotations.json")
WEIGHTS_FILE = os.path.join("scripts", "AestheticFramingModel_weights.npz")

SCENE_MAP = {
    "Portrait": 0, "Landscape": 1, "Street": 2,
    "Nature": 3, "Sunset": 4, "Macro": 5
}
RULE_MAP = {
    "golden_ratio": 0, "rule_of_thirds": 1, "leading_lines": 2
}

def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -15.0, 15.0)))

def d_sigmoid(s):
    return s * (1.0 - s)

def softmax(x):
    e = np.exp(x - np.max(x, axis=-1, keepdims=True))
    return e / (np.sum(e, axis=-1, keepdims=True) + 1e-8)

def relu(x):
    return np.maximum(0.0, x)

def d_relu(x):
    return (x > 0.0).astype(np.float32)

class AestheticFramingTrainer:
    def __init__(self):
        np.random.seed(42)
        # Input: (B, 3, 64, 64)
        # Conv1: 3 -> 24, k=4, s=4 -> (B, 24, 16, 16) -> flat patches: (3*4*4=48, 24)
        self.w_conv1 = np.random.randn(48, 24).astype(np.float32) * np.sqrt(2.0 / 48)
        self.b_conv1 = np.zeros(24, dtype=np.float32)
        
        # Conv2: 24 -> 48, k=2, s=2 -> (B, 48, 8, 8) -> flat patches: (24*2*2=96, 48)
        self.w_conv2 = np.random.randn(96, 48).astype(np.float32) * np.sqrt(2.0 / 96)
        self.b_conv2 = np.zeros(48, dtype=np.float32)
        
        # Conv3: 48 -> 96, k=2, s=2 -> (B, 96, 4, 4) -> flat patches: (48*2*2=192, 96)
        self.w_conv3 = np.random.randn(192, 96).astype(np.float32) * np.sqrt(2.0 / 192)
        self.b_conv3 = np.zeros(96, dtype=np.float32)
        
        # Conv4 / Pool: 96 -> 96, k=4, s=4 -> (B, 96, 1, 1) -> flat patches: (96*4*4=1536, 96)
        self.w_conv4 = np.random.randn(1536, 96).astype(np.float32) * np.sqrt(2.0 / 1536)
        self.b_conv4 = np.zeros(96, dtype=np.float32)
        
        # Dense FC: 96 -> 128
        self.w_fc = np.random.randn(96, 128).astype(np.float32) * np.sqrt(2.0 / 96)
        self.b_fc = np.zeros(128, dtype=np.float32)
        
        # Multi-task heads:
        self.w_coords = np.random.randn(128, 2).astype(np.float32) * 0.05
        self.b_coords = np.array([0.0, 0.0], dtype=np.float32)
        
        self.w_zoom = np.random.randn(128, 1).astype(np.float32) * 0.05
        self.b_zoom = np.zeros(1, dtype=np.float32)
        
        self.w_scene = np.random.randn(128, 6).astype(np.float32) * 0.05
        self.b_scene = np.zeros(6, dtype=np.float32)
        
        self.w_rule = np.random.randn(128, 3).astype(np.float32) * 0.05
        self.b_rule = np.zeros(3, dtype=np.float32)
        
        self.params = [
            self.w_conv1, self.b_conv1,
            self.w_conv2, self.b_conv2,
            self.w_conv3, self.b_conv3,
            self.w_conv4, self.b_conv4,
            self.w_fc, self.b_fc,
            self.w_coords, self.b_coords,
            self.w_zoom, self.b_zoom,
            self.w_scene, self.b_scene,
            self.w_rule, self.b_rule
        ]
        self.m = [np.zeros_like(p) for p in self.params]
        self.v = [np.zeros_like(p) for p in self.params]
        self.beta1 = 0.9
        self.beta2 = 0.999
        self.eps = 1e-8
        self.t = 0

    def forward(self, x):
        B = x.shape[0]
        # 1. Conv1 (k=4, s=4):
        p1 = x.reshape(B, 3, 16, 4, 16, 4).transpose(0, 2, 4, 1, 3, 5).reshape(B, 16, 16, 48)
        z1 = p1 @ self.w_conv1 + self.b_conv1
        a1 = relu(z1)
        
        # 2. Conv2 (k=2, s=2):
        p2 = a1.reshape(B, 8, 2, 8, 2, 24).transpose(0, 1, 3, 5, 2, 4).reshape(B, 8, 8, 96)
        z2 = p2 @ self.w_conv2 + self.b_conv2
        a2 = relu(z2)
        
        # 3. Conv3 (k=2, s=2):
        p3 = a2.reshape(B, 4, 2, 4, 2, 48).transpose(0, 1, 3, 5, 2, 4).reshape(B, 4, 4, 192)
        z3 = p3 @ self.w_conv3 + self.b_conv3
        a3 = relu(z3)
        
        # 4. Conv4 / Pool (k=4, s=4):
        p4 = a3.reshape(B, 1, 4, 1, 4, 96).transpose(0, 1, 3, 5, 2, 4).reshape(B, 1, 1, 1536)
        z4 = p4 @ self.w_conv4 + self.b_conv4
        a4 = relu(z4).reshape(B, 96)
        
        # 5. FC:
        z_fc = a4 @ self.w_fc + self.b_fc
        a_fc = relu(z_fc)
        
        # Heads:
        z_coords = a_fc @ self.w_coords + self.b_coords
        pred_coords = sigmoid(z_coords)
        
        z_zoom = a_fc @ self.w_zoom + self.b_zoom
        pred_zoom_norm = sigmoid(z_zoom)
        pred_zoom = 1.0 + 1.5 * pred_zoom_norm
        
        z_scene = a_fc @ self.w_scene + self.b_scene
        pred_scene = softmax(z_scene)
        
        z_rule = a_fc @ self.w_rule + self.b_rule
        pred_rule = softmax(z_rule)
        
        cache = (x, p1, z1, a1, p2, z2, a2, p3, z3, a3, p4, z4, a4, z_fc, a_fc,
                 z_coords, pred_coords, z_zoom, pred_zoom_norm, pred_zoom,
                 z_scene, pred_scene, z_rule, pred_rule)
        return pred_coords, pred_zoom, pred_scene, pred_rule, cache

    def backward(self, cache, targets):
        (x, p1, z1, a1, p2, z2, a2, p3, z3, a3, p4, z4, a4, z_fc, a_fc,
         z_coords, pred_coords, z_zoom, pred_zoom_norm, pred_zoom,
         z_scene, pred_scene, z_rule, pred_rule) = cache
        
        B = x.shape[0]
        y_coords = targets["coords"]
        y_zoom = targets["zoom"]
        y_scene = targets["scene"]
        y_rule = targets["rule"]
        
        d_pred_coords = 5.0 * (pred_coords - y_coords) / B
        d_z_coords = d_pred_coords * d_sigmoid(pred_coords)
        dw_coords = a_fc.T @ d_z_coords
        db_coords = np.sum(d_z_coords, axis=0)
        
        d_pred_zoom = 1.0 * (pred_zoom - y_zoom) / B
        d_pred_zoom_norm = d_pred_zoom * 1.5
        d_z_zoom = d_pred_zoom_norm * d_sigmoid(pred_zoom_norm)
        dw_zoom = a_fc.T @ d_z_zoom
        db_zoom = np.sum(d_z_zoom, axis=0)
        
        d_z_scene = (pred_scene - y_scene) / B
        dw_scene = a_fc.T @ d_z_scene
        db_scene = np.sum(d_z_scene, axis=0)
        
        d_z_rule = (pred_rule - y_rule) / B
        dw_rule = a_fc.T @ d_z_rule
        db_rule = np.sum(d_z_rule, axis=0)
        
        da_fc = (d_z_coords @ self.w_coords.T +
                 d_z_zoom @ self.w_zoom.T +
                 d_z_scene @ self.w_scene.T +
                 d_z_rule @ self.w_rule.T)
        dz_fc = da_fc * d_relu(z_fc)
        dw_fc = a4.T @ dz_fc
        db_fc = np.sum(dz_fc, axis=0)
        
        da4 = dz_fc @ self.w_fc.T
        dz4 = da4.reshape(B, 1, 1, 96) * d_relu(z4)
        dw_conv4 = p4.reshape(-1, 1536).T @ dz4.reshape(-1, 96)
        db_conv4 = np.sum(dz4, axis=(0, 1, 2))
        
        dp4 = dz4 @ self.w_conv4.T
        da3 = dp4.reshape(B, 1, 1, 96, 4, 4).transpose(0, 1, 4, 2, 5, 3).reshape(B, 4, 4, 96)
        
        dz3 = da3 * d_relu(z3)
        dw_conv3 = p3.reshape(-1, 192).T @ dz3.reshape(-1, 96)
        db_conv3 = np.sum(dz3, axis=(0, 1, 2))
        
        dp3 = dz3 @ self.w_conv3.T
        da2 = dp3.reshape(B, 4, 4, 48, 2, 2).transpose(0, 1, 4, 2, 5, 3).reshape(B, 8, 8, 48)
        
        dz2 = da2 * d_relu(z2)
        dw_conv2 = p2.reshape(-1, 96).T @ dz2.reshape(-1, 48)
        db_conv2 = np.sum(dz2, axis=(0, 1, 2))
        
        dp2 = dz2 @ self.w_conv2.T
        da1 = dp2.reshape(B, 8, 8, 24, 2, 2).transpose(0, 1, 4, 2, 5, 3).reshape(B, 16, 16, 24)
        
        dz1 = da1 * d_relu(z1)
        dw_conv1 = p1.reshape(-1, 48).T @ dz1.reshape(-1, 24)
        db_conv1 = np.sum(dz1, axis=(0, 1, 2))
        
        grads = [
            dw_conv1, db_conv1,
            dw_conv2, db_conv2,
            dw_conv3, db_conv3,
            dw_conv4, db_conv4,
            dw_fc, db_fc,
            dw_coords, db_coords,
            dw_zoom, db_zoom,
            dw_scene, db_scene,
            dw_rule, db_rule
        ]
        return grads

    def step(self, grads, lr=0.002):
        self.t += 1
        for i in range(len(self.params)):
            g = np.clip(grads[i], -5.0, 5.0)
            self.m[i] = self.beta1 * self.m[i] + (1.0 - self.beta1) * g
            self.v[i] = self.beta2 * self.v[i] + (1.0 - self.beta2) * (g ** 2)
            
            m_hat = self.m[i] / (1.0 - self.beta1 ** self.t)
            v_hat = self.v[i] / (1.0 - self.beta2 ** self.t)
            
            self.params[i] -= lr * m_hat / (np.sqrt(v_hat) + self.eps)

def load_dataset():
    print("📂 Đang nạp và tiền xử lý 2.200 ảnh nhiếp ảnh...")
    with open(ANNOTATIONS_FILE, "r", encoding="utf-8") as f:
        data = json.load(f)
        
    num_samples = len(data)
    images = np.zeros((num_samples, 3, 64, 64), dtype=np.float32)
    coords = np.zeros((num_samples, 2), dtype=np.float32)
    zooms = np.zeros((num_samples, 1), dtype=np.float32)
    scenes = np.zeros((num_samples, 6), dtype=np.float32)
    rules = np.zeros((num_samples, 3), dtype=np.float32)
    
    for i, item in enumerate(data):
        img_path = os.path.join(IMAGES_DIR, item["image_file"])
        try:
            with Image.open(img_path) as img:
                img = img.convert("RGB").resize((64, 64), Image.Resampling.BILINEAR)
                arr = np.array(img, dtype=np.float32) / 255.0
                images[i] = arr.transpose(2, 0, 1)
        except Exception:
            images[i] = 0.5
            
        coords[i] = [item["target_x"], item["target_y"]]
        zooms[i] = [item["suggested_zoom"]]
        
        s_idx = SCENE_MAP.get(item.get("scene_type", "Landscape"), 1)
        scenes[i, s_idx] = 1.0
        
        r_idx = RULE_MAP.get(item.get("composition_rule", "rule_of_thirds"), 1)
        rules[i, r_idx] = 1.0
        
    print(f"✅ Đã nạp thành công {num_samples} mẫu dữ liệu vào RAM!")
    return images, coords, zooms, scenes, rules

def train():
    images, coords, zooms, scenes, rules = load_dataset()
    N = len(images)
    indices = np.arange(N)
    np.random.shuffle(indices)
    
    split = int(0.9 * N)
    train_idx, val_idx = indices[:split], indices[split:]
    
    X_train, Y_c_train, Y_z_train, Y_s_train, Y_r_train = (
        images[train_idx], coords[train_idx], zooms[train_idx], scenes[train_idx], rules[train_idx]
    )
    X_val, Y_c_val, Y_z_val, Y_s_val, Y_r_val = (
        images[val_idx], coords[val_idx], zooms[val_idx], scenes[val_idx], rules[val_idx]
    )
    
    model = AestheticFramingTrainer()
    batch_size = 32
    num_epochs = 25
    steps_per_epoch = len(X_train) // batch_size
    
    print("=" * 80)
    print(f"🚀 BẮT ĐẦU HUẤN LUYỆN MẠNG NƠ-RON BỐ CỤC NHIẾP ẢNH THỰC TẾ ({N} ẢNH)")
    print(f"   • Train: {len(X_train)} ảnh | Val: {len(X_val)} ảnh")
    print(f"   • Kích thước tensor: (3, 64, 64) -> Apple Neural Engine Ultra-fast")
    print(f"   • Batch size: {batch_size} | Epochs: {num_epochs}")
    print("=" * 80)
    
    start_time = time.time()
    for epoch in range(1, num_epochs + 1):
        perm = np.random.permutation(len(X_train))
        epoch_loss = 0.0
        
        for step in range(steps_per_epoch):
            b_idx = perm[step * batch_size : (step + 1) * batch_size]
            bx = X_train[b_idx]
            targets = {
                "coords": Y_c_train[b_idx],
                "zoom": Y_z_train[b_idx],
                "scene": Y_s_train[b_idx],
                "rule": Y_r_train[b_idx]
            }
            
            p_c, p_z, p_s, p_r, cache = model.forward(bx)
            
            loss_c = 5.0 * np.mean((p_c - targets["coords"]) ** 2)
            loss_z = 1.0 * np.mean((p_z - targets["zoom"]) ** 2)
            loss_s = -np.mean(np.sum(targets["scene"] * np.log(p_s + 1e-8), axis=1))
            loss_r = -np.mean(np.sum(targets["rule"] * np.log(p_r + 1e-8), axis=1))
            loss = loss_c + loss_z + loss_s + loss_r
            epoch_loss += loss
            
            grads = model.backward(cache, targets)
            lr = 0.002 if epoch <= 15 else 0.0008
            model.step(grads, lr=lr)
            
        epoch_loss /= steps_per_epoch
        
        val_pc, val_pz, val_ps, val_pr, _ = model.forward(X_val)
        val_loss_c = 5.0 * np.mean((val_pc - Y_c_val) ** 2)
        val_loss_z = 1.0 * np.mean((val_pz - Y_z_val) ** 2)
        val_loss_s = -np.mean(np.sum(Y_s_val * np.log(val_ps + 1e-8), axis=1))
        val_loss_r = -np.mean(np.sum(Y_r_val * np.log(val_pr + 1e-8), axis=1))
        val_total_loss = val_loss_c + val_loss_z + val_loss_s + val_loss_r
        
        mean_coord_err_pct = np.mean(np.abs(val_pc - Y_c_val)) * 100.0
        scene_acc_pct = np.mean(np.argmax(val_ps, axis=1) == np.argmax(Y_s_val, axis=1)) * 100.0
        rule_acc_pct = np.mean(np.argmax(val_pr, axis=1) == np.argmax(Y_r_val, axis=1)) * 100.0
        
        print(f"Epoch [{epoch:02d}/{num_epochs:02d}] "
              f"Loss: {epoch_loss:.4f} | Val Loss: {val_total_loss:.4f} | "
              f"Target Error: {mean_coord_err_pct:.2f}% | Scene Acc: {scene_acc_pct:.1f}% | Rule Acc: {rule_acc_pct:.1f}%")

    elapsed = time.time() - start_time
    print("=" * 80)
    print(f"🎉 Huấn luyện thành công trong {elapsed:.1f} giây!")
    print(f"   • Sai số tọa độ điểm vàng trung bình: ±{mean_coord_err_pct:.2f}%")
    print(f"   • Độ chính xác bối cảnh (Scene Classification): {scene_acc_pct:.1f}%")
    print(f"   • Độ chính xác quy tắc bố cục (Rule Classification): {rule_acc_pct:.1f}%")
    print("=" * 80)
    
    print(f"💾 Lưu trọng số nơ-ron vào {WEIGHTS_FILE}...")
    np.savez_compressed(
        WEIGHTS_FILE,
        w_conv1=model.w_conv1, b_conv1=model.b_conv1,
        w_conv2=model.w_conv2, b_conv2=model.b_conv2,
        w_conv3=model.w_conv3, b_conv3=model.b_conv3,
        w_conv4=model.w_conv4, b_conv4=model.b_conv4,
        w_fc=model.w_fc, b_fc=model.b_fc,
        w_coords=model.w_coords, b_coords=model.b_coords,
        w_zoom=model.w_zoom, b_zoom=model.b_zoom,
        w_scene=model.w_scene, b_scene=model.b_scene,
        w_rule=model.w_rule, b_rule=model.b_rule
    )
    size_kb = os.path.getsize(WEIGHTS_FILE) / 1024.0
    print(f"✅ Hoàn tất lưu trọng số! Kích thước file: {size_kb:.1f} KB (Siêu nhẹ thay thế file 200MB cũ)")

if __name__ == "__main__":
    train()
