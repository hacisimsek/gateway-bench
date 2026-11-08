#!/usr/bin/env bash
# S1 baseline: direct-to-upstream, gateway-rust, gateway-java at the same request rates.
# Usage: bench/run-s1.sh [runs]   (stack must be up: make up)
#   ONLY="java" LABEL=java-g1 bench/run-s1.sh 3   # one target, results folder suffixed with the label
#   TOKEN=$(scripts/mint-jwt.sh 7200) ...          # send a valid JWT with every request
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=${1:-3}
RATES=(1000 5000 10000 20000)
WARMUP_RATE=5000
ALL_TARGETS=("direct:http://upstream:9000:upstream" "rust:http://gateway-rust:8080:gateway-rust" "java:http://gateway-java:8080:gateway-java")
TARGETS=()
for t in "${ALL_TARGETS[@]}"; do [[ -z "${ONLY:-}" || " $ONLY " == *" ${t%%:*} "* ]] && TARGETS+=("$t"); done
OUT=bench/results/s1/$(date +%Y%m%d-%H%M%S)${LABEL:+-$LABEL}
mkdir -p "$OUT"

{
  echo "date: $(date -u +%FT%TZ)"
  echo "host: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), docker cpus=$(docker info -f '{{.NCPU}}') mem=$(docker info -f '{{.MemTotal}}')"
  echo "commit: $(git rev-parse --short HEAD)$(git diff --quiet || echo '-dirty')"
  echo "limits: gateways 2 cpu/512m, upstream 4 cpu, k6 4 cpu"
  echo "jwt: $([[ -n ${TOKEN:-} ]] && echo 'yes (RS256, verified on every request)' || echo no)"
  echo "rate limit:$(docker inspect gateway-bench-gateway-rust-1 -f '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^RATE_LIMIT_/ /p' | tr '\n' ' ')"
  echo "java options:$(docker inspect gateway-bench-gateway-java-1 -f '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^JAVA_TOOL_OPTIONS=//p')"
} > "$OUT/env.txt"

# Redis CPU is sampled too when it runs (phase 3+): the rate limiter's cost lands there.
REDIS=gateway-bench-redis-1
[[ $(docker inspect -f '{{.State.Running}}' $REDIS 2>/dev/null) == true ]] || REDIS=

k6() { docker compose --profile bench run --rm -q k6 run -q ${TOKEN:+-e TOKEN=$TOKEN} "$@" /bench/k6/s1-passthrough.js >/dev/null; }

for run in $(seq 1 "$RUNS"); do
  for t in "${TARGETS[@]}"; do
    name=${t%%:*}; rest=${t#*:}; url=${rest%:*}; container=gateway-bench-${rest##*:}-1
    echo "run $run · $name · warm-up"
    k6 -e TARGET="$url" -e RATE=$WARMUP_RATE -e DURATION=20s
    for rate in "${RATES[@]}"; do
      echo "run $run · $name · $rate rps"
      stats="$OUT/$name-$rate-run$run.stats"
      ( while :; do docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$container" >> "$stats"; done ) &
      samplers=($!)
      if [[ -n $REDIS ]]; then
        ( while :; do docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$REDIS" >> "${stats%.stats}.redis"; done ) &
        samplers+=($!)
      fi
      k6 -e TARGET="$url" -e RATE="$rate" -e OUT="/bench/results/s1/$(basename "$OUT")/$name-$rate-run$run.json"
      kill "${samplers[@]}"; wait "${samplers[@]}" 2>/dev/null || true
    done
  done
done

python3 -I bench/summarize.py "$OUT"
