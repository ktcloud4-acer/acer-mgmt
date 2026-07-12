#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIDDLEWARES="${ROOT_DIR}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The Keycloak admin console embeds its own 3p-cookie check page. Keep that
# same-origin iframe working while still allowing Dashy's demo workspace.
grep -Fq "frame-ancestors 'self' https://dash.imcherry5778.xyz" "$MIDDLEWARES" \
  || fail "keycloak CSP must allow self and Dashy as frame ancestors"

echo "keycloak console iframe CSP tests passed"
