// Load test through the full path: edge (TLS + WAF + rate limit) -> HAProxy -> API -> Postgres.
// Run from the repo root:  k6 run tests/load/k6.js
// Rises to 80 req/s, holds, then drops back so the autoscaler can be seen scaling up and down.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

// Failures broken down by k6 error code (e.g. 1211 = timeout) or HTTP status, for diagnosis.
const failures = new Counter('failures');

const BASE = __ENV.BASE || 'https://localhost/api';

export const options = {
  insecureSkipTLSVerify: true, // local mkcert certificate; never use against a real site
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: [
        { target: 80, duration: '1m' },  // ramp up
        { target: 80, duration: '1m' },  // hold
        { target: 5, duration: '30s' },  // drop
        { target: 5, duration: '1m30s' }, // stay low: scale-down needs the cooldown to pass
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<300'],
  },
};

export default function () {
  const r = http.get(`${BASE}/receipts?limit=20`, { tags: { name: 'list' } });
  if (!check(r, { 'status 200': (res) => res.status === 200 })) {
    failures.add(1, { status: String(r.status), error_code: String(r.error_code) });
    console.warn(`t=${new Date().toISOString()} status=${r.status} error_code=${r.error_code} ${r.error}`);
  }
}
