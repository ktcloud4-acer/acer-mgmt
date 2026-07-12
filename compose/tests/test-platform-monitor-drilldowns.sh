#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
server="${ROOT_DIR}/compose/stacks/edge/platform-monitor/app/server.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

for url in \
  'https://grafana.imcherry5778.xyz' \
  'https://kibana.imcherry5778.xyz' \
  'https://argocd.imcherry5778.xyz' \
  'https://chaos.imcherry5778.xyz'; do
  grep -Fq "$url" "$server" || fail "missing Platform Health drill-down: $url"
done

grep -Fq 'Drill-down' "$server" || fail 'missing Drill-down panel heading'
echo 'PLATFORM_MONITOR_DRILLDOWNS=PASS'
