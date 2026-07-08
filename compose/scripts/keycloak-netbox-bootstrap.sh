#!/usr/bin/env bash
# Keycloak realm 'mgmt' 에 NetBox 용 OIDC 클라이언트를 등록/갱신한다.
# keycloak-grafana-bootstrap.sh 와 동일한 패턴. NetBox 는 social-auth OIDC 로
# SSO 하며 콜백 URL 은 https://netbox.<domain>/oauth/complete/oidc/ 이다.
set -euo pipefail

ENV_FILE=${ENV_FILE:-/home/user1/acer-mgmt/.env}
REALM=${KEYCLOAK_REALM:-}
CLIENT_ID=${NETBOX_OIDC_CLIENT_ID:-netbox}

get_env_value() {
  local key="$1"
  local value
  value="$(grep -m1 "^${key}=" "$ENV_FILE" | cut -d= -f2- || true)"
  value="${value%%#*}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#"${value%%[![:space:]]*}"}"
  if [[ -z "$value" ]]; then
    echo "Missing ${key} in ${ENV_FILE}" >&2
    exit 1
  fi
  printf '%s' "$value"
}

BASE_DOMAIN="$(get_env_value BASE_DOMAIN)"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-$(get_env_value KEYCLOAK_ADMIN_USER)}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"
REALM="${REALM:-$(get_env_value KEYCLOAK_REALM)}"
# NetBox OIDC 클라이언트 시크릿은 Vault 렌더 env 또는 환경변수에서 받는다.
CLIENT_SECRET="${NETBOX_OIDC_CLIENT_SECRET:?NETBOX_OIDC_CLIENT_SECRET must be set}"
NETBOX_URL="https://netbox.${BASE_DOMAIN}"

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
  echo "[$(date -Is)] creating realm ${REALM}"
  kc create realms \
    -s realm="$REALM" \
    -s enabled=true \
    -s displayName="Acer Mgmt"
else
  echo "[$(date -Is)] realm ${REALM} already exists"
fi

ensure_group() {
  local group="$1"
  if kc get groups -r "$REALM" -q search="$group" | grep -q "\"name\" *: *\"${group}\""; then
    echo "[$(date -Is)] group ${group} already exists"
  else
    echo "[$(date -Is)] creating group ${group}"
    kc create groups -r "$REALM" -s name="$group" >/dev/null
  fi
}

ensure_group platform-admin
ensure_group platform-editor
ensure_group platform-viewer

client_uuid() {
  kc get clients -r "$REALM" -q clientId="$CLIENT_ID" |
    sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' |
    head -n1
}

CLIENT_UUID="$(client_uuid)"
if [[ -z "$CLIENT_UUID" ]]; then
  echo "[$(date -Is)] creating NetBox client ${CLIENT_ID}"
  kc create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s rootUrl="$NETBOX_URL" \
    -s baseUrl="$NETBOX_URL" \
    -s "redirectUris=[\"${NETBOX_URL}/oauth/complete/oidc/\"]" \
    -s "webOrigins=[\"${NETBOX_URL}\"]" >/dev/null
  CLIENT_UUID="$(client_uuid)"
else
  echo "[$(date -Is)] NetBox client ${CLIENT_ID} already exists"
fi

echo "[$(date -Is)] updating NetBox client settings"
kc update "clients/${CLIENT_UUID}" -r "$REALM" \
  -s secret="$CLIENT_SECRET" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false \
  -s rootUrl="$NETBOX_URL" \
  -s baseUrl="$NETBOX_URL" \
  -s "redirectUris=[\"${NETBOX_URL}/oauth/complete/oidc/\"]" \
  -s "webOrigins=[\"${NETBOX_URL}\"]" >/dev/null

mapper_file="$(mktemp)"
trap 'rm -f "$mapper_file"' EXIT
cat >"$mapper_file" <<'JSON'
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "consentRequired": false,
  "config": {
    "full.path": "false",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "claim.name": "groups"
  }
}
JSON

docker cp "$mapper_file" "keycloak:/tmp/netbox-groups-mapper.json" >/dev/null
mapper_id="$(
  kc get "clients/${CLIENT_UUID}/protocol-mappers/models" -r "$REALM" |
    awk '
      /"id" *:/ { id=$0; sub(/^.*"id" *: *"/, "", id); sub(/".*$/, "", id) }
      /"name" *: *"groups"/ { print id; exit }
    '
)"

if [[ -n "$mapper_id" ]]; then
  echo "[$(date -Is)] updating groups claim mapper"
  kc update "clients/${CLIENT_UUID}/protocol-mappers/models/${mapper_id}" \
    -r "$REALM" \
    -f /tmp/netbox-groups-mapper.json >/dev/null
else
  echo "[$(date -Is)] creating groups claim mapper"
  kc create "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$REALM" \
    -f /tmp/netbox-groups-mapper.json >/dev/null
fi

echo "[$(date -Is)] Keycloak NetBox bootstrap completed"
