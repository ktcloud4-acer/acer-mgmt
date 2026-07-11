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

node - "$manifest" <<'NODE' || exit 1
const fs = require('fs')
const entries = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
const teams = ['ggg', 'khb', 'ljw', 'nmg', 'oje']
if (!Array.isArray(entries) || entries.length !== teams.length) process.exit(1)
for (const team of teams) {
  const entry = entries.find((item) => item.team === team)
  if (!entry || entry.project !== `acer-aio-${team}` || entry.base_url !== `https://${team}.imcherry5778.xyz` || entry.vault_path !== `mgmt/k6/${team}`) process.exit(1)
}
if (JSON.stringify(entries).match(/access[_-]?token|api[_-]?key|secret/i)) process.exit(1)
NODE

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
