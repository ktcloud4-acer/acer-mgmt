#!/usr/bin/env bash
set -euo pipefail

route="compose/stacks/edge/traefik/config/dynamic/k3d.yaml"

test -f "$route"
grep -Fq 'k3d-chaos-dashboard:' "$route"
grep -Fq 'Host(`chaos.imcherry5778.xyz`)' "$route"
grep -Fq 'service: k3d-ingress' "$route"
if grep -Fq 'mgmt-chaos.imcherry5778.xyz' "$route"; then
  echo 'mgmt-chaos route must not remain configured' >&2
  exit 1
fi

echo 'CHAOS_MESH_CENTRAL_DASHBOARD_ROUTE_VALIDATION=PASS'
