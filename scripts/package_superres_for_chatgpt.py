import os
import shutil
import zipfile
from pathlib import Path
import unicodedata

root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
target_dir = dl_dir / "AI_Camera_SuperRes_Package"
target_dir.mkdir(parents=True, exist_ok=True)

files_to_copy = [
    "AISmartFramingCamera/Services/SuperResolutionRAWEngine.swift",
    "AISmartFramingCamera/Services/SuperResolutionMetalShaders.swift",
    "AISmartFramingCamera/Services/CameraService.swift",
    "AISmartFramingCamera/ViewModels/CameraViewModel.swift",
    "AISmartFramingCamera/Services/DeviceMotionService.swift",
    "AISmartFramingCamera/Services/SpatialTrackingEngine.swift",
    "AISmartFramingCamera/Services/TrackingGeometry.swift",
    "AISmartFramingCamera/Services/CameraLogger.swift",
    "AISmartFramingCamera/Views/SettingsSheetView.swift",
    "AISmartFramingCamera/Views/CameraControlsView.swift",
    "AISmartFramingCamera/Views/CameraPreviewView.swift",
    "AISmartFramingCamera/Models/FramingModels.swift",
    "scripts/validate_super_resolution.py"
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

prompt_content = """# PROMPT YEU CAU CHO CHATGPT / CLAUDE: FIX TRIET DE TINH NANG CHUP SIEU NET 48MP (HANDHELD SUPER-RESOLUTION RAW FUSION)

CANH BAO QUAN TRONG: Doc that ky toan bo tap tin ma nguon duoc dinh kem. Tu suy nghi va thiet ke thuat toan moi toi uu nhat de giai quyet triet de cac loi thuc te, tao ra buc anh 48MP sieu net tu nhien tren iPhone. Khong du doan bia dat, khong viet ma nguon cat ngan.

--------------------------------------------------------------------------------

## 1. BAN CHAT VA BOI CANH DAY DU VE UNG DUNG

Day la ung dung gi?
- Day la ung dung may anh chup hinh thong minh tren iPhone (ten app: AI Smart Framing Camera), viet bang Swift/SwiftUI cho he dieu hanh iOS 17+ tren Apple Silicon (A11 Bionic den A18 Pro).
- DAY TUYET DOI KHONG PHAI LA DRONE (MAY BAY KHONG NGUOI LAI), KHONG PHAI ROBOT, KHONG PHAI CAMERA PTZ CO MOTOR XOAY, KHONG PHAI KINH AR.
- Thiet bi su dung la chiec iPhone do nguoi dung cam tren tay that ngoai doi thuc:
  + Che do su dung: Cam doc (Portrait), ti le khung hinh cam bien goc la 3:4 (kich thuoc 3024x4032 hoac 4032x3024), goc nhin ngang FOV khoang 60 den 65 do (tieu cu tuong duong khoang 24mm).
  + Dac thu sinh hoc cua tay nguoi: Tay nguoi luon co rung tay sinh hoc tu nhien (Handheld Tremor) voi tan so khoang 9 den 10 Hz va bien do nho. Chuyen dong rung tay nay tao ra do lech vi mo cuc nho (sub-pixel shift, tu 0.2 den 2.5 pixel) giua cac khung hinh chup lien tiep. Day chinh la co so vat ly cot loi de thuc hien sieu phan giai da khung hinh (Handheld Super-Resolution).

Quy trinh chup sieu net (Super-Resolution RAW Burst Pipeline):
1. Khi nguoi dung bam nut chup o che do Sieu Net, ung dung thuc hien chup mot chuoi burst (8 den 12 frames RAW 14-bit) thong qua AVCapturePhotoOutput voi toc do cao (30-40 fps).
2. Dong thoi, he thong thu nhan du lieu cam bien quan tinh 6DoF (CoreMotion CMMotionManager) gom con quay hoi chuyen (Gyroscope) va gia toc ke (Accelerometer) voi tan so 60Hz - 100Hz de ghi lai tu the goc quay (Quaternion orientation) va van toc goc cua tung khung hinh.
3. Cac khung hinh duoc dua vao dong co Metal Compute Shader de:
   - Chon khung hinh sac net nhat lam Khung Neo (Anchor Frame).
   - Tinh toan do lech vi mo (Sub-pixel motion offset) dua tren du lieu gyro 6DoF ket hop bo loc Kalman va so khop pixel.
   - Tinh trong so khu bong ma (Motion de-ghosting weights) de loai bo vung co vat the chuyen dong ngoai canh (nguoi di bo, xe co, canh cay).
   - Tich tu cac hat photon da khung hinh vao luoi sieu phan giai 48MP (High-Resolution Fusion Gather).
   - Chuan hoa trong so, bao toan dai mau va tuong phan Apple Display P3 / Rec.709.
   - Toi uu do net vi mo (Zero-Mushiness Micro-Contrast Enhancement) va xuat ra anh CGImage 48MP luu vao thu vien anh.

--------------------------------------------------------------------------------

## 2. NGUYEN VAN CAC CAU THAN VAN CUA NGUOI DUNG

Duoi day la nguyen van cac phan hoi va cau than van cua nguoi dung khi trai nghiem truc tiep tinh nang chup sieu net tren thiet bi:

1. "no cu bi trang sau khi chup y"
2. "lo qua no van bi mau trang xam"
3. "chup anh net 48mp sieu net su dung cac gyro 6dof kalman de loc rung cac kieu"
4. "fix di khi chup sieu net no bao dang chup raw 20% xong len 48mp gi ay xong vang luon"
5. "fix code anh chup ra bi den ko xem dc gi"
6. "fix di nhin van dc nhung no toi den xi anh a goi la nhin dc 5% thoi"

--------------------------------------------------------------------------------

## 3. CAC HIEN TUONG LOI THUC TE XAY RA TREN THIET BI

Chi ghi nhan chinh xac cac hien tuong thuc te xay ra (khong suy doan chu quan, khong bia thong tin):

1. Hien tuong anh bi chay trang xoa hoac trang xam bot bat (Blown-out White & Washed-out Flat Gray):
   - Sau khi ket thuc tien trinh chup va ghep chuoi RAW sieu net, buc anh tao ra bi trang xoa hoan toan (chay sang cuc nang o ca vung sang lan vung trung tinh) hoac bi bien thanh mot mau xam trang phang li, mat sach chi tiet, mat hoan toan do tuong phan va dai dong (dynamic range).
   - Mau sac goc cua vat the bi bien mat hoac bi nhat nhoa hoan toan.

2. Hien tuong anh bi toi den hoac chi nhin thay 5% chi tiet:
   - O mot so phien ban truoc do, anh chup ra bi toi den nhu muc hoac toi den gan nhu khong thay gi ngoai tru vai diem sang le loi (khoang 5% chi tiet).

3. Hien tuong bi vang app (Crash / OOM) khi dang chup hoac khi xu ly 48MP:
   - Khi tien trinh thong bao "dang chup raw 20%" roi chuyen sang xu ly 48MP thi ung dung bi dong dot ngot (vang khoi man hinh) tren mot so thiet bi co dung luong RAM han che.

4. Hien tuong anh bi bet nhoe hoac xuat hien bong ma (Mushiness & Ghosting Artifacts):
   - Khi tay nguoi cam may bi rung lac tu nhien, neu thuat toan can chinh sub-pixel khong chuan xac se dan den tinh trang cac chi tiet nho (chu viet tren bien hieu, soi vai, ke gach, canh hoa) bi nhoe nhoet, mat di do sac canh tu nhien cua do phan giai 48MP thuc su.

--------------------------------------------------------------------------------

## 4. YEU CAU CHO CHATGPT / CLAUDE KHI DOC VA FIX CODE

Nhiem vu cua ban:
Doc va hieu toan bo 13 tep tin ma nguon duoc cung cap trong goi AI_Camera_SuperRes_Package. Tu suy nghi, nghien cuu va thiet ke cac thuat toan moi hon de khac phuc toan dien cac hien tuong loi neu tren, dap ung cac tieu chi ky thuat sau:

1. Thuat toan loc rung va uoc luong vi chuyen dong Gyro 6DoF Kalman:
   - Su dung du lieu con quay hoi chuyen 6DoF (quaternion, angular velocity) va gia toc ke tu CoreMotion.
   - Thiet ke bo loc Kalman de loai bo nhieu cam bien va sai so troi (drift), mo hinh hoa chinh xac rung tay sinh hoc (hand tremor 9-10Hz).
   - Tinh toan vector dich chuyen sub-pixel (duoi 1 pixel) cuc ky chuan xac dua tren tieu cu quang hoc va ma tran xoay camera giua cac khung hinh trong chuoi burst.

2. Thuat toan sieu phan giai da khung hinh (Multi-Frame Super-Resolution Fusion):
   - Ghep noi du lieu photon tu 8-12 khung hinh RAW 14-bit vao luoi do phan giai cao (48MP tren cac dong may ho tro hoac scale an toan theo bo nho RAM).
   - Co co che loai bo bong ma (De-ghosting) thong minh cho cac chu the di dong (xe chay, nguoi di, ngon gio lam lung lay canh la).
   - Tich luy hat photon that su, khong phai phep phong to noi suy bicubic hay bilinear don thuan.

3. Bao toan mau sac, dai dong va triet tieu hoan toan hien tuong chay trang:
   - Quan ly mau sac chat che trong khong gian mau Apple Display P3 / Rec.709.
   - Bao toan nguyen ven can bang trang (Auto White Balance - AWB) va thong so phoi sang goc tu phan cung Apple ISP.
   - Thiet ke co che kiem soat tuong phan va tone curve duy nhat (Single-pass tone management), tuyet doi khong de xay ra hien tuong khuech dai do sang gap doi (double exposure boost / compound tone mapping) dan den anh bi trang xoa hoan toan hay bac mau.

4. Nang cao do net vi tuong phan (Zero-Mushiness Micro-Contrast):
   - Tai tao chi tiet goc sac sao, giu duoc do trong treo cua buc anh, khong bi quang sang vien (haloing / ringing).
   - Kiem soat bo nho Metal texture chat che, cap phat hop ly theo dung luong RAM thiet bi de tuyet doi khong bi tran RAM (OOM crash).

5. Kiem chung ma nguon:
   - Ban co the chay tap tin `validate_super_resolution.py` bang Python de kiem tra cac mo hinh vat ly, bo loc Kalman, phep chieu sub-pixel, da dang lay mau luoi 48MP va an toan phoi sang.

--------------------------------------------------------------------------------

## 5. DINH DANG KET QUA DAU RA BAT BUOC

- Cung cap ma nguon day du (FULL CODE) cho tat ca cac file duoc sua doi.
- Tuyet doi khong dung code rut gon, khong viet chu thich cat xoc kieu `// ... giu nguyen ...` hay `// ... rest of code unchanged ...`.
- Nguoi dung chi can copy toan bo noi dung file de ghi de vao du an la build va hoat dong ngay lap tuc.
- Khong su dung bat ky ky tu bieu cam (emoji) nao trong toan bo phan hoi.

--------------------------------------------------------------------------------

## 6. DANH SACH 13 FILE TRONG GOI NAY

1. `SuperResolutionRAWEngine.swift`: Dong co xu ly sieu phan giai RAW da khung, dieu phoi pipeline Metal GPU.
2. `SuperResolutionMetalShaders.swift`: Ma nguon Metal Shading Language (MSL) runtime gom cac Compute Kernels.
3. `CameraService.swift`: Thu nhan chuoi burst RAW, quan ly AVCapturePhotoOutput va metadata EXIF.
4. `CameraViewModel.swift`: Dieu phoi tien trinh chup tren UI, goi dong co xu ly va luu anh.
5. `DeviceMotionService.swift`: Thu thap du lieu chuyen dong 6DoF tu CMMotionManager.
6. `SpatialTrackingEngine.swift`: He thong tracking 3D va pose orientation quaternion.
7. `TrackingGeometry.swift`: Mo hinh hinh hoc pinhole camera va phep chieu 3D/2D.
8. `CameraLogger.swift`: He thong ghi log chan doan.
9. `SettingsSheetView.swift`: Giao dien bat/tat che do chup sieu net RAW.
10. `CameraControlsView.swift`: Giao dien nut chup va hien thi trang thai sieu net.
11. `CameraPreviewView.swift`: Khung hinh preview camera Metal.
12. `FramingModels.swift`: Cac kieu du lieu trang thai va cau hinh.
13. `validate_super_resolution.py`: Tap test Python kiem tra mo hinh Kalman, sub-pixel, dai dong va bo nho.
"""

def contains_emoji(text: str) -> bool:
    for char in text:
        cat = unicodedata.category(char)
        if cat in ('So', 'Cs'):
            return True
        code = ord(char)
        # Check standard emoji blocks
        if (0x1F600 <= code <= 0x1F64F) or \
           (0x1F300 <= code <= 0x1F5FF) or \
           (0x1F680 <= code <= 0x1F6FF) or \
           (0x1F700 <= code <= 0x1F77F) or \
           (0x1F780 <= code <= 0x1F7FF) or \
           (0x1F800 <= code <= 0x1F8FF) or \
           (0x1F900 <= code <= 0x1F9FF) or \
           (0x1FA00 <= code <= 0x1FA6F) or \
           (0x1FA70 <= code <= 0x1FAFF) or \
           (0x2600 <= code <= 0x26FF) or \
           (0x2700 <= code <= 0x27BF):
            return True
    return False

# Verify emoji check
assert not contains_emoji(prompt_content), "Prompt content contains emojis!"

# Write prompt file to Downloads and target_dir
prompt_file_dl = dl_dir / "PROMPT_SUPERRES_CHATGPT.md"
prompt_file_pkg = target_dir / "PROMPT_SUPERRES_CHATGPT.md"

with open(prompt_file_dl, "w", encoding="utf-8") as f:
    f.write(prompt_content)

with open(prompt_file_pkg, "w", encoding="utf-8") as f:
    f.write(prompt_content)

# Zip target_dir into C:\Users\admin\Downloads\AI_Camera_SuperRes_Package.zip
zip_path = dl_dir / "AI_Camera_SuperRes_Package.zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for file in target_dir.rglob("*"):
        if file.is_file():
            arcname = file.relative_to(target_dir)
            zipf.write(file, arcname)

print("Package generated successfully:")
print(f"- Target Directory: {target_dir}")
print(f"- Total Files Copied: {len(copied_files)}")
print(f"- Prompt File: {prompt_file_dl}")
print(f"- Zip File: {zip_path} ({zip_path.stat().st_size} bytes)")
