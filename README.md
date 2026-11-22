# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 4 done.** Upload → RabbitMQ → PaddleOCR worker → result back in the API in 4.5 s on a synthetic receipt; failures end as `failed` or in a dead-letter queue. Checks: network 12/12, API 14/14, WAF + load balancing 12/12, OCR pipeline 14/14; load test 9,074 requests, 0 errors, p95 10.72 ms ([docs/evidence/](docs/evidence/)). Accuracy on real receipts is not measured yet. See [PLAN.md](PLAN.md) and [docs/SETUP.md](docs/SETUP.md).

## Quick start

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d --build
powershell -NoProfile -File scripts\verify-week1.ps1
powershell -NoProfile -File scripts\verify-week2.ps1
powershell -NoProfile -File scripts\verify-week3.ps1
powershell -NoProfile -File scripts\verify-week4.ps1
```

API docs: `https://localhost/api/docs`

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks (`edge`, internal `app`, internal `data`); WAF edge (only port 443), HAProxy, API replicas, OCR worker, Prometheus, one-shot `migrate` job, Postgres, RabbitMQ, SeaweedFS S3 |
| `api/` | FastAPI service: upload with magic-byte checks, receipts CRUD, monthly stats; Alembic migrations; publishes OCR requests, applies results and re-publishes lost ones (`events.py`); `bootstrap.py` creates the least-privilege DB role, bucket, RabbitMQ topology and users; unit tests in `api/tests/` |
| `edge/` | Server config for the Nginx + ModSecurity + OWASP CRS image (TLS, rate limits, routing) and landing page; certificates are generated locally and git-ignored |
| `lb/` | HAProxy: round-robin over API replicas discovered via Docker DNS, health checks, failover |
| `observability/` | Prometheus scrape config (API replicas + HAProxy) |
| `autoscaler/` | Host-side autoscaler: reads req/s from Prometheus, scales `api` 1–4 with cooldown and hysteresis |
| `scripts/` | `init-env.ps1` (random secrets + local TLS cert), `verify-week1.ps1` (network isolation), `verify-week2.ps1` (upload flow, validation, least privilege), `verify-week3.ps1` (WAF, rate limit, load balancing, failover), `verify-week4.ps1` (OCR pipeline, dead-lettering, queue permissions) |
| `ocr_worker/` | `worker.py` (RabbitMQ consumer, PaddleOCR with models baked into the image), `receipt_parser.py` (total, date, merchant; robust to vowels PaddleOCR drops), `spike_ocr.py` (try OCR on your own photos) |
| `tests/` | Parser, worker and autoscaler unit tests; `fixtures/make_receipt.py` (synthetic receipt); `load/k6.js` load test |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `web/` | Placeholder for week 5 |

Other folders (`mobile/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
