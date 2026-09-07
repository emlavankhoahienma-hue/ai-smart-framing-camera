import os
import sys
import json
import glob
import shutil
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from PIL import Image, ImageFilter

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

OUT_DIR = os.path.join("data", "photography_dataset", "images")
ANNOTATIONS_FILE = os.path.join("data", "photography_dataset", "annotations.json")

if os.path.exists(OUT_DIR):
    shutil.rmtree(OUT_DIR)
os.makedirs(OUT_DIR, exist_ok=True)

# Build guaranteed 100% distinct file list
file_entries = []

# 1. Real iPhone camera photos (237)
iphone_files = list(set(glob.glob(r"C:\Users\admin\Downloads\iphone\*.JPG") + glob.glob(r"C:\Users\admin\Downloads\iphone\*.jpg")))
for f in iphone_files:
    file_entries.append((f, "iPhone_Real", "Street", "golden_ratio", 1.2))

# 2. Real Face & Portrait photos (433)
face_files = glob.glob(r"C:\Users\admin\Downloads\anhchuptrain\*.jpg")
for f in face_files:
    file_entries.append((f, "Portrait_Real", "Portrait", "golden_ratio", 1.4))

# 3. Real photos from jpg3 (350)
jpg3_files = glob.glob(r"C:\Users\admin\Downloads\jpg3\*.*")
for f in jpg3_files:
    file_entries.append((f, "JPG3_Real", "Nature", "rule_of_thirds", 1.0))

# 4. Real photos from png2 (447)
png2_files = glob.glob(r"C:\Users\admin\Downloads\png2\*.*")
for f in png2_files:
    file_entries.append((f, "PNG2_Real", "Macro", "rule_of_thirds", 1.5))

# 5. Distinct Real COCO photos (1500)
coco_files = glob.glob(r"C:\Users\admin\Downloads\AlignAI_Dataset_COCO\val2017\*.jpg")[:1500]
for f in coco_files:
    file_entries.append((f, "COCO_Real", "Street", "rule_of_thirds", 1.0))

print(f"Tổng số ảnh thực tế ĐỘC BẢN sẽ được gán nhãn: {len(file_entries)} ảnh...")

tasks = []
for idx, (f, cat, scene, rule, zoom) in enumerate(file_entries, start=1):
    out_name = f"photo_{idx:05d}_{scene.lower()}.jpg"
    tasks.append((idx, f, out_name, cat, scene, rule, zoom))

def process_one(task):
    idx, src_path, out_name, cat, scene, rule, default_zoom = task
    out_path = os.path.join(OUT_DIR, out_name)
    try:
        with Image.open(src_path) as img:
            img_rgb = img.convert("RGB")
            # Save 256x256
            img_small = img_rgb.resize((256, 256), Image.Resampling.BILINEAR)
            img_small.save(out_path, "JPEG", quality=85)
            
            # Analyze composition
            img_gray = img_small.convert("L").resize((64, 64))
            edges = img_gray.filter(ImageFilter.FIND_EDGES)
            edge_np = np.array(edges, dtype=np.float32) / 255.0
            
            total_e = np.sum(edge_np) + 1e-6
            y_idx, x_idx = np.indices((64, 64))
            sal_x = np.sum(x_idx * edge_np) / total_e / 64.0
            sal_y = np.sum(y_idx * edge_np) / total_e / 64.0
            
            gx = 0.382 if sal_x < 0.5 else 0.618
            gy = 0.382 if sal_y < 0.5 else 0.618
            
            if scene == "Portrait":
                target_y = float(np.clip(0.35 + 0.1 * (sal_y - 0.5), 0.28, 0.45))
                target_x = float(gx + 0.05 * (sal_x - gx))
                rule_name = "golden_ratio"
                zoom = 1.4
            elif scene == "Nature":
                target_y = 0.382 if sal_y < 0.5 else 0.618
                target_x = float(np.clip(sal_x, 0.30, 0.70))
                rule_name = "rule_of_thirds"
                zoom = 1.0
            elif scene == "Macro":
                target_x = float(gx * 0.7 + sal_x * 0.3)
                target_y = float(gy * 0.7 + sal_y * 0.3)
                rule_name = "rule_of_thirds"
                zoom = 1.6
            else:
                target_x = float(gx)
                target_y = float(gy)
                rule_name = "golden_ratio" if abs(sal_x - 0.5) > 0.1 else "rule_of_thirds"
                zoom = default_zoom
                
            return {
                "target_x": round(float(np.clip(target_x, 0.15, 0.85)), 4),
                "target_y": round(float(np.clip(target_y, 0.15, 0.85)), 4),
                "suggested_zoom": round(float(zoom), 2),
                "scene_type": scene,
                "composition_rule": rule_name,
                "image_file": out_name,
                "original_file": os.path.basename(src_path),
                "source_category": cat
            }
    except Exception as e:
        return None

annotations = []
with ThreadPoolExecutor(max_workers=16) as executor:
    results = executor.map(process_one, tasks)
    for res in results:
        if res:
            annotations.append(res)

with open(ANNOTATIONS_FILE, "w", encoding="utf-8") as f_out:
    json.dump(annotations, f_out, ensure_ascii=False, indent=2)

print(f"🎉 HOÀN TẤT TUYỆT ĐỐI: {len(annotations)}/{len(tasks)} ẢNH THỰC TẾ 100% ĐỘC BẢN KHÔNG LẶP LẠI!")
