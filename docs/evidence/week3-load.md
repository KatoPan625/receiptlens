# Week 3 — load test and autoscaling (2026-11-22)

Full path under test: **edge** (TLS + ModSecurity/OWASP CRS + rate limit) → **HAProxy** → **API replicas** → Postgres.
Load: `tests/load/k6.js`, ramping 5 → 80 req/s over 1 min, hold 1 min, drop to 5 req/s for 2 min.
Autoscaler: `autoscaler/autoscale.py --interval 5 --cooldown 30`, target 25 req/s per replica, 1–4 replicas.
Machine: Windows 11, Docker Desktop (WSL 2), 12 CPUs, 16 GB RAM.

## Result (`week3-k6-summary.json`)

| Metric | Threshold | Result |
|---|---|---|
| Requests | | 9,074 |
| Failed requests | < 1% | **0%** |
| p95 latency | < 300 ms | **10.72 ms** |

## Scaling decisions (`week3-autoscale.csv`)

| Time | req/s | Replicas | Action |
|---|---|---|---|
| 20:58:22 | 31.0 | 1 | scale up to 2 |
| 20:58:45 | 62.2 | 2 | scale up to 3 |
| 20:59:03 | 76.6 | 3 | scale up to 4 |
| 20:59:15 – 21:00:24 | 80 → 28.6 | 4 | hold |
| 21:00:47 | 5.0 | 4 | scale down to 3 (after 30 s cooldown) |
| 21:01:28 | 5.0 | 3 | scale down to 2 |

## What the first run taught

The first run (before hysteresis) failed the p95 threshold (322.83 ms) and had 42 failed requests (0.46%).
The autoscaler had scaled **down** from 2 to 1 at 22.5 req/s while load was still rising, because the
cooldown clock started during the idle period before the test. One replica then carried the ramp until
new replicas booted. Fix: scale down only if one replica fewer still keeps 20% headroom
(`rps <= 0.8 × target × (replicas − 1)`), covered by `tests/test_autoscale.py`. A follow-up steady
80 req/s run had 0 errors and p95 10.27 ms; the full ramp above is the re-run after the fix.
