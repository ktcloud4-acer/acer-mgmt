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

dashy_compose="${DASHY_ROOT}/compose.yaml"
dashy_config="${DASHY_ROOT}/config/conf.yml"
status_config="${DASHY_ROOT}/config/status.yml"
middlewares_config="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
grafana_compose="${REPO_ROOT}/compose/stacks/observability/grafana/compose.yaml"
prometheus_compose="${REPO_ROOT}/compose/stacks/observability/prometheus/compose.yaml"

for file in "$dashy_compose" "$dashy_config"; do
  assert_file "$file"
done

assert_file "$middlewares_config"
assert_file "$grafana_compose"
assert_file "$prometheus_compose"

assert_contains "$dashy_compose" "image: ghcr.io/lissy93/dashy:4.1.5"
assert_contains "$dashy_compose" "./config:/app/user-data:ro,Z"
assert_contains "$dashy_compose" 'traefik.http.routers.dashy.rule=Host(`dashy.${BASE_DOMAIN}`)'
assert_not_contains "$dashy_compose" 'Host(`dash.${BASE_DOMAIN}`)'
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

mapfile -t section_names < <(awk '$0 == "sections:" { in_sections=1; next } in_sections && /^  - name:/ { sub(/^  - name: /, ""); print }' "$dashy_config")
expected_section_order=("CI/CD" Security Observability Edge Data Infra Backup "Chaos Mesh")
[[ "${section_names[*]}" == "${expected_section_order[*]}" ]] || fail "unexpected Dashy section order: ${section_names[*]}"

for item in Grafana Prometheus Alertmanager Kibana n8n MinIO "Argo CD" GitLab SonarQube Allure Playwright Semaphore Harbor Kafka Supabase NetBox Keycloak Teleport Vault Wazuh "RedisInsight" Traefik "AdGuard Home"; do
  assert_contains "$dashy_config" "title: ${item}"
done

assert_contains "$dashy_config" "url: https://allure.imcherry5778.xyz/allure-docker-service/projects/acer-web/reports/latest/index.html"
assert_not_contains "$dashy_config" "allure-docker-service/projects/web-service/reports/latest/index.html"
assert_contains "$dashy_config" "statusCheckUrl: https://prometheus.imcherry5778.xyz/-/ready"
assert_contains "$dashy_config" "statusCheckAcceptCodes: '200'"
assert_contains "$dashy_config" "statusCheckUrl: https://alertmanager.imcherry5778.xyz/-/ready"
assert_not_contains "$dashy_config" "statusCheckUrl: http://prometheus:9090/-/ready"
assert_contains "$prometheus_compose" 'traefik.http.routers.prometheus-health.rule=Host(`prometheus.${BASE_DOMAIN}`) && (Path(`/-/ready`) || Path(`/-/healthy`))'
assert_contains "$prometheus_compose" "traefik.http.routers.prometheus-health.entrypoints=websecure"
assert_contains "$prometheus_compose" "traefik.http.routers.prometheus-health.middlewares=secure-headers@file"
assert_contains "$prometheus_compose" "traefik.http.routers.prometheus-health.priority=100"

for page in Monitor Containers; do
  assert_contains "$dashy_config" "name: ${page}"
done

assert_contains "$dashy_config" "title: Home"
assert_contains "$dashy_config" "path: /"

[[ ! -e "$status_config" ]] || fail "service-index-only scope must not contain status.yml"
assert_not_contains "$dashy_config" "hideFromWorkspace:"
assert_not_contains "$dashy_config" "Grafana Operations Summary"
assert_not_contains "$dashy_config" "disableContextMenu: true"
assert_not_contains "$dashy_config" ".png"
assert_not_contains "$dashy_config" "Status-Uptime"
assert_not_contains "$dashy_config" "Status-Container"
assert_not_contains "$dashy_config" "title: Runbooks"
assert_not_contains "$dashy_config" "docs/runbooks"
assert_not_contains "$dashy_config" "name: Operations"
assert_not_contains "$dashy_config" "title: Restic"
assert_not_contains "$dashy_config" "title: GitLab Runner"
assert_not_contains "$dashy_config" "title: Docker Runtime"
assert_not_contains "$dashy_config" "target: workspace"
assert_not_contains "$middlewares_config" "frameDeny: true"
assert_contains "$middlewares_config" 'X-Frame-Options: ""'
assert_contains "$grafana_compose" 'GF_SECURITY_ALLOW_EMBEDDING: "true"'

echo "Dashy service index configuration tests passed"
