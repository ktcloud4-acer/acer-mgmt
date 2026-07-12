#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inventory="$root/compose/ansible/aio-hosts.yml"
playbook="$root/compose/ansible/verify-aio-connectivity.yml"
runner="$root/compose/scripts/check-aio-tailnet-ansible.sh"
bootstrap_playbook="$root/compose/ansible/bootstrap-tailscale-operator.yml"
bootstrap_runner="$root/compose/scripts/bootstrap-aio-tailscale-operator.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

test -f "$inventory" || fail 'missing AIO Tailnet inventory'
test -f "$playbook" || fail 'missing AIO connectivity playbook'
test -f "$runner" || fail 'missing AIO connectivity runner'
test -f "$bootstrap_playbook" || fail 'missing central Operator bootstrap playbook'
test -f "$bootstrap_runner" || fail 'missing central Operator bootstrap runner'

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
contains "$bootstrap_playbook" 'mgmt/tailscale/operators/{{ tailnet_team }}'
contains "$bootstrap_playbook" 'tailscale_kubeconfig: /home/ubuntu/.kube/config'
contains "$bootstrap_playbook" '          echo'
contains "$bootstrap_playbook" 'delegate_to: localhost'
contains "$bootstrap_playbook" 'no_log: true'
contains "$bootstrap_playbook" 'mode: "0600"'
contains "$bootstrap_playbook" 'helm upgrade --install tailscale-operator'
contains "$bootstrap_playbook" 'kind: ProxyGroup'
contains "$bootstrap_playbook" 'tags: ["tag:k8s"]'
contains "$bootstrap_playbook" 'always:'
contains "$bootstrap_runner" 'AIO_SSH_PRIVATE_KEY'
contains "$bootstrap_runner" 'StrictHostKeyChecking=yes'
if grep -Eq 'tskey-[A-Za-z0-9_-]+' "$inventory" "$playbook" "$runner" "$bootstrap_playbook" "$bootstrap_runner"; then
  fail 'secret literal in central AIO Ansible source'
fi

echo 'AIO_TAILNET_ANSIBLE_CONTRACT=PASS'
