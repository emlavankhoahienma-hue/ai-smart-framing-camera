import os
import shutil
import zipfile
from pathlib import Path
import unicodedata

root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
target_dir = dl_dir / "AI_Camera_Tracking_Package"
target_dir.mkdir(parents=True, exist_ok=True)

files_to_copy = [
    "AISmartFramingCamera/Services/SpatialTrackingEngine.swift",
    "AISmartFramingCamera/Services/TrackingGeometry.swift",
    "AISmartFramingCamera/Services/NeuralTargetTracker.swift",
    "AISmartFramingCamera/Services/TargetPatchFlow.swift",
    "AISmartFramingCamera/Services/DeviceMotionService.swift",
    "AISmartFramingCamera/Services/VisualOdometryEngine.swift",
    "AISmartFramingCamera/Services/VisionFramingEngine.swift",
    "AISmartFramingCamera/Services/CompositionCalculator.swift",
    "AISmartFramingCamera/Services/NeuralSubjectIntelligenceEngine.swift",
    "AISmartFramingCamera/Models/FramingModels.swift",
    "scripts/validate_tracking_geometry.py",
    "scripts/validate_local_framing.py",
    "scripts/validate_patch_flow_reference.py",
    "scripts/trained_tracking_parameters.json",
    "scripts/train_synthetic_tracking_environment.py",
    "scripts/train_target_embedder.py",
]

# Copy individual files into target_dir
copied_files = []
for rel_path in files_to_copy:
    src = root / rel_path
    if not src.exists():
        print(f"Warning: {src} does not exist!")
        continue
    filename = Path(rel_path).name
    dst = target_dir / filename
    shutil.copy2(src, dst)
    copied_files.append(filename)

prompt_content = """# PROMPT YEU CAU CHO CHATGPT: FIX TRIET DE HE THONG BAM TARGET (SPATIAL TRACKING & AUTO ZOOM)

CANH BAO QUAN TRONG: Lam can than dang hoang, nghien cuu ky luong, tuyet doi khong tu tin thai qua roi viet code bua hoac suy doan vo can cu.

--------------------------------------------------------------------------------

## 1. BAN CHAT VA CHI TIET DAY DU VE UNG DUNG NAY (DOC THAT KY DE TRANH NHAM LAN)

Day la ung dung gi?
- Day la ung dung may anh chup hinh thong minh tren iPhone (ten app: AI Smart Framing Camera), viet bang Swift/SwiftUI cho he dieu hanh iOS 17+ (ho tro tu iPhone 8/X den iPhone 16 Pro).
- DAY TUYET DOI KHONG PHAI LA DRONE (MAY BAY KHONG NGUOI LAI), KHONG PHAI LA XE TU HANH, KHONG PHAI ROBOT, KHONG PHAI KINH AR, KHONG PHAI CAMERA PTZ XOAY DONG CO.
- Thiet bi quan sat la chiec dien thoai iPhone do con nguoi cam tren tay that ngoai doi thuc.
  + Che do su dung: Cam doc (Portrait), ti le khung hinh cam bien la 3:4, goc nhin ngang FOV khoang 60 den 65 do.
  + Dac thu vat ly: Nguoi dung cam tay luon co rung tay sinh hoc tu nhien (Handheld Tremor) voi tan so khoang 9 den 10 Hz va bien do nho. Khi nguoi dung lia may nhanh (whip pan), goc quay co the dat 200 den 400 do/giay.

Muc dich va co che hoat dong thuc te cua ung dung:
- Ung dung ho tro nguoi dung can bo cuc anh chuan nhiep anh (quy tac mot phan ba Rule of Thirds, ti le vang Golden Ratio).
- Khi nguoi dung cham ngón tay vao mot vat the thuc te (vi du: coc nuoc tren ban, con meo, khuon mat nguoi, chum chia khoa, bong hoa, toa nha):
  + Tren man hinh se khoa mot VONG TRON VANG (Target Reticle) len vat the do.
  + O chinh giua man hinh camera luon co mot CHAM TRANG CO DINH tai toa do (0.5, 0.5) dai dien cho truc quang hoc cua ong kinh camera.
  + Nguoi dung lia hoac nghieng dien thoai de dua cham trang lai gan vong vang theo huong dan.
  + Vat the la doi tuong vat ly 3D co dinh trong khong gian phong hoac ngoai troi:
    * Khi nguoi dung lia may sang PHAI: vat the thuc te nam ve ben TRAI khung hinh camera, do do Vong vang bat buoc phai troi sang TRAI (xa dan tam trang) de tiep tuc de len dung vat the thuc.
    * Khi nguoi dung ngua may len TREN: vat the nam ve phia DUOI khung hinh, Vong vang phai troi xuong DUOI.
    * Tuyet doi Vong vang khong duoc keo le chay theo cham trang o giua man hinh!
- Khi can dung bo cuc dep, ung dung ho tro co che tu dong zoom (AI Auto-Zoom tu 1x len 2x hoac 3x) va tu dong chup anh ro net cho nguoi dung.

--------------------------------------------------------------------------------

## 2. NGUYEN VAN PHAN HOI VA CAU THAN VAN CUA NGUOI DUNG

Duoi day la nguyen van cac cau than van cua nguoi dung khi trai nghiem truc tiep tren iPhone:

1. "bam no rung voi chay lung tung voi qua lo"
2. "tam no cu bi doi luc nhay lung tung xong ve lai cho cu kho chiu lam"
3. "fix t thay doi khi nao hen hen no ms auto zoom chu luc thuong no chi chup ko no ko AI zoom :( fix di"
4. "lo qua no van bi mau trang xam"
5. "tranh bao dat lai muc tieu lien tuc gay loi"

--------------------------------------------------------------------------------

## 3. CAC HIEN TUONG LOI THUC TE CAN PHAI KHAC PHUC

Chi ghi nhan chinh xac cac hien tuong loi thuc te xay ra tren thiet bi (khong suy doan ly do, khong bia thong tin):

1. Hien tuong rung lac va giat nhay (Jitter & Centroid Hunting):
   - Khi huong camera vao mot vat the tinh hoac khi lia may nhe, tam bam bi rung lac, giat giat, khong giu duoc do on dinh em ai tren vat the.
   - Tam co xu huong lac xung quanh vat the thay vi bam vung chac vao tam vat the thuc te.

2. Hien tuong nhay lung tung roi thut ve cho cu (Outlier Snapping):
   - Trong qua trinh bam, doi luc tam bam dot ngot bi nhay vot sang mot vi tri khac tren man hinh trong tich tac roi sau do lai thut ve vi tri cu.
   - Hien tuong nay xay ra lap di lap lai gay kho chiu cho nguoi dung.

3. Hien tuong chay lung tung khi lia may (Tracking Drift & Instability):
   - Khi nguoi dung lia may dien thoai, tam bam khong bam theo vat the trong the gioi thuc ma bi chay lung tung hoac bi lech khoi vat the.

4. Hien tuong lien tuc bao dat lai muc tieu gay loi (False Lost State & Constant Re-pin Prompts):
   - Khi lia may hoi nhanh hoac khi vat the tam thoi che khuat thoang qua, he thong lien tuc phat tin hieu mat dau, chop tat va nhay thong bao yeu cau nguoi dung phai cham chon lai muc tieu lien tuc, gay uc che va pha hong trai nghiem chup anh.
   - Yeu cau: Tranh tinh trang he thong de dai bo cuoc roi bat nguoi dung chon lai lien tuc.

5. Hien tuong AI Auto-Zoom hoat dong chap chon:
   - Nguoi dung phan anh: "doi khi nao hen hen no ms auto zoom chu luc thuong no chi chup ko no ko AI zoom".
   - Tinh nang tu dong zoom vao chu the (1x, 2x, 3x) hoat dong khong nhat quan, da so truong hop chi chup anh binh thuong ma khong tu dong zoom, chi thinh thoang moi kich hoat duoc zoom.

--------------------------------------------------------------------------------

## 4. CAC YEU CAU VA TIEU CHI BAT BUOC CHO CODE MOI

Toi khong chi dinh cho ban phai dung bat ky thuat toan hay cach lam cu the nao. Ban la chuyen gia ve computer vision va spatial tracking tren di dong, ban phai tu nghien cuu, tu lua chon va tu thiet ke giai phap toi uu nhat.

Ket qua cua ban bat buoc phai dap ung day du cac tieu chi sau:

1. Yeu cau ve chat luong bam target tren man hinh:
   - Khi camera dung yen hoac nguoi dung cam tay tu nhien: Tam bam phai dung yen vung chac tren vat the, khong duoc rung lac vi mo, khong giat nhay, triet tieu hoan toan rung tay 9-10Hz.
   - Khi nguoi dung lia may: Tam bam phai tiep tuc bam tren vat the thuc te trong khong gian (troi ve phia nguoc lai cua huong lia tren man hinh), tuyet doi khong duoc keo le di theo cham trang o giua man hinh.
   - Triet tieu hoan toan hien tuong tam dot ngot nhay sang cho khac roi thut ve cho cu.
   - Khi vat the di ra khoi khung hinh: He thong phai ghi nho vi tri goc trong khong gian va neo o mep vien man hinh (docking). Khi quay may tro lai, tam bam phai ngay lap tuc truot ve dung vat the ma khong bat nguoi dung phai chon lai muc tieu.
   - Xu ly muot ma trang thai tam thoi mat tin hieu quang hoc (bang con quay hoi chuyen), khong duoc bao mat dau va keu chon lai lien tuc gay loi.

2. Yeu cau ve co che AI Auto-Zoom:
   - Phai hoat dong on dinh, nhat quan, de kich hoat khi da khoa duoc chu the ro rang, khong de tinh trang "hen xui" luc duoc luc khong.

3. Yeu cau ve kiem tra hop dong (Contract Tests) va do tuong thich:
   - Tat ca cac bai kiem tra trong validate_tracking_geometry.py va validate_local_framing.py bat buoc phai PASS 100%. Khong duoc lam hong bat ky test case nao hien co.
   - Giu nguyen cac public API, signature, callback va kieu du lieu de khong gay loi bien dich voi cac file con lai trong project.
   - Dam bao an toan da luong (Thread-Safety) giua luong CoreMotion 60Hz, luong Vision 30Hz va luong Main UI. Khong duoc de xay ra deadlock hay race condition.
   - Khong tao dead code, khong them bien thua khong su dung.
   - Code viet bang Swift chuan Apple, ho tro iOS 17+.

4. Yeu cau ve dinh dang dau ra:
   - Cung cap day du toan bo ma nguon hoan chinh cua cac file duoc sua doi.
   - Khong viet ma nguon theo kieu rut gon nhu "// ... rest of code remains unchanged ...". Phai viet full code tung file de co the copy truc tiep vao du an.

--------------------------------------------------------------------------------

## 5. DANH SACH 16 FILE MA NGUON DINH KEM VA VAI TRO

1. SpatialTrackingEngine.swift: Dong co dung hop con quay hoi chuyen CoreMotion 60Hz va ket qua quang hoc tu Vision.
2. TrackingGeometry.swift: Toan hoc chieu tia camera (ray casting), noi suy pose (slerp), neo mep man hinh (docking).
3. NeuralTargetTracker.swift: Mang no-ron xac thuc dac trung ngoai quan cua vat the de chong nham lan.
4. TargetPatchFlow.swift: Luong quang hoc vi mo do tim su dich chuyen cua cac diem dac trung tren vat the.
5. DeviceMotionService.swift: Quan ly va dong bo mau con quay hoi chuyen 60Hz tu CoreMotion.
6. VisualOdometryEngine.swift: Dang ky anh homography de ho tro do dich chuyen vi mo giua hai khung hinh lien tiep.
7. VisionFramingEngine.swift: Pipeline xu ly thi giac Apple Vision, phat hien va theo doi bounding box.
8. CompositionCalculator.swift: Tinh toan goc bo cuc, huong ngam muc tieu va ti le auto-zoom.
9. NeuralSubjectIntelligenceEngine.swift: Phat hien chu the bang YOLO11 va Apple Vision Saliency.
10. FramingModels.swift: Cac kieu du lieu nen tang (TrackingQuality, FramingTarget, SceneType).
11. validate_tracking_geometry.py: Bo kiem dinh rang buoc hinh hoc gom 18 bai test bat buoc phai vuot qua.
12. validate_local_framing.py: Bo kiem dinh co che ngam, auto-zoom va bao toan khung hinh gom 8 bai test bat buoc phai vuot qua.
13. validate_patch_flow_reference.py: Mo hinh tham chieu do luong sai so luong quang hoc.
14. trained_tracking_parameters.json: Bo thong so sieu tham so do on dinh va sai so.
15. train_synthetic_tracking_environment.py: Moi truong gia lap vat ly 3D de hieu ro cac truong hop test.
16. train_target_embedder.py: Tap lenh huan luyen vector nhung ngoai quan.
"""

# Strip all emojis
clean_prompt = "".join([c for c in prompt_content if unicodedata.category(c) not in ("So", "Sk") and ord(c) <= 0x1F000 and not (0x2600 <= ord(c) <= 0x27BF)])

# Write prompt file
(target_dir / "PROMPT_CHATGPT.md").write_text(clean_prompt, encoding="utf-8")
(dl_dir / "PROMPT_CHATGPT.md").write_text(clean_prompt, encoding="utf-8")
(Path(r"C:\Users\admin\.gemini\antigravity\brain\b51f1c7c-a6a3-47e7-8980-264df7811faf") / "PROMPT_CHATGPT.md").write_text(clean_prompt, encoding="utf-8")

# Update zip file
zip_path = dl_dir / "AI_Camera_Tracking_Package.zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.write(target_dir / "PROMPT_CHATGPT.md", arcname="PROMPT_CHATGPT.md")
    for f in copied_files:
        zf.write(target_dir / f, arcname=f)

print(f"Successfully updated {dl_dir / 'PROMPT_CHATGPT.md'}")
print(f"Successfully updated ZIP: {zip_path} ({os.path.getsize(zip_path) / 1024:.1f} KB)")
