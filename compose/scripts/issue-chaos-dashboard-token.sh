#!/usr/bin/env bash
set -euo pipefail

# This script is run only by the locked Semaphore template in the acer-mgmt
# project. The mounted identity has a single RBAC permission: create a token
# for chaos-dashboard-manager in the chaos-mesh namespace.
KUBECONFIG="${KUBECONFIG:-/run/secrets/chaos-dashboard-token-issuer.kubeconfig}"
export KUBECONFIG
CHAOS_DASHBOARD_TOKEN_DURATION="${CHAOS_DASHBOARD_TOKEN_DURATION:-10m}"

if [[ "$CHAOS_DASHBOARD_TOKEN_DURATION" != "10m" ]]; then
  echo 'Only the fixed 10m Dashboard token lifetime is permitted.' >&2
  exit 1
fi

if [[ ! -r "$KUBECONFIG" ]]; then
  echo "The token-issuer kubeconfig is unavailable: $KUBECONFIG" >&2
  exit 1
fi

if ! kubectl -n chaos-mesh auth can-i create serviceaccounts/token \
  --resource-name=chaos-dashboard-manager --quiet; then
  echo 'The token issuer does not have the required restricted permission.' >&2
  exit 1
fi

echo 'Paste the following one-time token into the Chaos Mesh Dashboard within 10 minutes:'
kubectl -n chaos-mesh create token chaos-dashboard-manager --duration="${CHAOS_DASHBOARD_TOKEN_DURATION:-10m}"
