#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$root/compose/config/semaphore/tailscale-operator-projects.json"
task="$root/compose/scripts/tailscale/semaphore-bootstrap-operator.sh"
vault_bootstrap="$root/compose/scripts/bootstrap-vault-tailscale-operator.sh"
reconciler="$root/compose/scripts/reconcile-tailscale-operator-tasks.sh"
dockerfile="$root/compose/stacks/cicd/semaphore/Dockerfile"

fail() { echo "FAIL: $*" >&2; exit 1; }

test -f "$manifest" || fail "missing Tailscale bootstrap manifest"
test -f "$task" || fail "missing Tailscale bootstrap task"
test -f "$vault_bootstrap" || fail "missing Vault bootstrap script"
test -f "$reconciler" || fail "missing Semaphore bootstrap reconciler"
jq -e 'length == 5 and all(.[]; has("team") and has("project") and has("operator_vault_path") and has("bootstrap_vault_path") and has("argocd_vault_path") and has("proxy_hostname"))' "$manifest" >/dev/null || fail "invalid team bootstrap manifest"
for team in ggg khb ljw nmg oje; do
  jq -e --arg team "$team" '.[] | select(.team == $team and .project == ("acer-aio-" + $team))' "$manifest" >/dev/null || fail "missing team: $team"
  grep -Fq "mgmt/tailscale/operators/$team" "$vault_bootstrap" || fail "missing operator Vault path: $team"
  grep -Fq "mgmt/tailscale/bootstrap/$team" "$vault_bootstrap" || fail "missing recovery Vault path: $team"
done
grep -Fq 'ARG HELM_VERSION=v3.19.0' "$dockerfile" || fail "Semaphore image must pin Helm"
grep -Fq 'TAILSCALE_OPERATOR_CHART_VERSION=1.98.4' "$task" || fail "Tailscale chart must be pinned"
grep -Fq 'kind: ProxyGroup' "$task" || fail "ProxyGroup is required"
grep -Fq 'mode: noauth' "$task" || fail "ProxyGroup must use noauth"
grep -Fq 'allow_parallel_tasks:false' "$reconciler" || fail "bootstrap task must be serialized"
grep -Fq 'trap cleanup EXIT' "$task" || fail "credential cleanup is required"
if grep -Eq 'tskey-[A-Za-z0-9_-]+' "$task" "$vault_bootstrap" "$reconciler"; then fail "credentials must not be committed"; fi
bash -n "$task" "$vault_bootstrap" "$reconciler"
echo 'TAILSCALE_OPERATOR_BOOTSTRAP_CONTRACT=PASS'
