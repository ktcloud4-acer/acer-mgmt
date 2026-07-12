#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose="$root/compose/stacks/cicd/semaphore/compose.yaml"
dockerfile="$root/compose/stacks/cicd/semaphore/Dockerfile"
manifest="$root/compose/config/semaphore/chaos-dashboard-token-projects.json"
playbook="$root/compose/ansible/issue-chaos-dashboard-token.yml"
reconciler="$root/compose/scripts/reconcile-team-chaos-dashboard-token-tasks.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }

for file in "$compose" "$dockerfile" "$manifest" "$playbook" "$reconciler"; do
  test -f "$file" || fail "missing $file"
done

contains "$dockerfile" 'ansible-core'
contains "$dockerfile" 'openssh-client'
absent "$compose" 'SEMAPHORE_USE_REMOTE_RUNNER'
absent "$compose" 'traefik.http.routers.semaphore-runner'

jq -e '
  type == "array" and length == 5 and
  ([.[].team] | sort == ["ggg", "khb", "ljw", "nmg", "oje"]) and
  ([.[].project] | sort == ["acer-aio-ggg", "acer-aio-khb", "acer-aio-ljw", "acer-aio-nmg", "acer-aio-oje"])
' "$manifest" >/dev/null || fail 'invalid team-project manifest'

contains "$playbook" 'hosts: "aio_{{ chaos_dashboard_team }}"'
contains "$playbook" "chaos_dashboard_team in ['ggg', 'khb', 'ljw', 'nmg', 'oje']"
contains "$playbook" 'StrictHostKeyChecking=accept-new'
contains "$playbook" '/run/secrets/acer.pem'
contains "$playbook" '          - create'
contains "$playbook" '          - token'
contains "$playbook" '          - chaos-dashboard-manager'
contains "$playbook" '          - --duration=10m'
contains "$playbook" 'Paste the following one-time token'
absent "$playbook" 'cluster-admin'
absent "$playbook" 'CHAOS_TOKEN_ISSUER_KUBECONFIG_B64'
absent "$playbook" 'vault '

contains "$reconciler" 'chaos:issue-dashboard-token'
contains "$reconciler" 'Chaos Dashboard token - '
contains "$reconciler" 'api_delete'
contains "$reconciler" 'Chaos Dashboard token'
contains "$reconciler" 'SEMAPHORE_MANIFEST_PATH:-/tmp/chaos-dashboard-token-projects.json'
contains "$reconciler" 'AIO Tailnet'
contains "$reconciler" 'type:"static-yaml"'
contains "$reconciler" 'inventory_id:$inventory'
contains "$reconciler" 'compose/ansible/issue-chaos-dashboard-token.yml'
contains "$reconciler" '--extra-vars'
contains "$reconciler" 'chaos_dashboard_team='
contains "$reconciler" 'app:"ansible"'
contains "$reconciler" 'acer-mgmt'
absent "$reconciler" 'CHAOS_TOKEN_ISSUER_KUBECONFIG_B64'

echo 'SEMAPHORE_TEAM_CHAOS_DASHBOARD_TOKEN_CONTRACT=PASS'
