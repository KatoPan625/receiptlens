# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 1 done** (network and data tier, 12/12 checks in [docs/evidence/week1-verify.txt](docs/evidence/week1-verify.txt)); week 0 OCR test waiting for real receipts. See [PLAN.md](PLAN.md) and [docs/SETUP.md](docs/SETUP.md).

## Quick start

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d
powershell -NoProfile -File scripts\verify-week1.ps1
```

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks (`edge`, internal `app`, internal `data`); Nginx edge (only port 443), Postgres, RabbitMQ, SeaweedFS S3 |
| `edge/` | Nginx TLS config and landing page; certificates are generated locally and git-ignored |
| `scripts/` | `init-env.ps1` (random secrets + local TLS cert), `verify-week1.ps1` (network isolation checks) |
| `ocr_worker/` | `receipt_parser.py` (total-amount heuristics) and `spike_ocr.py` (week 0 PaddleOCR test); OCR worker from week 4 |
| `tests/` | Parser tests now; API tests, OCR fixtures and k6 load test later |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `api/`, `web/` | Placeholders for weeks 2 and 5 |

Other folders (`edge/`, `lb/`, `autoscaler/`, `mobile/`, `observability/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
