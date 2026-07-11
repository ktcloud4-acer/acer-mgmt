#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

import_script="${REPO_ROOT}/compose/scripts/import-argocd-cluster-secrets.sh"
bootstrap_script="${REPO_ROOT}/compose/scripts/bootstrap-vault-mgmt-eso.sh"

for script in "$import_script" "$bootstrap_script"; do
  [[ -f "$script" ]] || fail "expected script is missing: $script"
done

assert_contains "$import_script" 'argocd.argoproj.io/secret-type'
assert_contains "$import_script" '== cluster'
assert_contains "$import_script" 'kv/mgmt/argocd/clusters/${cluster}'
assert_contains "$import_script" 'ggg khb ljw nmg oje'
assert_contains "$import_script" 'umask 077'
assert_not_contains "$import_script" 'echo "$token"'
assert_not_contains "$import_script" 'echo "$config"'

assert_contains "$bootstrap_script" 'auth enable -path=kubernetes-mgmt kubernetes'
assert_contains "$bootstrap_script" 'argocd-cluster-reader'
assert_contains "$bootstrap_script" 'external-secrets'
assert_contains "$bootstrap_script" 'vault-auth-token'
assert_contains "$bootstrap_script" 'umask 077'

echo 'ARGOCD_CLUSTER_VAULT_SYNC_VALIDATION=PASS'
