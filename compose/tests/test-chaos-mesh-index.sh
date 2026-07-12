#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dashy_config="${ROOT_DIR}/compose/stacks/edge/dashy/config/conf.yml"
k3d_config="${ROOT_DIR}/compose/stacks/edge/traefik/config/dynamic/k3d.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_router_uses_sso() {
  local router="$1"
  awk -v router="$router" '
    $0 == "    " router ":" { found=1; next }
    found && /^    [[:alnum:]-]+:$/ { exit }
    found && $0 == "        - sso-auth" { matched=1 }
    END { exit found && matched ? 0 : 1 }
  ' "$k3d_config" || fail "expected ${router} to use sso-auth"
}

assert_chaos_card() {
  local title="$1" url="$2" status_url="$3"
  awk -v title="$title" -v url="$url" -v status_url="$status_url" '
    $0 == "      - title: " title { found=1; next }
    found && $0 == "        url: " url { url_found=1 }
    found && $0 == "        statusCheckUrl: " status_url { check_url_found=1 }
    found && $0 == "        statusCheckAcceptCodes: '\''200'\''" { code_found=1 }
    found && $0 ~ /^      - title:/ { exit }
    END { exit found && url_found && check_url_found && code_found ? 0 : 1 }
  ' "$dashy_config" || fail "expected Chaos Mesh card ${title} with explicit 200 status check"
}

grep -Fq 'name: Chaos Mesh' "$dashy_config" || fail 'missing Chaos Mesh section'

for router in k3d-chaos-dashboard ggg-chaos-dashboard khb-chaos-dashboard ljw-chaos-dashboard nmg-chaos-dashboard oje-chaos-dashboard; do
  assert_router_uses_sso "$router"
done

assert_chaos_card 'Mgmt Chaos' 'https://chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/mgmt'
assert_chaos_card 'ggg Chaos' 'https://ggg-chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/ggg'
assert_chaos_card 'khb Chaos' 'https://khb-chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/khb'
assert_chaos_card 'ljw Chaos' 'https://ljw-chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/ljw'
assert_chaos_card 'nmg Chaos' 'https://nmg-chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/nmg'
assert_chaos_card 'oje Chaos' 'https://oje-chaos.imcherry5778.xyz' 'http://platform-monitor:8080/api/status/chaos/oje'

echo 'CHAOS_MESH_INDEX=PASS'
