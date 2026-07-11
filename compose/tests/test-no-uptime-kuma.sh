#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if matches=$(rg -n -i \
  --glob '!test-no-uptime-kuma.sh' \
  'uptime[- ]kuma|kuma\.\$\{BASE_DOMAIN\}|kuma\.\{\{HOMEPAGE_VAR_BASE_DOMAIN\}\}|kuma\.imcherry5778\.xyz' \
  "${ROOT_DIR}/compose" "${ROOT_DIR}/docs"); then
  echo "FAIL: Uptime Kuma references remain:" >&2
  echo "${matches}" >&2
  exit 1
fi

echo "Uptime Kuma removal tests passed"
