#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${root_dir}/scripts/bootstrap-vault-team-harbor-pull.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq "$2" "$1" || fail "missing '$2'"; }

[[ -f "$script" ]] || fail "missing Harbor pull Vault bootstrap script"
contains "$script" 'apps/harbor/pull'
contains "$script" 'dockerconfigjson'
contains "$script" 'HARBOR_ADMIN_PASSWORD'
contains "$script" '/api/v2.0/robots'
contains "$script" 'level:"project"'
contains "$script" 'resource:"repository",action:"pull"'
contains "$script" 'scalecart-pull'
contains "$script" 'teams=(ggg khb ljw nmg oje)'
contains "$script" 'scalecart-$1'
contains "$script" 'kv/data/apps/harbor/pull'
contains "$script" 'kv/metadata/apps/harbor/pull'
contains "$script" 'vault policy write'

if grep -Eq 'echo .*HARBOR_ADMIN_PASSWORD|echo .*robot_token|echo .*registry_password|set -x' "$script"; then
  fail 'Harbor registry credentials must not be printed or traced'
fi

echo 'TEAM_HARBOR_PULL_VAULT_BOOTSTRAP=PASS'
