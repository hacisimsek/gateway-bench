#!/usr/bin/env bash
# Cold start: time from `docker start` until the gateway's readiness endpoint answers 200.
# Usage: bench/cold-start.sh [runs]   (stack must be up: make up)
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=${1:-5}
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

for gw in rust:9091/healthz java:9092/actuator/health/readiness; do
  name=${gw%%:*}; url="localhost:${gw#*:}"
  times=()
  for _ in $(seq "$RUNS"); do
    docker compose stop "gateway-$name" >/dev/null 2>&1
    start=$(now_ms)
    docker compose start "gateway-$name" >/dev/null 2>&1
    until curl -fs -o /dev/null "$url" 2>/dev/null; do sleep 0.02; done
    times+=($(( $(now_ms) - start )))
  done
  median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n "$(( (RUNS + 1) / 2 ))p")
  size=$(docker image inspect "gateway-bench-gateway-$name" -f '{{.Size}}' | awk '{printf "%.0f", $1 / 1000000}')
  printf '%-5s image %4s MB   ready in %5s ms (median of %s: %s)\n' "$name" "$size" "$median" "$RUNS" "${times[*]}"
done
