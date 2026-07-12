#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inventory="$root/compose/ansible/aio-hosts.yml"
playbook="$root/compose/ansible/verify-aio-connectivity.yml"
runner="$root/compose/scripts/check-aio-tailnet-ansible.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

test -f "$inventory" || fail 'missing AIO Tailnet inventory'
test -f "$playbook" || fail 'missing AIO connectivity playbook'
test -f "$runner" || fail 'missing AIO connectivity runner'

for team in ggg khb ljw nmg oje; do
  contains "$inventory" "aio_$team:"
  contains "$inventory" "$team-aio.tailc0244b.ts.net"
done
contains "$inventory" 'ansible_user: ubuntu'
contains "$playbook" 'ansible.builtin.ping'
contains "$playbook" 'changed_when: false'
contains "$runner" 'AIO_SSH_PRIVATE_KEY'
contains "$runner" 'ansible-playbook'
contains "$runner" 'StrictHostKeyChecking=yes'
if grep -Eq 'tskey-[A-Za-z0-9_-]+|oauth_client_secret|VAULT_TOKEN' "$inventory" "$playbook" "$runner"; then
  fail 'secret literal in central AIO Ansible source'
fi

echo 'AIO_TAILNET_ANSIBLE_CONTRACT=PASS'
