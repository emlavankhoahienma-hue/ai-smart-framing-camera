# TÀI LIỆU BẮT BUỘC: TỔNG HỢP VÀ ÁP DỤNG CHO ULTRA SHARP BẬC 1

## 1. HDR+ (Hasinoff et al. 2016) - "Burst photography for high dynamic range and low-light imaging on mobile cameras"
- Chụp chùm frame cùng phơi sáng (constant-exposure burst), tuyệt đối không phơi sáng xen kẽ (bracketing) để tránh biến thiên ánh sáng làm vỡ thuật toán căn chỉnh.
- Mức phơi sáng chọn vừa đủ thấp (underexposure có chủ đích) nhằm bảo toàn 100% chi tiết vùng cháy sáng (highlight protection).
- Căn chỉnh dựa trên tile để ước lượng chuyển động cục bộ và toàn cục của tay cầm máy.
- Gộp đa khung hình theo nguyên lý Wiener-style shrinkage: phân rã không gian tần số/vùng cục bộ, làm co các khác biệt ngẫu nhiên (nhiễu) về 0.
- Nguyên tắc chống bóng ma (Anti-ghosting): Chỉ gộp khi nội dung giữa frame phụ và frame tham chiếu tương đồng trong phạm vi thống kê của nhiễu.
- Tỷ lệ tín hiệu trên nhiễu (SNR) tăng xấp xỉ căn bậc hai của N (căn(N)) đối với N frame tĩnh được căn chỉnh chính xác.
- Khi một vùng có sự dịch chuyển không khớp, trọng số gộp của frame phụ tại vùng đó tự động rơi về 0, chỉ giữ lại frame tham chiếu.
- Tự động ước lượng mô hình phương sai nhiễu cảm biến theo mức sáng thay vì dùng hằng số cứng.
- Áp dụng cho Bậc 1: Chụp N frame phơi sáng cố định, khóa AE/AF/AWB; gộp trọng số thích ứng theo tỷ số chênh lệch trên độ lệch chuẩn nhiễu (d/sigma); rơi về frame gốc nếu có chuyển động lớn.

## 2. Handheld Multi-Frame Super-Resolution (Wronski et al. 2019) - "Handheld Multi-Frame Super-Resolution"
- Tận dụng chuyển động rung tay tự nhiên (hand tremor) để thu thập các mẫu dịch chuyển sub-pixel ngẫu nhiên giữa các frame.
- Căn chỉnh từ thô đến mịn (coarse-to-fine hierarchical tile matching) trên kim tự tháp hình ảnh (Gaussian pyramid) để bắt trọn dịch chuyển lớn ở tầng thô và dịch chuyển vi mô ở tầng mịn.
- Tinh chỉnh sub-pixel ở cấp độ từng tile để đạt độ chính xác căn chỉnh cao hơn lưới pixel nguyên.
- Mô hình độ tin cậy/mạnh mẽ thống kê (Statistical Robustness Model): Đánh giá từng tile/pixel xem sự sai khác bắt nguồn từ chi tiết tần số cao thật hay do chuyển động cục bộ/sai lệch căn chỉnh.
- Mặt nạ tin cậy (Robustness Mask, giá trị 0..1): Giảm trọng số mềm (soft rejection) mượt mà thay vì cắt ngưỡng cứng, tránh tạo ra viền răng cưa hoặc ranh giới khối (block boundary artifacts).
- Nội suy luồng dịch chuyển mượt mà (smooth motion field interpolation) giữa các tâm tile giúp biến dạng (warp) liên tục, không đứt gãy.
- Khử nhiễu và bảo toàn cấu trúc: Phân biệt rõ giữa nhiễu hạt sensor (cần gộp để triệt tiêu) và chi tiết thật/cạnh sắc nét (cần giữ nguyên biên độ).
- Khi toàn bộ frame có tỷ lệ sai số cao (ví dụ tay giật quá mạnh hoặc bị che khuất đột ngột), loại bỏ hoàn toàn frame đó khỏi chuỗi gộp.
- Áp dụng cho Bậc 1: Kim tự tháp Gaussian 4 tầng trên Luma, block matching 16x16 tile +-4px, tinh chỉnh sub-pixel Lucas-Kanade, lọc tile lỗi > 50%, trọng số Wiener/Gaussian theo MAD noise và rơi về frame gốc tại vật chuyển động.
