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
Grafana|https://cdn.simpleicons.org/grafana
Prometheus|https://cdn.simpleicons.org/prometheus
Alertmanager|hl-alertmanager
Kibana|https://cdn.simpleicons.org/kibana
n8n|https://cdn.simpleicons.org/n8n
MinIO|https://cdn.simpleicons.org/minio
Argo CD|https://cdn.simpleicons.org/argo
GitLab|https://cdn.simpleicons.org/gitlab
SonarQube|hl-sonarqube
Allure|https://raw.githubusercontent.com/allure-framework/allure2/main/allure-generator/src/main/javascript/features/shell/allure_logo.svg
Playwright|https://playwright.dev/img/playwright-logo.svg
Semaphore|https://cdn.simpleicons.org/semaphoreci
Harbor|hl-harbor
Kafka|https://cdn.simpleicons.org/apachekafka
Supabase|https://cdn.simpleicons.org/supabase
NetBox|hl-netbox
Keycloak|https://cdn.simpleicons.org/keycloak
Teleport|hl-teleport
Vault|https://cdn.simpleicons.org/vault
Wazuh|hl-wazuh
RedisInsight|https://cdn.simpleicons.org/redis
Traefik|https://cdn.simpleicons.org/traefikproxy
AdGuard Home|https://cdn.simpleicons.org/adguard
MAPPINGS

echo 'DASHY_BRAND_ICON_MAPPING=PASS'
