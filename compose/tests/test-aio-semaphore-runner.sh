#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose="$root/compose/stacks/cicd/semaphore/compose.yaml"
agent="$root/compose/stacks/security/vault-agent/config/agent.hcl"
task="$root/compose/scripts/tailscale/semaphore-bootstrap-operator.sh"
reconciler="$root/compose/scripts/reconcile-tailscale-operator-tasks.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }

contains "$compose" 'SEMAPHORE_USE_REMOTE_RUNNER: "true"'
contains "$compose" 'traefik.http.routers.semaphore-runner.rule=Host(`semaphore.${BASE_DOMAIN:-imcherry5778.xyz}`) && PathPrefix(`/api/internal/runners`)'
contains "$compose" 'traefik.http.routers.semaphore-runner.priority=200'
contains "$compose" 'traefik.http.routers.semaphore-runner.service=semaphore'
contains "$agent" 'SEMAPHORE_RUNNER_REGISTRATION_TOKEN='
contains "$agent" 'kv/data/mgmt/cicd/semaphore-runner/aio'
[[ "$(grep -Fc 'SEMAPHORE_RUNNER_REGISTRATION_TOKEN=' "$agent")" -eq 2 ]] || fail 'Runner token must render to both Semaphore env files'
contains "$task" 'vault_addr=https://vault.imcherry5778.xyz'
absent "$task" '/run/secrets/acer.pem'
absent "$task" 'ssh -i'
absent "$task" '16443'
contains "$reconciler" 'git@gitlab.imcherry5778.xyz:acer-group/acer-mgmt.git'
contains "$reconciler" 'AIO Runner GitLab deploy key'
contains "$reconciler" 'gitlab_deploy_key_private_b64'

echo 'AIO_SEMAPHORE_RUNNER_CONTRACT=PASS'
