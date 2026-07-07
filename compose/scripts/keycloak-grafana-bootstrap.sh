#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=${ENV_FILE:-/home/user1/acer-mgmt/.env}
REALM=${KEYCLOAK_REALM:-}
CLIENT_ID=${GRAFANA_OAUTH_CLIENT_ID:-}

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
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-$(get_env_value KEYCLOAK_ADMIN_PASSWORD)}"
REALM="${REALM:-$(get_env_value KEYCLOAK_REALM)}"
CLIENT_ID="${CLIENT_ID:-$(get_env_value GRAFANA_OAUTH_CLIENT_ID)}"
CLIENT_SECRET="${GRAFANA_OAUTH_CLIENT_SECRET:-$(get_env_value GRAFANA_OAUTH_CLIENT_SECRET)}"
GRAFANA_URL="https://grafana.${BASE_DOMAIN}"

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
  echo "[$(date -Is)] creating Grafana client ${CLIENT_ID}"
  kc create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s rootUrl="$GRAFANA_URL" \
    -s baseUrl="$GRAFANA_URL" \
    -s "redirectUris=[\"${GRAFANA_URL}/login/generic_oauth\"]" \
    -s "webOrigins=[\"${GRAFANA_URL}\"]" >/dev/null
  CLIENT_UUID="$(client_uuid)"
else
  echo "[$(date -Is)] Grafana client ${CLIENT_ID} already exists"
fi

echo "[$(date -Is)] updating Grafana client settings"
kc update "clients/${CLIENT_UUID}" -r "$REALM" \
  -s secret="$CLIENT_SECRET" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false \
  -s rootUrl="$GRAFANA_URL" \
  -s baseUrl="$GRAFANA_URL" \
  -s "redirectUris=[\"${GRAFANA_URL}/login/generic_oauth\"]" \
  -s "webOrigins=[\"${GRAFANA_URL}\"]" >/dev/null

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

docker cp "$mapper_file" "keycloak:/tmp/grafana-groups-mapper.json" >/dev/null
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
    -f /tmp/grafana-groups-mapper.json >/dev/null
else
  echo "[$(date -Is)] creating groups claim mapper"
  kc create "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$REALM" \
    -f /tmp/grafana-groups-mapper.json >/dev/null
fi

echo "[$(date -Is)] Keycloak Grafana bootstrap completed"
