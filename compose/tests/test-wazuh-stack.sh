#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
wazuh_stack="$ROOT_DIR/compose/stacks/security/wazuh/compose.yaml"
agent_config="$ROOT_DIR/compose/stacks/security/wazuh/config/agent.conf"
bootstrap="$ROOT_DIR/compose/scripts/bootstrap-wazuh-stack.sh"
secrets_bootstrap="$ROOT_DIR/compose/scripts/bootstrap-wazuh-secrets.sh"
agent_installer="$ROOT_DIR/compose/scripts/install-wazuh-agent.sh"
vault_agent="$ROOT_DIR/compose/stacks/security/vault-agent/config/agent.hcl"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_contains "$wazuh_stack" "wazuh-manager"
assert_contains "$wazuh_stack" "wazuh-indexer"
assert_contains "$wazuh_stack" "wazuh-dashboard"
assert_contains "$wazuh_stack" "WAZUH_INDEXER_PASSWORD"
assert_contains "$wazuh_stack" '${DATA_ROOT:-/home/mgmt-data}/wazuh/logs'
assert_contains "$agent_config" "/home/mgmt-data/vault"
assert_contains "$agent_config" "<ignore>"
assert_contains "$bootstrap" "wazuh/wazuh-certs-generator:0.0.4"
assert_contains "$bootstrap" "v4.14.6"
assert_contains "$bootstrap" "internal_users.yml"
assert_contains "$bootstrap" 'chown -R 1000:1000 "$WAZUH_ROOT/indexer"'
assert_contains "$secrets_bootstrap" "openssl rand -hex 32"
assert_contains "$secrets_bootstrap" "vault kv put -mount=kv mgmt/wazuh -"
assert_contains "$secrets_bootstrap" "-field=indexer_password mgmt/wazuh"
assert_contains "$secrets_bootstrap" 'docker exec -i "$VAULT_CONTAINER" sh -s'
if grep -Fq 'docker cp' "$secrets_bootstrap"; then
  fail "Wazuh secret bootstrap must not write into Vault's read-only rootfs"
fi
assert_contains "$agent_installer" "WAZUH_REGISTRATION_PASSWORD"
assert_contains "$agent_installer" "packages.wazuh.com/4.x/yum/"
assert_contains "$vault_agent" 'kv/data/mgmt/wazuh'
assert_contains "$vault_agent" 'destination = "/vault/secrets/security/wazuh.env"'
assert_contains "$vault_agent" 'destination = "/vault/secrets/security/wazuh-agent.env"'

echo "wazuh stack tests passed"
