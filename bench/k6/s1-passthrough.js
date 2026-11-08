// S1 — Passthrough: fixed request rate through the gateway to a 0 ms upstream.
// Measures pure gateway overhead. Run via bench/run-s1.sh.
import http from 'k6/http';

const RATE = Number(__ENV.RATE || 1000);

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    s1: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: Math.max(50, RATE / 20),
      maxVUs: 2000,
    },
  },
};

// With TOKEN set every request carries the same valid JWT; both gateways verify it every time.
const params = __ENV.TOKEN ? { headers: { Authorization: `Bearer ${__ENV.TOKEN}` } } : {};

export default function () {
  http.get(`${__ENV.TARGET}/users/42`, params);
}

export function handleSummary(data) {
  return __ENV.OUT ? { [__ENV.OUT]: JSON.stringify(data) } : {};
}
