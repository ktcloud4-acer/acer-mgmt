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

prometheus_compose="${REPO_ROOT}/compose/stacks/observability/prometheus/compose.yaml"
prometheus_config="${REPO_ROOT}/compose/stacks/observability/prometheus/config/prometheus.yml"
blackbox_config="${REPO_ROOT}/compose/stacks/observability/prometheus/config/blackbox.yml"
endpoint_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/infra-endpoints.yml"
backup_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/infra-backup.yml"
restic_compose="${REPO_ROOT}/compose/stacks/backup/restic/compose.yaml"
alertmanager_config="${REPO_ROOT}/compose/stacks/observability/alertmanager/config/alertmanager.yml"
vault_agent_config="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"

assert_file "$prometheus_compose"
assert_file "$prometheus_config"
assert_file "$blackbox_config"
assert_file "$endpoint_rules"
assert_file "$backup_rules"
assert_file "$restic_compose"
assert_file "$alertmanager_config"
assert_file "$vault_agent_config"

assert_contains "$prometheus_compose" "container_name: blackbox-exporter"
assert_contains "$prometheus_compose" "image: quay.io/prometheus/blackbox-exporter:"
assert_contains "$prometheus_compose" "./config/blackbox.yml:/etc/blackbox_exporter/config.yml:ro,Z"
assert_contains "$prometheus_compose" "--collector.textfile.directory=/textfile"
assert_contains "$prometheus_compose" '${DATA_ROOT:-/home/mgmt-data}/node-exporter-textfile:/textfile:ro,Z'

assert_contains "$blackbox_config" "http_2xx:"
assert_contains "$blackbox_config" "http_3xx:"
assert_contains "$blackbox_config" "dns_adguard:"
assert_contains "$blackbox_config" "preferred_ip_protocol: ip4"

assert_contains "$prometheus_config" "job_name: blackbox-http"
assert_contains "$prometheus_config" "blackbox-exporter:9115"
assert_contains "$prometheus_config" "http://grafana:3000/api/health"
assert_contains "$prometheus_config" "https://alertmanager.imcherry5778.xyz/"
assert_contains "$prometheus_config" "https://argocd.imcherry5778.xyz/healthz"

assert_contains "$endpoint_rules" "alert: InfraEndpointDown"
assert_contains "$endpoint_rules" "alert: TeamEndpointDown"
assert_contains "$endpoint_rules" "probe_success"
assert_not_contains "$endpoint_rules" "alert: ArgoCdEndpointDown"
assert_not_contains "$endpoint_rules" "scope: argocd"
assert_not_contains "$alertmanager_config" "receiver: slack-argocd-alerts"
assert_not_contains "$alertmanager_config" "channel=\"argocd\""
assert_not_contains "$vault_agent_config" 'slack_webhook_argocd'

assert_contains "$restic_compose" '${DATA_ROOT:-/home/mgmt-data}/node-exporter-textfile:/metrics:Z'
assert_contains "$restic_compose" "restic_last_success_timestamp_seconds"
assert_contains "$backup_rules" "alert: ResticBackupStale"
assert_contains "$backup_rules" "restic_last_success_timestamp_seconds"

echo "conservative alert expansion tests passed"
