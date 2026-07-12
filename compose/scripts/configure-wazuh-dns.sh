#!/usr/bin/env bash
# Add the canonical Wazuh Dashboard name to AdGuard's exact tailnet rewrites.
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:-imcherry5778.xyz}"
TAILSCALE_IP="${TAILSCALE_IP:?TAILSCALE_IP must be set}"
CONFIG_FILE="${ADGUARD_CONFIG:-/home/mgmt-data/adguard/conf/AdGuardHome.yaml}"
domain="wazuh.${BASE_DOMAIN}"

[[ $EUID -eq 0 ]] || { echo 'Run as root on acer-mgmt.' >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Missing AdGuard config: $CONFIG_FILE" >&2; exit 1; }

if ! grep -Fq "domain: ${domain}" "$CONFIG_FILE"; then
  grep -q '^  safe_fs_patterns:' "$CONFIG_FILE" || {
    echo "AdGuard rewrite insertion point is missing: $CONFIG_FILE" >&2
    exit 1
  }
  sed -i "/^  safe_fs_patterns:/i\\    - domain: ${domain}\\n      answer: ${TAILSCALE_IP}\\n      enabled: true" "$CONFIG_FILE"
fi

docker restart adguard >/dev/null
echo "Wazuh DNS rewrite now points to ${TAILSCALE_IP}."
