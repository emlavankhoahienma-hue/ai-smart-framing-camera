# GAICD_FORMAT (auto-discovered by tools/eval/prepare_gaicd.py)

Root: `C:\Users\admin\Downloads\GAIC\GAIC`

## Cây thư mục / đuôi file

| đuôi | số file |
|---|---|
| `.jpg` | 1236 |
| `.txt` | 1236 |

Thư mục cấp 1: `annotations`, `images`

Số ảnh theo split (suy từ tên thư mục): test=200, train=1036

Ảnh ghép được với annotation `.txt` cùng tên: 1236 / 1236 ảnh.

Ví dụ `annotations\210333.txt` (5 dòng đầu, nguyên văn):

```
  28   43  480  811 2.14 
  28   43  480  896 3.43 
  28   43  480  981 4.14 
  28   43  537  725 1.00 
  28   43  537  811 2.14 
```

Số cột mỗi dòng: 5 cột × 111240 dòng

Giá trị tọa độ lớn nhất ở 4 cột đầu = 981 → hệ tọa độ: **pixel**.

Cột MOS dùng: chỉ số 4 (0-based) (mặc định = cột cuối).

## Thử các thứ tự cột tọa độ (tỉ lệ dòng hợp lệ trong biên ảnh thật)

| order | ý nghĩa 4 cột đầu | ảnh hợp lệ toàn bộ |
|---|---|---|
| `xyxy` | x1 y1 x2 y2 | 24/1236 |
| `yxyx` | y1 x1 y2 x2 | 1236/1236 ✔ |
| `xywh` | x y w h | 0/1236 |
| `yxhw` | y x h w | 0/1236 |

Thứ tự cột dùng: **`yxyx`** (y1 x1 y2 x2) (duy nhất hợp lệ với mọi ảnh).

### Thống kê điểm MOS và xử lý giá trị placeholder -2.0

- Tổng số dòng annotation: 111240 dòng trên 1236 ảnh.
- Số crop mang điểm MOS = -2.0 (placeholder/invalid): **4387 crop (3.94%)** trên 942 ảnh.
- **Ý nghĩa của -2.0 theo mã nguồn GAICD gốc**: Theo mã nguồn PyTorch chính thức của tác giả Hui Zeng (`HuiZeng/Grid-Anchor-based-Image-Cropping-Pytorch/croppingDataset.py:78`), dòng annotation có `float(annotation_split[4]) == -2` đại diện cho các anchor dạng lưới không hợp lệ (tỷ lệ khung hình quá lệch hoặc bị loại trong quá trình tạo grid-anchor). Tác giả chính thức loại bỏ chúng bằng lệnh `if float(annotation_split[4]) != -2:`.
- **Xử lý**: Đã loại bỏ hoàn toàn 4387 crop mang điểm -2.0. Số crop hợp lệ còn lại: **106853 crop**.
- Thống kê trên các crop hợp lệ: min=1.0000, max=5.0000, mean=2.9435 (chuẩn thang đo 1.0 đến 5.0).
- Số crop hợp lệ mỗi ảnh: min=54, max=90, mean=86.5.

EXIF Orientation của ảnh: None: 1236. Ảnh có Orientation khác 1/None bị loại khỏi eval set (toạ độ annotation theo lưới pixel lưu trữ, tránh nhập nhằng sau khi xoay EXIF).

Đã vẽ 3 crop MOS cao nhất (xanh lá) và 3 thấp nhất (đỏ) cho 4 ảnh vào `debug/gaicd_check_*.jpg`. **Hãy mở xem để xác nhận** thứ tự cột và hệ tọa độ trước khi tin eval_set.json.

## Chọn tập eval

seed=42; nguồn: test (test: 200 dùng được, val: 0). GAICD không có nhãn loại cảnh nên KHÔNG cân bằng theo cảnh; chỉ lấy ngẫu nhiên cố định. Đã chọn 150 ảnh.

Đã ghi `eval_set.json` (150 ảnh) và copy ảnh vào `eval_input/` (đã nằm trong .gitignore; không commit ảnh Flickr).

