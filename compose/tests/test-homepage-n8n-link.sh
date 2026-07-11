#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
services="${REPO_ROOT}/compose/stacks/edge/homepage/config/services.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  grep -Fq -- "$expected" "$services" || fail "expected '${expected}' in ${services}"
}

[[ -f "$services" ]] || fail "missing file: $services"

assert_contains "    - n8n:"
assert_contains "        icon: n8n.png"
assert_contains "        href: https://n8n.{{HOMEPAGE_VAR_BASE_DOMAIN}}"
assert_contains "        description: Platform operations-digest automation"

echo "Homepage n8n link tests passed"
