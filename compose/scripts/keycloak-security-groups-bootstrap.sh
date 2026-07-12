#!/usr/bin/env bash
# Idempotently create the Keycloak mgmt-realm groups used by service RBAC.
# The Keycloak bootstrap administrator password is supplied at runtime only,
# normally from the Vault Agent-rendered security/keycloak.env file.
set -euo pipefail

REALM="${KEYCLOAK_REALM:-mgmt}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"

if ! docker inspect keycloak >/dev/null 2>&1; then
  echo "Required container not found: keycloak" >&2
  exit 1
fi

kc() {
  docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

echo "[$(date -Is)] waiting for Keycloak admin API"
for _ in $(seq 1 60); do
  if kc config credentials \
    --server http://127.0.0.1:8080 \
    --realm master \
    --user "$KEYCLOAK_ADMIN_USER" \
    --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kc config credentials \
  --server http://127.0.0.1:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

if ! kc get "realms/${REALM}" >/dev/null 2>&1; then
  echo "Keycloak realm does not exist: ${REALM}" >&2
  exit 1
fi

ensure_group() {
  local group="$1"
  if kc get groups -r "$REALM" -q search="$group" | grep -q "\\\"name\\\" *: *\\\"${group}\\\""; then
    echo "[$(date -Is)] group ${group} already exists"
  else
    echo "[$(date -Is)] creating group ${group}"
    kc create groups -r "$REALM" -s name="$group" >/dev/null
  fi
}

ensure_group "platform-admin"
ensure_group "platform-editor"
ensure_group "platform-viewer"
ensure_group "grafana-editor"
ensure_group "netbox-editor"
ensure_group "netbox-admin"
ensure_group "argocd-deployer"
ensure_group "argocd-admin"
ensure_group "wazuh-admins"
ensure_group "wazuh-readonly"

echo "[$(date -Is)] enabling Keycloak user/admin audit events"
kc update "events/config" -r "$REALM" \
  -s eventsEnabled=true \
  -s adminEventsEnabled=true \
  -s adminEventsDetailsEnabled=false \
  -s 'eventsListeners=["jboss-logging"]' >/dev/null

echo "[$(date -Is)] Keycloak security-group bootstrap completed"
