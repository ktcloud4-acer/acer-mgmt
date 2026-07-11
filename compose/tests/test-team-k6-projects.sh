#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$root_dir/compose/config/semaphore/team-k6-projects.json"
reconciler="$root_dir/compose/scripts/reconcile-team-k6-tasks.sh"
runner="$root_dir/compose/scripts/k6/semaphore-scalecart-api-hpa.sh"
compose_file="$root_dir/compose/stacks/cicd/semaphore/compose.yaml"
agent_config="$root_dir/compose/stacks/security/vault-agent/config/agent.hcl"

fail() {
  echo "TEAM_K6_PROJECTS_VALIDATION=FAIL: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "manifest is missing"
[[ -f "$reconciler" ]] || fail "reconciler is missing"
[[ -f "$runner" ]] || fail "runner is missing"

jq -e '
  . as $entries | type == "array" and length == 5 and
  all(["ggg", "khb", "ljw", "nmg", "oje"][]; . as $team |
    any($entries[]; .team == $team and .project == ("acer-aio-" + $team) and
      .base_url == ("https://" + $team + ".imcherry5778.xyz") and
      .vault_path == ("mgmt/k6/" + $team)))
' "$manifest" >/dev/null || fail "team project manifest is invalid"

! grep -Eqi 'access[_-]?token|api[_-]?key|secret' "$manifest" \
  || fail "manifest must not contain credentials"

grep -Fq 'ScaleCart API HPA Load Test' "$reconciler" || fail "task name is not reconciled"
grep -Fq 'TEAM_K6_DRY_RUN' "$reconciler" || fail "dry-run guard is missing"
grep -Fq '/run/vault-k6/${K6_TEAM}.env' "$runner" || fail "runner does not use its Vault-rendered key file"
grep -Fq 'K6_RATE' "$runner" || fail "runner does not permit rate override"
grep -Fq 'K6_DURATION' "$runner" || fail "runner does not permit duration override"
grep -Fq '/opt/acer-mgmt:ro' "$compose_file" || fail "Semaphore lacks the read-only automation repository mount"
grep -Fq '/run/vault-k6:ro' "$compose_file" || fail "Semaphore lacks the read-only k6 key mount"
grep -Fq 'kv/data/mgmt/k6/ggg' "$agent_config" || fail "Vault Agent lacks the ggg k6 key template"
grep -Fq 'kv/data/mgmt/k6/oje' "$agent_config" || fail "Vault Agent lacks the oje k6 key template"

echo "TEAM_K6_PROJECTS_VALIDATION=PASS"
