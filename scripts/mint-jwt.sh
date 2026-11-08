#!/usr/bin/env bash
# Mint an RS256 JWT with openssl, signed by .keys/private.pem (created by `make keys`).
# Usage: scripts/mint-jwt.sh [ttl_seconds] [issuer] [subject]
#   negative ttl -> already expired token (for negative tests)
set -euo pipefail
cd "$(dirname "$0")/.."

TTL=${1:-86400}
ISS=${2:-gateway-bench}
SUB=${3:-bench-user}
NOW=$(date +%s)
# An expired token was still issued before it expired (Spring rejects iat > exp as malformed).
IAT=$(( TTL > 0 ? NOW : NOW + TTL - 3600 ))

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"sub":"%s","iss":"%s","iat":%d,"exp":%d}' "$SUB" "$ISS" "$IAT" $((NOW + TTL)) | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign .keys/private.pem -binary | b64url)
echo "$header.$payload.$signature"
