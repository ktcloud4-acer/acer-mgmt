#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

root_env_example="${REPO_ROOT}/.env.example"
agent="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"

for secret_key in \
  ADMIN_PASSWORD \
  CF_DNS_API_TOKEN \
  KEYCLOAK_ADMIN_PASSWORD \
  KEYCLOAK_DB_PASSWORD \
  OAUTH2_PROXY_CLIENT_SECRET \
  OAUTH2_PROXY_COOKIE_SECRET \
  MINIO_ROOT_USER \
  VELERO_ACCESS_KEY \
  VELERO_SECRET_KEY \
  ADGUARD_BASIC_AUTH \
  SUPABASE_DASHBOARD_BASIC_AUTH; do
  assert_not_contains "$root_env_example" "${secret_key}="
done

assert_contains "$root_env_example" "BASE_DOMAIN=mgmt.example.com"
assert_contains "$root_env_example" "KEYCLOAK_ADMIN_USER=admin"
assert_contains "$root_env_example" "KEYCLOAK_REALM=mgmt"

for rendered_path in \
  '/vault/secrets/edge/traefik.env' \
  '/vault/secrets/security/keycloak.env' \
  '/vault/secrets/oauth2_proxy_client_secret' \
  '/vault/secrets/oauth2_proxy_cookie_secret' \
  '/vault/secrets/backup/minio.env' \
  '/vault/secrets/cicd/gitlab.env' \
  '/vault/secrets/cicd/semaphore.env' \
  '/vault/secrets/observability/grafana.env'; do
  assert_contains "$agent" "destination = \"${rendered_path}\""
done

assert_contains "$agent" "CF_DNS_API_TOKEN="
assert_contains "$agent" "KEYCLOAK_ADMIN_PASSWORD="
assert_contains "$agent" "KEYCLOAK_DB_PASSWORD="
assert_contains "$agent" "ADMIN_PASSWORD="
assert_contains "$agent" "GITLAB_OIDC_CLIENT_SECRET="
assert_contains "$agent" "kv/data/mgmt/oauth2-proxy"

echo "non-secret root env contract tests passed"
