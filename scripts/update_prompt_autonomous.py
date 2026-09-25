from pathlib import Path
import unicodedata
import zipfile

prompt = """# PROMPT YEU CAU CHO AI: TU DOC FULL SOURCE CODE VA TU THIET KE GIAI PHAP FIX TOAN BO CAC LOI NGUOI DUNG PHAN NAN

CANH BAO QUAN TRONG:
Chung toi cung cap toan bo ma nguon cua toan bo ung dung trong tep AI_Camera_Full_Source_Code.txt (va thu muc AI_Camera_Full_Code_Package).
Nhiem vu cua ban la phai TU MINH DOC HIEU TOAN BO SOURCE CODE, TU SUY NGHI VA TU THIET KE THUAT TOAN / CACH FIX. Chung toi KHONG chi dan thuat toan, KHONG giai thich cach lam hay nguyen nhan ky thuat.
Ban duoc phep sua doi bat ky tep tin nao trong toan bo du an, sua toan dien nhung cho ban doc thay chua duoc hoan thien, va bat buoc phai khac phuc triet de tat ca cac loi ma nguoi dung da phan nan ben duoi.
Tra ve MA NGUON DAY DU (FULL CODE) cho tung tep ban sua doi, tuyet doi khong viet code tat hay cat ngon.

--------------------------------------------------------------------------------

## 1. BOI CANH VA BAN CHAT UNG DUNG

- Ung dung: AI Smart Framing Camera tren iOS 17+ (viet bang Swift, SwiftUI, Metal Shading Language, CoreMotion, AVFoundation).
- Thiet bi su dung: Chiec dien thoai iPhone do nguoi dung cam tren tay that ngoai doi thuc.
- DAY TUYET DOI KHONG PHAI LA DRONE (MAY BAY KHONG NGUOI LAI), KHONG PHAI ROBOT, KHONG PHAI CAMERA PTZ CO MOTOR XOAY, KHONG PHAI KINH AR.
- Dac thu vat ly:
  + May cam doc (Portrait), ti le khung hinh cam bien la 3:4, goc nhin ngang FOV khoang 60 den 65 do (tieu cu ~24mm).
  + Nguoi dung cam tay luon co rung tay sinh hoc tu nhien (Handheld Tremor) voi tan so 9 den 10 Hz va bien do nho.
- Co che hoat dong nguoi dung trai nghiem:
  + Nguoi dung cham vao mot vat the thuc te tren man hinh de dat mot VONG TRON VANG (Target Reticle) khoa len vat the do.
  + O chinh giua man hinh camera luon co mot CHAM TRANG CO DINH tai toa do (0.5, 0.5) dai dien cho truc quang hoc cua ong kinh.
  + Nguoi dung lia hoac nghieng dien thoai de dua cham trang di vao trung tam vong vang target.
  + Khi cham trang di vao dung target (can dung bo cuc): He thong co che do tu dong zoom (AI Auto-Zoom) va BAT BUOC PHAI TU DONG CHUP ANH (Auto-Capture on Alignment) cho nguoi dung.

--------------------------------------------------------------------------------

## 2. NGUYEN VAN PHAN HOI VA CAU THAN VAN CUA NGUOI DUNG

Duoi day la nguyen van cac cau than van cua nguoi dung khi su dung truc tiep tren may:

1. "khi dua tam trang vo target no ko tu chup hay gi cho vao hay gi nhu khong fix"
2. "Chuc nang chup anh sieu net hien tai rat lo chup anh mau thi chan nhu thoi xua bo chuc nang giai raw chi ra anh raw thoi chup sieu net 48mp anh ko bi nguoc hay gi het lam lai thuat toan"
3. "no cu bi trang sau khi chup y"
4. "lo qua no van bi mau trang xam"
5. "bam no rung voi chay lung tung voi qua lo"
6. "tam no cu bi doi luc nhay lung tung xong ve lai cho cu kho chiu lam"
7. "fix t thay doi khi nao hen hen no ms auto zoom chu luc thuong no chi chup ko no ko AI zoom :( fix di"

--------------------------------------------------------------------------------

## 3. CAC HIEN TUONG LOI THUC TE XAY RA TREN MAY (CHI GHI NHAN SU THAT, KHONG BIA DAT)

Chi ghi nhan chinh xac cac hien tuong loi xay ra tren thiet bi de ban nam bat:

1. Loi Auto-Capture khi can tam khong hoat dong:
   - Nguoi dung lia may dua cham trang o tam man hinh vao khop voi vong vang target, nhung he thong hoan toan khong tu dong bam chup, dua vao hay khong dua vao thi may van tro li nhu khong he co chuc nang nay.

2. Loi mau sac anh chup sieu net:
   - Anh chup tu che do sieu net ra mau sac rat chan, nhat nhoa, bet mau, thieu tuong phan, toi tam hoac trang xam bot bat trong nhu may anh ky thuat so thoi xua.

3. Loi xuat anh che do RAW:
   - Nguoi dung chon chup RAW (.dng) nhung ung dung khong xuat ra dung anh RAW thuc thu ma lai xuat ra anh da bi xu ly/nen. Nguoi dung yeu cau: bo chuc nang tu giai raw, nguoi dung chup RAW thi phai ra dung file RAW goc.

4. Loi anh chup ra bi nguoc:
   - Anh chup ra bi nguoc chieu (lon nguoc dau hoac xoay sai huong) khong dung voi thuc te khi chup.

5. Loi thuat toan chup sieu net 48MP:
   - Chuc nang chup anh sieu net 48MP hien tai rat lo, chua dat duoc do sac net 48MP thuc su va anh khong on dinh. Yeu cau lam lai thuat toan de anh chup 48MP sieu net, chi tiet tach bach va khong bi loi.

--------------------------------------------------------------------------------

## 4. NHIEM VU CUA BAN (AI)

Ban co toan quyen doc toan bo source code va duoc phep sua full toan bo he thong. Nhiem vu cu the:

1. Tu doc va phan tich toan bo source code trong tep AI_Camera_Full_Source_Code.txt:
   - Hieu toan bo luong van hanh tu camera, bo loc tracking, can tam, auto-zoom, auto-capture, den pipeline chup anh sieu net Metal, xu ly mau va luu thu vien anh.

2. Tu suy nghi va tu thiet ke giai phap khac phuc triet de toan bo cac loi tren:
   - Tu phan tich tim ra tat ca cac nguyen nhan khien viec dua tam trang vao target khong tu dong chup, tu thiet ke lai de khi dua tam vao la may tu dong chup nhanh chong, muot ma, tin cay, khong bi liet, dap ung tot voi chuyen dong rung tay sinh hoc cua nguoi dung.
   - Tu thiet ke lai thuat toan chup anh sieu net 48MP: mau sac phai dep, tuoi sang, trong treo, do tuong phan chuan, chi tiet 48MP sac net, tuyet doi anh khong bi nguoc chieu hay lon dau.
   - Khi chup RAW: xuat dung file RAW goc DNG vao PhotoKit theo dung yeu cau nguoi dung.

3. Tu chu dong ra soat toan bo ma nguon va sua tat ca nhung chuc nang ma ban thay chua duoc hoan thien:
   - Bat ky logic, ham, luong xu ly nao trong toan bo du an ma ban doc thay con so sai, chua hoan thien, chua toi uu, de sinh loi hoac gay trai nghiem kem thi ban duoc phep va duoc yeu cau sua lai toan dien de ung dung dat chat luong tot nhat.

--------------------------------------------------------------------------------

## 5. QUY TAC DAU RA BAT BUOC

- Cung cap MA NGUON HOAN CHINH (FULL CODE) cho moi tep tin ma ban sua doi.
- Tuyet doi KHONG cat ngon ma nguon bang cac dong chu thich nhu // ... giu nguyen ... hoac // ... rest of code unchanged ...
- Ma nguon phai day du tu dau den cuoi de nguoi dung chi viec copy ghi de vao du an la build va chay ngay.
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

assert not contains_emoji(prompt), "Prompt contains emoji!"

dl = Path(r"C:\Users\admin\Downloads")
p1 = dl / "PROMPT_CHO_AI_FIX_TOAN_DIEN.md"
p1.write_text(prompt, encoding="utf-8")

pkg_dir = dl / "AI_Camera_Full_Code_Package"
p2 = pkg_dir / "PROMPT_CHO_AI_FIX_TOAN_DIEN.md"
p2.write_text(prompt, encoding="utf-8")

# Re-zip package
zip_path = dl / "AI_Camera_Full_Code_Package.zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
    for file in pkg_dir.rglob("*"):
        if file.is_file():
            arcname = file.relative_to(pkg_dir)
            zipf.write(file, arcname)

print(f"Updated prompt: {p1} ({p1.stat().st_size} bytes, emojis: 0)")
print(f"Updated zip: {zip_path} ({zip_path.stat().st_size} bytes)")
