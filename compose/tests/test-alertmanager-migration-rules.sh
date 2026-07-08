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

assert_grafana_rule_paused() {
  local uid="$1"
  local result

  result="$(
    awk -v uid="$uid" '
      $0 ~ "uid: " uid "$" {
        found = 1
        in_rule = 1
        next
      }
      in_rule && $0 ~ /^      - uid: / {
        in_rule = 0
      }
      in_rule && $0 ~ /^[[:space:]]*isPaused:[[:space:]]*true[[:space:]]*$/ {
        paused = 1
      }
      END {
        if (!found) {
          print "missing"
        } else if (!paused) {
          print "not_paused"
        } else {
          print "paused"
        }
      }
    ' "$grafana_alerting"
  )"

  [[ "$result" == "paused" ]] || fail "Grafana source rule ${uid} must be paused after migration: ${result}"
}

alerts_dir="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts"
host_rules="${alerts_dir}/infra-host.yml"
kubernetes_rules="${alerts_dir}/infra-kubernetes.yml"
alertmanager_config="${REPO_ROOT}/compose/stacks/observability/alertmanager/config/alertmanager.yml"
grafana_alerting="${REPO_ROOT}/compose/stacks/observability/grafana/provisioning/alerting/infra-alerting.yaml"

assert_file "$host_rules"
assert_file "$kubernetes_rules"
assert_file "$alertmanager_config"
assert_file "$grafana_alerting"

assert_contains "$host_rules" 'cluster=~"ggg|khb|ljw|nmg|oje"'
assert_contains "$host_rules" "alert: MgmtNodeExporterDown"
assert_contains "$host_rules" "alert: AioNodeExporterDown"
assert_contains "$host_rules" "alert: MgmtRootDiskHigh"
assert_contains "$host_rules" "alert: AioRootDiskHigh"
assert_contains "$host_rules" "alert: MgmtMemoryHigh"
assert_contains "$host_rules" "alert: AioMemoryHigh"
assert_contains "$host_rules" "scope: aio"
assert_contains "$host_rules" "target: 172.16.8.10:9100"

assert_contains "$kubernetes_rules" 'cluster=~"ggg|khb|ljw|nmg|oje"'
assert_contains "$kubernetes_rules" "alert: ClusterMetricsMissing"
assert_contains "$kubernetes_rules" "alert: KubeNodeNotReady"
assert_contains "$kubernetes_rules" "alert: KubeStateMetricsDown"
assert_contains "$kubernetes_rules" "alert: KubeletMetricsDown"
assert_contains "$kubernetes_rules" "alert: CAdvisorMetricsDown"
assert_contains "$kubernetes_rules" "alert: OpenCostMetricsDown"
assert_contains "$kubernetes_rules" "alert: KubePodPending"
assert_contains "$kubernetes_rules" "alert: KubePodRestartsHigh"

assert_contains "$alertmanager_config" "severity=\"critical\""
assert_contains "$alertmanager_config" "severity=\"warning\""
assert_contains "$alertmanager_config" "repeat_interval: 12h"
assert_contains "$alertmanager_config" "범위: {{ if .Labels.scope }}{{ .Labels.scope }}{{ else }}-{{ end }}"
assert_contains "$alertmanager_config" "클러스터: {{ if .Labels.cluster }}{{ .Labels.cluster }}{{ else }}-{{ end }}"

assert_grafana_rule_paused "infra_mgmt_node_down"
assert_grafana_rule_paused "infra_aio_node_down"
assert_grafana_rule_paused "infra_aio_opencost_down"
assert_grafana_rule_paused "infra_mgmt_disk_high"
assert_grafana_rule_paused "infra_aio_disk_high"
assert_grafana_rule_paused "infra_mgmt_mem_high"
assert_grafana_rule_paused "infra_aio_mem_high"

echo "alertmanager migration rule tests passed"
