#!/usr/bin/env bash
# Graceful shutdown: SIGTERM arrives while a slow request is in flight. The request must still
# finish with 200 and the gateway must exit on its own, well before Docker's kill timeout.
set -euo pipefail
cd "$(dirname "$0")/.."

DELAY_MS=3000   # upstream holds the request this long (x-delay-ms header)
KILL_AFTER=20   # docker sends SIGKILL after this many seconds
fail=0
token=$(scripts/mint-jwt.sh 600 gateway-bench "shutdown-$RANDOM")

for gw in rust:8081:9091/healthz java:8082:9092/actuator/health/readiness; do
  IFS=: read -r name port health <<< "$gw"
  out=$(mktemp)
  curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H "x-delay-ms: $DELAY_MS" \
    "localhost:$port/users/1" > "$out" &
  req=$!
  sleep 0.5
  start=$(date +%s)
  docker compose stop -t $KILL_AFTER "gateway-$name" >/dev/null 2>&1   # SIGTERM, waits for exit
  took=$(( $(date +%s) - start ))
  wait $req || true
  code=$(cat "$out"); rm -f "$out"
  mark=ok; [[ $code == 200 && $took -lt $KILL_AFTER ]] || { mark=FAIL; fail=1; }
  printf '%-5s in-flight request: %s, stopped after %ss (kill at %ss)  %s\n' "$name" "$code" "$took" "$KILL_AFTER" "$mark"

  docker compose start "gateway-$name" >/dev/null 2>&1
  for _ in $(seq 60); do curl -fs "localhost:$health" >/dev/null 2>&1 && break; sleep 0.5; done
done
exit $fail
