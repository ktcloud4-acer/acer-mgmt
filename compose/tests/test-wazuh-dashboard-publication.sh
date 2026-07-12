#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
traefik_config="$ROOT_DIR/compose/stacks/edge/traefik/config/dynamic/wazuh.yaml"
traefik_stack="$ROOT_DIR/compose/stacks/edge/traefik/compose.yaml"
dashy_config="$ROOT_DIR/compose/stacks/edge/dashy/config/conf.yml"
groups_script="$ROOT_DIR/compose/scripts/keycloak-security-groups-bootstrap.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }

for file in "$traefik_config" "$traefik_stack" "$dashy_config" "$groups_script"; do
  [[ -f "$file" ]] || fail "missing file: $file"
done

assert_contains "$traefik_config" 'Host(`wazuh.${BASE_DOMAIN}`)'
assert_contains "$traefik_config" 'sso-auth@file'
assert_contains "$traefik_config" 'secure-headers@file'
assert_contains "$traefik_config" 'https://wazuh-dashboard:5601'
assert_contains "$traefik_config" 'wazuh-dashboard-tls'
assert_contains "$traefik_stack" '/wazuh/config/wazuh_indexer_ssl_certs/root-ca.pem:/etc/traefik/wazuh-ca/root-ca.pem:ro,z'
assert_contains "$dashy_config" 'title: Wazuh'
assert_contains "$dashy_config" 'url: https://wazuh.imcherry5778.xyz'
assert_contains "$groups_script" 'ensure_group "wazuh-admins"'
assert_contains "$groups_script" 'ensure_group "wazuh-readonly"'

echo 'wazuh dashboard publication tests passed'
