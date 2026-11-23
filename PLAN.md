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
   Web / Flutter ── POST ảnh ─┘
                              │ (1) API kiểm tra loại/kích thước, ghi S3 + Postgres     mạng data (internal)
                              │ (2) API publish receipt.uploaded (+ quét bù mỗi 60 s)
                              ▼
                      RabbitMQ: ocr.requests ──► ocr.requests.dead (sau 5 lần lỗi)
                              │ (3)
                              ▼
                      ocr-worker: đọc ảnh từ SeaweedFS (chỉ đọc) → PaddleOCR → parser
                              │ (4) publish receipt.parsed
                              ▼
                      RabbitMQ: api.results ──► api ghi kết quả vào PostgreSQL (5)

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
- (đã làm) Edge dùng image `owasp/modsecurity-crs` (Nginx + ModSecurity v3 + OWASP CRS, paranoia 1, chế độ chặn), chạy user không phải root ở cổng 8443 (map 443 → 8443). Chỉ cho phép `GET HEAD POST OPTIONS PATCH`. Rate limit: đọc 100 yêu cầu/s (burst 200), upload 2/s (burst 10). `/api/metrics` bị chặn từ ngoài.
- (đã làm) HAProxy: round-robin, `server-template` 4 slot lấy IP các bản sao từ DNS của Docker, health check `/healthz`, `retries` + `redispatch` khi một bản sao chết; số liệu Prometheus và trang stats chỉ trong mạng `app`.
- (đã làm) Prometheus trong mạng `app` (không publish cổng), lấy số liệu từng bản sao API qua DNS SD và từ HAProxy.
- (đã làm) Autoscaler `autoscaler/autoscale.py` chạy **trên máy host**: đọc req/s của HAProxy từ Prometheus qua `docker compose exec`, rồi `docker compose up --scale api=N` (1–4). Tăng ngay; giảm từng bước sau cooldown và chỉ khi còn dư 20% năng lực. Chạy trên host để không phải gắn `docker.sock` (tương đương quyền root) vào container nào.
- Bằng chứng: `docs/evidence/week3-load.md`: 9.074 yêu cầu, 0 lỗi, p95 10,72 ms, số bản sao 1 → 4 → 2. Lần đo đầu trượt (p95 322 ms, 0,46% lỗi) vì autoscaler giảm sai lúc tải đang tăng; đã sửa bằng hysteresis.

### 4.4 Pipeline sự kiện + OCR (tuần 4) — đã làm
- **Nguồn sự kiện (quyết định tuần 4):** API publish `receipt.uploaded` ngay sau khi ghi DB thành công, có publisher confirms. Không dùng sự kiện từ SeaweedFS vì: gửi thẳng RabbitMQ thì tin nhắn là protobuf (phải biên dịch `.proto` của SeaweedFS), còn webhook chỉ thử lại 3 lần rồi bỏ. Để không mất việc khi publish lỗi, mỗi bản sao API chạy **vòng quét bù** 60 giây/lần: hoá đơn kẹt ở `uploaded` quá 2 phút được publish lại (tối đa 3 lần, khoá hàng bằng `SKIP LOCKED` để nhiều bản sao không gửi trùng), quá 10 phút thì đánh dấu `failed`.
- **RabbitMQ:** exchange `receipts` + `receipts.dlx`; quorum queue `ocr.requests` và `api.results`, `x-delivery-limit: 5` rồi vào `*.dead`. Job `migrate` tạo toàn bộ topology và 2 user: `api` (chỉ publish `receipts`, đọc `api.results`), `ocr` (chỉ publish `receipts`, đọc `ocr.requests`); không user nào có quyền configure.
- **`ocr-worker`:** PaddleOCR 3.7 / PaddlePaddle 3.3.1, mô hình PP-OCRv6 (mặc định của `lang="vi"`) được **tải sẵn lúc build image** vì mạng `data` không ra Internet. Phải tắt oneDNN (`enable_mkldnn=False`): bật thì Paddle báo `ConvertPirAttribute2RuntimeAttribute not support`. Key S3 chỉ đọc. Ảnh không giải mã được hoặc OCR lỗi → trả kết quả `failed` (không làm chết worker); S3 lỗi → requeue, quá 5 lần vào DLQ.
- **Giới hạn đã thấy của PaddleOCR với tiếng Việt:** PP-OCRv6 rơi các nguyên âm mang hai dấu (Nguyễn → "Nguyn", Tiền → "Tin"); PP-OCRv5 Latin còn kém hơn (đọc "TỔNG CỘNG" thành "TNG CQNG"). Parser vì thế so từ khoá theo **bộ xương phụ âm** (bỏ dấu rồi bỏ nguyên âm). Nếu hoá đơn thật vẫn kém, phương án là VietOCR (mô hình chuyên tiếng Việt, nặng hơn).
- **API nhận kết quả:** chỉ ghi vào hoá đơn đang `uploaded` → kết quả trùng là vô hại và **sửa tay của người dùng luôn thắng**. Tổng tiền ngoài khoảng hợp lệ bị bỏ.
- Bằng chứng: `docs/evidence/week4-verify.txt` (14/14): hoá đơn mẫu đi hết đường ống trong 4,5 s, đúng tổng/ngày/cửa hàng; ảnh hỏng thành `failed`; tin độc vào DLQ; user RabbitMQ bị `ACCESS_REFUSED` ngoài quyền; worker không ra Internet.
- **Chưa làm:** đo độ chính xác trên 30 hoá đơn thật (G2) — chờ ảnh thật trong `samples/`.

### 4.5 Web, giám sát, CI (tuần 5) — đã làm
- **Dashboard** (`web/`, HTML/CSS/JS thuần, cùng bảng màu portfolio, chỉ dùng font hệ thống): kéo-thả/chụp ảnh để upload, danh sách tự làm mới khi còn hoá đơn đang đọc, hộp chi tiết có ảnh gốc + văn bản OCR + form sửa tay (giờ Việt Nam), biểu đồ chi tiêu theo tháng. Dữ liệu chỉ chèn bằng `textContent`. Edge gắn **CSP chặt** (`script-src 'self'`, không `unsafe-inline`, không bên thứ ba).
- **Grafana 13.3** trong mạng `app`, chỉ vào được qua edge ở `/grafana/`, bắt đăng nhập (mật khẩu ngẫu nhiên trong `.env`), tắt đăng ký và truy cập ẩn danh. Datasource + dashboard 8 panel tự nạp (req/s, p95, số bản sao API theo thời gian, độ dài hàng đợi, tin trong DLQ, lỗi 5xx). WAF tắt riêng cho `/grafana/` vì CRS coi PromQL là tấn công injection; Grafana tự xác thực.
- **Prometheus** thêm số liệu RabbitMQ theo từng queue (`/metrics/detailed?family=queue_coarse_metrics`).
- **CI** (`.github/workflows/ci.yml`): ruff (lint + bandit + format), pytest 2 bộ, build 2 image, **Trivy chặn HIGH/CRITICAL đã có bản vá**, đẩy GHCR khi merge `main`. Action bên thứ ba ghim theo commit SHA. Job lint-test đã chạy thử trong container Python sạch (lộ ra lỗi `import app` khi gọi `pytest` trực tiếp → thêm `api/pytest.ini`).
- **Trivy lần đầu** thấy 6 HIGH mỗi image: `zlib1g` (Debian) và urllib3/msgpack/setuptools nằm trong **pip tự đóng gói**. Sửa: `apt-get upgrade` lúc build và **gỡ pip khỏi image chạy** → 0.
- **Cắt xuống bản 2:** Loki, cAdvisor (đúng thứ tự cắt ở mục 9).

### 4.6 App Flutter (tuần 6) — code + APK xong, chờ thử trên điện thoại
- `mobile/`: Flutter 3.50.1 (Dart 3.14), Android + web. Màn hình: danh sách (trạng thái, tổng tháng, kéo để làm mới, tự làm mới khi đang OCR), chụp/chọn ảnh → upload (thu nhỏ 2000 px, nén 85% trên máy), chi tiết (ảnh phóng to được, form sửa tay, văn bản OCR), cài đặt địa chỉ server (chỉ HTTPS).
- Flutter 3.47+ tách Material ra gói `material_ui`: code import `package:material_ui/material_ui.dart`.
- 6 test widget/đơn vị chạy màn hình thật với API giả (`MockClient`) và bộ chọn ảnh giả: danh sách, upload multipart, sửa tay (kiểm body PATCH, giờ +07:00), chặn số âm trước khi gọi server, chỉ chấp nhận HTTPS, thông báo lỗi dễ hiểu. `flutter analyze` sạch; CI có job `mobile`.
- **TLS tới server dev:** `network_security_config.xml` cấm HTTP; chỉ bản **debug** tin CA do người dùng cài (CA mkcert), bản release chỉ tin CA hệ thống. `init-env.ps1 -RenewCert` cấp lại chứng chỉ edge kèm `10.0.2.2` (emulator) và IP LAN/Tailscale.
- Manifest chính thêm quyền INTERNET (bản mẫu chỉ có ở debug), `allowBackup=false`.
- **APK debug build được** (`flutter build apk --debug`, 164 MB do có đủ ABI + thông tin debug). Lỗi gặp phải: Kotlin incremental không đóng được cache khi project ở ổ D: còn pub cache ở ổ C: → `kotlin.incremental=false` trong `android/gradle.properties`.
- **Chưa kiểm chứng trên thiết bị:** emulator Android 17 khởi động được nhưng adb liên tục `offline`/`not found` khi chạy cùng stack Docker (máy quá tải), chưa cài được APK. Bước tiếp: cài APK lên điện thoại Android thật.

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
| **3** ✅ | WAF, HAProxy, autoscaler, Prometheus | k6: số bản sao tăng/giảm theo tải |
| **4** ✅ | API → RabbitMQ → ocr-worker → API | Ảnh lên ≤ 15 giây có dữ liệu (đạt: 4,5 s); G2 chờ hoá đơn thật |
| **5** ✅ | Dashboard web, Grafana, CI + Trivy + GHCR | 16/16 kiểm tra; Trivy 0 HIGH/CRITICAL có bản vá |
| **6** ⏳ | App Flutter | Code + 6 test + APK xong; chờ thử trên điện thoại |
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
