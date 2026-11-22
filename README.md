# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Fully self-hosted with open source, rebuilding Google Cloud patterns (secure networking, load balancing, event-driven processing, ML-based OCR) at zero cost.

> Status: **Week 0, setup.** See [PLAN.md](PLAN.md) for scope, architecture and timeline, and [docs/SETUP.md](docs/SETUP.md) to get started.

## Layout

| Folder | Contents |
|---|---|
| `ocr_worker/` | `receipt_parser.py` (total-amount heuristics) and `spike_ocr.py` (week 0 PaddleOCR test); OCR worker from week 4 |
| `tests/` | Parser tests now; API tests, OCR fixtures and k6 load test later |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
| `api/`, `web/` | Placeholders for weeks 2 and 5 |

Other folders (`edge/`, `lb/`, `autoscaler/`, `mobile/`, `observability/`, `deploy/`) arrive in later weeks, see [PLAN.md](PLAN.md#5-cấu-trúc-repo).
