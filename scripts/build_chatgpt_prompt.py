import os
from pathlib import Path

root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
output_path = Path(r"C:\Users\admin\.gemini\antigravity\brain\b51f1c7c-a6a3-47e7-8980-264df7811faf\PROMPT_CHO_CHATGPT_TRACKING_FULL.md")
dl_path = Path(r"C:\Users\admin\Downloads\PROMPT_CHO_CHATGPT_TRACKING_FULL.md")

files_to_include = [
    ("AISmartFramingCamera/Services/SpatialTrackingEngine.swift", "swift"),
    ("AISmartFramingCamera/Services/TrackingGeometry.swift", "swift"),
    ("AISmartFramingCamera/Services/NeuralTargetTracker.swift", "swift"),
    ("AISmartFramingCamera/Services/TargetPatchFlow.swift", "swift"),
    ("AISmartFramingCamera/Services/DeviceMotionService.swift", "swift"),
    ("AISmartFramingCamera/Services/VisualOdometryEngine.swift", "swift"),
    ("scripts/validate_tracking_geometry.py", "python"),
    ("scripts/validate_local_framing.py", "python"),
    ("scripts/validate_patch_flow_reference.py", "python"),
    ("scripts/trained_tracking_parameters.json", "json"),
    ("scripts/train_synthetic_tracking_environment.py", "python"),
    ("scripts/train_target_embedder.py", "python"),
]

header = """# PROMPT YEU CAU CHO CHATGPT: DOC FULL CODE VA FIX TRIET DE HE THONG BAM TARGET (SPATIAL TRACKING & AUTO ZOOM)

Toi dang phat trien ung dung may anh thong minh AI Smart Framing Camera tren iOS (viet bang Swift, SwiftUI, iOS 17+).

Duoi day la toan bo ma nguon moi nhat cua cac file lien quan den he thong tracking target (bam muc tieu), bao gom ca cac file Swift tren iOS va cac file Python kiem tra rang buoc hinh hoc, moi truong gia lap va tap tham so.

Nhiem vu cua ban: Doc toan bo ma nguon cua cac file ben duoi, hieu ro cach he thong hoat dong va cac rang buoc trong tap test, sau do viet lai code hoan chinh de khac phuc toan bo cac loi duoc neu ben duoi.

--------------------------------------------------------------------------------

## PHAN 1: PHAN HOI TRUC TIEP VA CAC CAU THAN VAN CUA NGUOI DUNG

Duoi day la nguyen van cac cau than van cua nguoi dung khi trai nghiem truc tiep ung dung tren iPhone:

1. "bam no rung voi chay lung tung voi qua lo"
2. "tam no cu bi doi luc nhay lung tung xong ve lai cho cu kho chiu lam"
3. "fix t thay doi khi nao hen hen no ms auto zoom chu luc thuong no chi chup ko no ko AI zoom :( fix di"
4. "lo qua no van bi mau trang xam"

--------------------------------------------------------------------------------

## PHAN 2: CAC HIEN TUONG LOI THUC TE CAN PHAI KHAC PHUC

Chi ghi nhan chinh xac cac hien tuong loi thuc te xay ra tren thiet bi (khong giai thich suy doan ly do, khong bia thong tin):

1. Hien tuong rung lac va giat nhay (Jitter & Centroid Hunting):
   - Khi huong camera vao mot vat the tinh hoac khi lia may nhe, tam bam (Target Reticle) bi rung lac, khong giu duoc do on dinh em ai tren vat the.
   - Tam bam bi giat, co xu huong dao dong hoac lac xung quanh vat the thay vi bam chat vao tam vat the thuc te.

2. Hien tuong nhay lung tung roi thut ve cho cu (Outlier Snapping):
   - Trong qua trinh bam, doi luc tam bam dot ngot bi nhay vot sang mot vi tri khac tren man hinh roi sau do lai thut ve vi tri cu.
   - Hien tuong nay xay ra lap di lap lai gay kho chiu cho nguoi dung.

3. Hien tuong chay lung tung khi lia may (Tracking Drift & Instability):
   - Khi nguoi dung lia may dien thoai, tam bam khong bam theo vat the trong the gioi thuc ma bi chay lung tung hoac bi lech khoi vat the.

4. Hien tuong AI Auto-Zoom hoat dong chap chon:
   - Nguoi dung phan anh: "doi khi nao hen hen no ms auto zoom chu luc thuong no chi chup ko no ko AI zoom".
   - Tinh nang tu dong zoom vao chu the (1x, 2x, 3x) hoat dong khong nhat quan, da so truong hop chi chup anh binh thuong ma khong tu dong zoom, chi thinh thoang moi kich hoat duoc zoom.

--------------------------------------------------------------------------------

## PHAN 3: CAC YEU CAU VA TIEU CHI BAT BUOC CHO CODE MOI

Toi khong chi dinh cho ban phai dung bat ky thuat toan hay cach lam cu the nao. Ban la chuyen gia ve computer vision va spatial tracking tren di dong, ban phai tu nghien cuu, tu lua chon va tu thiet ke giai phap toi uu nhat.

Tuy nhien, ket qua cua ban bat buoc phai dap ung day du cac tieu chi sau:

1. Yeu cau ve chat luong bam target tren man hinh:
   - Khi camera dung yen hoac nguoi dung cam tay tu nhien: Tam bam phai dung yen vung chac tren vat the, khong duoc rung lac vi mo, khong giat nhay.
   - Khi nguoi dung lia may: Tam bam phai tiep tuc bam tren vat the thuc te trong khong gian (troi ve phia nguoc lai cua huong lia tren man hinh), tuyet doi khong duoc keo le di theo cham trang o giua man hinh.
   - Triet tieu hoan toan hien tuong tam dot ngot nhay sang cho khac roi thut ve cho cu.
   - Khi vat the di ra khoi khung hinh: He thong phai ghi nho vi tri goc trong khong gian va neo o mep vien man hinh (docking). Khi quay may tro lai, tam bam phai ngay lap tuc truot ve dung vat the.

2. Yeu cau ve co che AI Auto-Zoom:
   - Phai hoat dong on dinh, nhat quan, de kich hoat khi da khoa duoc chu the ro rang, khong de tinh trang "hen xui" luc duoc luc khong.

3. Yeu cau ve kiem tra hop dong (Contract Tests) va do tuong thich:
   - Tat ca cac bai kiem tra trong `scripts/validate_tracking_geometry.py` va `scripts/validate_local_framing.py` bat buoc phai PASS 100%. Khong duoc lam hong bat ky test case nao hien co.
   - Giu nguyen cac public API, signature, callback va kieu du lieu de khong gay loi bien dich voi cac file con lai trong project (`CameraViewModel.swift`, `VisionFramingEngine.swift`, `ARFramingOverlayView.swift`).
   - Dam bao an toan da luong (Thread-Safety) giua luong CoreMotion 60Hz, luong Vision 30Hz va luong Main UI. Khong duoc de xay ra deadlock hay race condition.
   - Khong tao dead code, khong them bien thua khong su dung.
   - Code viet bang Swift chuan Apple, ho tro iOS 17+.

4. Yeu cau ve dinh dang dau ra:
   - Cung cap day du toan bo ma nguon hoan chinh cua cac file duoc sua doi.
   - Khong viet ma nguon theo kieu rut gon nhu "// ... rest of code remains unchanged ...". Phai viet full code tung file de co the copy truc tiep vao du an.

--------------------------------------------------------------------------------

## PHAN 4: TOAN BO MA NGUON CAC FILE LIEN QUAN DEN TRACKING TARGET

"""

content_parts = [header]

for rel_path, lang in files_to_include:
    file_path = root / rel_path
    if not file_path.exists():
        print(f"Warning: {file_path} not found!")
        continue
    file_content = file_path.read_text(encoding="utf-8")
    part = f"""### FILE: `{rel_path}`

```{lang}
{file_content}
```

--------------------------------------------------------------------------------

"""
    content_parts.append(part)

full_text = "".join(content_parts)

# Remove all emojis to strictly satisfy 'ko su dung emoji'
import unicodedata
clean_chars = []
for ch in full_text:
    cat = unicodedata.category(ch)
    if cat in ("So", "Sk") or ord(ch) > 0x1F000 or (0x2600 <= ord(ch) <= 0x27BF):
        continue
    clean_chars.append(ch)
clean_text = "".join(clean_chars)

output_path.write_text(clean_text, encoding="utf-8")
dl_path.write_text(clean_text, encoding="utf-8")
print(f"Wrote {len(clean_text)} characters ({len(clean_text.encode('utf-8')) / 1024:.1f} KB) to {output_path} and {dl_path}")
