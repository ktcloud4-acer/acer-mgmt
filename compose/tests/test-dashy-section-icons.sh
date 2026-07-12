#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="${ROOT_DIR}/compose/stacks/edge/dashy/config/conf.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_section_icon() {
  local section="$1" icon="$2"
  awk -v section="$section" -v icon="$icon" '
    $0 == "  - name: " section { found=1; next }
    found && $0 == "    icon: " icon { matched=1; exit }
    found && $0 ~ /^  - name:/ { exit }
  END { exit found && matched ? 0 : 1 }
  ' "$config" || fail "expected ${section} section icon ${icon}"
}

assert_section_icon Backup 'fas fa-archive'
assert_section_icon Security 'fas fa-shield-alt'

echo 'DASHY_SECTION_ICONS=PASS'
