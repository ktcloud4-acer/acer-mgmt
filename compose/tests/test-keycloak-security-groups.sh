#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netbox_extra="$ROOT_DIR/compose/stacks/infra/netbox/config/extra.py"
bootstrap="$ROOT_DIR/compose/scripts/keycloak-security-groups-bootstrap.sh"
oauth_bootstrap="$ROOT_DIR/compose/scripts/keycloak-oauth2-proxy-bootstrap.sh"

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
assert_contains "$netbox_extra" "from django.contrib.auth.models import Group"
assert_contains "$netbox_extra" "netbox.authentication.user_default_groups_handler"
assert_contains "$bootstrap" 'ensure_group "netbox-admin"'
assert_contains "$bootstrap" 'ensure_group "netbox-editor"'
assert_contains "$bootstrap" 'ensure_group "argocd-admin"'
assert_contains "$bootstrap" 'grep -Eq'
assert_contains "$oauth_bootstrap" 'CLIENT_ID=${OAUTH2_PROXY_CLIENT_ID:-oauth2-proxy}'
assert_contains "$oauth_bootstrap" 'oidc-group-membership-mapper'
assert_contains "$oauth_bootstrap" '"claim.name": "groups"'
assert_contains "$oauth_bootstrap" '"full.path": "false"'
assert_contains "$oauth_bootstrap" '"id.token.claim": "true"'
assert_contains "$oauth_bootstrap" '"access.token.claim": "true"'
assert_contains "$oauth_bootstrap" '"userinfo.token.claim": "true"'

echo "keycloak security-group tests passed"
