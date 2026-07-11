#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing file: ${file}"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "did not expect '${unexpected}' in ${file}"
  fi
}

compose_file="${REPO_ROOT}/compose/stacks/observability/uptime-kuma/compose.yaml"
homepage_services="${REPO_ROOT}/compose/stacks/edge/homepage/config/services.yaml"
runbook="${REPO_ROOT}/docs/runbooks/uptime-kuma-2026-07-11.md"

assert_file "$compose_file"
assert_file "$runbook"
assert_contains "$compose_file" "image: louislam/uptime-kuma:2"
assert_contains "$compose_file" "container_name: uptime-kuma"
assert_contains "$compose_file" "restart: unless-stopped"
assert_contains "$compose_file" '${DATA_ROOT:-/home/mgmt-data}/uptime-kuma:/app/data:Z'
assert_contains "$compose_file" 'traefik.http.routers.uptime-kuma.rule=Host(`kuma.${BASE_DOMAIN}`)'
assert_contains "$compose_file" 'traefik.http.routers.uptime-kuma.middlewares=sso-auth@file,secure-headers@file'
assert_contains "$compose_file" "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
assert_contains "$compose_file" 'test: ["CMD", "extra/healthcheck"]'
assert_not_contains "$compose_file" "/var/run/docker.sock"
assert_not_contains "$compose_file" "ports:"

assert_contains "$homepage_services" "Uptime Kuma:"
assert_contains "$homepage_services" "https://kuma.{{HOMEPAGE_VAR_BASE_DOMAIN}}"

for team in nmg ggg oje khb ljw; do
  assert_contains "$runbook" "https://${team}-operator.tailc0244b.ts.net/livez"
  assert_contains "$runbook" "https://${team}.\${BASE_DOMAIN}/"
done

echo "uptime kuma stack tests passed"
