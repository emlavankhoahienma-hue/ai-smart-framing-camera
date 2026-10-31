# HƯỚNG DẪN THIẾT LẬP VÀ CHẠY ĐÁNH GIÁ PIPELINE TRÊN CI (TỪNG BƯỚC)

Tài liệu này hướng dẫn chi tiết từng bước bấm chuột và dòng lệnh trên Windows để bạn có thể tự mình chạy bộ đánh giá offline cho pipeline AI Target & Zoom mà không sợ vi phạm bản quyền ảnh Flickr và không tốn phí CI.

---

## 📌 Tổng quan quy trình
```
[Máy tính của bạn (Windows)]
1. Giải nén GAICD -> Chạy prepare_gaicd.py -> Sinh eval_set.json + nén eval_input/ thành eval_images.zip
2. Tạo repo GitHub PRIVATE tên "eval-data" -> Tạo Release và đính kèm eval_images.zip
3. Tạo Personal Access Token (chỉ-đọc) -> Thêm vào Secret "EVAL_DATA_TOKEN" của repo chính

[GitHub Actions (macOS 15 Runner - Miễn phí)]
4. Chạy workflow "Offline GAICD Evaluation Runner" (thử 5 ảnh rồi chạy 150 ảnh)
5. Workflow tự động tải zip, chạy pipeline Swift thật, xuất duy nhất eval_results.json

[Máy tính của bạn (Windows)]
6. Tải eval_results.json về -> Chạy score_results.py -> Xem report.md so sánh với 3 baseline!
```

---

## BƯỚC 1: Chuẩn bị 150 ảnh trên máy tính Windows
1. Tải bộ dữ liệu GAICD (từ link ở README của [HuiZeng/Grid-Anchor-based-Image-Cropping](https://github.com/HuiZeng/Grid-Anchor-based-Image-Cropping)) và giải nén toàn bộ vào thư mục:
   `data\GAICD\` (đường dẫn đầy đủ: `repo_smart_camera\data\GAICD`).
2. Mở cửa sổ **PowerShell** tại thư mục repo và chạy lệnh:
   ```powershell
   cd C:\Users\admin\Downloads\taovideo\repo_smart_camera
   .\.venv\Scripts\python.exe tools/eval/prepare_gaicd.py
   ```
   **Kiểm tra kết quả Bước 1:**
   - Mở file `docs\eval\GAICD_FORMAT.md` để xem cấu trúc và thứ tự cột tọa độ script vừa khám phá.
   - Mở thư mục `debug\` và xem các ảnh `gaicd_check_*.jpg`: các khung màu **xanh lá** là 3 crop điểm MOS cao nhất, các khung màu **đỏ** là 3 crop điểm MOS thấp nhất.
   - Kiểm tra xem file `eval_set.json` đã được tạo và thư mục `eval_input\` có 150 ảnh `.jpg`.
3. Nén thư mục `eval_input\` thành file `eval_images.zip` bằng lệnh PowerShell:
   ```powershell
   Compress-Archive -Path eval_input\* -DestinationPath eval_images.zip -Force
   ```
   **Kiểm tra:** File `eval_images.zip` xuất hiện ở thư mục gốc của repo (dung lượng khoảng vài chục MB).

---

## BƯỚC 2: Tạo Repo Private `eval-data` và Upload Release
1. Đăng nhập vào GitHub trên trình duyệt.
2. Bấm vào biểu tượng dấu **`+`** ở góc trên cùng bên phải màn hình ➔ chọn **New repository**.
3. Điền các thông tin:
   - **Repository name**: `eval-data`
   - Chọn chế độ: **`Private`** (bắt buộc chọn Private để ảnh không bị công khai ra ngoài).
   - Tích chọn: **Add a README file**.
   - Bấm nút **Create repository**.
4. Tạo Release và tải file zip lên:
   - Tại trang repo `eval-data` vừa tạo, nhìn sang cột bên phải mục **Releases** ➔ bấm **Create a new release** (hoặc truy cập đường dẫn: `https://github.com/<tên_tài_khoản>/eval-data/releases/new`).
   - Mục **Choose a tag**: gõ `v1.0` ➔ bấm **Create new tag: v1.0**.
   - Mục **Release title**: gõ `GAICD Eval Images`.
   - Mục **Attach binaries by dropping them here or selecting them**: kéo thả file `eval_images.zip` từ máy tính vào ô này.
   - Chờ file zip tải lên xong (hiện vạch xanh 100%) ➔ bấm nút xanh **Publish release**.

**Kiểm tra kết quả Bước 2:** Bạn nhìn thấy release `v1.0` có đính kèm file `eval_images.zip`.

---

## BƯỚC 3: Tạo Token Truy Cập và Lưu vào Secret của Repo Chính
Vì repo `eval-data` là Private, ta cần một Token để workflow của repo chính có quyền tải file zip về máy ảo.

### 3.1. Tạo GitHub Personal Access Token (Fine-grained)
1. Bấm vào ảnh đại diện cá nhân ở góc trên cùng bên phải GitHub ➔ chọn **Settings**.
2. Cuộn xuống cuối cùng ở menu bên trái ➔ bấm **Developer settings**.
3. Chọn mục **Personal access tokens** ➔ chọn **Fine-grained tokens** ➔ bấm nút **Generate new token**.
4. Điền các thông số:
   - **Token name**: `EVAL_DATA_TOKEN`
   - **Expiration**: chọn `90 days` (hoặc tùy chọn của bạn).
   - **Resource owner**: chọn tài khoản của bạn.
   - **Repository access**: tích vào mục **Only select repositories** ➔ trong ô tìm kiếm chọn repo **`eval-data`**.
   - **Permissions** (Quyền hạn):
     - Mở mục **Repository permissions**.
     - Tìm dòng **Contents** ➔ chọn quyền **Read-only** (chỉ đọc).
   - Cuộn xuống dưới cùng và bấm nút xanh **Generate token**.
5. **Sao chép token**: Bấm biểu tượng Copy để lưu chuỗi token (dạng `github_pat_...`). *Lưu ý: token này chỉ hiển thị 1 lần duy nhất.*

### 3.2. Lưu Token vào Secret của Repo `ai-smart-framing-camera`
1. Quay lại trang GitHub của repo chính: `https://github.com/emlavankhoahienma-hue/ai-smart-framing-camera`.
2. Bấm vào tab **Settings** (ở thanh menu trên cùng của repo).
3. Ở menu bên trái, tìm mục **Secrets and variables** ➔ bấm chọn **Actions**.
4. Bấm nút xanh **New repository secret**.
5. Điền thông tin:
   - **Name**: `EVAL_DATA_TOKEN` (bắt buộc đúng từng chữ hoa/thường).
   - **Secret**: Dán chuỗi token vừa copy ở bước 3.1 vào đây.
   - Bấm **Add secret**.

**Kiểm tra kết quả Bước 3:** Bạn nhìn thấy secret `EVAL_DATA_TOKEN` xuất hiện trong danh sách Repository secrets.

---

## BƯỚC 4: Chạy Evaluation trên GitHub Actions
1. Vào tab **Actions** trên repo `ai-smart-framing-camera`.
2. Ở cột menu bên trái, bấm vào workflow: **Offline GAICD Evaluation Runner**.
3. Bấm vào nút xổ xuống **Run workflow** ở góc phải:
   - **Branch**: chọn nhánh `eval-harness` (hoặc `main` nếu đã merge).
   - **Số ảnh tối đa để đánh giá**:
     - Lần 1: Giữ nguyên số `5` để chạy thử nghiệm nhanh (chỉ mất khoảng 3 - 5 phút).
     - Lần 2 (khi lần 1 thành công): Đặt số `150` để chạy toàn bộ tập đánh giá.
   - Bấm nút xanh **Run workflow**.
4. Chờ job chạy xong (hiện dấu tích xanh `✔`):
   - Bấm vào tên lần chạy vừa hoàn thành.
   - Cuộn xuống mục **Artifacts** ở cuối trang.
   - Bấm vào **`eval-results-<run_number>`** để tải file `.zip` chứa `eval_results.json` về máy tính.

**Kiểm tra kết quả Bước 4:** Giải nén file vừa tải về, bạn có file `eval_results.json` chứa kết quả đánh giá thực tế của pipeline Swift.

---

## BƯỚC 5: Chấm điểm và Xuất Báo cáo trên Windows
1. Đặt file `eval_results.json` vừa tải về vào thư mục gốc của repo:
   `repo_smart_camera\eval_results.json`
2. Mở cửa sổ **PowerShell** và chạy lệnh:
   ```powershell
   cd C:\Users\admin\Downloads\taovideo\repo_smart_camera
   .\.venv\Scripts\python.exe tools/eval/score_results.py --results eval_results.json --eval-set eval_set.json
   ```
3. Xem kết quả chi tiết:
   - Script sẽ in tóm tắt trực tiếp ra màn hình.
   - Thư mục báo cáo được tạo tự động tại: `eval_runs\<thời_gian>_<git_hash>\`
     - Mở file **`report.md`** để đọc báo cáo markdown: so sánh điểm của AI với 3 baseline (`full_frame`, `center_crop`, `random_crop`), tỉ lệ thắng crop giữa theo `best_iou` và `best_iou_top10`, số ảnh xoay `is_rotated`.
     - File **`report.csv`** chứa toàn bộ số liệu thống kê trung vị, mean, p25, p75.
4. Trực quan hóa hình ảnh (tùy chọn):
   ```powershell
   .\.venv\Scripts\python.exe tools/eval/visualize.py --results eval_results.json --eval-set eval_set.json --images eval_input --out debug/vis
   ```
   Mở thư mục `debug\vis` để xem ảnh vẽ khung:
   - 🔴 **Khung đỏ**: Vùng crop do AI đề xuất.
   - 🟢 **Khung xanh lá**: Vùng crop có điểm MOS cao nhất từ tập dữ liệu GAICD.
   - 🟡 **Khung vàng**: Vùng nhận diện chủ thể chính (hero box).
