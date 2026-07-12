#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$root_dir/compose/config/semaphore/team-k6-projects.json"
reconciler="$root_dir/compose/scripts/reconcile-team-k6-tasks.sh"
playbook="$root_dir/compose/ansible/run-scalecart-api-hpa-load-test.yml"
k6_script="$root_dir/compose/scripts/k6/scalecart-api-hpa.js"
compose_file="$root_dir/compose/stacks/cicd/semaphore/compose.yaml"
agent_config="$root_dir/compose/stacks/security/vault-agent/config/agent.hcl"
bootstrap="$root_dir/compose/scripts/bootstrap-vault-k6-api-keys.sh"

fail() {
  echo "TEAM_K6_PROJECTS_VALIDATION=FAIL: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "manifest is missing"
[[ -f "$reconciler" ]] || fail "reconciler is missing"
[[ -f "$playbook" ]] || fail "Ansible playbook is missing"

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
[[ "$(grep -Fc 'project_id:$project' "$reconciler")" -ge 2 ]] || fail "Semaphore repository and environment payloads must include their project id"
grep -Fq '. + {id:$environment}' "$reconciler" || fail "Semaphore environment update payload must include its id"
grep -Fq '. + {id:$template}' "$reconciler" || fail "Semaphore template update payload must include its id"
grep -Fq '/run/vault-k6' "$playbook" || fail "playbook does not use the Vault key directory"
grep -Fq 'K6_DEMO_API_KEY' "$playbook" || fail "playbook does not read the k6 API key"
grep -Fq 'K6_RATE' "$playbook" || fail "playbook does not permit rate override"
grep -Fq 'K6_DURATION' "$playbook" || fail "playbook does not permit duration override"
grep -Fq 'scalecart-api-hpa.js' "$playbook" || fail "playbook must invoke the checked-in k6 workload"
grep -Fq 'SCALECART_K6_HOLD_DURATION' "$playbook" || fail "playbook must translate the k6 hold duration"
grep -Fq 'SCALECART_K6_HOLD_DURATION' "$k6_script" || fail "k6 script must read the translated hold duration"
grep -Fq '/opt/acer-mgmt:ro' "$compose_file" || fail "Semaphore lacks the read-only automation repository mount"
grep -Fq '/run/vault-k6:ro' "$compose_file" || fail "Semaphore lacks the read-only k6 key mount"
grep -Fq 'kv/data/mgmt/k6/ggg' "$agent_config" || fail "Vault Agent lacks the ggg k6 key template"
grep -Fq 'kv/data/mgmt/k6/oje' "$agent_config" || fail "Vault Agent lacks the oje k6 key template"
[[ "$(grep -Fc 'destination = "/vault/secrets/cicd/k6/' "$agent_config")" -eq 5 ]] || fail "Vault Agent must render five team k6 files"
[[ "$(grep -Fc 'perms = "0644"' "$agent_config")" -ge 5 ]] || fail "Semaphore must be able to read the k6-only Vault files"
grep -Fq 'sudo install -d -o 100 -g 0 -m 0750' "$bootstrap" || fail "Vault k6 bootstrap must create a Semaphore-readable render directory"
grep -Fq 'dd if=/dev/urandom' "$bootstrap" || fail "Vault k6 bootstrap must use the Vault image random source"
grep -Fq 'printf "{\"K6_DEMO_API_KEY\"' "$bootstrap" || fail "Vault k6 bootstrap must write valid JSON"
grep -Fq 'vault kv put -mount=kv "mgmt/k6/${team}"' "$bootstrap" || fail "Vault k6 bootstrap must create the runner key path"

echo "TEAM_K6_PROJECTS_VALIDATION=PASS"
