#!/usr/bin/env bash
# Reconcile the Keycloak OIDC client used by the shared oauth2-proxy gateway.
# The client secret is read only from the Vault Agent-rendered runtime file and
# is never printed or written to the repository.
set -euo pipefail

REALM=${KEYCLOAK_REALM:-mgmt}
BASE_DOMAIN=${BASE_DOMAIN:?BASE_DOMAIN must be set}
KEYCLOAK_ADMIN_USER=${KEYCLOAK_ADMIN_USER:-admin}
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"
CLIENT_ID=${OAUTH2_PROXY_CLIENT_ID:-oauth2-proxy}
CLIENT_SECRET_FILE=${OAUTH2_PROXY_CLIENT_SECRET_FILE:-/home/mgmt-data/vault-agent/secrets/oauth2_proxy_client_secret}
KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT=${KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT:-3600}

[[ "$KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
  echo 'KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT must be a positive number of seconds' >&2
  exit 1
}

[[ -r "$CLIENT_SECRET_FILE" ]] || {
  echo "Missing readable oauth2-proxy client secret: $CLIENT_SECRET_FILE" >&2
  exit 1
}
CLIENT_SECRET="$(<"$CLIENT_SECRET_FILE")"
[[ -n "$CLIENT_SECRET" ]] || {
  echo 'oauth2-proxy client secret is empty' >&2
  exit 1
}

docker inspect keycloak >/dev/null 2>&1 || {
  echo 'Required container not found: keycloak' >&2
  exit 1
}

kc() {
  docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

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

kc get "realms/${REALM}" >/dev/null 2>&1 || {
  echo "Keycloak realm does not exist: $REALM" >&2
  exit 1
}

# Keep the Keycloak SSO idle window longer than oauth2-proxy's 30-minute
# refresh cadence. This avoids invalid_grant errors for an active dashboard.
kc update "realms/${REALM}" -s "ssoSessionIdleTimeout=${KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT}" >/dev/null

client_uuid() {
  kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id,clientId |
    sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p'
}

CLIENT_UUID="$(client_uuid)"
if [[ -z "$CLIENT_UUID" ]]; then
  kc create clients -r "$REALM" \
    -s clientId="$CLIENT_ID" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s "redirectUris=[\"https://auth.${BASE_DOMAIN}/oauth2/callback\"]" \
    -s "webOrigins=[\"https://auth.${BASE_DOMAIN}\"]" >/dev/null
  CLIENT_UUID="$(client_uuid)"
fi

[[ -n "$CLIENT_UUID" ]] || {
  echo "Unable to resolve Keycloak client: $CLIENT_ID" >&2
  exit 1
}

echo "Reconciling Keycloak client $CLIENT_ID"
kc update "clients/${CLIENT_UUID}" -r "$REALM" \
  -s secret="$CLIENT_SECRET" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false \
  -s "redirectUris=[\"https://auth.${BASE_DOMAIN}/oauth2/callback\"]" \
  -s "webOrigins=[\"https://auth.${BASE_DOMAIN}\"]" >/dev/null

mapper_file=$(mktemp)
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
    "introspection.token.claim": "true",
    "claim.name": "groups"
  }
}
JSON

docker cp "$mapper_file" keycloak:/tmp/oauth2-proxy-groups-mapper.json >/dev/null
docker exec --user 0 keycloak chmod 0644 /tmp/oauth2-proxy-groups-mapper.json
mapper_id="$(
  kc get "clients/${CLIENT_UUID}/protocol-mappers/models" -r "$REALM" |
    awk '
      /"id" *:/ { id=$0; sub(/^.*"id" *: *"/, "", id); sub(/".*$/, "", id) }
      /"name" *: *"groups"/ && !found { result=id; found=1 }
      END { if (found) print result }
    '
)"

if [[ -n "$mapper_id" ]]; then
  # Keycloak preserves client mapper identifiers but rejects a full payload
  # replacement on some versions. A mapper with this stable name is already
  # the desired claim contract, so preserve it rather than risking removal.
  echo "Groups claim mapper already exists for $CLIENT_ID"
else
  echo "Creating groups claim mapper for $CLIENT_ID"
  kc create "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$REALM" \
    -f /tmp/oauth2-proxy-groups-mapper.json >/dev/null
fi

echo "Keycloak oauth2-proxy bootstrap completed for realm $REALM (SSO idle ${KEYCLOAK_SSO_SESSION_IDLE_TIMEOUT}s)"
