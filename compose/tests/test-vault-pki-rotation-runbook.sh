#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runbook="$root/docs/runbooks/vault-pki-operations.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
require() { grep -Fq -- "$1" "$runbook" || fail "rotation runbook missing: $1"; }

for expected in \
  'ARGOCD_REPO="$HOME/acer-argocd"' \
  'security/cert-manager/${team}/clusterissuer-next.yaml' \
  'security/cert-manager/base/root-ca.crt' \
  'security/chaos-mesh-certificates/base/rotation-canary.yaml' \
  'security/chaos-mesh-certificates/base/certificates.yaml' \
  'apps/vault-pki.yaml' \
  'apps/chaos-mesh-certificates.yaml' \
  'git -C "$ARGOCD_REPO" switch -c' \
  'git -C "$ARGOCD_REPO" diff --check' \
  'git -C "$ARGOCD_REPO" push -u origin' \
  'argocd app sync "vault-pki-${team}"' \
  'argocd app sync "chaos-mesh-certificates-${team}"' \
  'clusterissuer/vault-internal-next' \
  'certificate/rotation-canary' \
  'MIN_OVERLAP_SECONDS=$((LEAF_TTL_SECONDS + ROLLBACK_WINDOW_SECONDS))' \
  '[[ "$ELAPSED_OVERLAP_SECONDS" -ge "$MIN_OVERLAP_SECONDS" ]]' \
  'openssl verify -CAfile "$NEW_ROOT" -untrusted "$NEW_INTERMEDIATE"' \
  'openssl verify -CAfile "$OLD_ROOT" -untrusted "$OLD_INTERMEDIATE"' \
  'OLD_ISSUED_LEAVES=0' \
  'RETIREMENT APPROVED' \
  'git -C "$ARGOCD_REPO" revert' \
  'pki_int_newroot/intermediate/generate/internal' \
  'pki_int_newroot/intermediate/set-signed' \
  'vault-internal-newroot' \
  'Root dual trust bundle'; do
  require "$expected"
done

if grep -Eq '^[[:space:]]*kubectl[[:space:]]+(apply|patch|edit|replace|delete)' "$runbook"; then
  fail 'rotation mutates production Kubernetes imperatively instead of GitOps'
fi
if grep -Eq '^[[:space:]]*argocd[[:space:]]+app[[:space:]]+set' "$runbook"; then
  fail 'rotation changes Argo desired state imperatively'
fi

# Mechanically prove the documented overlap is leaf TTL plus rollback window.
LEAF_TTL_SECONDS=$((90 * 24 * 60 * 60))
ROLLBACK_WINDOW_SECONDS=$((30 * 24 * 60 * 60))
MIN_OVERLAP_SECONDS=$((LEAF_TTL_SECONDS + ROLLBACK_WINDOW_SECONDS))
[[ "$MIN_OVERLAP_SECONDS" -eq 10368000 ]] || fail 'minimum overlap is not 120 days'

echo 'VAULT_PKI_ROTATION_RUNBOOK=PASS'
