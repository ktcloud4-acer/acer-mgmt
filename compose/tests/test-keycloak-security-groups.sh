#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netbox_extra="$ROOT_DIR/compose/stacks/infra/netbox/config/extra.py"
bootstrap="$ROOT_DIR/compose/scripts/keycloak-security-groups-bootstrap.sh"

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

assert_contains "$netbox_extra" '"netbox-admin"'
assert_contains "$netbox_extra" '"netbox-editor"'
assert_contains "$netbox_extra" "def map_keycloak_groups"
assert_contains "$netbox_extra" "SOCIAL_AUTH_PIPELINE"
assert_contains "$bootstrap" 'ensure_group "netbox-admin"'
assert_contains "$bootstrap" 'ensure_group "netbox-editor"'
assert_contains "$bootstrap" 'ensure_group "argocd-admin"'

echo "keycloak security-group tests passed"
