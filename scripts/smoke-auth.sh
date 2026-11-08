#!/usr/bin/env bash
# Same JWT checks against both gateways; they must agree on every case.
set -euo pipefail
cd "$(dirname "$0")/.."

# Compose by default; for a kind environment, e.g.
#   RUST_URL=http://rust.test.localhost:8000 JAVA_URL=http://java.test.localhost:8000 JWT_KEY=.keys/test/private.pem
RUST_URL=${RUST_URL:-http://localhost:8081}
JAVA_URL=${JAVA_URL:-http://localhost:8082}
mint() { scripts/mint-jwt.sh "$@"; }
valid=$(mint 3600)
in_skew=$(mint -30)            # expired 30 s ago: inside the 60 s clock-skew allowance
expired=$(mint -3600)
wrong_issuer=$(mint 3600 someone-else)
# Change a character in the middle of the signature. Not the last one: in base64url its low
# bits are padding, so some edits decode to the same bytes (Java accepts those, Rust rejects them).
sig=${valid##*.}; c=${sig:10:1}
tampered="${valid%.*}.${sig:0:10}$([[ $c == A ]] && echo B || echo A)${sig:11}"
other_key=$( (openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null > /tmp/other.pem) &&
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') &&
  p=$(printf '{"sub":"x","iss":"gateway-bench","exp":%d}' $(( $(date +%s) + 3600 )) | openssl base64 -A | tr '+/' '-_' | tr -d '=') &&
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign /tmp/other.pem -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=') &&
  echo "$h.$p.$s")

# name | expected status | Authorization header
cases=(
  "no token|401|"
  "valid|200|Bearer $valid"
  "expired 30 s ago (within skew)|200|Bearer $in_skew"
  "expired 1 h ago|401|Bearer $expired"
  "wrong issuer|401|Bearer $wrong_issuer"
  "tampered signature|401|Bearer $tampered"
  "signed by another key|401|Bearer $other_key"
  "Basic auth|401|Basic dXNlcjpwYXNz"
)

fail=0
printf '%-32s %6s %6s %6s\n' case expect rust java
for c in "${cases[@]}"; do
  IFS='|' read -r name expect auth <<< "$c"
  got=()
  for url in "$RUST_URL" "$JAVA_URL"; do
    got+=("$(curl -s -o /dev/null -w '%{http_code}' ${auth:+-H "Authorization: $auth"} "$url/users/1")")
  done
  mark=ok; [[ ${got[0]} == "$expect" && ${got[1]} == "$expect" ]] || { mark=FAIL; fail=1; }
  printf '%-32s %6s %6s %6s  %s\n' "$name" "$expect" "${got[0]}" "${got[1]}" "$mark"
done
exit $fail
