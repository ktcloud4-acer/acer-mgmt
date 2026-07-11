#!/usr/bin/env bash
set -euo pipefail

dashboard="compose/stacks/observability/grafana/dashboards/Monitoring/chaos_mesh_resilience_overview.json"

test -f "$dashboard"
jq -e '.uid == "chaos-mesh-resilience-overview"' "$dashboard" >/dev/null
jq -e '.title == "Chaos Mesh Resilience Overview"' "$dashboard" >/dev/null
jq -e '.templating.list[] | select(.name == "cluster" and .query.query == "label_values(up{job=\"chaos-mesh-controller\"}, cluster)")' "$dashboard" >/dev/null
jq -e '.templating.list[] | select(.name == "namespace" and (.query.query | contains("exported_namespace")))' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("chaos_controller_manager_chaos_experiments")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("exported_namespace")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("chaos_controller_manager_emitted_event_total")' "$dashboard" >/dev/null
jq -e '[.panels[].targets[]?.expr] | join("\n") | contains("scalecart:api_error_ratio:5m")' "$dashboard" >/dev/null

echo 'CHAOS_MESH_GRAFANA_ARTIFACT_VALIDATION=PASS'
