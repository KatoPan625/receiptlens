"""Metrics-driven autoscaler for the API replicas (the "managed instance group" role).

Runs on the host, not in a container: it scales with `docker compose`, so no container
needs the Docker socket (which would be root-equivalent). It reads Prometheus through
`docker compose exec`, so Prometheus stays unpublished on the internal network.

Usage (from the repo root):
    python autoscaler/autoscale.py                      # loop forever
    python autoscaler/autoscale.py --once --dry-run     # one decision, change nothing
"""
import argparse
import csv
import json
import math
import subprocess
import time
import urllib.parse
from datetime import datetime
from pathlib import Path

QUERY = 'sum(rate(haproxy_backend_http_requests_total{proxy="api"}[30s]))'


def desired_replicas(rps: float, current: int, target_rps: float, lo: int, hi: int,
                     below_since: float | None, now: float, cooldown: float) -> tuple[int, float | None]:
    """Return (replicas to run, timestamp since load has been low enough to shrink).

    Scale up at once. Scale down only when one replica fewer would still have 20% headroom
    (hysteresis) and load stayed that low for `cooldown` seconds, one replica at a time,
    so a short dip or a rising ramp does not cause flapping.
    """
    want = max(lo, min(hi, math.ceil(rps / target_rps) if rps > 0 else lo))
    if want > current:
        return want, None
    if want < current and rps <= 0.8 * target_rps * (current - 1):
        since = below_since if below_since is not None else now
        return (current - 1, None) if now - since >= cooldown else (current, since)
    return current, None


def compose(*args: str) -> str:
    return subprocess.run(["docker", "compose", *args], check=True, capture_output=True, text=True).stdout


def current_rps() -> float:
    url = "http://localhost:9090/api/v1/query?query=" + urllib.parse.quote(QUERY)
    result = json.loads(compose("exec", "-T", "prometheus", "wget", "-qO-", url))["data"]["result"]
    return float(result[0]["value"][1]) if result else 0.0


def current_replicas() -> int:
    return len([line for line in compose("ps", "api", "-q").splitlines() if line.strip()])


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--target-rps", type=float, default=25, help="requests/s one replica should handle")
    p.add_argument("--min", type=int, default=1)
    p.add_argument("--max", type=int, default=4, help="HAProxy has 4 server slots")
    p.add_argument("--interval", type=float, default=10)
    p.add_argument("--cooldown", type=float, default=60)
    p.add_argument("--log", type=Path, help="append decisions to this CSV")
    p.add_argument("--once", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args()

    below_since = None
    while True:
        now = time.time()
        try:
            rps, current = current_rps(), current_replicas()
        except (subprocess.CalledProcessError, KeyError, ValueError, IndexError) as e:
            print(f"{datetime.now():%H:%M:%S} cannot read state, skipping: {e}")
        else:
            want, below_since = desired_replicas(rps, current, a.target_rps, a.min, a.max, below_since, now, a.cooldown)
            action = "keep" if want == current else f"scale {current}->{want}"
            print(f"{datetime.now():%H:%M:%S} rps={rps:7.1f} replicas={current} {action}", flush=True)
            if want != current and not a.dry_run:
                compose("up", "-d", "--no-deps", "--no-recreate", "--scale", f"api={want}", "api")
            if a.log:
                new = not a.log.exists()
                with a.log.open("a", newline="") as f:
                    w = csv.writer(f)
                    if new:
                        w.writerow(["time", "rps", "replicas", "desired"])
                    w.writerow([f"{datetime.now():%H:%M:%S}", f"{rps:.1f}", current, want])
        if a.once:
            break
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
