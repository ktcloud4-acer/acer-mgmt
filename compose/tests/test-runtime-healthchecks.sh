#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMETHEUS="${ROOT_DIR}/compose/stacks/observability/prometheus/compose.yaml"
RUNTIME="${ROOT_DIR}/compose/stacks/edge/docker-runtime/compose.yaml"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

contains "$PROMETHEUS" 'wget -q -O /dev/null http://127.0.0.1:9100/metrics'
contains "$PROMETHEUS" 'wget -q -O /dev/null http://127.0.0.1:9115/metrics'
contains "$RUNTIME" 'wget -q -O /dev/null http://127.0.0.1:2375/version'

echo 'RUNTIME_HEALTHCHECKS=PASS'
