# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 2 done.** Network and data tier (12/12 checks) and API with upload and least privilege (14/14 checks), see [docs/evidence/](docs/evidence/). Week 0 OCR test is waiting for real receipts. See [PLAN.md](PLAN.md) and [docs/SETUP.md](docs/SETUP.md).

## Quick start

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d --build
powershell -NoProfile -File scripts\verify-week1.ps1
powershell -NoProfile -File scripts\verify-week2.ps1
```

API docs: `https://localhost/api/docs`

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks (`edge`, internal `app`, internal `data`); Nginx edge (only port 443), API, one-shot `migrate` job, Postgres, RabbitMQ, SeaweedFS S3 |
| `api/` | FastAPI service: upload with magic-byte checks, receipts CRUD, monthly stats; Alembic migrations; `bootstrap.py` creates the least-privilege DB role and bucket; unit tests in `api/tests/` |
| `edge/` | Nginx TLS config and landing page; certificates are generated locally and git-ignored |
| `scripts/` | `init-env.ps1` (random secrets + local TLS cert), `verify-week1.ps1` (network isolation), `verify-week2.ps1` (upload flow, validation, least privilege) |
| `ocr_worker/` | `receipt_parser.py` (total-amount heuristics) and `spike_ocr.py` (week 0 PaddleOCR test); OCR worker from week 4 |
| `tests/` | Parser tests now; API tests, OCR fixtures and k6 load test later |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `web/` | Placeholder for week 5 |

Other folders (`lb/`, `autoscaler/`, `mobile/`, `observability/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
