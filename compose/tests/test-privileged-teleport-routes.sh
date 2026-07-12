#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
teleport_config="$ROOT_DIR/compose/stacks/security/teleport/config/teleport.yaml"
teleport_stack="$ROOT_DIR/compose/stacks/security/teleport/compose.yaml"
traefik_config="$ROOT_DIR/compose/stacks/edge/traefik/config/traefik.yaml"
traefik_stack="$ROOT_DIR/compose/stacks/edge/traefik/compose.yaml"
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
assert_contains "$teleport_config" "uri: http://traefik:8081/dashboard/"
assert_contains "$teleport_config" "Host: traefik.teleport.imcherry5778.xyz"
assert_contains "$traefik_config" "teleport:"
assert_contains "$traefik_config" "address: \":8081\""
assert_contains "$traefik_stack" 'traefik.http.routers.traefik-teleport.rule=Host(`traefik.teleport.${BASE_DOMAIN}`)'
assert_contains "$traefik_stack" "traefik.http.routers.traefik-teleport.entrypoints=teleport"
assert_contains "$traefik_stack" "traefik.http.routers.traefik-teleport.service=api@internal"
assert_not_contains "$traefik_stack" '"8081:8081"'
assert_contains "$teleport_config" "name: minio-console"
assert_contains "$teleport_config" "name: semaphore"
assert_contains "$teleport_config" "name: keycloak-admin"
assert_contains "$teleport_config" "uri: http://keycloak:8080"
assert_contains "$teleport_config" "public_addr: keycloak-admin.teleport.imcherry5778.xyz"
assert_contains "$teleport_config" "redirect: [keycloak.imcherry5778.xyz]"
assert_contains "$teleport_config" "owner: security"

for app in grafana n8n gitlab sonarqube allure playwright harbor wazuh redisinsight kafka-ui supabase-studio netbox dashy platform-monitor docker-runtime; do
  assert_contains "$teleport_config" "name: $app"
  assert_contains "$dns_script" "$app"
done

assert_contains "$teleport_config" "uri: http://grafana-teleport-proxy:8080"
assert_contains "$teleport_config" "uri: http://n8n:5678"
assert_contains "$teleport_config" "uri: http://gitlab:80"
assert_contains "$teleport_config" "redirect: [gitlab.imcherry5778.xyz, gitlab]"
assert_contains "$teleport_config" "uri: http://sonarqube:9000"
assert_contains "$teleport_config" "uri: http://allure:5050"
assert_contains "$teleport_config" "uri: http://playwright-report:80"
assert_contains "$teleport_config" "uri: http://nginx:8080"
assert_contains "$teleport_config" "uri: https://wazuh-dashboard:5601"
assert_contains "$teleport_config" "redirect: [wazuh.imcherry5778.xyz, wazuh-dashboard]"
assert_contains "$teleport_config" "uri: http://redisinsight:5540"
assert_contains "$teleport_config" "uri: http://kafka-ui:8080"
assert_contains "$teleport_config" "uri: http://supabase-studio:3000"
assert_contains "$teleport_config" "redirect: [supabase-admin.imcherry5778.xyz, supabase-studio]"
assert_contains "$teleport_config" "uri: http://netbox:8080"
assert_contains "$teleport_config" "redirect: [netbox.imcherry5778.xyz, netbox]"
assert_contains "$teleport_config" "uri: http://dashy:8080"
assert_contains "$teleport_config" "uri: http://platform-monitor:8080"
assert_contains "$teleport_config" "uri: http://docker-runtime-viewer:8080"
assert_contains "$teleport_stack" "traefik-grafana-auth:"
assert_contains "$teleport_stack" 'ipv4_address: ${TELEPORT_GRAFANA_AUTH_IP:-10.254.254.4}'
assert_contains "$teleport_stack" "supabase_default:"

grafana_stack="$ROOT_DIR/compose/stacks/observability/grafana/compose.yaml"
grafana_proxy_config="$ROOT_DIR/compose/stacks/observability/grafana/teleport-proxy/nginx.conf"
assert_contains "$grafana_stack" "grafana-teleport-proxy"
assert_contains "$grafana_stack" 'GF_AUTH_PROXY_WHITELIST: ${TRAEFIK_GRAFANA_AUTH_IP:-10.254.254.2}/32,${GRAFANA_TELEPORT_PROXY_IP:-10.254.254.5}/32'
assert_contains "$grafana_stack" 'ipv4_address: ${GRAFANA_TELEPORT_PROXY_IP:-10.254.254.5}'
assert_contains "$grafana_proxy_config" "allow 10.254.254.4;"
assert_contains "$grafana_proxy_config" 'proxy_set_header X-Auth-Request-User $http_x_teleport_user;'
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
