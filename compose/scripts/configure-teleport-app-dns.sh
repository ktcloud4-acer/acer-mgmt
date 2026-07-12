#!/usr/bin/env bash
# Configure AdGuard rewrites for Teleport app subdomains on the tailnet only.
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:-imcherry5778.xyz}"
TAILSCALE_IP="${TAILSCALE_IP:?TAILSCALE_IP must be set}"
CONFIG_FILE="${ADGUARD_CONFIG:-/home/mgmt-data/adguard/conf/AdGuardHome.yaml}"

[[ $EUID -eq 0 ]] || { echo 'Run as root on acer-mgmt.' >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Missing AdGuard config: $CONFIG_FILE" >&2; exit 1; }

add_rewrite() {
  local domain="$1"
  if grep -Fq "domain: ${domain}" "$CONFIG_FILE"; then
    return
  fi
  sed -i "/^  safe_fs_patterns:/i\\    - domain: ${domain}\\n      answer: ${TAILSCALE_IP}\\n      enabled: true" "$CONFIG_FILE"
}

for app in kibana prometheus alertmanager vault adguard traefik minio semaphore keycloak-admin n8n gitlab sonarqube allure playwright harbor wazuh redisinsight kafka-ui supabase-studio netbox dashy platform-monitor docker-runtime grafana; do
  add_rewrite "${app}.teleport.${BASE_DOMAIN}"
done

# The former sibling tp-* names cannot work with Teleport's proxy-domain rule.
sed -i -E '/^[[:space:]]+- domain: tp-(kibana|prometheus|alertmanager|keycloak|vault|netbox)\./,+2d' "$CONFIG_FILE"

docker restart adguard >/dev/null
echo "Teleport app DNS rewrites now point to ${TAILSCALE_IP}."
