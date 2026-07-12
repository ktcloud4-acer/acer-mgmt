#!/usr/bin/env bash
# Reconcile Grafana's confidential Keycloak client and patch only its client
# secret into Vault. Secret material is never printed or stored in Compose.
set -euo pipefail

REALM=${KEYCLOAK_REALM:-mgmt}
BASE_DOMAIN=${BASE_DOMAIN:?BASE_DOMAIN must be set}
KEYCLOAK_ADMIN_USER=${KEYCLOAK_ADMIN_USER:-admin}
: "${KEYCLOAK_ADMIN_PASSWORD:?KEYCLOAK_ADMIN_PASSWORD must be set}"
CLIENT_ID=${GRAFANA_OIDC_CLIENT_ID:-grafana}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
VAULT_TOKEN_FILE=${VAULT_TOKEN_FILE:-/tmp/.vt}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_KV_PATCH_HELPER="${SCRIPT_DIR}/vault-kv2-patch-secret.py"
REDIRECT_URI="https://grafana.teleport.${BASE_DOMAIN}:3080/login/generic_oauth"
WEB_ORIGIN="https://grafana.teleport.${BASE_DOMAIN}:3080"

docker inspect keycloak >/dev/null 2>&1 || {
  echo 'Required container not found: keycloak' >&2
  exit 1
}
docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1 || {
  echo "Required container not found: $VAULT_CONTAINER" >&2
  exit 1
}
docker exec "$VAULT_CONTAINER" test -s "$VAULT_TOKEN_FILE" || {
  echo "Missing readable Vault token file in $VAULT_CONTAINER: $VAULT_TOKEN_FILE" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo 'python3 is required for the direct Vault KV v2 patch helper' >&2
  exit 1
}
[[ -r "$VAULT_KV_PATCH_HELPER" ]] || {
  echo "Missing Vault KV v2 patch helper: $VAULT_KV_PATCH_HELPER" >&2
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
    "introspection.token.claim": "true",
    "claim.name": "groups"
  }
}
JSON

docker cp "$mapper_file" keycloak:/tmp/grafana-groups-mapper.json >/dev/null
docker exec --user 0 keycloak chmod 0644 /tmp/grafana-groups-mapper.json
groups_mapper_id() {
  kc get "clients/${CLIENT_UUID}/protocol-mappers/models" -r "$REALM" |
    python3 -c '
import json
import sys

try:
    mappers = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Keycloak returned invalid protocol mapper JSON: {exc}")

if not isinstance(mappers, list):
    raise SystemExit("Keycloak protocol mapper response is not a JSON list")

groups_mappers = []
for mapper in mappers:
    if not isinstance(mapper, dict) or mapper.get("name") != "groups":
        continue
    mapper_id = mapper.get("id")
    if not isinstance(mapper_id, str) or not mapper_id:
        raise SystemExit("Keycloak groups mapper has no usable ID")
    groups_mappers.append(mapper_id)

if len(groups_mappers) > 1:
    raise SystemExit("Refusing to reconcile duplicate groups mappers")

if groups_mappers:
    print(groups_mappers[0])
'
}

MAPPER_ID="$(groups_mapper_id)"
if [[ -n "$MAPPER_ID" ]]; then
  # Keycloak 26 rejects an update payload without the mapper's immutable ID.
  # Recreate the uniquely named client mapper instead, avoiding an ID-bearing
  # payload that would need to be copied through a temporary secret-like file.
  kc delete "clients/${CLIENT_UUID}/protocol-mappers/models/${MAPPER_ID}" -r "$REALM" >/dev/null
fi

kc create "clients/${CLIENT_UUID}/protocol-mappers/models" \
  -r "$REALM" \
  -f /tmp/grafana-groups-mapper.json >/dev/null

CLIENT_SECRET="$({
  kc get "clients/${CLIENT_UUID}/client-secret" -r "$REALM" |
    sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p'
} | tail -n 1)"
[[ -n "$CLIENT_SECRET" ]] || {
  echo "Keycloak client secret is empty: $CLIENT_ID" >&2
  exit 1
}

printf '%s' "$CLIENT_SECRET" | python3 "$VAULT_KV_PATCH_HELPER" \
  --vault-container "$VAULT_CONTAINER" \
  --token-file "$VAULT_TOKEN_FILE" \
  --mount kv \
  --secret-path mgmt/grafana \
  --field oidc_client_secret \
  --allow-rw-fallback

echo "Keycloak Grafana OIDC bootstrap completed for realm $REALM"
