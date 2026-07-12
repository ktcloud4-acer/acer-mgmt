#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_not_contains() {
  if grep -Fq -- "$2" "$1"; then
    fail "did not expect '$2' in $1"
  fi
}

assert_item_target() {
  local title="$1"
  local target="$2"
  awk -v title="$title" -v target="$target" '
    $0 == "      - title: " title { found=1; next }
    found && $0 == "        target: " target { success=1; exit }
    found && $0 ~ /^      - title:/ { exit }
  END { exit success ? 0 : 1 }
  ' "$3" || fail "expected ${title} target ${target} in $3"
}

vault_compose="${REPO_ROOT}/compose/stacks/security/vault/compose.yaml"
middlewares="${REPO_ROOT}/compose/stacks/edge/traefik/config/dynamic/middlewares.yaml"
dashy_config="${REPO_ROOT}/compose/stacks/edge/dashy/config/conf.yml"
reconciler="${REPO_ROOT}/compose/scripts/reconcile-vault-dashy-embed.sh"
network_reconciler="${REPO_ROOT}/compose/scripts/reconcile-dashy-sso-networks.sh"
grafana_compose="${REPO_ROOT}/compose/stacks/observability/grafana/compose.yaml"
prometheus_compose="${REPO_ROOT}/compose/stacks/observability/prometheus/compose.yaml"
tempo_compose="${REPO_ROOT}/compose/stacks/observability/tempo/compose.yaml"
alertmanager_compose="${REPO_ROOT}/compose/stacks/observability/alertmanager/compose.yaml"
allure_compose="${REPO_ROOT}/compose/stacks/cicd/allure/compose.yaml"
adguard_compose="${REPO_ROOT}/compose/stacks/edge/adguard/compose.yaml"
traefik_compose="${REPO_ROOT}/compose/stacks/edge/traefik/compose.yaml"

for file in "$vault_compose" "$middlewares" "$dashy_config" "$reconciler" "$network_reconciler"; do
  [[ -f "$file" ]] || fail "missing file: $file"
done

assert_contains "$vault_compose" 'traefik.http.routers.vault.middlewares=sso-auth@file,secure-headers@file'
assert_contains "$vault_compose" 'traefik.http.routers.vault-api.rule=Host(`vault.${BASE_DOMAIN}`) && PathPrefix(`/v1`)'
assert_contains "$vault_compose" 'traefik.http.routers.vault-api.priority=100'
assert_contains "$vault_compose" 'traefik.http.routers.vault-api.middlewares=secure-headers@file'

declare -A ui_router_contract=(
  ["compose/stacks/observability/grafana/compose.yaml"]='traefik.http.routers.grafana.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/observability/prometheus/compose.yaml"]='traefik.http.routers.prometheus.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/observability/alertmanager/compose.yaml"]='traefik.http.routers.alertmanager.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/observability/elk/compose.yaml"]='traefik.http.routers.kibana.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/backup/minio/compose.yaml"]='traefik.http.routers.minio-console.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/cicd/allure/compose.yaml"]='traefik.http.routers.allure.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/cicd/playwright/compose.yaml"]='traefik.http.routers.playwright.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/cicd/semaphore/compose.yaml"]='traefik.http.routers.semaphore.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/data/kafka/compose.yaml"]='traefik.http.routers.kafka-ui.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/edge/adguard/compose.yaml"]='traefik.http.routers.adguard.middlewares=sso-auth@file,secure-headers@file'
  ["compose/stacks/edge/traefik/compose.yaml"]='traefik.http.routers.traefik.middlewares=sso-auth@file,secure-headers@file'
)

for relative_path in "${!ui_router_contract[@]}"; do
  assert_contains "${REPO_ROOT}/${relative_path}" "${ui_router_contract[$relative_path]}"
done

assert_contains "$middlewares" 'Content-Security-Policy: "frame-src '\''self'\''; frame-ancestors https://dash.imcherry5778.xyz; object-src '\''none'\'';"'
assert_contains "$middlewares" 'X-Frame-Options: ""'

# Grafana must consume the identity headers produced by oauth2-proxy, not
# start a second Keycloak browser login inside the Dashy frame.
assert_contains "$grafana_compose" 'GF_AUTH_DISABLE_LOGIN_FORM: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_GENERIC_OAUTH_ENABLED: "false"'
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_ENABLED: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_HEADER_NAME: X-Auth-Request-User'
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_AUTO_SIGN_UP: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_ENABLE_LOGIN_TOKEN: "true"'
assert_contains "$grafana_compose" 'GF_AUTH_PROXY_WHITELIST: ${TRAEFIK_GRAFANA_AUTH_IP:-10.254.254.2}/32'
assert_contains "$grafana_compose" 'traefik.http.routers.grafana.middlewares=sso-auth@file,secure-headers@file'
assert_contains "$grafana_compose" 'traefik.http.services.grafana.loadbalancer.server.port=3000'
assert_contains "$grafana_compose" 'traefik-grafana-auth:'
assert_contains "$grafana_compose" 'grafana-observability:'
assert_contains "$prometheus_compose" 'grafana-observability:'
assert_contains "$tempo_compose" 'grafana-observability:'
assert_contains "$traefik_compose" 'traefik-grafana-auth:'
assert_contains "$network_reconciler" '10.254.254.0/29'
assert_contains "$network_reconciler" '10.254.253.0/29'

# Browser UI must not retain an unauthenticated host-port shortcut. Allure's
# Tailnet listener is kept solely for CI result uploads and is intentionally
# documented as a machine API exception.
assert_not_contains "$prometheus_compose" '      - "9090:9090"'
assert_not_contains "$alertmanager_compose" '100.117.59.96:9093:9093'
assert_not_contains "$adguard_compose" '100.117.59.96:3000:3000/tcp'
assert_contains "$allure_compose" '      - "${TAILSCALE_IP:?TAILSCALE_IP must be set}:5050:5050"'

for item in Grafana Alertmanager Semaphore Vault; do
  assert_item_target "$item" workspace "$dashy_config"
done

assert_contains "$reconciler" 'obsolete_policy=dashy-embed-ui-headers'
assert_contains "$reconciler" '/tmp/.vt'
assert_contains "$reconciler" 'vault policy write'
assert_contains "$reconciler" 'vault policy read admin'
assert_contains "$reconciler" 'path "sys/config/ui/headers/Content-Security-Policy"'
assert_contains "$reconciler" 'vault policy write admin'
assert_contains "$reconciler" 'vault token capabilities sys/config/ui/headers/Content-Security-Policy'
assert_contains "$reconciler" 'tr "," "\n"'
assert_contains "$reconciler" 'grep -Fxq update'
assert_contains "$reconciler" 'grep -Fxq sudo'
sh -n "$reconciler" || fail 'Vault reconciliation script must be POSIX-sh compatible'

echo "Dashy SSO and Vault contract tests passed"
