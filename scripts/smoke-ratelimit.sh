#!/usr/bin/env bash
# Rate limit checks against both gateways. Needs the stack's default limits (10/s, burst 20).
set -euo pipefail
cd "$(dirname "$0")/.."

BURST=20
RATE=10
fail=0
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
# Tokens that may refill while requests are in flight (slow CI runners take longer).
refill_since() { echo $(( ($(now_ms) - $1) * RATE / 1000 + 1 )); }
check() { # check <name> <ok?> <detail>
  local mark=ok; $2 || { mark=FAIL; fail=1; }
  printf '%-44s %-26s %s\n' "$1" "$3" "$mark"
}
token() { scripts/mint-jwt.sh 600 gateway-bench "$1"; }
# fire <port> <token> <n>: n requests in parallel, prints one status code per line
fire() {
  local args=()
  for _ in $(seq "$3"); do args+=(-o /dev/null "localhost:$1/users/1"); done
  curl -s --parallel --parallel-max 50 -H "Authorization: Bearer $2" -w '%{http_code}\n' "${args[@]}"
}
count() { grep -c "^$1$" || true; }

for gw in rust:8081 java:8082; do
  name=${gw%%:*}; port=${gw#*:}
  t=$(token "smoke-$name-$RANDOM$RANDOM")
  t0=$(now_ms)
  codes=$(fire "$port" "$t" 30)
  extra=$(refill_since "$t0")
  ok=$(count 200 <<< "$codes"); limited=$(count 429 <<< "$codes")
  check "$name: 30 parallel, burst $BURST" "$( ((ok >= BURST && ok <= BURST + extra && ok + limited == 30)) && echo true || echo false)" "200=$ok 429=$limited"
  retry=$(curl -s -D - -o /dev/null -H "Authorization: Bearer $t" "localhost:$port/users/1" | tr -d '\r' | grep -i '^retry-after:' || true)
  check "$name: 429 carries Retry-After" "$([[ -n $retry ]] && echo true || echo false)" "${retry:-missing}"
done

# One subject, both gateways: they must drain the same bucket in Redis.
t=$(token "smoke-shared-$RANDOM$RANDOM")
t0=$(now_ms)
rust_ok=$(fire 8081 "$t" $BURST | count 200)
java_ok=$(fire 8082 "$t" 10 | count 200)
extra=$(refill_since "$t0")
check "shared bucket: $BURST via rust, then 10 via java" "$( ((rust_ok == BURST && java_ok <= extra)) && echo true || echo false)" "rust 200=$rust_ok java 200=$java_ok"

# Fail open: with Redis gone, requests pass unlimited instead of failing.
trap 'docker compose start redis >/dev/null 2>&1' EXIT
docker compose stop redis >/dev/null 2>&1
t=$(token "smoke-down-$RANDOM")
for gw in rust:8081 java:8082; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" "localhost:${gw#*:}/users/1")
  check "${gw%%:*}: Redis stopped -> fail open" "$([[ $code == 200 ]] && echo true || echo false)" "status=$code"
done
exit $fail
