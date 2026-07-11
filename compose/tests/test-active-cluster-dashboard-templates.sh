#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/compose/stacks/observability/grafana/dashboards/Monitoring/active-clusters"
PROMETHEUS_CONFIG="${ROOT_DIR}/compose/stacks/observability/prometheus/config/prometheus.yml"
ALERT_RULES="${ROOT_DIR}/compose/stacks/observability/prometheus/config/alerts/infra-endpoints.yml"
AIO_DASHBOARD="${ROOT_DIR}/compose/stacks/observability/grafana/dashboards/Monitoring/aio/aio_node_exporter.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

for dashboard in kubernetes_nodes opencost_node_cost opencost_namespace_cost opencost_workload_allocation opencost_idle_efficiency; do
  file="${DASHBOARD_DIR}/${dashboard}.json"
  [[ -f "$file" ]] || fail "missing template dashboard: $file"
  jq empty "$file"
  assert_contains "$file" '"type": "query"'
  assert_contains "$file" '"name": "cluster"'
done

if find "${ROOT_DIR}/compose/stacks/observability/grafana/dashboards/Monitoring" -type f -path '*_cluster/*.json' | grep -q .; then
  fail "per-team cluster dashboard clones remain"
fi

assert_contains "$PROMETHEUS_CONFIG" 'lifecycle: active'
assert_contains "$PROMETHEUS_CONFIG" 'lifecycle: standby'
assert_contains "$ALERT_RULES" 'cluster_monitoring_enabled'
assert_contains "$ALERT_RULES" 'lifecycle="active"'
assert_contains "$AIO_DASHBOARD" 'label_values(up{job=\"host-vm\"}'

echo "active cluster dashboard template tests passed"
