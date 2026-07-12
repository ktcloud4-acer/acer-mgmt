#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PRIMARY_REPO="$(git -C "${REPO_ROOT}" worktree list --porcelain | awk '/^worktree / {sub(/^worktree /, ""); print; exit}')"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "${PRIMARY_REPO}/.." && pwd)}"

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

bp_doc="${WORKSPACE_ROOT}/acer-docs/acer-mgmt/docs/sre-best-practice-2026-07-10.md"
bp_spec="${WORKSPACE_ROOT}/acer-docs/acer-mgmt/docs/specs/sre-bp-design-2026-07-10.md"
argo_inventory="${WORKSPACE_ROOT}/acer-argocd/docs/argocd-application-inventory-2026-07-10.md"
slo_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/scalecart-slo.yml"
sre_dashboard="${REPO_ROOT}/compose/stacks/observability/grafana/dashboards/Monitoring/sre_scalecart_landing.json"
api_config="${WORKSPACE_ROOT}/acer-web/services/scalecart-api/src/main/resources/application.yml"
worker_config="${WORKSPACE_ROOT}/acer-web/services/scalecart-worker/src/main/resources/application.yml"

assert_file "$bp_doc"
assert_file "$bp_spec"
assert_file "$argo_inventory"
assert_file "$slo_rules"
assert_file "$sre_dashboard"
assert_file "$api_config"
assert_file "$worker_config"

assert_contains "$bp_doc" "API 가용성"
assert_contains "$bp_doc" "에러 버짓"
assert_contains "$bp_doc" "Argo CD 운영 기준"
assert_contains "$bp_spec" "SRE 운영 모범 사례 구현 설계"

assert_contains "$argo_inventory" "Argo CD Application 인벤토리"
assert_contains "$argo_inventory" "scalecart-khb"
assert_contains "$argo_inventory" "automated.prune=true"

assert_contains "$slo_rules" "scalecart:api_availability:5m"
assert_contains "$slo_rules" "scalecart:api_latency:p95_5m"
assert_contains "$slo_rules" "scalecart:api_error_budget_remaining:30d"
assert_contains "$slo_rules" "ScaleCartApiErrorBudgetFastBurn"
assert_contains "$slo_rules" "ScaleCartWorkerKafkaLagHigh"

assert_contains "$sre_dashboard" "\"title\": \"ScaleCart SRE Landing\""
assert_contains "$sre_dashboard" "scalecart:api_availability:5m"
assert_contains "$sre_dashboard" "scalecart:api_latency:p99_5m"

assert_contains "$api_config" "percentiles-histogram:"
assert_contains "$api_config" "http.server.requests: true"
assert_contains "$worker_config" "percentiles-histogram:"
assert_contains "$worker_config" "http.server.requests: true"

echo "sre bp artifact tests passed"
