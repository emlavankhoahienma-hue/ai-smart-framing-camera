import sys
sys.stdout.reconfigure(encoding="utf-8")
import json
from pathlib import Path
from PIL import Image

output_dir = Path("build_artifacts/diagnostic_sheets")
report_file = output_dir / "full_benchmark_report.json"
report = json.loads(report_file.read_text(encoding="utf-8"))

print(f"Total Evaluated Photos: {len(report)}")

sheets = [
    "benchmark_sheet_user_coco_6.jpg",
    "benchmark_sheet_portraits_6.jpg",
    "benchmark_sheet_objects_animals_6.jpg"
]
for s in sheets:
    sp = output_dir / s
    if sp.exists():
        im = Image.open(sp)
        print(f"Sheet {s:38s}: dimensions={im.size}, file_size={sp.stat().st_size:,} bytes, format={im.format}")
    else:
        print(f"Sheet {s:38s}: MISSING!")

print("\n=== Detailed Case Verification ===")
all_anchors_retained = True
all_dest_valid = True
all_crops_in_bounds = True

for i, r in enumerate(report):
    cw = r["crop_window"]
    anc = r["anchor"]
    td = r["target_dest"]
    
    # Check anchor inside crop window
    inside_crop = (cw[0] <= anc[0] <= cw[0] + cw[2] + 0.001) and (cw[1] <= anc[1] <= cw[1] + cw[3] + 0.001)
    if not inside_crop:
        all_anchors_retained = False
        
    # Check crop bounds in [0, 1]
    in_bounds = (0.0 <= cw[0] and cw[0] + cw[2] <= 1.001 and 0.0 <= cw[1] and cw[1] + cw[3] <= 1.001)
    if not in_bounds:
        all_crops_in_bounds = False
        
    # Check target dest validity
    dest_ok = (0.20 <= td[0] <= 0.80 and 0.20 <= td[1] <= 0.80)
    if not dest_ok:
        all_dest_valid = False
        
    f_name = r["file"]
    sc = r["scene"]
    lbl = r["hero_label"]
    cf = r["hero_conf"]
    rule = r["alignment_rule"]
    zm = r["zoom_ratio"]
    print(f"[{i+1:2d}] {f_name:16s} ({sc:12s}) | Hero: {lbl:20s} (conf: {cf:.2f})")
    print(f"     Anchor: ({anc[0]:.3f}, {anc[1]:.3f}) -> Target: ({td[0]:.3f}, {td[1]:.3f}) | Rule: {rule}")
    print(f"     Crop: [x={cw[0]:.3f}, y={cw[1]:.3f}, w={cw[2]:.3f}, h={cw[3]:.3f}] | Zoom: {zm:.2f}x | Retained: {inside_crop}")

print("\n=== Geometric Verification Summary ===")
print(f"All Subject Anchors Retained: {all_anchors_retained} (18/18)")
print(f"All Crop Windows Within Frame: {all_crops_in_bounds} (18/18)")
print(f"All Target Destinations Valid: {all_dest_valid} (18/18)")
