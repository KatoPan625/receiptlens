# Tuần 0 — Chuẩn bị (bản tự host, 0đ)

Mục tiêu tuần 0: đủ công cụ, và **biết PaddleOCR đọc hoá đơn thật tốt đến đâu** trước khi xây bất cứ gì. Không cần thẻ hay tài khoản cloud.

---

## 1. Công cụ

| Công cụ | Dùng ở | Trạng thái trên máy Pan (22/11/2026) |
|---|---|---|
| Python 3.13, Git | mọi tuần | ✅ có |
| Docker Desktop | tuần 1+ | ✅ có |
| WSL Ubuntu | Ansible (tuần 7) | ✅ có |
| k6, nmap | tuần 1, 3 | ✅ đã cài |
| mkcert | tuần 1 (TLS local) | ✅ đã cài (1.4.4) |
| Tailscale | tuần 1 (truy cập quản trị), tuần 6 (điện thoại) | ✅ đã cài (1.104.7), cần đăng nhập |
| Trivy | tuần 5 | ✅ đã cài (0.76.2) |
| Flutter SDK | tuần 6 | cần cài, theo hướng dẫn chính thức tại flutter.dev |

Cài các công cụ còn thiếu (PowerShell):

```powershell
winget install --id FiloSottile.mkcert -e
```

```powershell
winget install --id Tailscale.Tailscale -e
```

```powershell
winget install --id AquaSecurity.Trivy -e
```

Tailscale: đăng nhập bằng tài khoản của bạn trong ứng dụng Tailscale (bạn tự làm).

> gcloud và Terraform đã cài từ hướng cũ (GCP) không còn cần cho dự án này. Có thể giữ lại để học tiếp, hoặc gỡ: `winget uninstall --id Google.CloudSDK -e` và `winget uninstall --id Hashicorp.Terraform -e`.

---

## 2. Thử OCR với hoá đơn thật (quan trọng nhất tuần 0)

1. Chụp 5–10 hoá đơn khác loại (siêu thị, quán cà phê, cửa hàng tiện lợi, hoá đơn in nhiệt mờ) và bỏ vào `samples/`.
2. Tạo môi trường Python và cài thư viện. Lần đầu tải khoảng vài trăm MB (PaddlePaddle + mô hình OCR):

```powershell
python -m venv .venv; .\.venv\Scripts\python -m pip install -r ocr_worker\requirements-spike.txt
```

3. Chạy:

```powershell
.\.venv\Scripts\python ocr_worker\spike_ocr.py samples
```

Kết quả (văn bản OCR + đoán tổng tiền) nằm ở `spike_output/` (đã git-ignore). Ghi lại vào bảng:

| Ảnh | Loại hoá đơn | Tổng tiền thật | Script đoán | Đúng? | Ghi chú (mờ, nghiêng, mất dấu…) |
|---|---|---|---|---|---|
| | | | | | |

**Quyết định cuối tuần 0:** tổng tiền đúng ≥ 6/10 → giữ kế hoạch. Thấp hơn → ghi lý do; tuần 4 sẽ thử bật xoay/làm phẳng ảnh của PaddleOCR, chỉnh parser, hoặc chấp nhận sửa tay nhiều hơn.

---

## 3. Chạy test parser

```powershell
.\.venv\Scripts\python -m pytest -q tests
```

---

## Checklist tuần 0

- [x] Cài mkcert, Tailscale, Trivy (Flutter để tuần 6)
- [x] Cài thư viện PaddleOCR vào `.venv` (paddleocr 3.7.0, paddlepaddle 3.3.1)
- [ ] Đăng nhập Tailscale
- [ ] Chạy thử OCR 5–10 hoá đơn, điền bảng
- [x] Test parser chạy đạt
- [ ] Tạo repo GitHub (để **private** cho tới tuần 7)

---

# Tuần 1 — Mạng và tầng dữ liệu

Dựng 3 mạng (`edge`, `app`, `data`), Postgres, RabbitMQ, SeaweedFS (S3) và Nginx TLS. Chỉ cổng 443 được publish.

1. Sinh `.env` (mật khẩu ngẫu nhiên, không in ra) và chứng chỉ TLS cho máy. Chạy lại không ghi đè thứ đã có:

```powershell
powershell -NoProfile -File scripts\init-env.ps1
```

2. Chạy stack:

```powershell
docker compose up -d
```

3. Kiểm tra bằng chứng (12 mục; kết quả mẫu ở `docs/evidence/week1-verify.txt`):

```powershell
powershell -NoProfile -File scripts\verify-week1.ps1
```

4. Tắt khi không dùng (dữ liệu giữ trong volume):

```powershell
docker compose down
```

> Muốn trình duyệt tin chứng chỉ `https://localhost` thì tự chạy `mkcert -install`. Lệnh này thêm CA của mkcert vào kho tin cậy của Windows, nên chỉ làm trên máy của bạn.

- [x] Stack chạy, cả 4 dịch vụ healthy
- [x] Chỉ publish 443; tầng `data` không ra được Internet; edge không chạm được Postgres
- [ ] Tailscale: truy cập máy chủ từ thiết bị khác (sau khi đăng nhập)

---

# Tuần 2 — API, upload, quyền tối thiểu

API FastAPI chạy trong mạng `app` + `data`, nhận ảnh qua `https://localhost/api/receipts`, ghi vào SeaweedFS và Postgres. Job `migrate` chạy một lần để tạo bảng, role `api_rw` và bucket.

1. Bổ sung khoá mới vào `.env` (giữ nguyên các giá trị cũ):

```powershell
powershell -NoProfile -File scripts\init-env.ps1
```

2. Build và chạy:

```powershell
docker compose up -d --build
```

3. Test đơn vị (không cần Docker, dùng SQLite + S3 giả):

```powershell
.\.venv\Scripts\python -m pip install -r api\requirements-dev.txt; Set-Location api; ..\.venv\Scripts\python -m pytest -q tests; Set-Location ..
```

4. Kiểm tra trên stack thật (14 mục; kết quả mẫu ở `docs/evidence/week2-verify.txt`):

```powershell
powershell -NoProfile -File scripts\verify-week2.ps1
```

Tài liệu API tự sinh: `https://localhost/api/docs`.

- [x] Upload, đọc lại ảnh, sửa tay, thống kê tháng
- [x] Từ chối file giả ảnh (415), file > 10 MB (413), dữ liệu sai (422)
- [x] `api_rw` không DELETE/DROP được; key S3 của API không tạo được bucket; API không ra Internet

---

# Tuần 3 — WAF, cân bằng tải, tự co giãn

Đường đi của mỗi yêu cầu: **edge** (TLS + ModSecurity/OWASP CRS + rate limit) → **lb** (HAProxy) → **api** (1–4 bản sao). Prometheus lấy số liệu trong mạng nội bộ, không publish cổng.

1. Chạy (lần đầu sẽ tải image WAF, HAProxy, Prometheus):

```powershell
docker compose up -d --build
```

2. Kiểm tra WAF, rate limit, chia tải, chịu lỗi khi một bản sao chết (12 mục, kết quả mẫu ở `docs/evidence/week3-verify.txt`):

```powershell
powershell -NoProfile -File scripts\verify-week3.ps1
```

3. Đo tải + tự co giãn. Mở **hai** terminal ở thư mục dự án.

Terminal 1, autoscaler (Ctrl+C để dừng):

```powershell
.\.venv\Scripts\python autoscaler\autoscale.py --interval 5 --cooldown 30 --log docs\evidence\week3-autoscale.csv
```

Terminal 2, k6 (khoảng 4 phút):

```powershell
k6 run --summary-export docs\evidence\week3-k6-summary.json tests\load\k6.js
```

Kết quả đã đo: `docs/evidence/week3-load.md` (9.074 yêu cầu, 0 lỗi, p95 10,72 ms, bản sao 1 → 4 → 2).

4. Test đơn vị autoscaler + parser:

```powershell
.\.venv\Scripts\python -m pytest -q tests
```

- [x] SQLi, XSS, path traversal, method DELETE bị WAF chặn (403); upload PNG thật vẫn qua
- [x] Upload dồn dập bị 429, đọc không bị ảnh hưởng
- [x] HAProxy chia đều cho các bản sao; giết một bản sao vẫn 30/30 yêu cầu thành công
- [x] Autoscaler tăng/giảm theo tải, không dao động
