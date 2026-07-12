#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
teleport_config="$ROOT_DIR/compose/stacks/security/teleport/config/teleport.yaml"
teleport_stack="$ROOT_DIR/compose/stacks/security/teleport/compose.yaml"
oidc_script="$ROOT_DIR/compose/stacks/security/teleport/scripts/apply-keycloak-oidc.sh"
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

assert_not_contains() {
  local file="$1"
  local unwanted="$2"
  [[ -f "$file" ]] || fail "missing file: $file"
  ! grep -Fq -- "$unwanted" "$file" || fail "$file must not contain: $unwanted"
}

assert_contains "$teleport_config" "name: adguard"
assert_contains "$teleport_stack" '${DATA_ROOT:-/home/mgmt-data}/vault-agent/secrets/security/teleport:/run/teleport/tls'
assert_not_contains "$teleport_stack" '/run/acer-mgmt/secrets/security/teleport:/run/teleport/tls'
assert_contains "$oidc_script" 'vault-agent/secrets/security/teleport.env'
assert_contains "$teleport_config" "public_addr: adguard.teleport.imcherry5778.xyz"
if sed -n '/^  apps:/,$p' "$teleport_config" | grep -Eq '^[[:space:]]+public_addr: .*:3080'; then
  fail "Teleport application public_addr must not contain a proxy port"
fi
assert_contains "$teleport_config" "name: traefik"
assert_contains "$teleport_config" "name: minio-console"
assert_contains "$teleport_config" "name: semaphore"
assert_contains "$teleport_config" "name: keycloak-admin"
assert_contains "$teleport_config" "uri: http://keycloak:8080"
assert_contains "$teleport_config" "public_addr: keycloak-admin.teleport.imcherry5778.xyz"
assert_contains "$teleport_config" "redirect: [keycloak.imcherry5778.xyz]"
assert_contains "$teleport_config" "owner: security"
assert_not_contains "$middlewares" "redirect-to-teleport"
assert_contains "$dns_script" "for app in kibana prometheus alertmanager vault adguard traefik minio semaphore keycloak-admin"
assert_contains "$tls_script" "*.teleport."
assert_contains "$tls_script" "vault kv put -mount=kv mgmt/teleport"
if grep -Fq '"teleport.$BASE_DOMAIN"' "$tls_script"; then
  fail "Teleport app certificate request must not include the ACME-redundant teleport base SAN"
fi
if grep -Fq 'docker cp' "$tls_script" || grep -Fq 'vault kv patch' "$tls_script"; then
  fail "Teleport TLS renewal must support Vault read-only rootfs and KV update ACLs"
fi

for stack in \
  "$ROOT_DIR/compose/stacks/edge/adguard/compose.yaml" \
  "$ROOT_DIR/compose/stacks/edge/traefik/compose.yaml" \
  "$ROOT_DIR/compose/stacks/backup/minio/compose.yaml"; do
  assert_contains "$stack" "sso-auth@file,secure-headers@file"
done

# Semaphore keeps the same initial SSO boundary, but has a dedicated iframe
# policy and a non-redirecting API route for its native OIDC callback.
semaphore_stack="$ROOT_DIR/compose/stacks/cicd/semaphore/compose.yaml"
assert_contains "$semaphore_stack" "sso-auth@file,semaphore-iframe@file"
assert_contains "$semaphore_stack" "oauth2-auth@file,semaphore-iframe@file"

echo "privileged Teleport route tests passed"
