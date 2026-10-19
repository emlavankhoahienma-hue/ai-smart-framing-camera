import os
import shutil
import zipfile
from pathlib import Path
from datetime import datetime

repo_root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
dl_dir.mkdir(parents=True, exist_ok=True)

target_folder_name = "AI_Camera_Intelligence_FullCode"
bundle_dir = dl_dir / target_folder_name
if bundle_dir.exists():
    shutil.rmtree(bundle_dir)
bundle_dir.mkdir(parents=True, exist_ok=True)

# Subfolders strictly for AI Detection, Target Placement, Composition, and Zoom (All .txt)
ai_detection_dir = bundle_dir / "AI_Detection_Engine"
ai_detection_dir.mkdir(parents=True, exist_ok=True)

ai_target_comp_dir = bundle_dir / "AI_Target_and_Composition"
ai_target_comp_dir.mkdir(parents=True, exist_ok=True)

ai_zoom_math_dir = bundle_dir / "AI_Zoom_and_PureCalculations"
ai_zoom_math_dir.mkdir(parents=True, exist_ok=True)

models_data_dir = bundle_dir / "Data_Models"
models_data_dir.mkdir(parents=True, exist_ok=True)

tests_dir = bundle_dir / "Validation_Tests"
tests_dir.mkdir(parents=True, exist_ok=True)

# 1. Map of files to copy and convert to .txt
# ONLY AI Detection, Target Placement, Hero Clustering, Composition, and AI Zoom.
# STRICTLY NO forms, NO UI views, NO tracking/IMU/Kalman/odometry/patch flow files.
files_to_copy = [
    # AI Detection Engine (YOLOv26 ANE + Apple Vision)
    ("AISmartFramingCamera/Services/YOLODetectionEngine.swift", ai_detection_dir),
    ("AISmartFramingCamera/Services/VisionFramingEngine.swift", ai_detection_dir),
    ("AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift", ai_detection_dir),
    ("models/yolov26-engine/docs/SPECIFICATION.md", ai_detection_dir),
    ("models/yolov26-engine/weights/manifest.json", ai_detection_dir),
    ("models/yolov26-engine/weights/benchmark_report.json", ai_detection_dir),
    ("models/yolov26-engine/scripts/model_architecture.py", ai_detection_dir),
    ("models/yolov26-engine/scripts/export_coreml.py", ai_detection_dir),
    ("models/yolov26-engine/scripts/benchmark_ane.py", ai_detection_dir),
    ("models/yolov26-engine/scripts/train_or_distill.py", ai_detection_dir),
    ("scripts/export_siglip_coreml.py", ai_detection_dir),

    # AI Target Selection, Hero Selection, and Composition
    ("AISmartFramingCamera/Services/CompositionPlanning.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/CompositionCalculator.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/PhotographicCompositionModel.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/CharmPhotographicModel.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/CompositionAestheticSearch.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/PortraitFramingEvidence.swift", ai_target_comp_dir),
    ("AISmartFramingCamera/Services/CompositionImageEvidence.swift", ai_target_comp_dir),

    # AI Zoom and Pure Math Calculations
    ("AISmartFramingCamera/Services/CompositionTuning.swift", ai_zoom_math_dir),
    ("AISmartFramingCamera/Services/CompositionPureCalculations.swift", ai_zoom_math_dir),

    # Data Models for Bounding Boxes, Candidates, Targets, and Composition Intents
    ("AISmartFramingCamera/Models/FramingModels.swift", models_data_dir),

    # Verification Tests strictly for AI Detection, AI Zoom, and Multi-Scenario Benchmark
    ("tests/CompositionMultiScenarioBenchmarkTests.swift", tests_dir),
    ("scripts/benchmark_multi_scenario_baseline.py", tests_dir),
    ("build_artifacts/benchmark_baseline_phase0.json", tests_dir),
    ("scripts/test_item1_yolo_clamping_bug.py", tests_dir),
    ("scripts/test_item2_mlmultiarray_strides_bug.py", tests_dir),
    ("scripts/test_item3_letterbox_unpadding_bug.py", tests_dir),
    ("scripts/test_item4_coordinate_unification.py", tests_dir),
    ("scripts/test_item9_continuous_ideal_zoom.py", tests_dir),
    ("scripts/test_yolo_input_size_resizing.py", tests_dir),
]

copied_count = 0
for rel_path, dest_folder in files_to_copy:
    src_file = repo_root / rel_path
    if src_file.exists():
        # Target filename is strictly .txt
        txt_filename = src_file.stem + ".txt"
        target_path = dest_folder / txt_filename
        
        raw_content = src_file.read_text(encoding="utf-8")
        ext = src_file.suffix.lower()
        if ext == ".swift":
            header_prefix = f"// [Source Language: Swift] [Original Path: {rel_path}]\n\n"
        elif ext == ".py":
            header_prefix = f"# [Source Language: Python] [Original Path: {rel_path}]\n\n"
        elif ext in [".json", ".md"]:
            header_prefix = f"// [Source Type: {ext.replace('.', '').upper()}] [Original Path: {rel_path}]\n\n"
        else:
            header_prefix = f"// [Original Path: {rel_path}]\n\n"
            
        target_path.write_text(header_prefix + raw_content, encoding="utf-8")
        copied_count += 1
        print(f"  + Converted to TXT: {txt_filename} from {src_file.name}")
    else:
        print(f"Warning: file not found: {src_file}")

print(f"Copied and converted {copied_count} files into {bundle_dir} (All .txt format)")

# 2. Build the master consolidated document in BOTH .txt and .md
master_doc_txt = dl_dir / "AI_Camera_Intelligence_Complete_Architecture_and_FullCode.txt"
master_doc_md = dl_dir / "AI_Camera_Intelligence_Complete_Architecture_and_FullCode.md"

header = r"""================================================================================
HE THONG AI CAMERA - THUAT TOAN NHAN DIEN AI, DUA TARGET, GOM CUM & ZOOM AI
FULL CODE VA DAC TA KIEN TRUC (DINH DANG PLAIN TEXT .TXT)
================================================================================

Thoi gian trich xuat: __TIME_PLACEHOLDER__
Pham vi: CHI BAO GOM CAC THUAT TOAN AI COT LOI:
 1. AI Nhan dien chu the (YOLOv26 ANE Hardware-Accelerated & Apple Vision)
 2. AI Dua Target, Gom cum chu the & Hero Selection (Bipartite Face-to-Body IoU Matching, Candidate Ranking)
 3. AI Bo cuc dien anh (Rule of Thirds, Golden Ratio, Gaze Lead, Headroom/Footroom)
 4. AI Zoom dien anh (Continuous Ideal Zoom k = sqrt(A_desired / A_0) & Edge Safety Margin)
 5. Data Models dinh nghia Bounding Boxes, Targets, Proposals

TUYET DOI KHONG CHUA:
 - Khong chua bat ky file UI, View, Form, HUD, Overlay View.
 - Khong chua bat ky file Bam target, 6DOF tracking, IMU, con quay CoreMotion, bo loc Kalman, optical flow hay odometry.
 - Khong chua plumbing code hay service camera nen tang.

================================================================================
MUC LUC TAI LIEU
================================================================================
1. Ban chat & Muc tieu cua He thong AI
2. Luong xu ly thuan tuy cua AI (Pure AI Pipeline Dataflow)
3. Cong thuc toan hoc & Thuat toan cot loi
   3.1. Chuyen doi he toa do Upright Portrait [0, 1]x[0, 1]
   3.2. Letterbox Unpadding & GPU Image Resizing (CVPixelBufferPool)
   3.3. Hero Selection & Gom cum chu the Face-to-Body theo IoU
   3.4. Tinh toan toa do Target diem vang bo cuc & Huong anh nhin (Gaze Lead)
   3.5. Cong thuc Zoom lien tuc ly tuong k = sqrt(A_desired / A_0) & Khoang cach an toan mep (Edge Safety Margin)
4. Toan bo Ma nguon day du (Full Code Listing - 100% Ma nguon khong rut gon)
   4.1. Tap trung Tham so & Tinh chinh (CompositionTuning.swift)
   4.2. Phep tinh Toan hoc thuan tuy cho Zoom & Toa do (CompositionPureCalculations.swift)
   4.3. Bo hoach dinh Bo cuc & Hero Selection (CompositionPlanning.swift)
   4.4. Bo tinh toan vi tri Target bo cuc & Gaze Lead (CompositionCalculator.swift)
   4.5. Mo hinh Heuristic Bo cuc nhiep anh (PhotographicCompositionModel.swift)
   4.6. Mo hinh Tham my Charm (CharmPhotographicModel.swift)
   4.7. Tim kiem Tham my lien tuc (CompositionAestheticSearch.swift)
   4.8. Bang chung Bo cuc Chan dung (PortraitFramingEvidence.swift)
   4.9. Bang chung Anh & Attention Saliency (CompositionImageEvidence.swift)
   4.10. Bo nhan dien YOLOv26 ANE Hardware-Accelerated (YOLODetectionEngine.swift)
   4.11. Bo nhan dien Apple Vision Framing (VisionFramingEngine.swift)
   4.12. Tri tue chu the & Cham diem Ung vien (NeuralSubjectIntelligenceEngine.swift)
   4.13. Data Models cho Detections, Targets & Candidates (FramingModels.swift)
   4.14. Dac ta Kien truc Mo hinh YOLOv26 ANE (SPECIFICATION.md)
   4.15. Dinh nghia Mang PyTorch YOLOv26 (model_architecture.py)
   4.16. Pipeline Export CoreML toi uu cho Apple Neural Engine (export_coreml.py)
   4.17. Script Export SigLIP CoreML (export_siglip_coreml.py)
5. Cac cau hoi trong tam nho Chuyen gia AI phan bien va de xuat phuong an toi uu

================================================================================
1. BAN CHAT & MUC TIEU CUA HE THONG AI
================================================================================

He thong AI nay co 4 nhiem vu cot loi chay tren thiet bi di dong (iPhone):
1. Nhan dien chu the toc do cuc cao (ANE Hardware Acceleration):
   - Su dung mo hinh YOLOv26 duoc toi uu hoa rieng cho Apple Neural Engine (ANE) va Apple Vision Framework.
   - Phat hien nguoi (Person / Body), khuon mat (Face), thu cung (Dog, Cat) va cac vat the trong khung hinh.
2. Gom cum chu the & Hero Selection (Dua Target):
   - Trong mot khung hinh co the co nhieu nguoi, nhieu khuon mat.
   - AI phai gom cum khuon mat vao than nguoi tuong ung (Face-to-Body bipartite matching theo IoU hinh hoc).
   - Danh gia diem hap dan, dien tich, do net, vi tri trung tam de chon ra chu the chinh (Hero Subject).
   - Xac dinh toa do Target ly tuong (theo Quy tac mot phan ba Rule of Thirds, Ty le vang Golden Ratio hoac Headroom tieu chuan chan dung).
   - Bu tru theo huong anh nhin (Gaze Lead): chu the nhin sang ben nao thi mo rong khong gian thoang ve phia do.
3. AI Auto-Zoom dien anh (Continuous Ideal Zoom):
   - Tinh toan he so phong dai ly tuong de chu the dat dien tich chuan trong khung hinh:
     * Chan dung: 34% dien tich khung hinh (desiredAreaPortrait = 0.34).
     * Khuon mat: 16% dien tich khung hinh (desiredAreaFace = 0.16).
     * Nua nguoi / 2 nguoi: 28% dien tich khung hinh (desiredAreaTwoPeople = 0.28).
     * Toan than: 42% dien tich khung hinh (desiredAreaFullBody = 0.42).
   - Tuan thu tuyet doi khoang cach an toan mep (Edge Safety Margin m = 0.06): Phong to khong bao gio duoc phep cat chem vao dau, tay hoac mep cua chu the.

================================================================================
2. LUONG XU LY THUAN TUY CUA AI (PURE AI PIPELINE DATAFLOW)
================================================================================

[Camera Frame (CVPixelBuffer)]
        |
        +-----------------------------------+
        |                                   |
        v                                   v
[YOLODetectionEngine (ANE)]      [VisionFramingEngine (Vision)]
  - CVPixelBufferPool GPU resize    - VNRecognizeAnimalsRequest
    to 640x640 BGRA                 - VNDetectFaceRectanglesRequest
  - ANE Inference (1.5ms)           - VNDetectHumanRectanglesRequest
  - Letterbox Unpadding             - Upright Portrait [0, 1]x[0, 1]
  - Box Decoding & NMS                      |
        |                                   |
        +-----------------+-----------------+
                          |
                          v
         [NeuralSubjectIntelligenceEngine]
           - Gom cum Face-to-Body theo IoU
           - Tinh toan Category Bonus & Area Score
           - Binh chon Chu the chinh (Hero Subject)
                          |
                          v
               [CompositionPlanning]
           - Xac dinh kich thuoc chu the hien tai A_0
           - Tinh ty le zoom ly tuong k = sqrt(A_desired / A_0)
           - Tinh gioi han zoom an toan mep (k_max_x, k_max_y) voi margin 0.06
           - Sinh danh sach cac phuong an zoom lien tuc (Dynamic Zooms)
                          |
                          v
        [CompositionCalculator & Photographic Models]
           - Tinh diem Target bo cuc (Rule of Thirds / Golden Ratio)
           - Bu tru Gaze Lead Vector theo huong anh nhin
           - Cham diem bo cuc (Headroom, Footroom, Balance, Charm score)
           - Tra ve: Target Point (x, y), Optimal Zoom Level, Composition Score

================================================================================
3. CONG THUC TOAN HOC & THUAT TOAN COT LOI
================================================================================

3.1. Chuyen doi he toa do Upright Portrait
Tat ca toa do hop gioi han (Bounding Box) duoc quy chuan ve he Upright Portrait [0, 1] x [0, 1] voi goc (0, 0) o goc tren-trai, truc X huong sang phai, truc Y huong xuong duoi:
  x_upright = x_vision
  y_upright = 1.0 - (y_vision + h_vision)
  w_upright = w_vision
  h_upright = h_vision

3.2. Letterbox Unpadding & GPU Resizing
Khi anh camera ti le H0 x W0 dua vao mo hinh YOLO kich thuoc vuong S x S (vi du 640 x 640), ty le thu phong la:
  r = min(S / W0, S / H0)
Khoang dem (padding) duoc bo sung:
  pad_x = (S - W0 * r) / 2
  pad_y = (S - H0 * r) / 2
Khi giai ma bounding box (x1, y1, x2, y2) tu tensor ANE, hop gioi han thuc tren man hinh chuan hoa [0, 1] la:
  x = (x1 - pad_x) / (W0 * r)
  y = (y1 - pad_y) / (H0 * r)
  w = (x2 - x1) / (W0 * r)
  h = (y2 - y1) / (H0 * r)

3.3. Hero Selection & Gom cum Face-to-Body IoU
Doi voi tap hop cac Body Bi va tap hop cac Face Fj:
- Tinh chi so bao ham hoac IoU giua Fj va Bi:
  Containment(Fj, Bi) = Area(Fj giao Bi) / Area(Fj)
- Neu Containment(Fj, Bi) > 0.7, khuon mat Fj thuoc ve nguoi Bi.
- Diem uu tien chu the (Hero Score):
  Score = w_category * CategoryBonus + w_area * sqrt(Area) + w_center * (1 - d_center)

3.4. Tinh toan Target Bo cuc & Gaze Lead
Diem Target ly tuong (Tx, Ty) duoc xac dinh boi giao diem cua cac duong mot phan ba (Rule of Thirds x in {1/3, 2/3}, y in {1/3, 2/3}) hoac Ty le vang (Golden Ratio x in {0.382, 0.618}).
Khi chu the nhin ve huong ben phai voi vector g = (gx, gy):
  Tx = Tx_base + lambda_gaze * gx
  Ty = Ty_base + lambda_gaze * gy
Giu cho khong gian phia truoc mat chu the luon rong hon phia sau lung (Looking Room / Lead Room).

3.5. Zoom lien tuc ly tuong & An toan mep (Continuous Ideal Zoom)
Dien tich hop chu the ti le voi binh phuong he so phong dai tuyen tinh (A = A0 * k^2).
Ty le phong dai ly tuong de dat dien tich mong muon A_desired:
  k = sqrt(A_desired / A0)
De khong lam cat chem vao mep khung hinh voi khoang an toan m = 0.06:
  k_max_x = (2 * min(cx - m, 1 - m - cx)) / w0
  k_max_y = (2 * min(cy - m, 1 - m - cy)) / h0
  k_safe = max(1.0, min(k_max_x, k_max_y))
He so zoom cuoi cung:
  Z_ideal = max(Z_current, min(Z_max, Z_current * min(k, k_safe)))

================================================================================
4. TOAN BO MA NGUON DAY DU (FULL CODE LISTING)
================================================================================
"""

files_to_bundle_content = [
    # Zoom and Tuning Math
    ("AISmartFramingCamera/Services/CompositionTuning.swift", "Swift"),
    ("AISmartFramingCamera/Services/CompositionPureCalculations.swift", "Swift"),

    # AI Target Placement & Composition
    ("AISmartFramingCamera/Services/CompositionPlanning.swift", "Swift"),
    ("AISmartFramingCamera/Services/CompositionCalculator.swift", "Swift"),
    ("AISmartFramingCamera/Services/PhotographicCompositionModel.swift", "Swift"),
    ("AISmartFramingCamera/Services/CharmPhotographicModel.swift", "Swift"),
    ("AISmartFramingCamera/Services/CompositionAestheticSearch.swift", "Swift"),
    ("AISmartFramingCamera/Services/PortraitFramingEvidence.swift", "Swift"),
    ("AISmartFramingCamera/Services/CompositionImageEvidence.swift", "Swift"),

    # AI Detection Engine
    ("AISmartFramingCamera/Services/YOLODetectionEngine.swift", "Swift"),
    ("AISmartFramingCamera/Services/VisionFramingEngine.swift", "Swift"),
    ("AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift", "Swift"),

    # Data Models
    ("AISmartFramingCamera/Models/FramingModels.swift", "Swift"),

    # YOLOv26 Model Specs & Export Pipeline
    ("models/yolov26-engine/docs/SPECIFICATION.md", "Markdown"),
    ("models/yolov26-engine/scripts/model_architecture.py", "Python"),
    ("models/yolov26-engine/scripts/export_coreml.py", "Python"),
    ("scripts/export_siglip_coreml.py", "Python"),

    # Multi-Scenario Benchmark Suite & Baseline
    ("tests/CompositionMultiScenarioBenchmarkTests.swift", "Swift"),
    ("scripts/benchmark_multi_scenario_baseline.py", "Python"),
    ("build_artifacts/benchmark_baseline_phase0.json", "JSON"),
]

footer_questions = r"""
================================================================================
5. CAC CAU HOI TRONG TAM NHO CHUYEN GIA AI PHAN BIEN VA TOI UU
================================================================================

Chung toi can ban tap trung danh gia va de xuat phuong an thiet ke / ma nguon toi uu nhat cho 3 bai toan sau:

Cau hoi 1: Toi uu thuat toan Hero Selection & Gom cum Face-to-Body IoU
- Trong tinh huong mot buc anh co nhieu nguoi va nhieu khuon mat:
  - Lam the nao de gop cum (cluster) Face Fj thuoc ve Body Bi nao mot cach chinh xac tuyet doi va tiet kiem CPU nhat (Bipartite Matching)?
  - Tham so categoryBonusFace = 2.4 hien tai co lam lech diem khien he thong luon uu tien chon mot khuon mat rat nho o phia xa thay vi mot nguoi dung o vi tri trung tam phia truoc khong?
  - Ban hay de xuat cong thuc tinh diem Hero Score va ma nguon Swift/Python toi uu nhat.

Cau hoi 2: Toi uu thuat toan AI Auto-Zoom lien tuc ly tuong
- Cong thuc zoom k = sqrt(A_desired / A0) ket hop gioi han an toan mep m = 0.06 trong CompositionPureCalculations.swift:
  - Khi chu the khong o chinh giua ma lech ve goc, lam sao de auto-zoom ket hop dong thoi giua phong to va de xuat vi tri recompose khong gay cam giac giat (choppy)?
  - De xuat duong cong chuyen tiep zoom (Zoom transition curve / easing function) giup camera iPhone phong to muot ma nhu quay phim dien anh.

Cau hoi 3: Toi uu kien truc mang nhan dien YOLOv26 ANE
- Kien truc mang PyTorch va pipeline CoreML trong model_architecture.py va export_coreml.py:
  - Dau vao 640x640 so voi 416x416: Ty le can bang toi uu giua do tre suy luan tren Apple Neural Engine (ANE) va do chinh xac khi phat hien nguoi o xa?
  - Co the tich hop Non-Maximum Suppression (NMS) va Bounding Box unpadding truc tiep vao trong do thi CoreML Model (in-graph CoreML layer) de loai bo hoan toan xu ly CPU post-processing tren Swift khong?
"""

print(f"Writing master consolidated TXT document: {master_doc_txt}...")
now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

with open(master_doc_txt, "w", encoding="utf-8") as out:
    out.write(header.replace("__TIME_PLACEHOLDER__", now_str))

    for rel_path, lang in files_to_bundle_content:
        file_path = repo_root / rel_path
        if file_path.exists():
            out.write(f"\n\n{'='*80}\n")
            out.write(f"FILE: {rel_path} ({lang})\n")
            out.write(f"{'='*80}\n\n")
            content = file_path.read_text(encoding="utf-8")
            out.write(content)
            if not content.endswith("\n"):
                out.write("\n")
            print(f"  + Added to Master TXT: {rel_path} ({len(content)} chars)")
        else:
            print(f"  - Missing {rel_path}")

    out.write(footer_questions)

print(f"Master TXT created successfully: {master_doc_txt} ({master_doc_txt.stat().st_size / (1024 * 1024):.2f} MB)")

# Also create markdown version
shutil.copy2(master_doc_txt, master_doc_md)

# Copy master txt into bundle directory
shutil.copy2(master_doc_txt, bundle_dir / "AI_Camera_Intelligence_Complete_Architecture_and_FullCode.txt")

# 3. Create full ZIP archive in Downloads
zip_path = dl_dir / "AI_Camera_Intelligence_FullCode.zip"
print(f"Creating ZIP archive: {zip_path}...")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for root, _, files in os.walk(bundle_dir):
        for f in files:
            full_f = Path(root) / f
            arc_name = full_f.relative_to(dl_dir)
            zipf.write(full_f, arc_name)

print(f"ZIP archive created successfully: {zip_path} ({zip_path.stat().st_size / (1024 * 1024):.2f} MB)")
