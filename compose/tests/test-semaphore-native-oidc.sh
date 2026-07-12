#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "did not expect '$2' in $1"
  fi
}

compose_file="${REPO_ROOT}/compose/stacks/cicd/semaphore/compose.yaml"
middlewares="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
vault_agent="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"
dashy_config="${REPO_ROOT}/compose/stacks/edge/dashy/config/conf.yml"

for file in "$compose_file" "$middlewares" "$vault_agent" "$dashy_config"; do
  [[ -f "$file" ]] || fail "missing file: $file"
done

assert_contains "$compose_file" 'SEMAPHORE_OIDC_PROVIDERS:'
assert_contains "$compose_file" 'client_secret_file'
assert_contains "$compose_file" '/run/secrets/semaphore_oidc_client_secret:ro,z'
assert_contains "$compose_file" 'user: "1001:1000"'
assert_contains "$compose_file" 'SEMAPHORE_PASSWORD_LOGIN_DISABLED: "true"'
assert_contains "$compose_file" 'traefik.http.routers.semaphore.middlewares=oauth2-auth@file,semaphore-iframe@file'
assert_not_contains "$compose_file" 'traefik.http.routers.semaphore.middlewares=sso-auth@file'

assert_contains "$vault_agent" 'destination = "/vault/secrets/semaphore_oidc_client_secret"'
assert_contains "$middlewares" 'semaphore-iframe:'
assert_contains "$middlewares" 'frame-ancestors https://dash.imcherry5778.xyz'

awk '
  $0 == "      - title: Semaphore" { found=1; next }
  found && $0 == "        target: workspace" { success=1; exit }
  found && $0 ~ /^      - title:/ { exit }
  END { exit success ? 0 : 1 }
' "$dashy_config" || fail "Semaphore must open in Dashy Workspace"

echo "Semaphore native OIDC contract tests passed"
