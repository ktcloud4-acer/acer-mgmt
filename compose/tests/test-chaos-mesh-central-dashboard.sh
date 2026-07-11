#!/usr/bin/env bash
set -euo pipefail

route="compose/stacks/edge/traefik/config/dynamic/k3d.yaml"

test -f "$route"
grep -Fq 'k3d-chaos-dashboard:' "$route"
grep -Fq 'Host(`mgmt-chaos.imcherry5778.xyz`)' "$route"
grep -Fq 'service: k3d-ingress' "$route"
grep -Fq "regex: '^https://chaos\\.imcherry5778\\.xyz/(.*)'" "$route"

echo 'CHAOS_MESH_CENTRAL_DASHBOARD_ROUTE_VALIDATION=PASS'
