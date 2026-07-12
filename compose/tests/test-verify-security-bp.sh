#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verify_script="$ROOT_DIR/compose/scripts/verify-security-bp.sh"

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

assert_contains "$verify_script" "tctl apps ls"
assert_contains "$verify_script" "vault audit list"
assert_contains "$verify_script" '$DATA_ROOT/vault-agent/secrets'
assert_contains "$verify_script" 'VAULT_ADDR=https://127.0.0.1:8200'
assert_contains "$verify_script" "Keycloak event configuration"
assert_contains "$verify_script" "wazuh-manager"
assert_contains "$verify_script" "Teleport application certificate coverage"

echo "security BP verifier tests passed"
