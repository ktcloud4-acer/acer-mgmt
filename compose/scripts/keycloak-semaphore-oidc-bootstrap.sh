#!/usr/bin/env bash
# Reconcile Semaphore's confidential Keycloak client and store its client
# secret in Vault. The secret is only piped into the Vault container; it is
# never printed, committed, or inserted into a Compose environment variable.
set -euo pipefail

REALM=${KEYCLOAK_REALM:-mgmt}
BASE_DOMAIN=${BASE_DOMAIN:?BASE_DOMAIN must be set}
KEYCLOAK_ADMIN_USER=${KEYCLOAK_ADMIN_USER:-admin}
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"
CLIENT_ID=${SEMAPHORE_OIDC_CLIENT_ID:-semaphore}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE:-/tmp/.vt}
REDIRECT_URI="https://semaphore.${BASE_DOMAIN}/api/auth/oidc/keycloak/redirect"
WEB_ORIGIN="https://semaphore.${BASE_DOMAIN}"

docker inspect keycloak >/dev/null 2>&1 || {
  echo 'Required container not found: keycloak' >&2
  exit 1
}
docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1 || {
  echo "Required container not found: $VAULT_CONTAINER" >&2
  exit 1
}
docker exec "$VAULT_CONTAINER" sh -c "test -s '$VAULT_TOKEN_FILE'" || {
  echo "Missing readable Vault token file in $VAULT_CONTAINER: $VAULT_TOKEN_FILE" >&2
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
    -s "redirectUris=[\"${REDIRECT_URI}\"]" \
    -s "webOrigins=[\"${WEB_ORIGIN}\"]" >/dev/null
  CLIENT_UUID="$(client_uuid)"
fi

[[ -n "$CLIENT_UUID" ]] || {
  echo "Unable to resolve Keycloak client: $CLIENT_ID" >&2
  exit 1
}

kc update "clients/${CLIENT_UUID}" -r "$REALM" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false \
  -s "redirectUris=[\"${REDIRECT_URI}\"]" \
  -s "webOrigins=[\"${WEB_ORIGIN}\"]" >/dev/null

if [[ "${SEMAPHORE_ROTATE_OIDC_SECRET:-false}" == "true" ]]; then
  kc create "clients/${CLIENT_UUID}/client-secret" -r "$REALM" >/dev/null
fi

CLIENT_SECRET="$({
  kc get "clients/${CLIENT_UUID}/client-secret" -r "$REALM" |
    sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p'
} | tail -n 1)"
[[ -n "$CLIENT_SECRET" ]] || {
  echo "Keycloak client secret is empty: $CLIENT_ID" >&2
  exit 1
}

printf '%s' "$CLIENT_SECRET" | docker exec -i \
  -e "VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE}" \
  "$VAULT_CONTAINER" sh -ceu '
    secret="$(cat)"
    VAULT_TOKEN="$(cat "$VAULT_TOKEN_FILE")"
    vault kv patch -mount=kv mgmt/semaphore oidc_client_secret="$secret" >/dev/null
  '

echo "Keycloak Semaphore OIDC bootstrap completed for realm $REALM"
