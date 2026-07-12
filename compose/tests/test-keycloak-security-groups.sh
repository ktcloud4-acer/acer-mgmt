#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
netbox_extra="$ROOT_DIR/compose/stacks/infra/netbox/config/extra.py"
bootstrap="$ROOT_DIR/compose/scripts/keycloak-security-groups-bootstrap.sh"
oauth_bootstrap="$ROOT_DIR/compose/scripts/keycloak-oauth2-proxy-bootstrap.sh"
semaphore_oidc_bootstrap="$ROOT_DIR/compose/scripts/keycloak-semaphore-oidc-bootstrap.sh"
vault_kv_patch="$ROOT_DIR/compose/scripts/vault-kv2-patch-secret.py"

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

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file must not contain: $unexpected"
  fi
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
assert_contains "$oauth_bootstrap" '"introspection.token.claim": "true"'
assert_not_contains "$oauth_bootstrap" 'head -n1'
assert_contains "$oauth_bootstrap" '--fields id,clientId'
assert_contains "$oauth_bootstrap" 'docker exec --user 0 keycloak chmod 0644 /tmp/oauth2-proxy-groups-mapper.json'
assert_not_contains "$oauth_bootstrap" 'kc update "clients/${CLIENT_UUID}/protocol-mappers/models/${mapper_id}"'
assert_contains "$semaphore_oidc_bootstrap" 'CLIENT_ID=${SEMAPHORE_OIDC_CLIENT_ID:-semaphore}'
assert_contains "$semaphore_oidc_bootstrap" '/api/auth/oidc/keycloak/redirect'
assert_contains "$semaphore_oidc_bootstrap" 'vault-kv2-patch-secret.py'
assert_contains "$semaphore_oidc_bootstrap" '--allow-rw-fallback'
assert_not_contains "$semaphore_oidc_bootstrap" 'vault kv patch -mount=kv mgmt/semaphore'
assert_contains "$vault_kv_patch" 'connection.putrequest('
assert_contains "$vault_kv_patch" '"PATCH"'
assert_contains "$vault_kv_patch" 'application/merge-patch+json'
assert_contains "$vault_kv_patch" '"GET"'
assert_contains "$vault_kv_patch" '"POST"'
assert_contains "$vault_kv_patch" '"cas"'
assert_contains "$vault_kv_patch" 'X-Vault-Token'
assert_contains "$vault_kv_patch" 'ssl.create_default_context'
assert_contains "$vault_kv_patch" 'sys.stdin.buffer.read()'
assert_not_contains "$vault_kv_patch" 'VAULT_SKIP_VERIFY'
assert_not_contains "$vault_kv_patch" 'response.read().decode'

echo "keycloak security-group tests passed"
