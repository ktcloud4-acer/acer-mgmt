#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing file: ${file}"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

compose_file="${REPO_ROOT}/compose/stacks/security/oauth2-proxy/compose.yaml"
readme_file="${REPO_ROOT}/compose/stacks/security/oauth2-proxy/README.md"
traefik_middlewares="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
vault_agent_config="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"

assert_file "$compose_file"
assert_file "$readme_file"
assert_file "$traefik_middlewares"
assert_file "$vault_agent_config"

assert_contains "$compose_file" "image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.3"
assert_contains "$compose_file" "container_name: oauth2-proxy"
assert_contains "$compose_file" 'user: "100:1000"'
assert_contains "$compose_file" "--provider=keycloak-oidc"
assert_contains "$compose_file" '--oidc-issuer-url=https://keycloak.${BASE_DOMAIN}/realms/mgmt'
assert_contains "$compose_file" "--client-secret-file=/run/secrets/oauth2_proxy_client_secret"
assert_contains "$compose_file" "--cookie-secret-file=/run/secrets/oauth2_proxy_cookie_secret"
assert_contains "$compose_file" '--allowed-group=${OAUTH2_PROXY_ALLOWED_GROUP:-platform-admin}'
assert_contains "$compose_file" 'traefik.http.routers.oauth2-proxy.rule=Host(`auth.${BASE_DOMAIN}`)'
assert_contains "$compose_file" "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"

assert_contains "$traefik_middlewares" "address: http://oauth2-proxy:4180/oauth2/auth"
assert_contains "$traefik_middlewares" "service: oauth2-proxy@docker"

assert_contains "$vault_agent_config" 'kv/data/mgmt/oauth2-proxy'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/oauth2_proxy_client_secret"'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/oauth2_proxy_cookie_secret"'

echo "oauth2-proxy stack tests passed"
