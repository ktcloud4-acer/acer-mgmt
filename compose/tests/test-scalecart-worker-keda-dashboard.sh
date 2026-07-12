#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dashboard="$root/compose/stacks/observability/grafana/dashboards/Monitoring/scalecart_worker_keda_demo.json"

test -f "$dashboard" || { echo "missing KEDA dashboard" >&2; exit 1; }
jq empty "$dashboard"
jq -e '.uid == "scalecart-worker-keda-demo"' "$dashboard" >/dev/null
jq -e '.title == "ScaleCart Worker KEDA Demo"' "$dashboard" >/dev/null
jq -e '.templating.list[] | select(.name == "cluster")' "$dashboard" >/dev/null

for title in \
  "Kafka Lag" "Worker Ready / Desired" "KEDA Scale-out Requested" \
  "Pending Worker Pods" "Kafka Lag and Threshold" \
  "Order Produce / Consume Rate" "Worker Replica Timeline" \
  "Worker Node Actual CPU" "Worker Node CPU Request Reservation" \
  "Worker Node Actual Memory" "Worker Node Memory Request Reservation" \
  "Additional Worker Slots by CPU" "Additional Worker Slots by Memory" \
  "Node Placement Status"; do
  jq -e --arg title "$title" '.panels[] | select(.title == $title)' "$dashboard" >/dev/null
done

dashboard_json="$(cat "$dashboard")"
for metric in \
  'scalecart:worker_kafka_lag:max' \
  'scalecart_orders_produced_total' \
  'scalecart_orders_consumed_total' \
  'kube_horizontalpodautoscaler_status_desired_replicas' \
  'kube_pod_status_phase' \
  'node_cpu_seconds_total' \
  'kube_pod_container_resource_requests' \
  'kube_node_status_allocatable' \
  'kube_node_spec_taint'; do
  grep -Fq -- "$metric" <<<"$dashboard_json" || { echo "missing $metric" >&2; exit 1; }
done

grep -Fq -- 'KEDA Scale-out Requested' <<<"$dashboard_json"
grep -Fq -- '536870912' <<<"$dashboard_json"
grep -Fq -- '0.25' <<<"$dashboard_json"
pending_fallback='kube_horizontalpodautoscaler_status_desired_replicas{namespace="scalecart",horizontalpodautoscaler="keda-hpa-scalecart-worker",cluster=~"$cluster"} * 0'
jq -e --arg expected "$pending_fallback" '[.panels[].targets[]?.expr] | join("\n") | contains($expected)' "$dashboard" >/dev/null

echo 'SCALECART_WORKER_KEDA_DASHBOARD=PASS'
