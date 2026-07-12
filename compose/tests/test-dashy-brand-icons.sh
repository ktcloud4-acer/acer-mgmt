#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="${ROOT_DIR}/compose/stacks/edge/dashy/config/conf.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_item_icon() {
  local title="$1" expected="$2"
  awk -v title="$title" -v expected="$expected" '
    $0 == "      - title: " title { found=1; next }
    found && $0 == "        icon: " expected { matched=1; exit }
    found && $0 ~ /^      - title:/ { exit }
  END { exit found && matched ? 0 : 1 }
  ' "$config" || fail "expected ${title} to use ${expected}"
}

while IFS='|' read -r title icon; do
  assert_item_icon "$title" "$icon"
done <<'MAPPINGS'
Grafana|si-grafana
Prometheus|si-prometheus
Alertmanager|hl-alertmanager
Kibana|si-kibana
n8n|si-n8n
MinIO|si-minio
Argo CD|si-argo
GitLab|si-gitlab
SonarQube|hl-sonarqube
Allure|https://raw.githubusercontent.com/allure-framework/allure2/main/allure-generator/src/main/javascript/features/shell/allure_logo.svg
Playwright|https://playwright.dev/img/playwright-logo.svg
Semaphore|si-semaphoreci
Harbor|hl-harbor
Kafka|si-apachekafka
Supabase|si-supabase
NetBox|hl-netbox
Keycloak|si-keycloak
Teleport|hl-teleport
Vault|si-vault
Wazuh|hl-wazuh
RedisInsight|si-redis
Traefik|si-traefikproxy
AdGuard Home|si-adguard
MAPPINGS

echo 'DASHY_BRAND_ICON_MAPPING=PASS'
