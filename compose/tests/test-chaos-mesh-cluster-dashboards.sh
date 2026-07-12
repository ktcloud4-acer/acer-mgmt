#!/usr/bin/env bash
set -euo pipefail

route="compose/stacks/edge/traefik/config/dynamic/k3d.yaml"

test -f "$route"
grep -Fq 'Host(`chaos.imcherry5778.xyz`)' "$route"
if grep -Fq 'mgmt-chaos.imcherry5778.xyz' "$route"; then
  echo 'mgmt-chaos must not remain configured' >&2
  exit 1
fi

for team in nmg ggg khb ljw oje; do
  grep -Fq "Host(\`$team-chaos.imcherry5778.xyz\`)" "$route"
  grep -Fq "$team-chaos-dashboard:" "$route"
  grep -Fq "url: \"https://$team-chaos.tailc0244b.ts.net\"" "$route"
done

if grep -A5 -- 'nmg-chaos-dashboard:' "$route" | grep -Fq 'passHostHeader: true'; then
  echo 'team Chaos Dashboard proxy must not preserve the public Host header' >&2
  exit 1
fi

echo 'CHAOS_MESH_CLUSTER_DASHBOARD_ROUTE_VALIDATION=PASS'
