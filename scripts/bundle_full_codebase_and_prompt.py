import os
import shutil
import zipfile
from pathlib import Path
import unicodedata

repo_root = Path(r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera")
dl_dir = Path(r"C:\Users\admin\Downloads")
dl_dir.mkdir(parents=True, exist_ok=True)

# 1. Collect all Swift files and key python/test files
swift_root = repo_root / "AISmartFramingCamera"
all_swift_files = sorted(swift_root.rglob("*.swift"))
test_files = [
    repo_root / "scripts/validate_super_resolution.py",
    repo_root / "scripts/validate_tracking_geometry.py",
    repo_root / "scripts/validate_local_framing.py",
    repo_root / "scripts/validate_tracking_stability.py",
    repo_root / "scripts/validate_patch_flow_reference.py",
]

# Primary priority files first, then the rest
priority_names = [
    "CameraViewModel.swift",
    "CameraService.swift",
    "SuperResolutionRAWEngine.swift",
    "SuperResolutionMetalShaders.swift",
    "ARFramingOverlayView.swift",
    "SpatialTrackingEngine.swift",
    "TrackingGeometry.swift",
    "VisionFramingEngine.swift",
    "CompositionCalculator.swift",
    "DeviceMotionService.swift",
    "CameraControlsView.swift",
    "CameraMainView.swift",
    "CameraPreviewView.swift",
    "SettingsSheetView.swift",
    "CapturedPhotoPreviewView.swift",
    "FramingModels.swift",
    "CameraLogger.swift",
]

ordered_swift_files = []
# Add priority files first
for p_name in priority_names:
    for f in all_swift_files:
        if f.name == p_name and f not in ordered_swift_files:
            ordered_swift_files.append(f)
# Add all remaining swift files
for f in all_swift_files:
    if f not in ordered_swift_files:
        ordered_swift_files.append(f)

# 2. Build the single full-code file: AI_Camera_Full_Source_Code.txt
single_full_code_path = dl_dir / "AI_Camera_Full_Source_Code.txt"
with open(single_full_code_path, "w", encoding="utf-8") as out:
    out.write("================================================================================\n")
    out.write("AI SMART FRAMING CAMERA - TOAN BO MA NGUON NGUYEN BAN (FULL SOURCE CODE)\n")
    out.write(f"Tong so tep Swift: {len(ordered_swift_files)}\n")
    out.write(f"Tong so tep kiem thu Python: {len(test_files)}\n")
    out.write("Moi tep duoc ngan cach bang tieu de ro rang. Ban co quyen doc va sua bat ky tep nao.\n")
    out.write("================================================================================\n\n")

    for f in ordered_swift_files:
        rel = f.relative_to(repo_root)
        out.write("================================================================================\n")
        out.write(f"FILE: {rel.as_posix()}\n")
        out.write("================================================================================\n")
        content = f.read_text(encoding="utf-8")
        out.write(content)
        if not content.endswith("\n"):
            out.write("\n")
        out.write("\n")

    for f in test_files:
        if f.exists():
            rel = f.relative_to(repo_root)
            out.write("================================================================================\n")
            out.write(f"TEST SCRIPT: {rel.as_posix()}\n")
            out.write("================================================================================\n")
            content = f.read_text(encoding="utf-8")
            out.write(content)
            if not content.endswith("\n"):
                out.write("\n")
            out.write("\n")

print(f"Generated single full code file: {single_full_code_path} ({single_full_code_path.stat().st_size} bytes)")

# 3. Create package folder and zip
package_dir = dl_dir / "AI_Camera_Full_Code_Package"
package_dir.mkdir(parents=True, exist_ok=True)

# Copy all priority files and scripts to package_dir for convenient modular browsing
for f in ordered_swift_files[:20] + test_files:
    if f.exists():
        dst = package_dir / f.name
        shutil.copy2(f, dst)

# 4. Generate the Prompt content (ZERO EMOJIS)
prompt_text = """# PROMPT YEU CAU CHO AI: SUA TOAN DIEN HE THONG AUTO-CAPTURE VA CHUP ANH SIEU NET 48MP

CANH BAO QUAN TRONG:
Ban duoc phep doc toan bo ma nguon trong tep AI_Camera_Full_Source_Code.txt (hoac thu muc AI_Camera_Full_Code_Package) va duoc phep sua doi bat ky tep nao de giai quyet triet de 2 loi duoc neu duoi day.
Khong du doan bia dat. Khong viet ma nguon cat ngan (tuyet doi khong dung // ... giu nguyen ... hoac // ... rest of code unchanged ...).
Tra ve ma nguon day du (FULL CODE) cho moi tep ban sua doi.

--------------------------------------------------------------------------------

## 1. BAN CHAT VA BOI CANH CUA UNG DUNG

- Ung dung: AI Smart Framing Camera tren iOS 17+ (viet bang Swift, SwiftUI, Metal Shading Language, CoreMotion, AVFoundation).
- Thiet bi su dung: Chiec iPhone do nguoi dung cam tren tay that ngoai doi thuc (tu iPhone 8/X den iPhone 16 Pro).
- DAY TUYET DOI KHONG PHAI LA DRONE (MAY BAY KHONG NGUOI LAI), KHONG PHAI ROBOT, KHONG PHAI CAMERA PTZ CO MOTOR XOAY, KHONG PHAI KINH AR.
- Dac thu vat ly:
  + May cam doc (Portrait), ti le khung hinh cam bien la 3:4 (4032x3024 hoac 3024x4032), goc nhin ngang FOV khoang 60 den 65 do (tieu cu ~24mm).
  + Tay nguoi luon co rung tay sinh hoc tu nhien (Handheld Tremor) voi tan so 9 den 10 Hz va bien do nho.
- Co che van hanh:
  + Nguoi dung cham vao mot vat the thuc te tren man hinh de dat mot VONG TRON VANG (Target Reticle) len vat the do.
  + O chinh giua man hinh camera luon co mot CHAM TRANG CO DINH tai toa do (0.5, 0.5) dai dien cho truc quang hoc cua ong kinh.
  + Nguoi dung lia hoac nghieng dien thoai de dua cham trang lai gan va trung vao vong vang theo huong dan.
  + Khi cham trang di vao trung tam vong vang (can dung bo cuc): Ung dung ho tro co che tu dong zoom (AI Auto-Zoom) va BAT BUOC PHAI TU DONG CHUP ANH (Auto-Capture on Alignment) cho nguoi dung.

--------------------------------------------------------------------------------

## 2. NGUYEN VAN CAC CAU THAN VAN CUA NGUOI DUNG

Duoi day la nguyen van phan hoi truc tiep cua nguoi dung sau khi trai nghiem:

Cau than van 1:
"khi dua tam trang vo target no ko tu chup hay gi cho vao hay gi nhu khong fix"

Cau than van 2:
"Chuc nang chup anh sieu net hien tai rat lo chup anh mau thi chan nhu thoi xua bo chuc nang giai raw chi ra anh raw thoi chup sieu net 48mp anh ko bi nguoc hay gi het lam lai thuat toan"

Cac cau than van lien quan truoc do:
"no cu bi trang sau khi chup y"
"lo qua no van bi mau trang xam"
"chup anh net 48mp sieu net su dung cac gyro 6dof kalman de loc rung cac kieu"

--------------------------------------------------------------------------------

## 3. PHAN TICH CHI TIET 2 VAN DE CAN KHAC PHUC TRIET DE

### VAN DE 1: DUA TAM TRANG VAO TARGET NHUNG KHONG HE TU DONG CHUP (AUTO-CAPTURE BI LIET)

Hien tuong thuc te:
Nguoi dung dua tam trang vao khop voi vong vang target, nhung he thong hoan toan tro li, khong he tu dong chup anh, giong nhu tinh nang khong ton tai hoac khong hoat dong.

Nguyen nhan ma nguon hien tai (trong CameraViewModel.swift):
1. Trong ham evaluateAlignment(at:):
   Dieu kien can aligned = hasFreshOpticalLock && dist <= tolerance bi chan boi hasFreshOpticalLock:
   - hasFreshOpticalLock doi hoi latestOpticalBox != nil (phai co bounding box tu Apple Vision). Neu nguoi dung cham vao mot diem tren ban, coc nuoc, hoa, vat the bat ky ma Vision khong sinh ra bounding box thi hasFreshOpticalLock = false, khien aligned MAI MAI BANG FALSE du tam trang da de len dung target!
2. Bien zoomVerified:
   Neu he thong khong chay auto-zoom hoac zoom timeout hoac o muc 1x thi zoomVerified bi false, khien ham startAutoCaptureCountdown() khong bao gio duoc goi.
3. Ham startAutoCaptureCountdown():
   Thiet lap dem nguoc va ngu 850 miligiay (Task.sleep 850ms). Trong suot 850ms nay, vi nguoi dung cam tay luon co rung tay sinh hoc 9-10Hz, chi can khoang cach nhich ra ngoai tolerance 1 miligiay la nhanh else cua evaluateAlignment huy ngay lap tuc (autoCaptureTask?.cancel(), autoCaptureCountdown = 0). Ket qua la dem nguoc khong bao gio song sot qua 850ms tren thiet bi thuc te!
4. Hon 10 tang dieu kien chan cuoi:
   Tai dong 2070-2076 cua CameraViewModel.swift, ngay ca khi het 850ms, he thong lai kiem tra them:
   cropSafe, currentSubjectBoxIsSafe (lai doi latestOpticalBox != nil), trackingQuality == .locked, zoomVerified, v.v. Chi can 1 dieu kien khong thoa la huy luon va kich hoat lastFailedCaptureAttemptTime, khoa chan nguoi dung khong cho chup tiep trong 400ms!

Yeu cau sua doi cho Van de 1:
- Thiet ke lai toan bo co che Auto-Capture khi can tam:
  + Khi tam trang di vao vung target (dist <= tolerance hoac mot nguong dung sai hop ly), he thong phai lap tuc nhan dien trang thai aligned.
  + Phai ho tro target duoc cham chon boi nguoi dung (SpatialTrackingEngine 3D point) ma KHONG bat buoc phai co bounding box Vision (latestOpticalBox khong duoc lam blocker).
  + Xu ly rung tay sinh hoc (hand tremor): Dung bo dem tich luy thoi gian (dwell accumulator) voi do tre hop ly (~0.25s den 0.35s) va co do tre tre (hysteresis). Khong duoc huy dem nguoc tuc thi chi vi mot nhip rung tay nho vuot nguong trong vai mili-giay.
  + Co phan hoi ro rang (haptic, am thanh, dem nguoc hien thi) va tu dong bam chup ngay khi thoa man thoi gian giu tam.
  + Loai bo cac bien chan vo ly khien luong chup tu dong bi chet yeu.

---

### VAN DE 2: CHUP ANH SIEU NET LO, MAU CHAN NHU THOI XUA, XUAT RAW THAT, ANH BI NGUOC VA THUAT TOAN 48MP

Hien tuong thuc te:
1. Mau sac anh chup ra nhat nhoa, bet mau, thieu tuong phan, toi tam hoac bot bat trong nhu anh chup tu may anh ky thuat so co lo thoi xua.
2. Nguoi dung yeu cau: "bo chuc nang giai raw chi ra anh raw thoi" - Khi nguoi dung chon chup RAW (.dng), dung co tu giai ma bang bo demosaic loi roi bien no thanh anh HEIF/JPEG chat luong thap! Hay xuat file DNG goc cua Apple ProRAW / Bayer RAW!
3. "anh ko bi nguoc hay gi het": Anh chup ra bi nguoc (lon nguoc dau xuong duoi hoac bi xoay sai huong) do sai lech he toa do Metal (goc tren-trai) va Core Image / CGImage (goc duoi-trai) hoac EXIF orientation khong duoc bao toan.
4. "chup sieu net 48mp ... lam lai thuat toan": Lam lai thuat toan chup anh sieu net 48MP thuc su.

Nguyen nhan ma nguon hien tai:
1. Mau sac bi chan:
   Trong SuperResolutionRAWEngine.swift, rawFilter.exposure = 0 va bo giai ma CIRAWFilter thieu cac buoc xu ly phan cung Smart HDR, Deep Fusion va tone curve tinh vi cua Apple ISP. Metal shaders lai tu linearize va encodeP3 khong dong nhat khien dai dynamic range bi bop nghẹt, mau sac nhat nheo, khong co do trong treo tu nhien.
2. Che do RAW bi luu thanh HEIF:
   Trong CameraViewModel.swift, dong 2931:
   let photoFormat: PhotoSaveFormat = selectedPhotoFormat == .dng && item.rawPhotoData == nil ? .heif : selectedPhotoFormat
   Khi nguoi dung bat chup RAW ma he thong lai tu giai ma va bien thanh HEIF thay vi xuat ra file RAW DNG thuc thu.
3. Anh bi nguoc (Inverted / Upside Down):
   Trong SuperResolutionRAWEngine.swift ham makeCGImage(from: texture), viec tao CIImage tu MTLTexture truc tiep khien truc Y bi dao nguoc vi Core Image co goc toa do tai Bottom-Left trong khi Metal o Top-Left. Dong thoi huong anh orientation tu metadata khong duoc ap dung dung cach khi xuat ra anh cuoi cung.
4. Thiet bi iPhone hien dai (iPhone 14 Pro, 15, 15 Pro, 16, 16 Pro) da co cam bien 48MP phan cung:
   Trong CameraService.swift, photoOutput.maxPhotoDimensions ho tro toi da 8064x6048 (48MP). Khi nguoi dung chup anh 48MP tren cac dong may co cam bien 48MP, he thong hoan toan co the chup anh 48MP goc tu Apple Photonic Engine voi day du mau sac HDR tuyet my nhat, hoac ket hop da khung de loai bo nhieu va lam net chi tiet.

Yeu cau sua doi cho Van de 2:
1. Sua triet de loi anh bi nguoc:
   He toa do giua Metal texture va CGImage/CIImage phai duoc flip dung huong (flip vertically hoac ap dung dung CGAffineTransform). Orientation cua anh phai dung 100% (chup doc ra anh doc, chup ngang ra anh ngang, khong bao gio bi lon nguoc hay xoay 90/180 do).
2. Xử ly che do RAW chuan xac:
   Khi nguoi dung chon che do anh RAW (DNG): Ung dung phai ghi dung du lieu RAW goc (DNG payload tu AVCapturePhoto) vao thu vien anh PhotoKit bang PHAssetCreationRequest (su dung .photo va phan mo rong DNG), khong duoc bien RAW thanh anh nen 8-bit.
3. Giu tron mau sac Apple Display P3 song dong:
   Khong duoc de anh bi nhat mau hay "chan nhu thoi xua". Mau sac phai tuoi sang, trong treo, do tuong phan sau, giu nguyen ven chat luong tu Apple ISP / Smart HDR.
4. Thuat toan 48MP Sieu Net:
   - Tan dung toi da phan cung: Neu thiet bi ho tro 48MP (photoOutput.maxPhotoDimensions >= 8000), kich hoat che do chup 48MP do phan giai cao nhat cua Apple.
   - Neu thuc hien ghep da khung (Multi-frame fusion): Su dung IMU con quay hoi chuyen 6DoF Kalman de can chinh sub-pixel, tang cuong do net chi tiet vi mo (micro-contrast), khong gay bệt nhòe, khong bi quang vien (haloing), khong lam sai mau va bao toan day du dai sang.

--------------------------------------------------------------------------------

## 4. QUYEN HAN VA DINH DANG DAU RA

- Ban co TOAN QUYEN sua doi tat ca cac tep ma nguon can thiet trong du an, dac biet la:
  1. `AISmartFramingCamera/ViewModels/CameraViewModel.swift`
  2. `AISmartFramingCamera/Services/CameraService.swift`
  3. `AISmartFramingCamera/Services/SuperResolutionRAWEngine.swift`
  4. `AISmartFramingCamera/Services/SuperResolutionMetalShaders.swift`
  5. `AISmartFramingCamera/Views/ARFramingOverlayView.swift`
  6. `AISmartFramingCamera/Views/SettingsSheetView.swift`
  7. Va bat ky tep nao khac neu can thiet de logic hoat dong hoan hao.
- Tra ve MA NGUON HOAN CHINH (FULL CODE) cho tung tep can thay doi, khong bo sot dong nao, khong viet tat, de nguoi dung chi viec copy ghi de va build ngay lap tuc.
- Tuyet doi KHONG su dung bat ky ky tu bieu cam (emoji) nao trong toan bo phan hoi cua ban.
"""

def contains_emoji(text: str) -> bool:
    for char in text:
        cat = unicodedata.category(char)
        if cat in ('So', 'Cs'):
            return True
        code = ord(char)
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

assert not contains_emoji(prompt_text), "Prompt text contains emoji!"

# Write prompt file
prompt_path = dl_dir / "PROMPT_CHO_AI_FIX_TOAN_DIEN.md"
prompt_path.write_text(prompt_text, encoding="utf-8")
print(f"Generated prompt file: {prompt_path} ({prompt_path.stat().st_size} bytes)")

# Also copy prompt into package_dir
(package_dir / "PROMPT_CHO_AI_FIX_TOAN_DIEN.md").write_text(prompt_text, encoding="utf-8")

# Zip package
zip_path = dl_dir / "AI_Camera_Full_Code_Package.zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for file in package_dir.rglob("*"):
        if file.is_file():
            arcname = file.relative_to(package_dir)
            zipf.write(file, arcname)

print(f"Generated package zip: {zip_path} ({zip_path.stat().st_size} bytes)")
