#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$root/compose/scripts/bootstrap-teleport-team-nodes.sh"
readme="$root/compose/ansible/README.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }

test -f "$runner" || fail 'missing central Teleport team enrollment runner'
test -x "$runner" || fail 'central Teleport team enrollment runner must be executable'
[[ "$(git -C "$root" ls-files -s -- compose/scripts/bootstrap-teleport-team-nodes.sh | awk '{print $1}')" == '100755' ]] || \
  fail 'central Teleport team enrollment runner must be tracked as executable'
contains "$runner" 'set -euo pipefail'
contains "$runner" 'EUID'
contains "$runner" 'ggg|khb|ljw|nmg|oje'
contains "$runner" "readonly TOKEN_TTL='15m'"
contains "$runner" 'tctl tokens add --type=node --ttl="$TOKEN_TTL" --format=text'
contains "$runner" 'for role in aio master worker1 worker2'
contains "$runner" 'mktemp -d'
contains "$runner" 'AIO_SSH_PRIVATE_KEY'
contains "$runner" 'StrictHostKeyChecking=accept-new'
contains "$runner" '/dev/stdin'
contains "$runner" '/run/acer-bootstrap/teleport'
contains "$runner" '25-teleport-nodes/bootstrap.sh'
contains "$runner" 'tctl nodes ls --format=json'
contains "$runner" 'metadata.labels.team'
contains "$runner" 'metadata.labels.role'
contains "$runner" 'tctl tokens rm'
contains "$runner" 'trap cleanup EXIT INT TERM'
contains "$readme" 'bootstrap-teleport-team-nodes.sh'
if grep -Eiq "tsv[^[:space:]\"']*|tskey-" "$runner" "$readme"; then
  fail 'token literal in central Teleport enrollment source'
fi

echo 'TELEPORT_TEAM_ENROLLMENT_CONTRACT=PASS'
