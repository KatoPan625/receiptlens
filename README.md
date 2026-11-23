# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 5 done.** Web dashboard (strict CSP), Grafana behind login, CI with ruff + pytest + Trivy. All 68 checks pass across weeks 1–5; load test 9,074 requests, 0 errors, p95 10.72 ms; images have 0 fixable HIGH/CRITICAL vulnerabilities ([docs/evidence/](docs/evidence/)). Accuracy on real receipts is not measured yet. See [PLAN.md](PLAN.md) and [docs/SETUP.md](docs/SETUP.md).

## Quick start

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d --build
powershell -NoProfile -File scripts\verify-week1.ps1
powershell -NoProfile -File scripts\verify-week2.ps1
powershell -NoProfile -File scripts\verify-week3.ps1
powershell -NoProfile -File scripts\verify-week4.ps1
powershell -NoProfile -File scripts\verify-week5.ps1
```

Dashboard: `https://localhost/` · API docs: `https://localhost/api/docs` · Monitoring: `https://localhost/grafana/` (user `admin`, password in `.env`)

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks (`edge`, internal `app`, internal `data`); WAF edge (only port 443), HAProxy, API replicas, OCR worker, Prometheus, one-shot `migrate` job, Postgres, RabbitMQ, SeaweedFS S3 |
| `api/` | FastAPI service: upload with magic-byte checks, receipts CRUD, monthly stats; Alembic migrations; publishes OCR requests, applies results and re-publishes lost ones (`events.py`); `bootstrap.py` creates the least-privilege DB role, bucket, RabbitMQ topology and users; unit tests in `api/tests/` |
| `edge/` | Server config for the Nginx + ModSecurity + OWASP CRS image (TLS, rate limits, routing to API, dashboard and Grafana); certificates are generated locally and git-ignored |
| `lb/` | HAProxy: round-robin over API replicas discovered via Docker DNS, health checks, failover |
| `observability/` | Prometheus scrape config (API replicas, HAProxy, RabbitMQ queues); Grafana datasource + dashboard provisioning |
| `autoscaler/` | Host-side autoscaler: reads req/s from Prometheus, scales `api` 1–4 with cooldown and hysteresis |
| `scripts/` | `init-env.ps1` (random secrets + local TLS cert), `verify-week1.ps1` (network isolation), `verify-week2.ps1` (upload flow, validation, least privilege), `verify-week3.ps1` (WAF, rate limit, load balancing, failover), `verify-week4.ps1` (OCR pipeline, dead-lettering, queue permissions), `verify-week5.ps1` (dashboard, CSP, Grafana, Trivy, lint, tests) |
| `ocr_worker/` | `worker.py` (RabbitMQ consumer, PaddleOCR with models baked into the image), `receipt_parser.py` (total, date, merchant; robust to vowels PaddleOCR drops), `spike_ocr.py` (try OCR on your own photos) |
| `tests/` | Parser, worker and autoscaler unit tests; `fixtures/make_receipt.py` (synthetic receipt); `load/k6.js` load test |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `web/` | Dashboard: upload, receipt list, corrections, monthly chart (plain HTML/CSS/JS, served by the edge with a strict CSP) |
| `.github/workflows/` | CI: ruff, pytest, image build, Trivy gate (fixable HIGH/CRITICAL), push to GHCR on `main` |

Other folders (`mobile/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
