# Ke hoach va trang thai nang cap AI anh - AlignAI Studio

## Nguyen nhan loi han muc

OpenRouter mien phi chi cho cac model mien phi (`:free`), khong cap luot mien phi cho Gemini 3.7 Flash hoac Gemini 3.1 Pro qua OpenRouter. Doi sang ngay khong giai quyet duoc loi thieu credits (`HTTP 402`) khi app goi model tra phi. Chinh sach hien tai neu 50 yeu cau/ngay cho tai khoan Free voi cac model mien phi; gioi han co the thay doi theo OpenRouter.

## Phuong an hien tai

1. AI tren may la mac dinh, khong yeu cau mang hoac OpenRouter API Key. Ban cu bat cloud mac dinh se duoc chuyen sang tat cloud mot lan khi cap nhat.
2. Neu nguoi dung tu bat OpenRouter, model mac dinh cho cai moi la `google/gemma-4-31b-it:free`, nhan dau vao anh. Chi chuyen tiep sang model `:free` khac hoac `openrouter/free`, khong tu goi model tra phi.
3. Gemini 3.7 Flash va Gemini 3.1 Pro van co trong danh sach cho nguoi tu chon khi co credits; ten model duoc gan nhan tra phi.
4. Loi `HTTP 402` dung thu cac model tra phi va tat cloud, chuyen ve AI cuc bo. Han muc mien phi `HTTP 429` chuyen AI cuc bo ma khong thu them nhieu model trong phien do.
5. Phan tich mau anh da chup va AI dao dien video deu tuan theo cong tac cloud. Nut kiem tra ket noi ghi ro co dung mot luot API.
6. Prompt cloud van phan tich toan khung hinh, anh 1600 px; toa do/zoom duoc kiem tra truoc khi ap dung. Loi giai thich bo cuc duoc hien trong khung ngam.

## Kiem tra

- `scripts/check_swift_brackets.py`: dat.
- `scripts/check_responsive_layout.py`: dat.
- Co kiem thu hoi quy cho chuoi model mien phi khong chuyen sang tra phi va tinh hop le cua ket qua cloud; can chay XCTest tren macOS.
- Sau build, thu AI khi khong co mang/key, model Gemma mien phi, va tai khoan tra ve 402/429.

## Nguon

- Chinh sach Free: https://openrouter.ai/pricing/
- Gemma 4 31B mien phi, nhan anh: https://openrouter.ai/google/gemma-4-31b-it:free
- Gemini 3.7 Flash tra phi: https://openrouter.ai/google/gemini-3.7-flash
