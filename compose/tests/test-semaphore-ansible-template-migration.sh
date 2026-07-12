#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dockerfile="$root/compose/stacks/cicd/semaphore/Dockerfile"
semaphore_compose="$root/compose/stacks/cicd/semaphore/compose.yaml"
dns_playbook="$root/compose/ansible/dns-smoke-test.yml"
k6_playbook="$root/compose/ansible/run-scalecart-api-hpa-load-test.yml"
dns_reconciler="$root/compose/scripts/reconcile-mgmt-dns-smoke-task.sh"
k6_reconciler="$root/compose/scripts/reconcile-team-k6-tasks.sh"
dns_wrapper="$root/compose/scripts/dns-smoke-test.sh"
k6_wrapper="$root/compose/scripts/k6/semaphore-scalecart-api-hpa.sh"
k6_launcher="$root/compose/scripts/k6/run-scalecart-api-hpa.sh"
k6_workload="$root/compose/scripts/k6/scalecart-api-hpa.js"
readme="$root/compose/ansible/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
absent_file() { test ! -e "$1" || fail "unexpected legacy wrapper: $1"; }

for file in "$dockerfile" "$semaphore_compose" "$dns_playbook" "$k6_playbook" "$dns_reconciler" "$k6_reconciler" "$k6_workload" "$readme"; do
  test -f "$file" || fail "missing $file"
done
absent_file "$dns_wrapper"
absent_file "$k6_wrapper"
absent_file "$k6_launcher"

contains "$dockerfile" 'bind-tools'
contains "$semaphore_compose" 'group_add:'
contains "$semaphore_compose" '- "0"'

contains "$dns_playbook" 'hosts: localhost'
contains "$dns_playbook" 'connection: local'
contains "$dns_playbook" 'dig'
contains "$dns_playbook" 'registry-1.docker.io'
contains "$dns_playbook" 'kubectl'
contains "$dns_playbook" 'grafana.'
contains "$dns_playbook" 'alertmanager'

contains "$k6_playbook" 'hosts: localhost'
contains "$k6_playbook" 'connection: local'
contains "$k6_playbook" '/run/vault-k6'
contains "$k6_playbook" 'K6_DEMO_API_KEY'
contains "$k6_playbook" 'no_log: true'
contains "$k6_playbook" 'scalecart-api-hpa.js'
contains "$k6_playbook" '/opt/acer-mgmt/compose/scripts/k6/scalecart-api-hpa.js'
contains "$k6_playbook" 'K6_RATE'
contains "$k6_playbook" 'K6_DURATION'
contains "$k6_playbook" "lookup('ansible.builtin.env', 'K6_TEAM')"
contains "$k6_playbook" "lookup('ansible.builtin.env', 'K6_BASE_URL')"

contains "$dns_reconciler" 'check:dns'
contains "$dns_reconciler" 'compose/ansible/dns-smoke-test.yml'
contains "$dns_reconciler" 'app:"ansible"'
contains "$dns_reconciler" 'Semaphore localhost'

contains "$k6_reconciler" 'compose/ansible/run-scalecart-api-hpa-load-test.yml'
contains "$k6_reconciler" 'app:"ansible"'
contains "$k6_reconciler" 'Semaphore localhost'
contains "$k6_reconciler" 'inventory_id:$inventory'

echo 'SEMAPHORE_ANSIBLE_TEMPLATE_MIGRATION_CONTRACT=PASS'
