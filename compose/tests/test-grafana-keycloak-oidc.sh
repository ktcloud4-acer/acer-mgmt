#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
grafana_compose="$ROOT_DIR/compose/stacks/observability/grafana/compose.yaml"
vault_agent_config="$ROOT_DIR/compose/stacks/security/vault-agent/config/agent.hcl"
bootstrap="$ROOT_DIR/compose/scripts/keycloak-grafana-oidc-bootstrap.sh"

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

assert_template_block_contains() {
  local file="$1"
  local destination="$2"
  shift 2
  local template_block
  template_block="$(awk -v destination="$destination" '
    /^template[[:space:]]*\{/ {
      in_template = 1
      block = $0 ORS
      next
    }
    in_template {
      block = block $0 ORS
      if ($0 ~ /^}/) {
        if (index(block, "destination") && index(block, destination)) {
          print block
          exit
        }
        in_template = 0
      }
    }
  ' "$file")"

  [[ -n "$template_block" ]] || {
    fail "missing Vault Agent template for destination: $destination"
  }

  local expected
  for expected in "$@"; do
    grep -Fq -- "$expected" <<<"$template_block" || {
      fail "Vault Agent template for $destination does not contain: $expected"
    }
  done
}

assert_template_block_contains "$vault_agent_config" \
  '/vault/secrets/grafana_oidc_client_secret' \
  'kv/data/mgmt/grafana' \
  '.Data.data.oidc_client_secret' \
  'perms       = "0640"' \
  'command = "chgrp 472 /vault/secrets/grafana_oidc_client_secret && chmod 0640 /vault/secrets/grafana_oidc_client_secret"'

assert_contains "$bootstrap" 'CLIENT_ID=${GRAFANA_OIDC_CLIENT_ID:-grafana}'
assert_contains "$bootstrap" 'REDIRECT_URI="https://grafana.${BASE_DOMAIN}/login/generic_oauth"'
assert_contains "$bootstrap" 'oidc-group-membership-mapper'
assert_contains "$bootstrap" '"claim.name": "groups"'
assert_contains "$bootstrap" '--secret-path mgmt/grafana'
assert_contains "$bootstrap" '--field oidc_client_secret'
assert_contains "$bootstrap" 'groups_mapper_id()'
assert_contains "$bootstrap" 'json.load(sys.stdin)'
assert_contains "$bootstrap" 'if len(groups_mappers) > 1:'
assert_contains "$bootstrap" 'Refusing to reconcile duplicate groups mappers'
assert_contains "$bootstrap" 'MAPPER_ID="$(groups_mapper_id)"'
assert_contains "$bootstrap" 'if [[ -n "$MAPPER_ID" ]]; then'
assert_contains "$bootstrap" 'kc delete "clients/${CLIENT_UUID}/protocol-mappers/models/${MAPPER_ID}"'
assert_contains "$bootstrap" 'kc create "clients/${CLIENT_UUID}/protocol-mappers/models"'
assert_not_contains "$bootstrap" 'kc update "clients/${CLIENT_UUID}/protocol-mappers/models/${MAPPER_ID}"'
assert_not_contains "$bootstrap" 'awk '
assert_contains "$bootstrap" 'docker exec "$VAULT_CONTAINER" test -s "$VAULT_TOKEN_FILE"'
assert_not_contains "$bootstrap" 'sh -c "test -s'

assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_ENABLED: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_CLIENT_ID: ${GRAFANA_OIDC_CLIENT_ID:-grafana}'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $$__file{/run/secrets/grafana_oidc_client_secret}'
assert_not_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET__FILE'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_VALIDATE_ID_TOKEN: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_JWK_SET_URL: https://keycloak.${BASE_DOMAIN}/realms/${KEYCLOAK_REALM:-mgmt}/protocol/openid-connect/certs'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH: groups'
assert_contains "$grafana_compose" "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: contains(groups[*], 'grafana-editor') && 'Editor' || 'Viewer'"
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_ENABLED: "false"'
assert_contains "$grafana_compose" 'traefik.http.routers.grafana.middlewares=secure-headers@file'
assert_not_contains "$grafana_compose" 'traefik.http.routers.grafana.middlewares=sso-auth@file'
assert_contains "$grafana_compose" '${DATA_ROOT:-/home/mgmt-data}/vault-agent/secrets/grafana_oidc_client_secret:/run/secrets/grafana_oidc_client_secret:ro,z'
assert_not_contains "$grafana_compose" '- /vault-agent/secrets/grafana_oidc_client_secret:/run/secrets/grafana_oidc_client_secret:ro,z'

echo 'Grafana Keycloak OIDC contract tests passed'
