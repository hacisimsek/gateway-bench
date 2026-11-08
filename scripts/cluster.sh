#!/usr/bin/env bash
# Local GitOps cluster: kind + Argo CD. After this, everything comes from git (deploy/argocd/apps).
# Usage: scripts/cluster.sh up | down
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=gateway-bench
KIND=.bin/kind
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

case ${1:-up} in
down)
  $KIND delete cluster --name $NAME
  exit 0 ;;
up) ;;
*) echo "usage: $0 up|down" >&2; exit 2 ;;
esac

scripts/tools.sh >/dev/null
[[ -f .keys/sealed-secrets/tls.crt ]] || { echo "run scripts/seal-secrets.sh first" >&2; exit 1; }

if ! $KIND get clusters | grep -qx $NAME; then
  $KIND create cluster --config deploy/kind/cluster.yaml
fi
kubectl config use-context kind-$NAME >/dev/null

# The Sealed Secrets controller adopts an existing active key instead of generating one,
# so secrets sealed in git keep working on every new cluster.
kubectl -n kube-system create secret tls sealed-secrets-key \
  --cert=.keys/sealed-secrets/tls.crt --key=.keys/sealed-secrets/tls.key --dry-run=client -o yaml |
  kubectl label --local -f - sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml |
  kubectl apply -f - >/dev/null

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -k deploy/argocd/install --server-side --force-conflicts >/dev/null
for d in deploy/argocd-repo-server deploy/argocd-server deploy/argocd-applicationset-controller statefulset/argocd-application-controller; do
  kubectl -n argocd rollout status "$d" --timeout=5m >/dev/null
done
kubectl apply -f deploy/argocd/root.yaml >/dev/null

echo "Argo CD is syncing deploy/argocd/apps from GitHub. Watch it with:"
echo "  kubectl -n argocd get applications"
echo "Argo CD UI: kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443"
echo "  user admin, password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "Gateways: http://rust.<env>.localhost:8000 and http://java.<env>.localhost:8000 (env: test, preprod, prod)"
