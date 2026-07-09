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

assert_missing() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "unexpected path: ${path}"
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

prometheus_config="${REPO_ROOT}/compose/stacks/observability/prometheus/config/prometheus.yml"
endpoint_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/infra-endpoints.yml"
argocd_rules="${REPO_ROOT}/compose/stacks/observability/prometheus/config/alerts/argocd.yml"
alertmanager_config="${REPO_ROOT}/compose/stacks/observability/alertmanager/config/alertmanager.yml"
kustomization="${REPO_ROOT}/k3d/bootstrap/argocd/kustomization.yaml"
cmd_params="${REPO_ROOT}/k3d/bootstrap/argocd/cmd-params-cm-patch.yaml"
secret_delete_patch="${REPO_ROOT}/k3d/bootstrap/argocd/notifications-secret-delete-patch.yaml"
disable_patch="${REPO_ROOT}/k3d/bootstrap/argocd/notifications-disable-patch.yaml"
notifications_dir="${REPO_ROOT}/k3d/bootstrap/argocd/notifications"
trigger_failure="${notifications_dir}/trigger.on-failure.yaml"
trigger_deployed="${notifications_dir}/trigger.on-deployed.yaml"
template_failure="${notifications_dir}/template.app-failure.yaml"
service_webhook="${notifications_dir}/service.webhook.argocd_slack.yaml"

assert_file "$prometheus_config"
assert_file "$endpoint_rules"
assert_file "$alertmanager_config"
assert_file "$kustomization"
assert_file "$cmd_params"
assert_file "$secret_delete_patch"
assert_file "$trigger_failure"
assert_file "$template_failure"
assert_file "$service_webhook"

assert_missing "$argocd_rules"
assert_missing "$disable_patch"
assert_missing "$trigger_deployed"

assert_not_contains "$prometheus_config" "channel: argocd"
assert_not_contains "$prometheus_config" "job_name: argocd-application-controller"
assert_not_contains "$prometheus_config" "https://argocd.imcherry5778.xyz/"
assert_not_contains "$endpoint_rules" "ArgoCdEndpointDown"
assert_not_contains "$alertmanager_config" "slack-argocd-alerts"
assert_not_contains "$alertmanager_config" 'channel="argocd"'

assert_contains "$kustomization" "argocd-notifications-cm"
assert_contains "$kustomization" "service.webhook.argocd_slack=notifications/service.webhook.argocd_slack.yaml"
assert_contains "$kustomization" "template.app-failure=notifications/template.app-failure.yaml"
assert_contains "$kustomization" "trigger.on-failure=notifications/trigger.on-failure.yaml"
assert_not_contains "$kustomization" "trigger.on-deployed"
assert_contains "$cmd_params" "notificationscontroller.log.level: info"

assert_contains "$trigger_failure" "health.status == 'Degraded'"
assert_contains "$trigger_failure" "phase in ['Error', 'Failed']"
assert_not_contains "$trigger_failure" "OutOfSync"
assert_not_contains "$trigger_failure" "Unknown"
assert_contains "$service_webhook" 'url: $argocd-slack-webhook-url'

echo "selective Argo CD native notification tests passed"
