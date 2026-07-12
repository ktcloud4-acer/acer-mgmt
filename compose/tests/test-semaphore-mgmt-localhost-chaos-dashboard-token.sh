#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
playbook="$root/compose/ansible/issue-mgmt-chaos-dashboard-token.yml"
reconciler="$root/compose/scripts/reconcile-mgmt-chaos-dashboard-token-task.sh"
issuer="$root/compose/scripts/issue-chaos-dashboard-token.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }

for file in "$playbook" "$reconciler" "$issuer"; do
  test -f "$file" || fail "missing $file"
done

contains "$playbook" 'hosts: localhost'
contains "$playbook" 'connection: local'
contains "$playbook" 'issue-chaos-dashboard-token.sh'
contains "$playbook" 'chaos_dashboard_token.stdout'
contains "$playbook" 'no_log: true'
contains "$issuer" 'Paste the following one-time token'
absent "$playbook" 'ssh '
absent "$playbook" 'cluster-admin'

contains "$reconciler" 'mgmt/chaos-dashboard-token-issuer'
contains "$reconciler" 'chaos-dashboard-token-issuer'
contains "$reconciler" 'Semaphore localhost'
contains "$reconciler" 'type:"static-yaml"'
contains "$reconciler" 'inventory_id:$inventory'
contains "$reconciler" 'Chaos Dashboard token'
contains "$reconciler" 'compose/ansible/issue-mgmt-chaos-dashboard-token.yml'
contains "$reconciler" 'app:"ansible"'
absent "$reconciler" 'ssh '
absent "$reconciler" 'cluster-admin'

echo 'SEMAPHORE_MGMT_LOCALHOST_CHAOS_DASHBOARD_TOKEN_CONTRACT=PASS'
