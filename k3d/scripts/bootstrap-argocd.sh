#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${KUBECONFIG:?KUBECONFIG must point to the mgmt k3d cluster}"

kubectl apply --server-side --force-conflicts -k "${ROOT}/bootstrap/argocd"

kubectl wait --for=condition=Established \
  crd/applications.argoproj.io \
  crd/applicationsets.argoproj.io \
  crd/appprojects.argoproj.io \
  --timeout=180s

for workload in \
  deployment/argocd-applicationset-controller \
  deployment/argocd-dex-server \
  deployment/argocd-notifications-controller \
  deployment/argocd-redis \
  deployment/argocd-repo-server \
  deployment/argocd-server \
  statefulset/argocd-application-controller; do
  kubectl rollout status -n argocd "${workload}" --timeout=300s
done

echo "Argo CD bootstrap 완료"
kubectl get pods,svc,ingress -n argocd
