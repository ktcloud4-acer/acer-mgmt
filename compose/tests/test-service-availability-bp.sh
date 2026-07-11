#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMETHEUS_CONFIG="${ROOT_DIR}/compose/stacks/observability/prometheus/config/prometheus.yml"
BLACKBOX_CONFIG="${ROOT_DIR}/compose/stacks/observability/prometheus/config/blackbox.yml"
ALERT_RULES="${ROOT_DIR}/compose/stacks/observability/prometheus/config/alerts/infra-endpoints.yml"
DASHBOARD="${ROOT_DIR}/compose/stacks/observability/grafana/dashboards/Monitoring/service_availability.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

for file in "$PROMETHEUS_CONFIG" "$BLACKBOX_CONFIG" "$ALERT_RULES" "$DASHBOARD"; do
  [[ -f "$file" ]] || fail "missing $file"
done

for module in http_2xx http_3xx http_401 http_403 dns_adguard; do
  assert_contains "$BLACKBOX_CONFIG" "${module}:"
done

for service in grafana prometheus alertmanager keycloak vault harbor argocd sonar kafka kibana teleport gitlab minio n8n adguard-ui netbox supabase adguard-dns nmg-api nmg-dashboard ggg-api ggg-dashboard oje-api oje-dashboard khb-api khb-dashboard ljw-api ljw-dashboard; do
  assert_contains "$PROMETHEUS_CONFIG" "service: ${service}"
done

assert_contains "$ALERT_RULES" "InfraEndpointDown"
assert_contains "$ALERT_RULES" "TeamEndpointDown"
assert_contains "$DASHBOARD" "Service Availability"
assert_contains "$DASHBOARD" "probe_success"

jq empty "$DASHBOARD"
echo "service availability BP tests passed"
