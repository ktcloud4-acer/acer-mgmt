#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"; }

compose_file="${REPO_ROOT}/compose/stacks/cicd/semaphore/compose.yaml"
vault_agent="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"
issuer_bootstrap="${REPO_ROOT}/compose/scripts/bootstrap-vault-chaos-dashboard-issuer.sh"

assert_contains "$compose_file" 'SEMAPHORE_VAULT_ENV_FILE:-/home/mgmt-data/vault-agent/secrets/cicd/semaphore.env'
assert_contains "$compose_file" 'env_file:'
assert_not_contains "$compose_file" '${SEMAPHORE_DB_PASSWORD'
assert_not_contains "$compose_file" '${ADMIN_PASSWORD'
assert_not_contains "$compose_file" '${SEMAPHORE_ACCESS_KEY_ENCRYPTION'
assert_not_contains "$compose_file" '${SEMAPHORE_COOKIE_HASH'
assert_not_contains "$compose_file" '${SEMAPHORE_COOKIE_ENCRYPTION'

assert_contains "$vault_agent" 'destination = "/vault/secrets/cicd/semaphore.env"'
assert_contains "$vault_agent" 'SEMAPHORE_DB_PASS='
assert_contains "$vault_agent" 'SEMAPHORE_ADMIN_PASSWORD='
assert_contains "$vault_agent" 'kv/data/mgmt/chaos-dashboard-token-issuer'
assert_contains "$vault_agent" 'destination = "/vault/secrets/cicd/chaos-dashboard-token-issuer.env"'
assert_contains "$vault_agent" 'CHAOS_TOKEN_ISSUER_KUBECONFIG_B64='

assert_contains "$issuer_bootstrap" 'chaos-dashboard-token-issuer'
assert_contains "$issuer_bootstrap" 'kubernetes.io/service-account-token'
assert_contains "$issuer_bootstrap" 'mgmt/chaos-dashboard-token-issuer'
assert_contains "$issuer_bootstrap" 'vault kv put -mount=kv'
assert_not_contains "$issuer_bootstrap" 'cluster-admin'

echo 'SEMAPHORE_VAULT_ENV_VALIDATION=PASS'
