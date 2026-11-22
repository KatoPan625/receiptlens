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
- [ ] Đăng nhập Tailscale
- [ ] Chạy thử OCR 5–10 hoá đơn, điền bảng
- [ ] Test parser chạy đạt
- [ ] Tạo repo GitHub (để **private** cho tới tuần 7)
