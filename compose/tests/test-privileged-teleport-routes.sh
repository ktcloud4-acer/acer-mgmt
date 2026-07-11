#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
teleport_config="$ROOT_DIR/compose/stacks/security/teleport/config/teleport.yaml"
middlewares="$ROOT_DIR/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
dns_script="$ROOT_DIR/compose/scripts/configure-teleport-app-dns.sh"
tls_script="$ROOT_DIR/compose/scripts/renew-teleport-app-tls.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_contains "$teleport_config" "name: adguard"
assert_contains "$teleport_config" "public_addr: adguard.teleport.imcherry5778.xyz:3080"
assert_contains "$teleport_config" "name: traefik"
assert_contains "$teleport_config" "name: minio-console"
assert_contains "$teleport_config" "name: semaphore"
assert_contains "$middlewares" "redirect-to-teleport-adguard"
assert_contains "$middlewares" "redirect-to-teleport-vault"
assert_contains "$dns_script" "for app in kibana prometheus alertmanager vault adguard traefik minio semaphore"
assert_contains "$tls_script" "*.teleport."
assert_contains "$tls_script" "vault kv put -mount=kv mgmt/teleport"
if grep -Fq 'docker cp' "$tls_script" || grep -Fq 'vault kv patch' "$tls_script"; then
  fail "Teleport TLS renewal must support Vault read-only rootfs and KV update ACLs"
fi

for stack in \
  "$ROOT_DIR/compose/stacks/edge/adguard/compose.yaml" \
  "$ROOT_DIR/compose/stacks/edge/traefik/compose.yaml" \
  "$ROOT_DIR/compose/stacks/backup/minio/compose.yaml" \
  "$ROOT_DIR/compose/stacks/cicd/semaphore/compose.yaml"; do
  assert_contains "$stack" "redirect-to-teleport"
done

echo "privileged Teleport route tests passed"
