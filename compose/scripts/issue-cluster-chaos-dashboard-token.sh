#!/usr/bin/env bash
set -euo pipefail

# This script is executed by a cluster-specific Semaphore template.  The
# template fixes both the cluster name and its restricted issuer credential;
# callers cannot supply a kubeconfig or request a longer-lived token.
: "${CHAOS_DASHBOARD_CLUSTER:?missing fixed Dashboard cluster}"
: "${CHAOS_TOKEN_ISSUER_KUBECONFIG_B64:?missing Dashboard issuer credential}"

case "$CHAOS_DASHBOARD_CLUSTER" in
  mgmt|nmg|ggg|khb|ljw|oje) ;;
  *) echo 'Unsupported Chaos Dashboard cluster.' >&2; exit 1 ;;
esac

credential_dir="$(mktemp -d)"
trap 'rm -rf "$credential_dir"' EXIT
umask 077
export KUBECONFIG="$credential_dir/issuer.kubeconfig"
printf '%s' "$CHAOS_TOKEN_ISSUER_KUBECONFIG_B64" | base64 -d >"$KUBECONFIG"
unset CHAOS_TOKEN_ISSUER_KUBECONFIG_B64

if ! kubectl -n chaos-mesh auth can-i create serviceaccounts/chaos-dashboard-manager \
  --subresource=token --quiet; then
  echo 'The restricted Dashboard token issuer permission is unavailable.' >&2
  exit 1
fi

echo "Paste the following one-time token into the $CHAOS_DASHBOARD_CLUSTER Chaos Mesh Dashboard within 10 minutes:"
kubectl -n chaos-mesh create token chaos-dashboard-manager --duration=10m
