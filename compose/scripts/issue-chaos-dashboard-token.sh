#!/usr/bin/env bash
set -euo pipefail

# This script is run only by the locked Semaphore template in the acer-mgmt
# project. The encrypted Semaphore environment injects the credential only for
# this task; the identity can create a token for one service account only.
: "${CHAOS_TOKEN_ISSUER_KUBECONFIG_B64:?missing Semaphore secret CHAOS_TOKEN_ISSUER_KUBECONFIG_B64}"
credential_dir="$(mktemp -d)"
trap 'rm -rf "$credential_dir"' EXIT
KUBECONFIG="${credential_dir}/issuer.kubeconfig"
export KUBECONFIG
umask 077
printf '%s' "$CHAOS_TOKEN_ISSUER_KUBECONFIG_B64" | base64 -d >"$KUBECONFIG"
unset CHAOS_TOKEN_ISSUER_KUBECONFIG_B64
CHAOS_DASHBOARD_TOKEN_DURATION="${CHAOS_DASHBOARD_TOKEN_DURATION:-10m}"

if [[ "$CHAOS_DASHBOARD_TOKEN_DURATION" != "10m" ]]; then
  echo 'Only the fixed 10m Dashboard token lifetime is permitted.' >&2
  exit 1
fi

if ! kubectl -n chaos-mesh auth can-i create serviceaccounts/chaos-dashboard-manager \
  --subresource=token --quiet; then
  echo 'The token issuer does not have the required restricted permission.' >&2
  exit 1
fi

echo 'Paste the following one-time token into the Chaos Mesh Dashboard within 10 minutes:'
kubectl -n chaos-mesh create token chaos-dashboard-manager --duration="${CHAOS_DASHBOARD_TOKEN_DURATION:-10m}"
