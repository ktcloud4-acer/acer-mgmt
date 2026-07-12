#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inventory="$root/compose/ansible/aio-hosts.yml"
playbook="$root/compose/ansible/bootstrap-tailscale-operator.yml"
team=${1:-}

if [[ -z "$team" ]]; then
  read -rp 'Team (ggg|khb|ljw|nmg|oje): ' team
fi
case "$team" in
  ggg|khb|ljw|nmg|oje) ;;
  *) echo "Unsupported team: $team" >&2; exit 2 ;;
esac

key=${AIO_SSH_PRIVATE_KEY:-"$HOME/.ssh/acer.pem"}
test -r "$inventory"
test -r "$playbook"
test -r "$key" || { echo "AIO SSH key is not readable: $key" >&2; exit 1; }

export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS='-o StrictHostKeyChecking=yes'
exec ansible-playbook -i "$inventory" --limit "aio_$team" \
  --private-key "$key" -e "tailnet_team=$team" "$playbook"
