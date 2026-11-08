#!/usr/bin/env bash
# Pinned cluster tools into .bin/ (gitignored), checksums verified. Nothing is installed system-wide.
# kubectl is expected on PATH (Docker Desktop ships it).
set -euo pipefail
cd "$(dirname "$0")/.."

KIND_VERSION=v0.33.0
KUBESEAL_VERSION=0.41.2

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64; [[ $arch == aarch64 ]] && arch=arm64
mkdir -p .bin
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [[ ! -x .bin/kind ]] || ! .bin/kind version | grep -q "$KIND_VERSION"; then
  url=https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-$os-$arch
  curl -fsSL -o "$tmp/kind" "$url"
  want=$(curl -fsSL "$url.sha256sum" | cut -d' ' -f1)
  [[ $(sha256 "$tmp/kind") == "$want" ]] || { echo "kind: checksum mismatch" >&2; exit 1; }
  install -m 0755 "$tmp/kind" .bin/kind
fi

if [[ ! -x .bin/kubeseal ]] || ! .bin/kubeseal --version | grep -q "$KUBESEAL_VERSION"; then
  base=https://github.com/bitnami-labs/sealed-secrets/releases/download/v$KUBESEAL_VERSION
  file=kubeseal-$KUBESEAL_VERSION-$os-$arch.tar.gz
  curl -fsSL -o "$tmp/$file" "$base/$file"
  want=$(curl -fsSL "$base/sealed-secrets_${KUBESEAL_VERSION}_checksums.txt" | grep " $file\$" | cut -d' ' -f1)
  [[ -n $want && $(sha256 "$tmp/$file") == "$want" ]] || { echo "kubeseal: checksum mismatch" >&2; exit 1; }
  tar -xzf "$tmp/$file" -C "$tmp" kubeseal
  install -m 0755 "$tmp/kubeseal" .bin/kubeseal
fi

.bin/kind version
.bin/kubeseal --version
