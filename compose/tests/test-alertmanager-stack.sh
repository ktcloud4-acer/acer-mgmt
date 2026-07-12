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

alertmanager_compose="${REPO_ROOT}/compose/stacks/observability/alertmanager/compose.yaml"
alertmanager_config="${REPO_ROOT}/compose/stacks/observability/alertmanager/config/alertmanager.yml"
prometheus_compose="${REPO_ROOT}/compose/stacks/observability/prometheus/compose.yaml"
prometheus_config="${REPO_ROOT}/compose/stacks/observability/prometheus/config/prometheus.yml"
smoke_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/alertmanager-smoke.yml"
demo_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/demo-scalecart.yml"
vault_agent_config="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"

assert_file "$alertmanager_compose"
assert_file "$alertmanager_config"
assert_file "$smoke_rules"
assert_file "$demo_rules"
assert_file "$vault_agent_config"

assert_contains "$alertmanager_compose" "image: prom/alertmanager:"
assert_contains "$alertmanager_compose" "container_name: alertmanager"
assert_contains "$alertmanager_compose" 'user: "100:1000"'
assert_contains "$alertmanager_compose" "--config.file=/etc/alertmanager/alertmanager.yml"
assert_contains "$alertmanager_compose" "--storage.path=/alertmanager"
assert_contains "$alertmanager_compose" '${DATA_ROOT:-/home/mgmt-data}/vault-agent/secrets/alertmanager:/etc/alertmanager/secrets:ro,z'
assert_contains "$alertmanager_compose" 'traefik.http.routers.alertmanager.rule=Host(`alertmanager.${BASE_DOMAIN}`)'
assert_contains "$alertmanager_compose" "traefik.http.services.alertmanager.loadbalancer.server.port=9093"

assert_contains "$alertmanager_config" "slack_api_url_file: /etc/alertmanager/secrets/slack_webhook_infra"
assert_contains "$alertmanager_config" 'severity="test"'
assert_contains "$alertmanager_config" 'receiver: "null"'
assert_contains "$alertmanager_config" "receiver: slack-infra-alerts"
assert_contains "$alertmanager_config" 'channel: "#infra-알림"'
assert_contains "$alertmanager_config" "repeat_interval: 4h"
assert_contains "$alertmanager_config" 'demo="true"'
assert_contains "$alertmanager_config" '대시보드: <{{ .Annotations.dashboard_url }}|Teleport에서 Grafana 열기>'

assert_contains "$prometheus_compose" "./config/alerts:/etc/prometheus/alerts:ro,Z"
assert_contains "$prometheus_compose" '100.117.59.96:9090:9090'
assert_contains "$prometheus_config" "alertmanagers:"
assert_contains "$prometheus_config" "alertmanager:9093"
assert_contains "$prometheus_config" "/etc/prometheus/alerts/*.yml"

assert_contains "$smoke_rules" "AlertmanagerSmokeTest"
assert_contains "$smoke_rules" 'vector(0) == 1'
assert_contains "$demo_rules" "name: demo-scalecart"
assert_contains "$demo_rules" "alert: ScaleCartWorkerAvailabilityDegraded"
assert_contains "$demo_rules" 'cluster=~"ggg|khb|ljw|nmg|oje"'
assert_contains "$demo_rules" 'deployment="scalecart-worker"'
assert_contains "$demo_rules" "for: 5s"
assert_contains "$demo_rules" 'demo: "true"'
assert_contains "$demo_rules" "https://grafana.teleport.imcherry5778.xyz:3080"

assert_contains "$vault_agent_config" 'kv/data/mgmt/alertmanager'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/alertmanager/slack_webhook_infra"'

echo "alertmanager stack tests passed"
