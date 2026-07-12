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

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
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
assert_not_contains "$compose_file" '--allowed-group='
assert_contains "$compose_file" 'traefik.http.routers.oauth2-proxy.rule=Host(`auth.${BASE_DOMAIN}`)'
assert_contains "$compose_file" 'traefik.http.routers.oauth2-root.rule=Host(`auth.${BASE_DOMAIN}`) && Path(`/`)'
assert_contains "$compose_file" 'traefik.http.routers.oauth2-root.priority=100'
assert_contains "$compose_file" 'traefik.http.routers.oauth2-root.middlewares=auth-root-redirect@file'
assert_contains "$compose_file" "traefik.http.services.oauth2-proxy.loadbalancer.server.port=4180"

assert_contains "$traefik_middlewares" "address: http://oauth2-proxy:4180/oauth2/auth"
assert_contains "$traefik_middlewares" "service: oauth2-proxy@docker"
assert_contains "$traefik_middlewares" 'auth-root-redirect:'
assert_contains "$traefik_middlewares" 'regex: "^https://auth\\.imcherry5778\\.xyz/?$"'
assert_contains "$traefik_middlewares" 'replacement: "https://dash.imcherry5778.xyz/"'
assert_contains "$traefik_middlewares" 'permanent: false'

assert_contains "$vault_agent_config" 'kv/data/mgmt/oauth2-proxy'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/oauth2_proxy_client_secret"'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/oauth2_proxy_cookie_secret"'

echo "oauth2-proxy stack tests passed"
