#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
services="${HOMEPAGE_SERVICES:-${REPO_ROOT}/compose/stacks/edge/homepage/config/services.yaml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_card_field() {
  local field="$1"
  local expected="$2"
  local count

  count="$(printf '%s\n' "$n8n_card" | awk -v field="$field" '$0 ~ ("^        " field ":") { count++ } END { print count + 0 }')"
  [[ "$count" -eq 1 ]] || fail "expected exactly one ${field} field in the Observability n8n card"
  printf '%s\n' "$n8n_card" | grep -Fxq -- "$expected" || fail "expected '${expected}' in the Observability n8n card"
}

[[ -f "$services" ]] || fail "missing file: $services"

n8n_card="$(awk '
  { sub(/\r$/, "") }
  $0 == "- Observability:" { observability = 1; next }
  observability && $0 ~ /^- / { exit }
  !observability { next }
  $0 == "    - n8n:" { n8n = 1; next }
  n8n && $0 ~ /^    - / { exit }
  n8n { print }
' "$services")"

[[ -n "$n8n_card" ]] || fail "missing n8n card in the Observability group"

assert_card_field "icon" "        icon: n8n.png"
assert_card_field "href" "        href: https://n8n.{{HOMEPAGE_VAR_BASE_DOMAIN}}"
assert_card_field "description" "        description: Platform operations-digest automation"

echo "Homepage n8n link tests passed"
