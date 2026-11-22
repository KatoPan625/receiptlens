# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 3 done.** Network isolation (12/12), API with least privilege (14/14), WAF + load balancing + failover (12/12); load test 9,074 requests, 0 errors, p95 10.72 ms with autoscaling 1 → 4 → 2 replicas ([docs/evidence/](docs/evidence/)). Week 0 OCR test is waiting for real receipts. See [PLAN.md](PLAN.md) and [docs/SETUP.md](docs/SETUP.md).

## Quick start

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d --build
powershell -NoProfile -File scripts\verify-week1.ps1
powershell -NoProfile -File scripts\verify-week2.ps1
powershell -NoProfile -File scripts\verify-week3.ps1
```

API docs: `https://localhost/api/docs`

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks (`edge`, internal `app`, internal `data`); WAF edge (only port 443), HAProxy, API replicas, Prometheus, one-shot `migrate` job, Postgres, RabbitMQ, SeaweedFS S3 |
| `api/` | FastAPI service: upload with magic-byte checks, receipts CRUD, monthly stats; Alembic migrations; `bootstrap.py` creates the least-privilege DB role and bucket; unit tests in `api/tests/` |
| `edge/` | Server config for the Nginx + ModSecurity + OWASP CRS image (TLS, rate limits, routing) and landing page; certificates are generated locally and git-ignored |
| `lb/` | HAProxy: round-robin over API replicas discovered via Docker DNS, health checks, failover |
| `observability/` | Prometheus scrape config (API replicas + HAProxy) |
| `autoscaler/` | Host-side autoscaler: reads req/s from Prometheus, scales `api` 1–4 with cooldown and hysteresis |
| `scripts/` | `init-env.ps1` (random secrets + local TLS cert), `verify-week1.ps1` (network isolation), `verify-week2.ps1` (upload flow, validation, least privilege), `verify-week3.ps1` (WAF, rate limit, load balancing, failover) |
| `ocr_worker/` | `receipt_parser.py` (total-amount heuristics) and `spike_ocr.py` (week 0 PaddleOCR test); OCR worker from week 4 |
| `tests/` | Parser and autoscaler unit tests; `load/k6.js` load test; OCR fixtures later |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `web/` | Placeholder for week 5 |

Other folders (`mobile/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
