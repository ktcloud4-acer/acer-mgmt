#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DASHY_ROOT="${REPO_ROOT}/compose/stacks/edge/dashy"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  ! grep -Fq -- "$2" "$1" || fail "did not expect '$2' in $1"
}

assert_item_target() {
  local title="$1"
  local target="$2"
  awk -v title="$title" -v target="$target" '
    $0 == "      - title: " title { found=1; next }
    found && $0 == "        target: " target { success=1; exit }
    found && $0 ~ /^      - title:/ { exit }
  END { exit success ? 0 : 1 }
  ' "$3" || fail "expected ${title} target ${target} in $3"
}

dashy_compose="${DASHY_ROOT}/compose.yaml"
dashy_config="${DASHY_ROOT}/config/conf.yml"
status_config="${DASHY_ROOT}/config/status.yml"
middlewares_config="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
grafana_compose="${REPO_ROOT}/compose/stacks/observability/grafana/compose.yaml"

for file in "$dashy_compose" "$dashy_config"; do
  assert_file "$file"
done

assert_file "$middlewares_config"
assert_file "$grafana_compose"

assert_contains "$dashy_compose" "image: ghcr.io/lissy93/dashy:4.1.5"
assert_contains "$dashy_compose" "./config:/app/user-data:ro,Z"
assert_contains "$dashy_compose" 'traefik.http.routers.dashy.rule=Host(`dash.${BASE_DOMAIN}`)'
assert_contains "$dashy_compose" "traefik.http.routers.dashy.middlewares=sso-auth@file,secure-headers@file"

for setting in \
  "disableConfiguration: true" \
  "preventWriteToDisk: true" \
  "preventLocalSave: true" \
  "defaultOpeningMethod: newtab"; do
  assert_contains "$dashy_config" "$setting"
done

for group in Observability Backup CI/CD Data Infra Security Edge; do
  assert_contains "$dashy_config" "name: ${group}"
done

for item in Grafana Prometheus Alertmanager Kibana n8n MinIO Restic "Argo CD" GitLab "GitLab Runner" SonarQube Allure Playwright Semaphore Harbor Kafka Supabase NetBox Keycloak Teleport Vault Wazuh RedisInsight Traefik "AdGuard Home"; do
  assert_contains "$dashy_config" "title: ${item}"
done

[[ ! -e "$status_config" ]] || fail "service-index-only scope must not contain status.yml"
assert_not_contains "$dashy_config" "hideFromWorkspace:"
assert_not_contains "$dashy_config" "Grafana Operations Summary"
assert_not_contains "$dashy_config" "disableContextMenu: true"
assert_not_contains "$dashy_config" ".png"
assert_not_contains "$middlewares_config" "frameDeny: true"
assert_contains "$middlewares_config" 'X-Frame-Options: ""'
assert_contains "$grafana_compose" 'GF_SECURITY_ALLOW_EMBEDDING: "true"'

for item in Grafana Alertmanager Semaphore Vault; do
  assert_item_target "$item" workspace "$dashy_config"
done

echo "Dashy service index configuration tests passed"
