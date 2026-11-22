# ReceiptLens — Kế hoạch dự án

> Chụp hoá đơn → hệ thống tự đọc tổng tiền, ngày, cửa hàng → thống kê chi tiêu.
> Mục tiêu thật: **chứng minh 4 skill badge Google Cloud bằng một hệ thống chạy được, có số đo.**

---

## 1. Mục tiêu và tiêu chí "xong"

| # | Tiêu chí | Đo bằng |
|---|---|---|
| G1 | Upload ảnh hoá đơn, sau ≤ 15 giây thấy dữ liệu đã đọc trên dashboard | Video demo |
| G2 | Đọc đúng **tổng tiền** ≥ 80% trên bộ 30 hoá đơn thật | `pytest` + báo cáo độ chính xác |
| G3 | API tự co giãn 1 → N máy khi tăng tải, p95 < 300 ms ở mức tải đã chọn | k6 + biểu đồ Cloud Monitoring |
| G4 | Từ Internet chỉ thấy cổng 80/443 của Load Balancer; máy ảo không có IP public | `nmap` + ảnh firewall rules |
| G5 | Toàn bộ hạ tầng dựng lại được bằng `terraform apply`, xoá sạch bằng `terraform destroy` | Chạy thử trên project trống |
| G6 | README có bảng "Badge → áp dụng ở đâu", sơ đồ kiến trúc, chi phí | Repo public |

**Ngoài phạm vi bản 1 (để bản 2):** đăng nhập nhiều người dùng, app Flutter, phân loại chi tiêu bằng ML, HTTPS với domain riêng (xem mục 9).

---

## 2. Badge → phần của dự án

| Badge | Áp dụng trong ReceiptLens |
|---|---|
| **Build a Secure Google Cloud Network** (Intermediate) | VPC tự thiết kế, subnet riêng, máy ảo không IP public, Cloud NAT, firewall tối thiểu, SSH chỉ qua IAP, Cloud SQL private IP, service account quyền tối thiểu, Cloud Armor |
| **Implementing Cloud Load Balancing for Compute Engine** | Instance template → Managed Instance Group tự co giãn → Global external Application Load Balancer, health check, định tuyến `/api/*` → MIG, `/*` → bucket tĩnh |
| **Set Up an App Dev Environment on Google Cloud** | Cloud Storage nhận ảnh, Pub/Sub phát sự kiện, Cloud Run function xử lý |
| **Prepare Data for ML APIs on Google Cloud** | Vision API OCR, làm sạch và chuẩn hoá văn bản thô thành dữ liệu có cấu trúc |
| 4 khoá **Computing Foundations** | Kiến thức nền cho IAM, mạng, compute, dữ liệu xuyên suốt |

---

## 3. Kiến trúc

```
                    Internet
                       │  (chỉ 80/443)
              ┌────────▼─────────┐
              │  Cloud Armor     │  rate limit + rule OWASP
              │  Global external │
              │  Application LB  │
              └───┬──────────┬───┘
         /api/*   │          │  /*
                  ▼          ▼
   ┌──────────────────────┐  ┌────────────────────┐
   │ VPC receiptlens-vpc  │  │ Bucket web tĩnh    │
   │ subnet app (private) │  │ (dashboard HTML/JS)│
   │ ┌──────────────────┐ │  └────────────────────┘
   │ │ MIG: FastAPI x1–N│─┼──► Cloud SQL Postgres (private IP)
   │ └───────┬──────────┘ │
   │         │ Cloud NAT ─┼──► ra Internet (cài gói, gọi API)
   └─────────┼────────────┘
             │ (1) cấp signed URL
             ▼
   Trình duyệt ── PUT ảnh ──► Bucket receipts-raw
                                   │ (2) OBJECT_FINALIZE
                                   ▼
                         Pub/Sub topic receipt-uploaded
                                   │ (3) Eventarc
                                   ▼
                      Cloud Run function ocr-worker ──► Vision API
                                   │ (4) kết quả đã parse
                                   ▼
                         Pub/Sub topic receipt-parsed ──► DLQ khi lỗi
                                   │ (5) pull subscription
                                   ▼
                         API (MIG) ghi vào Cloud SQL
```

**Vì sao function không ghi thẳng vào DB?** Để function không cần vào VPC. API là nơi duy nhất chạm DB → ranh giới bảo mật rõ, và Pub/Sub được dùng hai lần (đúng tinh thần badge App Dev).

---

## 4. Thành phần chi tiết

### 4.1 Mạng (tuần 1)
- VPC `receiptlens-vpc`, chế độ custom; subnet `app` (vd `10.10.0.0/24`) ở 1 region gần VN (vd `asia-southeast1`).
- Cloud Router + Cloud NAT cho subnet `app`.
- Firewall (mặc định từ chối, chỉ mở):
  - Health check và LB của Google → cổng app (8080). Lấy dải IP chính thức trong tài liệu Load Balancing.
  - IAP TCP forwarding → cổng 22 (dải IAP chính thức trong tài liệu IAP).
  - Không rule nào mở `0.0.0.0/0` vào máy ảo.
- Private Service Access cho Cloud SQL.
- Service account riêng: `sa-api` (đọc Secret, tạo signed URL, subscribe Pub/Sub, Cloud SQL client), `sa-ocr` (đọc bucket, gọi Vision, publish Pub/Sub).

### 4.2 Backend API (tuần 2)
- FastAPI + SQLAlchemy, chạy trong Docker, image lưu ở Artifact Registry.
- Mật khẩu DB trong Secret Manager.
- Bảng `receipts`:

| Cột | Kiểu | Ghi chú |
|---|---|---|
| `id` | uuid | khoá chính |
| `object_path` | text | đường dẫn ảnh trong bucket |
| `status` | enum | `uploaded` / `parsed` / `failed` / `corrected` |
| `merchant` | text | tên cửa hàng |
| `total_vnd` | bigint | đơn vị đồng |
| `purchased_at` | timestamptz | giờ VN |
| `raw_text` | text | văn bản OCR gốc |
| `confidence` | real | độ tin cậy của parser |
| `created_at`, `updated_at` | timestamptz | |

- Endpoint:

| Method | Path | Mục đích |
|---|---|---|
| `POST` | `/api/uploads` | Trả signed URL để trình duyệt upload thẳng lên bucket |
| `GET` | `/api/receipts` | Danh sách, lọc theo tháng |
| `GET` | `/api/receipts/{id}` | Chi tiết + văn bản gốc |
| `PATCH` | `/api/receipts/{id}` | Sửa tay khi OCR sai → `corrected` |
| `GET` | `/api/stats/monthly` | Tổng chi theo tháng, theo cửa hàng |
| `GET` | `/healthz` | Health check cho LB |

### 4.3 Load balancing (tuần 3)
- Instance template: Debian + startup script cài Docker, kéo image từ Artifact Registry, chạy container cổng 8080. Không gắn IP public.
- MIG regional, autoscale theo CPU (vd mục tiêu 60%), min 1, max 3; autohealing dùng `/healthz`.
- Global external Application LB: backend service → MIG; backend bucket → web tĩnh; URL map `/api/*` và `/*`.
- Cloud Armor: rate limit theo IP, rule OWASP dựng sẵn.

### 4.4 Pipeline sự kiện + OCR (tuần 4)
- Bucket `receipts-raw`: uniform access, không public, lifecycle xoá ảnh sau 30 ngày.
- Pub/Sub notification của bucket → topic `receipt-uploaded`.
- Cloud Run function `ocr-worker` (Python), trigger Eventarc từ topic:
  1. Gọi Vision `DOCUMENT_TEXT_DETECTION`, gợi ý ngôn ngữ `vi`.
  2. Parser: tìm dòng tổng (`TỔNG CỘNG`, `Tổng tiền`, `Thanh toán`…), số tiền dạng `125.000` / `125,000đ`, ngày `dd/mm/yyyy`, tên cửa hàng ở vài dòng đầu.
  3. Publish kết quả lên `receipt-parsed`.
- Subscription `receipt-parsed` có dead-letter topic sau 5 lần lỗi.
- API chạy một consumer nền pull subscription và ghi DB; ack sau khi ghi thành công (idempotent theo `object_path`).

### 4.5 Web, giám sát, CI/CD (tuần 5)
- Dashboard tĩnh (HTML/JS, cùng phong cách portfolio): upload, danh sách, sửa tay, biểu đồ tháng.
- Cloud Monitoring: dashboard (RPS, p95, số máy trong MIG, lỗi OCR), uptime check, cảnh báo email.
- GitHub Actions + **Workload Identity Federation** (không tạo key JSON):
  - PR: `ruff`, `pytest`, `terraform fmt -check` + `terraform validate`.
  - Merge `main`: build image → Artifact Registry → rolling update MIG; deploy function.

---

## 5. Cấu trúc repo

```
receiptlens/
├─ infra/            # Terraform: network/, compute/, lb/, data/, pipeline/
├─ api/              # FastAPI, Dockerfile, consumer Pub/Sub
├─ ocr_worker/       # Cloud Run function + parser
├─ web/              # dashboard tĩnh
├─ tests/
│  ├─ fixtures/      # văn bản OCR mẫu (không chứa thông tin cá nhân)
│  ├─ test_parser.py
│  └─ load/k6.js
├─ docs/             # sơ đồ, ảnh bằng chứng, báo cáo đo
└─ .github/workflows/
```

---

## 6. Lộ trình (≈ 6 tuần, 8–10 giờ/tuần)

| Tuần | Việc | Bàn giao |
|---|---|---|
| **0** | Tạo project GCP, **budget alert**, bucket lưu Terraform state, repo. **Thử OCR 5–10 hoá đơn thật bằng `gcloud ml vision detect-document`** | Biết độ chính xác thực tế trước khi xây |
| **1** | Mạng (4.1) bằng Terraform. SSH qua IAP vào 1 VM thử | `nmap` chỉ thấy cổng đã cho phép; ảnh firewall |
| **2** | API + Cloud SQL private + Secret Manager (4.2) trên 1 VM | Gọi API qua IAP tunnel; migration chạy được |
| **3** | MIG + LB + Cloud Armor (4.3) | k6: biểu đồ MIG tăng máy, số p95 |
| **4** | Bucket → Pub/Sub → function → Vision → parsed → DB (4.4) | Upload ảnh, ≤ 15 giây có dữ liệu; parser test đạt G2 |
| **5** | Dashboard, giám sát, CI/CD (4.5) | Merge `main` là tự deploy |
| **6** | README, sơ đồ, bảng badge, video demo, dòng CV, thẻ trên portfolio; thử `destroy` → `apply` lại từ đầu | Repo public hoàn chỉnh |

---

## 7. Chi phí và cách giữ rẻ

> Số dưới đây là **ước tính để định hướng**, phải kiểm lại bằng Google Cloud Pricing Calculator trước khi dựng.

| Thành phần | Ghi chú chi phí |
|---|---|
| Load Balancer (forwarding rule) | Tính theo giờ dù không có truy cập — thành phần đắt nhất khi để chạy liên tục |
| VM trong MIG (e2-small) | Tính theo giờ; min 1 máy |
| Cloud SQL (máy nhỏ nhất) | Tính theo giờ; có thể **stop** khi không dùng |
| Cloud NAT | Phí gateway theo giờ + dữ liệu |
| Cloud Armor | Phí theo policy và số rule mỗi tháng |
| Vision API | Có hạn mức miễn phí hằng tháng; demo vài trăm ảnh là trong mức đó |
| Pub/Sub, Cloud Run function, Storage | Gần như miễn phí ở quy mô demo |

**Quy tắc:**
1. Dùng gói dùng thử cho tài khoản mới nếu đủ điều kiện.
2. Đặt **budget alert** (vd 50%, 90%, 100% của ngân sách bạn chọn) ngay tuần 0.
3. Chỉ bật toàn bộ khi làm việc/quay demo; xong là `terraform destroy` (hoặc tối thiểu xoá LB + stop Cloud SQL).
4. Bật Cloud Armor ở tuần 3 nhưng có thể tắt khi không demo.

---

## 8. Kiểm thử và bằng chứng

| Loại | Công cụ | Đưa vào README |
|---|---|---|
| Parser | `pytest` trên 30 văn bản OCR mẫu | Bảng độ chính xác theo trường (tổng tiền, ngày, cửa hàng) |
| API | `pytest` + TestClient | Badge CI xanh |
| Tải | k6 tăng dần RPS | Biểu đồ p95 + số máy MIG theo thời gian |
| Bảo mật | `nmap` từ máy ngoài; thử SSH trực tiếp (phải thất bại) | Output + ảnh firewall/IAP |
| Hạ tầng | `terraform validate`, destroy/apply lại | Ghi thời gian dựng lại toàn bộ |

---

## 9. Rủi ro và cách xử lý

| Rủi ro | Xử lý |
|---|---|
| OCR hoá đơn in nhiệt mờ, sai tổng tiền | Thử ở tuần 0; cho phép sửa tay (`PATCH`); ghi độ chính xác thật, không thổi phồng |
| HTTPS cần domain cho Google-managed certificate | Bản 1 dùng HTTP qua IP của LB cho demo; bản 2 mua domain rẻ và bật HTTPS |
| Chi phí phát sinh khi quên tắt | Budget alert + checklist `destroy` cuối mỗi buổi |
| Ảnh hoá đơn chứa thông tin cá nhân | Bucket không public, lifecycle 30 ngày, ảnh mẫu trong repo phải che thông tin |
| Quá tải thời gian | Cắt Cloud Armor/CI/CD xuống bản 2 trước, giữ nguyên lõi tuần 1–4 |

---

## 10. Dòng CV khi xong (điền số thật)

> **ReceiptLens** — Built a secure, autoscaling receipt-OCR platform on Google Cloud: custom VPC with private-only VMs, Cloud NAT and IAP; managed instance group behind a global Application Load Balancer with Cloud Armor; event pipeline with Cloud Storage, Pub/Sub, Cloud Run functions and Vision API; fully provisioned with Terraform and deployed via GitHub Actions (Workload Identity Federation). Held p95 < **X** ms at **Y** RPS; **Z**% total-amount accuracy on 30 real receipts.

---

## 11. Việc cần bạn quyết trước khi bắt đầu

- [ ] Tài khoản GCP: dùng project mới, có còn quyền dùng gói dùng thử không?
- [ ] Ngân sách tối đa mỗi tháng để đặt budget alert.
- [ ] Region: `asia-southeast1` (Singapore) hay region khác.
- [ ] Có sẵn 30 hoá đơn thật để làm bộ đo không.
