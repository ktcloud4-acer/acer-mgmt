#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${KUBECONFIG:?KUBECONFIG must point to the mgmt k3d cluster}"

cleanup() {
  kubectl delete application.argoproj.io argocd-smoke -n argocd \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace argocd-smoke \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
kubectl apply -f "${ROOT}/tests/smoke-application.yaml"

kubectl wait application.argoproj.io/argocd-smoke -n argocd \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl wait application.argoproj.io/argocd-smoke -n argocd \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
kubectl rollout status deployment/guestbook-ui -n argocd-smoke --timeout=180s

echo "Argo CD smoke test 성공"
kubectl get application.argoproj.io/argocd-smoke -n argocd
kubectl get deployment,pod,service -n argocd-smoke
