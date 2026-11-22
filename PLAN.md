# ReceiptLens — Kế hoạch dự án (bản tự host, 0đ)

> Chụp hoá đơn → hệ thống tự đọc tổng tiền, ngày, cửa hàng → thống kê chi tiêu.
> **Toàn bộ chạy bằng mã nguồn mở trên máy của bạn: không thẻ, không tài khoản cloud tính tiền, không hoá đơn bất ngờ.**
> Mục tiêu: chứng minh các khái niệm của 4 skill badge Google Cloud bằng cách **tự dựng lại chúng**, cộng backend, web, mobile, DevOps.

---

## 1. Mục tiêu và tiêu chí "xong"

| # | Tiêu chí | Đo bằng |
|---|---|---|
| G1 | Upload ảnh hoá đơn (web hoặc app), sau ≤ 15 giây thấy dữ liệu đã đọc | Video demo |
| G2 | Đọc đúng **tổng tiền** ≥ 80% trên bộ 30 hoá đơn thật | `pytest` + báo cáo độ chính xác |
| G3 | API tự tăng/giảm số bản sao khi tải đổi; p95 < 300 ms ở mức tải đã chọn | k6 + biểu đồ Grafana |
| G4 | Từ ngoài chỉ thấy cổng 443; DB, hàng đợi, lưu trữ không ra Internet được | `nmap` + thử kết nối ra ngoài từ container `data` (phải thất bại) |
| G5 | Không còn lỗ hổng mức HIGH/CRITICAL đã có bản vá trong image | Trivy trong CI |
| G6 | Dựng lại toàn bộ trên một máy Linux trống bằng một lệnh | Ansible playbook |
| G7 | README có bảng "Khái niệm GCP ↔ bản tự dựng", sơ đồ, bằng chứng | Repo public |

**Ngoài phạm vi bản 1:** nhiều người dùng có đăng nhập, phân loại chi tiêu bằng ML, domain riêng.

---

## 2. Khái niệm GCP (badge) ↔ bản tự dựng

| Badge | Khái niệm trên GCP | ReceiptLens tự dựng |
|---|---|---|
| **Build a Secure Google Cloud Network** | VPC + subnet riêng, firewall mặc định chặn, VM không IP public, Cloud NAT, IAP, Cloud Armor | 3 mạng Docker: `edge` / `app` / `data`; `app` và `data` đặt `internal: true` (không ra Internet); chỉ edge publish cổng 443; quản trị từ xa qua **Tailscale** thay IAP; **Nginx + ModSecurity + OWASP CRS** và rate limit thay Cloud Armor |
| **Implementing Cloud Load Balancing for Compute Engine** | Instance template, MIG tự co giãn, health check, Application LB | **HAProxy** chia tải cho N bản sao API, health check `/healthz`, trang stats; **autoscaler** tự viết đọc số liệu Prometheus rồi `docker compose up --scale`; giai đoạn nâng cao: **k3s + HPA** |
| **Set Up an App Dev Environment** | Cloud Storage, Pub/Sub, Cloud Functions | **SeaweedFS** (API S3; MinIO đã ngừng phát hành image trên Docker Hub) phát sự kiện file mới → **RabbitMQ** → worker; dead-letter exchange khi lỗi |
| **Prepare Data for ML APIs** | Vision API, làm sạch dữ liệu | **PaddleOCR** (`lang="vi"`) chạy local → parser chuẩn hoá → dữ liệu có cấu trúc |
| 4 khoá **Computing Foundations** | IAM, mạng, compute, dữ liệu | Quyền tối thiểu cho từng service (user DB riêng, access key S3 riêng theo bucket), mạng, giám sát |

---

## 3. Kiến trúc

```
                 Internet / Cloudflare Quick Tunnel (chỉ khi demo)
                              │ 443
                 ┌────────────▼────────────┐   mạng edge
                 │ Nginx + ModSecurity CRS │   TLS, WAF, rate limit
                 └────────────┬────────────┘
                              │
                 ┌────────────▼────────────┐   mạng app (internal)
                 │ HAProxy  ──► api x1..N  │◄── autoscaler (đọc Prometheus)
                 └────────────┬────────────┘
   Web / Flutter ── POST ảnh ─┘      (5) consume receipt.parsed
                              │ (1) API kiểm tra loại/kích thước rồi ghi S3
                              ▼
                      SeaweedFS (S3) receipts-raw  mạng data (internal)
                                   │ (2) filer notification
                                   ▼
                              RabbitMQ: receipt.uploaded ──► DLX khi lỗi
                                   │ (3)
                                   ▼
                              ocr-worker (PaddleOCR + parser)
                                   │ (4)
                                   ▼
                              RabbitMQ: receipt.parsed ──► api ──► PostgreSQL

   Quản trị: Tailscale → máy chủ.   Giám sát: Prometheus · Grafana · Loki · cAdvisor
```

**Vì sao worker không ghi thẳng vào DB?** Chỉ API chạm DB → ranh giới quyền rõ ràng; worker chỉ cần quyền đọc bucket và publish hàng đợi.

**Vì sao upload đi qua API, không dùng presigned URL?** (quyết định tuần 2) Presigned URL buộc edge nối vào mạng chứa SeaweedFS; Docker không chặn theo cổng trong cùng mạng, nên edge sẽ chạm được cả cổng quản trị của SeaweedFS. Đi qua API thì tầng `data` kín hoàn toàn, và API kiểm tra file bằng magic bytes (JPEG/PNG/WebP, ≤ 10 MB) trước khi ghi. Đổi lại API phải nhận cả file; với ảnh hoá đơn ≤ 10 MB thì chấp nhận được.

---

## 4. Thành phần chi tiết

### 4.1 Mạng và bảo mật (tuần 1)
- `compose.yaml` khai báo 3 mạng; container chỉ gắn vào mạng nó cần.
- Chỉ Nginx publish cổng 443 (TLS bằng chứng chỉ **mkcert** cho local; khi demo qua Cloudflare thì Cloudflare lo TLS).
- PostgreSQL, SeaweedFS, RabbitMQ: không publish cổng nào ra máy host.
- Bí mật trong `.env` (git-ignore) + Docker secrets; mỗi service một tài khoản riêng.
- Bằng chứng: `nmap` từ máy khác trong LAN; `docker exec` vào container `data` thử `curl` ra Internet → phải thất bại.

### 4.2 Backend API (tuần 2)
- FastAPI + SQLAlchemy + Alembic, Python 3.13, Docker.
- Bảng `receipts`: `id`, `object_key`, `status` (`uploaded`/`parsed`/`failed`/`corrected`), `merchant`, `total_vnd`, `purchased_at`, `raw_text`, `confidence`, `created_at`, `updated_at`.
- Endpoint (đã làm): `POST /api/receipts` (multipart), `GET /api/receipts?month=YYYY-MM`, `GET /api/receipts/{id}`, `GET /api/receipts/{id}/image`, `PATCH /api/receipts/{id}`, `GET /api/stats/monthly`, `GET /api/healthz`. `GET /metrics` để tuần 3.
- Quyền tối thiểu (đã làm): job `migrate` dùng tài khoản chủ DB và admin S3 để tạo bảng, role `api_rw` (chỉ SELECT/INSERT/UPDATE) và bucket; API chạy bằng `api_rw` và key S3 chỉ có quyền trên `receipts-raw`.

### 4.3 Cân bằng tải, WAF, tự co giãn (tuần 3)
- Nginx: TLS, ModSecurity + OWASP CRS, `limit_req` theo IP, proxy tới HAProxy.
- HAProxy: round-robin tới các bản sao `api`, health check `/healthz`, trang stats chỉ mở trong mạng nội bộ.
- Autoscaler (Python nhỏ): mỗi 15 giây đọc RPS/CPU từ Prometheus → tăng/giảm `api` trong khoảng 1–4, có thời gian chờ chống dao động.
- Bằng chứng: k6 tăng tải dần, biểu đồ số bản sao + p95.

### 4.4 Pipeline sự kiện + OCR (tuần 4)
- SeaweedFS: bucket `receipts-raw`, không public, xoá ảnh sau 30 ngày. Sự kiện file mới: filer notification `gocdk_pub_sub` → exchange RabbitMQ (tin dạng protobuf) hoặc webhook JSON → API publish; chốt cách ở tuần này.
- `ocr-worker`: PaddleOCR (`lang="vi"`, tắt các bước xoay/làm phẳng ảnh nếu không cần) → `receipt_parser` → publish `receipt.parsed`.
- Queue có dead-letter exchange sau 5 lần lỗi; API consumer ack sau khi ghi DB, idempotent theo `object_key`.
- Bằng chứng: báo cáo độ chính xác 30 hoá đơn (tổng tiền, ngày, cửa hàng).

### 4.5 Web, giám sát, CI (tuần 5)
- Dashboard tĩnh (HTML/JS, cùng phong cách portfolio) do Nginx phục vụ: upload, danh sách, sửa tay, biểu đồ tháng.
- Prometheus + Grafana + Loki + cAdvisor; dashboard RPS, p95, số bản sao, độ dài hàng đợi, lỗi OCR.
- GitHub Actions (miễn phí cho repo public): `ruff`, `pytest`, build image, **Trivy** quét, đẩy image lên **GHCR**.

### 4.6 App Flutter (tuần 6)
- Chụp ảnh / chọn ảnh → `POST /api/receipts` → xem danh sách và trạng thái.
- Kết nối server qua Tailscale (điện thoại cài Tailscale) hoặc LAN.

### 4.7 Dựng lại một lệnh + hoàn thiện (tuần 7)
- Ansible playbook (chạy từ WSL Ubuntu) dựng toàn bộ lên một máy Linux trống (VM hoặc WSL): cài Docker, copy cấu hình, sinh bí mật, `compose up`.
- (Nâng cao, tuỳ chọn) chuyển sang **k3s** với HPA để có autoscaling "thật" kiểu Kubernetes.
- README: sơ đồ, bảng ở mục 2, bằng chứng mục 7, video demo; dòng CV; thẻ dự án trên portfolio.

---

## 5. Cấu trúc repo

```
receiptlens/
├─ compose.yaml          # (tuần 1) toàn bộ dịch vụ + 3 mạng
├─ edge/                 # Nginx + ModSecurity, chứng chỉ (git-ignore)
├─ lb/                   # HAProxy
├─ api/                  # FastAPI, Alembic, consumer
├─ ocr_worker/           # PaddleOCR worker + receipt_parser.py
├─ autoscaler/
├─ web/                  # dashboard tĩnh
├─ mobile/               # Flutter app (tuần 6)
├─ observability/        # Prometheus, Grafana, Loki
├─ deploy/ansible/       # (tuần 7)
├─ tests/                # parser, API, k6
├─ docs/                 # SETUP, sơ đồ, bằng chứng
└─ samples/              # ảnh hoá đơn thật (git-ignore)
```

---

## 6. Lộ trình (≈ 7 tuần, 8–10 giờ/tuần)

| Tuần | Việc | Bàn giao |
|---|---|---|
| **0** | Thử PaddleOCR trên 5–10 hoá đơn thật | Biết độ chính xác thực tế trước khi xây |
| **1** ✅ | `compose.yaml`: 3 mạng, Postgres, SeaweedFS, RabbitMQ, Nginx (TLS); Tailscale | `nmap` chỉ thấy 443; container `data` không ra được Internet |
| **2** ✅ | API + DB + upload qua API, quyền tối thiểu | Upload ảnh vào SeaweedFS qua API; 14/14 kiểm tra |
| **3** | WAF, HAProxy, autoscaler, Prometheus | k6: số bản sao tăng/giảm theo tải |
| **4** | SeaweedFS → RabbitMQ → ocr-worker → API | Ảnh lên ≤ 15 giây có dữ liệu; đạt G2 |
| **5** | Dashboard web, Grafana/Loki, CI + Trivy + GHCR | CI xanh; dashboard giám sát |
| **6** | App Flutter | Chụp và upload từ điện thoại |
| **7** | Ansible, (tuỳ chọn) k3s, README, video, CV, portfolio | Repo public hoàn chỉnh |

---

## 7. Bằng chứng đưa vào README

| Loại | Công cụ | Kết quả cần có |
|---|---|---|
| Độ chính xác OCR | `pytest` trên 30 văn bản mẫu | Bảng đúng/sai theo trường |
| Tải + tự co giãn | k6 + Grafana | Biểu đồ RPS, p95, số bản sao theo thời gian |
| Mạng | `nmap`, thử ra Internet từ `data` | Chỉ 443 mở; `data` bị chặn |
| WAF | Gửi payload SQLi/XSS mẫu | Nginx trả 403, log ModSecurity |
| Image | Trivy | Không HIGH/CRITICAL có bản vá |
| Dựng lại | Ansible trên máy trống | Thời gian dựng lại toàn bộ |

---

## 8. Chi phí

| Thành phần | Chi phí |
|---|---|
| Docker, PostgreSQL, SeaweedFS, RabbitMQ, Nginx, ModSecurity, HAProxy, PaddleOCR, Prometheus, Grafana, Loki, k3s, Ansible, Flutter | **0đ** (mã nguồn mở) |
| GitHub repo public + Actions + GHCR | **0đ** |
| Tailscale (gói cá nhân) | **0đ** |
| Cloudflare Quick Tunnel (demo tạm, không cần tài khoản, URL thay đổi mỗi lần) | **0đ** |
| Domain riêng | Không cần ở bản 1 |

Chi phí duy nhất là **tài nguyên máy**: nên có RAM ≥ 8 GB; PaddleOCR chạy bằng CPU.

---

## 9. Rủi ro và cách xử lý

| Rủi ro | Xử lý |
|---|---|
| OCR hoá đơn in nhiệt mờ, sai tổng tiền | Thử ở tuần 0; cho sửa tay; báo cáo độ chính xác thật |
| Máy yếu, chạy nhiều container chậm | Giới hạn `mem_limit`; tắt Loki/Grafana khi không cần |
| API phải nhận cả file ảnh (không dùng presigned URL) | Giới hạn 10 MB ở cả Nginx và API; tuần 3 có nhiều bản sao API sau HAProxy |
| Quick Tunnel đổi URL, không đảm bảo uptime | Chỉ dùng khi demo trực tiếp; README dùng video + ảnh |
| Ảnh hoá đơn chứa thông tin cá nhân | `samples/` git-ignore; bucket không public; fixture phải che thông tin |
| Quá tải thời gian | Cắt k3s, Loki, Flutter xuống bản 2; giữ lõi tuần 1–5 |

---

## 10. Dòng CV khi xong (điền số thật)

> **ReceiptLens**: Self-hosted receipt-OCR platform replicating Google Cloud patterns with open source: segmented Docker networks with an internet-isolated data tier, Nginx + ModSecurity WAF, HAProxy load balancing with a metrics-driven autoscaler, event pipeline SeaweedFS (S3) → RabbitMQ → PaddleOCR worker, FastAPI + PostgreSQL, Flutter client, Prometheus/Grafana, CI with Trivy, one-command rebuild via Ansible. p95 < **X** ms at **Y** RPS; **Z**% total-amount accuracy on 30 real receipts.
