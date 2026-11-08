#!/usr/bin/env bash
# Keys and secrets for the kind environments. Everything private stays in .keys/ (gitignored);
# only public keys and *sealed* secrets go into deploy/.
#
# - Sealed Secrets key pair: made here instead of by the controller, so secrets can be sealed
#   offline and stay valid when the cluster is recreated (scripts/cluster.sh restores the key).
# - One JWT key pair per environment: a token minted for test is useless in prod.
# - One Redis password per environment, sealed for its namespace.
set -euo pipefail
cd "$(dirname "$0")/.."

ENVS=(test preprod prod)
SEAL_KEY=.keys/sealed-secrets/tls.key
SEAL_CERT=.keys/sealed-secrets/tls.crt

if [[ ! -f $SEAL_CERT ]]; then
  mkdir -p .keys/sealed-secrets
  openssl req -x509 -days 3650 -nodes -newkey rsa:4096 -keyout "$SEAL_KEY" -out "$SEAL_CERT" \
    -subj "/CN=sealed-secret/O=sealed-secret" 2>/dev/null
  echo "created Sealed Secrets key pair in .keys/sealed-secrets/"
fi

for env in "${ENVS[@]}"; do
  overlay=deploy/overlays/$env
  if [[ ! -f .keys/$env/private.pem ]]; then
    mkdir -p ".keys/$env"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ".keys/$env/private.pem" 2>/dev/null
    openssl pkey -in ".keys/$env/private.pem" -pubout -out ".keys/$env/public.pem"
  fi
  cp ".keys/$env/public.pem" "$overlay/jwt-public.pem"

  # Sealing is randomised, so only (re)seal when asked or missing, to keep git diffs meaningful.
  if [[ ! -f $overlay/redis-auth.sealed.yaml || ${RESEAL:-} == 1 ]]; then
    kubectl create secret generic redis-auth --namespace "gateway-$env" \
      --from-literal=password="$(openssl rand -hex 24)" --dry-run=client -o yaml |
      .bin/kubeseal --cert "$SEAL_CERT" --format yaml > "$overlay/redis-auth.sealed.yaml"
    echo "sealed redis-auth for gateway-$env"
  fi
done
