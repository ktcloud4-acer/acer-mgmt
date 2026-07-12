#!/usr/bin/env bash
# Reconcile Wazuh host resources and the Dashboard API service account.
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/home/mgmt-data}"
WAZUH_SECRETS_FILE="${WAZUH_SECRETS_FILE:-${DATA_ROOT}/vault-agent/secrets/security/wazuh.env}"
MANAGER_CONTAINER="${WAZUH_MANAGER_CONTAINER:-wazuh-manager}"
DASHBOARD_CONTAINER="${WAZUH_DASHBOARD_CONTAINER:-wazuh-dashboard}"
SYSCTL_FILE="${WAZUH_SYSCTL_FILE:-/etc/sysctl.d/99-acer-wazuh.conf}"
DASHBOARD_CONFIG="${DATA_ROOT}/wazuh/config/wazuh_dashboard/wazuh.yml"

[[ $EUID -eq 0 ]] || { echo 'Run as root on acer-mgmt.' >&2; exit 1; }
[[ -r "$WAZUH_SECRETS_FILE" ]] || { echo "Missing Wazuh secrets: $WAZUH_SECRETS_FILE" >&2; exit 1; }
[[ -f "$DASHBOARD_CONFIG" ]] || { echo "Missing Dashboard config: $DASHBOARD_CONFIG" >&2; exit 1; }

printf '%s\n' '# Required by Wazuh modulesd Inventory Harvester.' \
  'fs.inotify.max_user_instances=1024' >"$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

set -a
# shellcheck disable=SC1090
. "$WAZUH_SECRETS_FILE"
set +a
: "${WAZUH_API_PASSWORD:?missing WAZUH_API_PASSWORD}"

sed -i "/^[[:space:]]*username: wazuh-wui$/,/^[[:space:]]*run_as:/ s#^[[:space:]]*password:.*#      password: \"${WAZUH_API_PASSWORD}\"#" \
  "$DASHBOARD_CONFIG"

if ! printf '%s\n' "$WAZUH_API_PASSWORD" | docker exec -i "$MANAGER_CONTAINER" \
  /var/ossec/framework/python/bin/python3 -c '
import sys
from wazuh.security import AuthenticationManager

password = sys.stdin.read().rstrip("\n")
if not password:
    raise SystemExit("empty password")
with AuthenticationManager() as auth:
    if not auth.update_user(2, password):
        raise SystemExit("RBAC user update failed")
' >/dev/null 2>&1; then
  echo 'Wazuh API service account reconciliation failed.' >&2
  exit 1
fi

docker restart "$DASHBOARD_CONTAINER" >/dev/null
for _ in $(seq 1 30); do
  docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${DASHBOARD_CONTAINER} Up" && break
  sleep 1
done

api_status="$(docker exec "$DASHBOARD_CONTAINER" sh -c '
  cfg=/usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml
  user=$(awk "/^[[:space:]]*username:/ {print \$2; exit}" "$cfg")
  password=$(awk "/^[[:space:]]*password:/ {gsub(/\"/, \"\", \$2); print \$2; exit}" "$cfg")
  curl -sk --connect-timeout 5 --max-time 15 -o /dev/null -w "%{http_code}" \
    -u "$user:$password" -X POST "https://wazuh.manager:55000/security/user/authenticate?raw=true"
')"
[[ "$api_status" == "200" ]] || {
  echo "Wazuh manager API auth failed with HTTP ${api_status}." >&2
  exit 1
}
echo 'manager API auth HTTP 200'
echo 'Wazuh runtime resources and API service account reconciled.'
