# ReceiptLens

Snap a receipt; ReceiptLens reads the total, date and merchant and turns it into monthly spending stats.
Built on Google Cloud to apply four Google Cloud skill badges in one working system.

> Status: **Week 0, setup.** See [PLAN.md](PLAN.md) for scope, architecture and timeline, and [docs/SETUP.md](docs/SETUP.md) to get started.

## Layout

| Folder | Contents |
|---|---|
| `infra/` | Terraform for network, compute, load balancer, data and event pipeline |
| `api/` | FastAPI service and Pub/Sub consumer (week 2) |
| `ocr_worker/` | Cloud Run function and receipt parser (week 4); `receipt_parser.py` + `spike_ocr.py` for week 0 |
| `web/` | Static dashboard (week 5) |
| `tests/` | Parser tests, OCR text fixtures, k6 load test |
| `docs/` | Setup guide, diagrams, evidence |
| `samples/` | Your real receipt photos. **Git-ignored**: they contain personal data |
