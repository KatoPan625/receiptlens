# Tuần 0 — Chuẩn bị

Mục tiêu tuần 0: có công cụ, có project GCP **đã đặt budget alert**, có bucket lưu Terraform state, và **biết OCR đọc hoá đơn thật tốt đến đâu** trước khi xây bất cứ gì.

---

## 1. Cài công cụ (PowerShell)

Máy của Pan đã cài đủ (22/11/2026): Python 3.13, Docker, Git, gcloud 594.0.0, Terraform 1.17.2, k6 2.4.0, nmap 7.80. Máy khác thì cài bằng:

```powershell
winget install --id Google.CloudSDK -e
```

```powershell
winget install --id Hashicorp.Terraform -e
```

```powershell
winget install --id GrafanaLabs.k6 -e
```

```powershell
winget install --id Insecure.Nmap -e
```

Mở lại terminal rồi kiểm tra:

```powershell
gcloud --version; terraform -version; k6 version; nmap --version
```

---

## 2. Đăng nhập và tạo project

> Đăng nhập, liên kết thanh toán và nhập thẻ: **bạn tự làm** trên giao diện Google Cloud. Không gửi mật khẩu, key hay số thẻ cho ai.

```powershell
gcloud auth login
```

```powershell
gcloud auth application-default login
```

Đặt tên project (phải duy nhất toàn cầu, vd `receiptlens-pan-01`):

```powershell
$PROJECT = "receiptlens-pan-01"; gcloud projects create $PROJECT --name="ReceiptLens"
```

Liên kết billing account trong Console: **Billing → My projects → chọn project → Change billing**. Sau đó:

```powershell
gcloud config set project $PROJECT; gcloud config set compute/region asia-southeast1
```

---

## 3. Budget alert — làm trước mọi thứ khác

Lấy ID billing account:

```powershell
gcloud billing accounts list
```

Tạo budget (thay `BILLING_ID` và số tiền theo ngân sách bạn chọn; đơn vị phải trùng tiền tệ của billing account):

```powershell
gcloud billing budgets create --billing-account=BILLING_ID --display-name="receiptlens" --budget-amount=10USD --filter-projects="projects/$PROJECT" --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
```

> Budget chỉ **cảnh báo qua email**, không tự dừng chi tiêu. Thói quen an toàn nhất vẫn là `terraform destroy` sau mỗi buổi.

---

## 4. Bật API cần cho tuần 0–1

```powershell
gcloud services enable vision.googleapis.com compute.googleapis.com iap.googleapis.com storage.googleapis.com
```

Các API khác (Pub/Sub, Cloud Run, Eventarc, Cloud SQL, Secret Manager, Artifact Registry…) sẽ do Terraform bật dần ở tuần tương ứng.

---

## 5. Bucket lưu Terraform state

```powershell
gcloud storage buckets create "gs://$PROJECT-tfstate" --location=asia-southeast1 --uniform-bucket-level-access --public-access-prevention
```

```powershell
gcloud storage buckets update "gs://$PROJECT-tfstate" --versioning
```

Sau đó:

```powershell
Copy-Item infra\backend.hcl.example infra\backend.hcl; Copy-Item infra\terraform.tfvars.example infra\terraform.tfvars
```

Sửa hai file vừa chép (điền tên project/bucket), rồi:

```powershell
terraform -chdir=infra init -backend-config=backend.hcl; terraform -chdir=infra validate
```

---

## 6. Thử OCR với hoá đơn thật (quan trọng nhất tuần 0)

1. Chụp 5–10 hoá đơn khác loại (siêu thị, quán cà phê, cửa hàng tiện lợi, hoá đơn in nhiệt mờ) và bỏ vào `samples/`.
2. Tạo môi trường Python và cài thư viện:

```powershell
python -m venv .venv; .\.venv\Scripts\python -m pip install -r ocr_worker\requirements-spike.txt
```

3. Chạy:

```powershell
.\.venv\Scripts\python ocr_worker\spike_ocr.py samples
```

Kết quả (văn bản OCR + đoán tổng tiền) nằm ở `spike_output/` (đã git-ignore). Ghi lại vào bảng dưới:

| Ảnh | Loại hoá đơn | Tổng tiền thật | Script đoán | Đúng? | Ghi chú (mờ, nghiêng, mất dấu…) |
|---|---|---|---|---|---|
| | | | | | |

**Quyết định cuối tuần 0:** nếu tổng tiền đúng ≥ 6/10 → giữ kế hoạch. Nếu thấp hơn → ghi lý do; parser ở tuần 4 sẽ cần xử lý thêm, hoặc chấp nhận sửa tay nhiều hơn.

---

## Checklist tuần 0

- [ ] Cài gcloud, Terraform, k6, nmap
- [ ] Tạo project, liên kết billing
- [ ] **Budget alert**
- [ ] Bật API tuần 0–1
- [ ] Bucket Terraform state + `terraform init` thành công
- [ ] Chạy thử OCR 5–10 hoá đơn, điền bảng
- [ ] Tạo repo GitHub (để **private** cho tới tuần 6)
