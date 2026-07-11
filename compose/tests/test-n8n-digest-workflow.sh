#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
workflow="${REPO_ROOT}/compose/stacks/observability/n8n/workflows/platform-digest.json"
import_script="${REPO_ROOT}/compose/stacks/observability/n8n/scripts/import-workflows.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail "missing workflow: $workflow"
[[ -f "$import_script" ]] || fail "missing workflow import script: $import_script"

if command -v jq >/dev/null 2>&1; then
  jq empty "$workflow"
  jq -e '.id == "w2QbrmV1sZx4cKp9"' "$workflow" >/dev/null
  jq -e '.name == "ACER 전체 운영 다이제스트"' "$workflow" >/dev/null
  jq -e '.settings.timezone == "Asia/Seoul"' "$workflow" >/dev/null
  jq -e '[.nodes[].type] | index("n8n-nodes-base.manualTrigger")' "$workflow" >/dev/null
  jq -e '[.nodes[].type] | index("n8n-nodes-base.scheduleTrigger")' "$workflow" >/dev/null
  jq -e '[.nodes[].type] | index("n8n-nodes-base.httpRequest")' "$workflow" >/dev/null
  jq -e '[.nodes[].type] | index("n8n-nodes-base.code")' "$workflow" >/dev/null
elif command -v node >/dev/null 2>&1; then
  node - "$workflow" <<'NODE'
const fs = require('fs');
const workflow = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const types = workflow.nodes.map((node) => node.type);
const required = [
  'n8n-nodes-base.manualTrigger',
  'n8n-nodes-base.scheduleTrigger',
  'n8n-nodes-base.httpRequest',
  'n8n-nodes-base.code',
];
if (workflow.id !== 'w2QbrmV1sZx4cKp9' || workflow.name !== 'ACER 전체 운영 다이제스트' || workflow.settings?.timezone !== 'Asia/Seoul' || required.some((type) => !types.includes(type))) {
  process.exit(1);
}
NODE
else
  fail "jq or node is required to validate workflow JSON"
fi

grep -Fq '0 5 9 * * *' "$workflow" || fail "schedule must be 09:05 Asia/Seoul"
grep -Fq 'http://prometheus:9090/api/v1/query' "$workflow" || fail "missing Prometheus API query"
if command -v jq >/dev/null 2>&1; then
  jq -r '.. | strings' "$workflow" | grep -Fq 'ALERTS{alertstate="firing"}' || fail "missing firing alert query"
else
  grep -Fq 'ALERTS{alertstate=\"firing\"}' "$workflow" || fail "missing firing alert query"
fi
grep -Fq '필수 Prometheus 시계열 미수집' "$workflow" || fail "missing collection-gap classification"
grep -Fq 'ggg' "$workflow" || fail "missing ggg scope"
grep -Fq 'khb' "$workflow" || fail "missing khb scope"
grep -Fq 'ljw' "$workflow" || fail "missing ljw scope"
grep -Fq 'nmg' "$workflow" || fail "missing nmg scope"
grep -Fq 'oje' "$workflow" || fail "missing oje scope"
grep -Fq 'SLACK_WEBHOOK_INFRA' "$workflow" || fail "missing Slack environment contract"
grep -Fq 'n8n import:workflow --input=/workflows/platform-digest.json' "$import_script" || fail "missing workflow import command"

if grep -Eqi 'docker\\.sock|n8n-nodes-base\\.ssh|openstack' "$workflow"; then
  fail "workflow contains a prohibited infrastructure access path"
fi

echo "n8n digest workflow tests passed"
