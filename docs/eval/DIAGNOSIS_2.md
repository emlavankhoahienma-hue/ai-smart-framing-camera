# Báo cáo Chẩn đoán Giai đoạn 2: Phân tích Ứng viên & Mô hình Lựa chọn (Phase A)

Tài liệu này phân tích chi tiết toàn bộ **4,996 ứng viên bố cục** được sinh ra và chấm điểm trên 150 ảnh GAICD (chia 100 DEV / 50 HOLDOUT theo `seed=42`).

---

## 1. Kết quả Phân tích Toàn diện Ứng viên (Phase A2)

### 1.1. So sánh Hiệu năng: Selected vs Oracle vs Median vs Full Frame vs Center Same Zoom
Mỗi ứng viên được tính điểm `mos_soft` (trung bình trọng số các crop ground-truth có IoU $\ge 0.50$ với trọng số $\text{IoU}^4$) và `mos_soft_percentile` trên phân phối MOS của từng ảnh. Toàn bộ tính trên biểu diễn `crop_simple`.

| Tập dữ liệu | Chỉ số | **AI Selected** (Được chọn) | **Median Candidate** (Trung vị) | **Full Frame** (Khung gốc) | **Center Same Zoom** | **ORACLE** (Ứng viên tốt nhất) |
|---|---|:---:|:---:|:---:|:---:|:---:|
| **DEV (100 ảnh)** | `mos_soft` | 3.1058 | 3.0862 | 3.0770 | 3.0767 | **3.2852** |
| | `mos_soft_percentile` | **57.14%** | 57.23% | 56.92% | 55.88% | **66.31% (+9.17%)** |
| | `best_iou_top10` | 0.6986 | 0.7815 | 0.7666 | 0.7090 | **0.7436** |
| **HOLDOUT (50 ảnh)** | `mos_soft` | 3.0210 | 3.0261 | 3.0373 | 2.9825 | **3.2192** |
| | `mos_soft_percentile` | **59.99%** | 60.02% | 59.17% | 58.86% | **66.27% (+6.28%)** |
| | `best_iou_top10` | 0.6976 | 0.7785 | 0.7800 | 0.7146 | **0.7718** |
| **ALL (150 ảnh)** | `mos_soft` | 3.0777 | 3.0662 | 3.0638 | 3.0453 | **3.2632** |
| | `mos_soft_percentile` | **58.08%** | 58.16% | 57.67% | 56.87% | **66.30% (+8.22%)** |
| | `best_iou_top10` | 0.6983 | 0.7805 | 0.7710 | 0.7108 | **0.7530** |

---

### 1.2. Tương quan Spearman theo ảnh giữa `mos_soft` và các điểm thành phần (A2.ii)
Độ tương quan thứ hạng Spearman trung bình trên từng ảnh giữa điểm thẩm mỹ con người (`mos_soft`) và các điểm số của hệ thống:

| Điểm thành phần | Hệ số tương quan $\rho$ (DEV) | Hệ số tương quan $\rho$ (HOLDOUT) | Hệ số tương quan $\rho$ (ALL) | Đánh giá |
|---|:---:|:---:|:---:|---|
| **`scores.samp`** (SAMP-Net) | **+0.0584** | **+0.1350** | **+0.0839** | Rất yếu nhưng dương |
| **`scores.charm`** (Charm-PARA) | **+0.0553** | **+0.1146** | **+0.0743** | Rất yếu nhưng dương |
| **`scores.geom`** (Hình học / Heuristic) | **+0.0416** | **+0.0065** | **+0.0299** | Gần như bằng 0 |
| **`scores.final`** (Điểm quyết định chọn) | **+0.0632** | **+0.0581** | **+0.0615** | Gần như không tương quan ($\rho \approx 0.06$) |

---

### 1.3. Khảo sát Ứng viên "Giữ nguyên khung" (Identity Candidate) & Khả năng của Oracle (A2.iii)
- **Ứng viên Giữ nguyên khung (`is_unchanged = true`)**:
  - Có mặt trong **150 / 150 ảnh (100.0%)**.
  - Là lựa chọn tốt nhất (Oracle == Identity) ở **40 / 150 ảnh (26.7%)** (DEV: 24/100, HOLDOUT: 16/50).
- **Oracle vượt trội hơn Full Frame**:
  - Có tới **88 / 150 ảnh (58.7%)** (DEV: 62/100, HOLDOUT: 26/50) mà ứng viên Oracle có điểm `mos_soft` cao hơn Full Frame ít nhất $+0.05$ điểm MOS.
  - Có **84 / 150 ảnh (56.0%)** có Oracle percentile cao hơn Full Frame ít nhất $+2.0$ điểm phần trăm.

---

### 1.4. Tỉ lệ thắng trên các ảnh có thay đổi khung (Active Framing Win Rate)
Xét riêng các ảnh mà AI thật sự thay đổi khung ngắm (`zoom_final > 1.05` hoặc tâm lệch $> 0.01$):
- **DEV ($n=91$ ảnh đổi khung)**:
  - Thắng trên `mos_soft`: 19 / 91 (**20.9%**)
  - Thắng trên `best_iou_top10`: 15 / 91 (**16.5%**)
- **HOLDOUT ($n=48$ ảnh đổi khung)**:
  - Thắng trên `mos_soft`: 11 / 48 (**22.9%**)
  - Thắng trên `best_iou_top10`: 7 / 48 (**14.6%**)

---

## 2. Kết luận Cốt lõi: Lỗi ở SINH hay ở CHỌN? (A2.iv)

**KẾT LUẬN: VẤN ĐỀ NẰM HOÀN TOÀN Ở KHÂU CHỌN (SELECTION), KHÔNG PHẢI Ở KHÂU SINH ỨNG VIÊN (GENERATION).**

1. **Sinh ứng viên rất tốt (High Oracle Ceiling)**:
   - Trong mỗi ảnh, bộ sinh ứng viên tạo ra trung bình 33.3 ứng viên, trong đó luôn chứa ứng viên Oracle đạt `mos_soft_percentile` trung bình tới **66.31%** (vượt trội hơn Full Frame 56.92% và AI Selected 57.14%).
   - Ở hơn **58.7% số ảnh**, trong pool thực sự có crop đẹp hơn ảnh gốc ban đầu.
2. **Khâu chọn gần như tương đương CHỌN NGẪU NHIÊN**:
   - Điểm `scores.final` có tương quan Spearman với đánh giá con người chỉ là **$\rho = +0.06$** (gần bằng 0).
   - Điểm trung bình của AI Selected (**57.14%**) gần như trùng khít với Median Candidate (**57.23%**). Hệ thống chọn trúng ứng viên mức trung vị thay vì chọn ứng viên top đầu.
3. **Thiếu cơ chế bảo thủ (Conservative Margin)**:
   - Khi điểm của một crop chỉ nhỉnh hơn Full Frame $0.01$ (vốn là nhiễu do tương quan thấp), AI lập tức rời bỏ Full Frame để chuyển sang crop mạo hiểm, dẫn đến tỉ lệ thua center crop lên tới 79%.
4. **Khả năng cải thiện (Headroom)**:
   - Vì Oracle đạt 66.31% (cao hơn hiện tại ~9 điểm phần vị), **hệ thống có dư địa cải thiện rất lớn** nếu điều chỉnh cơ chế chọn và lọc bớt các yếu tố heuristic phản tác dụng. Không dừng lại ở đây.
