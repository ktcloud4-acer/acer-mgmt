#!/usr/bin/env bash
set -euo pipefail

route="compose/stacks/edge/traefik/config/dynamic/k3d.yaml"

test -f "$route"
grep -Fq 'Host(`chaos.imcherry5778.xyz`)' "$route"
if grep -Fq 'mgmt-chaos.imcherry5778.xyz' "$route"; then
  echo 'mgmt-chaos must not remain configured' >&2
  exit 1
fi

assert_team_service() {
  local team="$1"
  awk -v service="    ${team}-chaos-dashboard:" \
      -v url="          - url: \"https://${team}-ingress.tailc0244b.ts.net\"" '
    $0 == "  services:" { in_services=1; next }
    in_services && $0 == service { found=1; next }
    found && /^    [[:alnum:]-]+:$/ { exit }
    found && $0 == "        passHostHeader: true" { host_found=1 }
    found && $0 == url { url_found=1 }
    END { exit found && host_found && url_found ? 0 : 1 }
  ' "$route" || {
    echo "${team} Chaos Dashboard must use ${team}-ingress with passHostHeader=true" >&2
    exit 1
  }
}

for team in nmg ggg khb ljw oje; do
  grep -Fq "Host(\`$team-chaos.imcherry5778.xyz\`)" "$route"
  grep -Fq "$team-chaos-dashboard:" "$route"
  assert_team_service "$team"
done

echo 'CHAOS_MESH_CLUSTER_DASHBOARD_ROUTE_VALIDATION=PASS'
