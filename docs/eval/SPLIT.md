# Phân chia tập dữ liệu Đánh giá: DEV (100 ảnh) & HOLDOUT (50 ảnh)

Tập đánh giá 150 ảnh GAICD được phân chia tất định thành hai tập con:
- **DEV (100 ảnh)**: Dùng để đưa ra quyết định giữ/hoàn tác (keep/revert) trong các thí nghiệm Phase B theo CỔNG KIỂM.
- **HOLDOUT (50 ảnh)**: Chỉ xem ở cuối mỗi thí nghiệm để kiểm tra tính tổng quát (chống overfitting). Không dùng để tối ưu hoặc tinh chỉnh trọng số.

**Phương pháp phân chia**:
- Ngẫu nhiên tất định với `seed = 42` (Python `random.Random(42).shuffle`).
- Dữ liệu định dạng JSON được lưu trữ tại `tools/eval/split.json`.

---

## 1. Thống kê tập DEV (100 ảnh)
Số lượng: **100 ảnh** (66.7%).
Danh sách ảnh:
`210333.jpg`, `213811.jpg`, `215679.jpg`, `216186.jpg`, `220989.jpg`, `222317.jpg`, `223398.jpg`, `223403.jpg`, `224213.jpg`, `226993.jpg`,
`227221.jpg`, `227299.jpg`, `227914.jpg`, `228108.jpg`, `230489.jpg`, `230861.jpg`, `230970.jpg`, `233918.jpg`, `235071.jpg`, `238842.jpg`,
`239103.jpg`, `239178.jpg`, `241851.jpg`, `244458.jpg`, `245367.jpg`, `248695.jpg`, `252650.jpg`, `256034.jpg`, `256204.jpg`, `256372.jpg`,
`256569.jpg`, `257850.jpg`, `258079.jpg`, `262319.jpg`, `262664.jpg`, `262843.jpg`, `263339.jpg`, `264035.jpg`, `265773.jpg`, `265882.jpg`,
`267156.jpg`, `269389.jpg`, `270415.jpg`, `271557.jpg`, `274095.jpg`, `275355.jpg`, `275883.jpg`, `276639.jpg`, `277150.jpg`, `277717.jpg`,
`278913.jpg`, `280145.jpg`, `282136.jpg`, `283401.jpg`, `283626.jpg`, `284849.jpg`, `286151.jpg`, `288320.jpg`, `289006.jpg`, `289569.jpg`,
`290457.jpg`, `292671.jpg`, `293144.jpg`, `293460.jpg`, `294101.jpg`, `295489.jpg`, `296238.jpg`, `296541.jpg`, `297007.jpg`, `297806.jpg`,
`300075.jpg`, `302256.jpg`, `302302.jpg`, `302787.jpg`, `304726.jpg`, `305717.jpg`, `305797.jpg`, `306149.jpg`, `307044.jpg`, `307284.jpg`,
`307771.jpg`, `308183.jpg`, `308552.jpg`, `309302.jpg`, `309683.jpg`, `310643.jpg`, `311181.jpg`, `311652.jpg`, `312781.jpg`, `314482.jpg`,
`316528.jpg`, `317820.jpg`, `318287.jpg`, `318413.jpg`, `319914.jpg`, `321156.jpg`, `322674.jpg`, `323676.jpg`, `324220.jpg`, `325007.jpg`

---

## 2. Thống kê tập HOLDOUT (50 ảnh)
Số lượng: **50 ảnh** (33.3%).
Danh sách ảnh:
`211144.jpg`, `217386.jpg`, `218744.jpg`, `219695.jpg`, `220865.jpg`, `225575.jpg`, `227289.jpg`, `230678.jpg`, `230983.jpg`, `231086.jpg`,
`232491.jpg`, `234384.jpg`, `236402.jpg`, `246738.jpg`, `248554.jpg`, `250325.jpg`, `250917.jpg`, `251677.jpg`, `253258.jpg`, `256860.jpg`,
`262070.jpg`, `262312.jpg`, `263595.jpg`, `265742.jpg`, `267803.jpg`, `271630.jpg`, `271650.jpg`, `272363.jpg`, `273030.jpg`, `273187.jpg`,
`274619.jpg`, `275591.jpg`, `279313.jpg`, `281898.jpg`, `282159.jpg`, `283526.jpg`, `288674.jpg`, `290886.jpg`, `295493.jpg`, `296245.jpg`,
`296495.jpg`, `297127.jpg`, `297497.jpg`, `300188.jpg`, `300760.jpg`, `302305.jpg`, `304245.jpg`, `308947.jpg`, `311319.jpg`, `329827.jpg`

---

## 3. Quy tắc CỔNG KIỂM (Gate Rules)
- **Cổng DEV**:
  - Giữ (keep) nếu `mos_soft_percentile` (simple) tăng $\ge 1.0$ điểm HOẶC `best_iou_top10` (simple) tăng $\ge 0.01$.
  - Không có chỉ số nào giảm quá $0.5$ điểm MOS %ile hoặc $0.005$ IoU.
  - Tỉ lệ thắng vs `center_same_zoom` (trên các ảnh có dịch chuyển) không giảm quá 2 điểm phần trăm.
  - Số lượng lỗi `ok=false` không tăng.
- **Cổng HOLDOUT**:
  - Không giảm quá $0.5$ điểm so với trước thí nghiệm. Nếu giảm $> 0.5$ điểm, coi là học thuộc (overfitting) và thực hiện hoàn tác (`git revert`).
