# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> **Status: all 7 weeks done.** 68 automated checks pass across weeks 1–5. Load test: 9,074 requests, 0 errors, p95 10.72 ms. Images have 0 fixable HIGH/CRITICAL vulnerabilities. The Android app was tested end to end on an emulator. One Ansible command rebuilds everything on an empty Ubuntu server and proves it works ([evidence](#evidence)).
> **Not measured yet:** OCR accuracy on real receipts (`samples/` is empty). Every OCR result so far is on synthetic receipts, which are much easier than crumpled thermal prints.

## Architecture

```
                         HTTPS :443 (the only published port)
                                   │
   network edge     ┌──────────────▼──────────────┐
                    │ Nginx + ModSecurity + CRS   │  TLS, WAF, rate limits, CSP;
                    │ /  /m/  /api/  /grafana/    │  serves the dashboard and Flutter web build
                    └──────────────┬──────────────┘
   network app      ┌──────────────▼──────────────┐
   (internal)       │ HAProxy ──► api × 1..4      │◄── autoscaler (host side, reads Prometheus)
                    │ Prometheus · Grafana        │
                    └──────────────┬──────────────┘
   network data                    │ (1) magic-byte check, store image (S3) + row (Postgres)
   (internal,                      │ (2) publish receipt.uploaded; a sweep re-publishes lost ones
    no Internet)                   ▼
                    RabbitMQ ocr.requests ──► ocr.requests.dead after 5 failures
                                   │ (3)
                    ocr-worker: read image (read-only S3 key) → PaddleOCR (vi) → parser
                                   │ (4) publish receipt.parsed
                    RabbitMQ api.results ──► api writes the result to PostgreSQL (5)
```

Only the API touches the database; the OCR worker can read one bucket and publish to one exchange.
Uploads go through the API (not presigned URLs), so the edge never reaches the data network.

## Google Cloud concept → what is built here

| Skill badge | On Google Cloud | In ReceiptLens |
|---|---|---|
| Build a Secure Google Cloud Network | VPC, firewall rules, private VMs, Cloud NAT, IAP, Cloud Armor | Three Docker networks; `app` and `data` are internal (no Internet); only the edge publishes a port; ModSecurity + OWASP CRS and rate limits instead of Cloud Armor |
| Implementing Cloud Load Balancing for Compute Engine | Instance template, managed instance group, health checks, HTTP(S) LB | HAProxy over API replicas found by Docker DNS, health checks and failover; an autoscaler that scales replicas 1–4 from Prometheus request rates, with cooldown and hysteresis |
| Set Up an App Dev Environment | Cloud Storage, Pub/Sub, Cloud Functions | SeaweedFS (S3 API) for images, RabbitMQ quorum queues with dead-lettering, an OCR worker that consumes events |
| Prepare Data for ML APIs | Vision API, data cleaning | PaddleOCR (Vietnamese model baked into the image) and a parser that turns raw text into merchant, date and total |
| Cloud Computing Foundations | IAM, networking, compute, data | Least privilege per service: its own DB role, S3 key scoped to one bucket, RabbitMQ user without configure rights |

## Quick start (Windows + Docker Desktop)

```powershell
powershell -NoProfile -File scripts\init-env.ps1
docker compose up -d --build
powershell -NoProfile -File scripts\verify-week1.ps1   # ... through verify-week5.ps1
```

Dashboard `https://localhost/` · Phone web app `https://localhost/m/` · API docs `https://localhost/api/docs` · Grafana `https://localhost/grafana/` (user `admin`, password in `.env`).

## One-command rebuild on an empty Linux server (Ansible)

`deploy/ansible/site.yml` takes an Ubuntu 24.04 machine that has nothing but SSH and sudo and leaves it running and verified:
- installs Docker Engine from Docker's apt repository;
- copies the source (only files git tracks or would track, so `.env`, keys and certificates stay behind);
- generates every secret and a small TLS CA **on the target**: they never exist on the control machine;
- builds and starts the stack;
- smoke-tests the public path. It checks health, checks that the WAF blocks an SQL injection, uploads a test receipt, and waits for OCR to read 87.000 đ.

Re-running it keeps secrets, data and certificates.

On this PC the "empty server" is a fresh WSL distro (`scripts/new-wsl-target.ps1` creates it with only SSH and one sudo user). Ansible runs from another WSL Ubuntu:

```powershell
powershell -NoProfile -File scripts\new-wsl-target.ps1
```

```bash
cd /mnt/d/Projects/receiptlens/deploy/ansible
ansible-playbook -i inventory.ini site.yml
```

For a real VM, change the host line in `deploy/ansible/inventory.ini`. Remove the WSL target with `wsl --unregister rl-target`, which deletes it and its data.

## Clients

- **Web dashboard** (`web/`): upload, list, corrections, monthly chart; plain HTML/CSS/JS under a strict CSP.
- **Flutter app** (`mobile/`): camera or gallery upload with on-device downscaling, live status while OCR runs, correction form. On Android it uses Cronet, so debug builds trust a locally installed dev CA. The same code is built for the web at `/m/` for iPhone. See [mobile/README.md](mobile/README.md).

## Evidence

| What | How | Result |
|---|---|---|
| Network isolation | `verify-week1.ps1` | Only 443 open; containers on `app`/`data` cannot reach the Internet ([log](docs/evidence/week1-verify.txt)) |
| Upload flow, least privilege | `verify-week2.ps1` | Magic-byte checks, 10 MB limit, API role cannot `DELETE` or `DROP` ([log](docs/evidence/week2-verify.txt)) |
| WAF, rate limit, failover | `verify-week3.ps1` | SQLi/XSS/path traversal → 403; uploads throttled → 429; killing a replica loses no request ([log](docs/evidence/week3-verify.txt)) |
| Load + autoscaling | k6 at 80 req/s | 9,074 requests, 0 errors, p95 10.72 ms; replicas 1 → 4 → 2 ([summary](docs/evidence/week3-load.md)) |
| OCR pipeline | `verify-week4.ps1` | Synthetic receipt read in ~5 s; malformed messages go to the dead-letter queue ([log](docs/evidence/week4-verify.txt)) |
| Images, lint, tests | Trivy, ruff, pytest | 0 fixable HIGH/CRITICAL; 33 Python tests + 6 Flutter tests pass ([log](docs/evidence/week5-verify.txt)) |
| Mobile | Android emulator | List, upload, OCR (87.000 đ), correction through the WAF all work |
| Rebuild | Ansible on an empty Ubuntu 24.04 | See [docs/evidence/week7-ansible.md](docs/evidence/week7-ansible.md) |
| OCR accuracy on 30 real receipts | `samples/` + `spike_ocr.py` | **Not measured yet** |

## Layout

| Folder | Contents |
|---|---|
| `compose.yaml` | Three networks, WAF edge, HAProxy, API replicas, OCR worker, Prometheus, Grafana, one-shot `migrate` job, Postgres, RabbitMQ, SeaweedFS |
| `api/` | FastAPI service, Alembic migrations, event publisher/consumer (`events.py`), least-privilege bootstrap, unit tests |
| `ocr_worker/` | RabbitMQ consumer with PaddleOCR, `receipt_parser.py`, `spike_ocr.py` to try your own photos |
| `edge/`, `lb/` | Nginx + ModSecurity config; HAProxy config |
| `observability/` | Prometheus scrape config, Grafana provisioning and dashboard |
| `autoscaler/` | Host-side autoscaler |
| `web/`, `mobile/` | Dashboard; Flutter app (Android + web) |
| `deploy/ansible/` | One-command rebuild playbook and inventory |
| `scripts/` | `init-env.ps1` (secrets + local TLS cert), `verify-week1..5.ps1`, `new-wsl-target.ps1` |
| `tests/` | Parser, worker and autoscaler tests; synthetic receipt fixture; k6 load test |
| `docs/` | Setup guide and evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `.github/workflows/` | CI: ruff, pytest, `flutter analyze` + tests, image build, Trivy gate, push to GHCR |

Plan and decisions (Vietnamese): [PLAN.md](PLAN.md). Setup guide: [docs/SETUP.md](docs/SETUP.md).
