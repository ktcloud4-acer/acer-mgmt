#!/usr/bin/env bash
# Issue a DNS-01 certificate for the Teleport proxy and its app subdomain, then
# patch only the TLS fields in Vault. The Vault token remains inside the Vault
# container and certificate private keys are never printed.
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:-imcherry5778.xyz}"
ACME_EMAIL="${ACME_EMAIL:-imcherry5778@gmail.com}"
TRAEFIK_ENV="${TRAEFIK_ENV:-/home/mgmt-data/vault-agent/secrets/edge/traefik.env}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/tmp/.vt}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

[[ $EUID -eq 0 ]] || { echo 'Run as root on acer-mgmt.' >&2; exit 1; }
[[ -r "$TRAEFIK_ENV" ]] || { echo "Missing rendered Cloudflare credential: $TRAEFIK_ENV" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$TRAEFIK_ENV"
set +a
: "${CF_DNS_API_TOKEN:?CF_DNS_API_TOKEN must be set}"
docker exec "$VAULT_CONTAINER" sh -c "test -s '$VAULT_TOKEN_FILE'" || {
  echo "Missing Vault deployment token: ${VAULT_TOKEN_FILE}" >&2
  exit 1
}

docker run --rm \
  -e CF_DNS_API_TOKEN \
  -v "$workdir:/certs:Z" \
  goacme/lego:v4.25.1 \
  --accept-tos \
  --email "$ACME_EMAIL" \
  --dns cloudflare \
  --domains "$BASE_DOMAIN" \
  --domains "*.$BASE_DOMAIN" \
  --domains "teleport.$BASE_DOMAIN" \
  --domains "*.teleport.$BASE_DOMAIN" \
  --path /certs run >/dev/null

cert="$workdir/certificates/${BASE_DOMAIN}.crt"
key="$workdir/certificates/${BASE_DOMAIN}.key"
[[ -s "$cert" && -s "$key" ]] || { echo 'ACME certificate files were not created' >&2; exit 1; }
docker cp "$cert" "$VAULT_CONTAINER:/tmp/teleport-app-tls.crt"
docker cp "$key" "$VAULT_CONTAINER:/tmp/teleport-app-tls.key"
docker exec -i "$VAULT_CONTAINER" sh -s <<'VAULT_SCRIPT'
set -eu
export VAULT_TOKEN="$(cat /tmp/.vt)"
vault kv patch -mount=kv mgmt/teleport tls_cert_pem=- </tmp/teleport-app-tls.crt >/dev/null
vault kv patch -mount=kv mgmt/teleport tls_key_pem=- </tmp/teleport-app-tls.key >/dev/null
rm -f /tmp/teleport-app-tls.crt /tmp/teleport-app-tls.key
VAULT_SCRIPT

docker restart vault-agent >/dev/null
echo "Teleport TLS certificate updated in Vault for *.${BASE_DOMAIN} and *.teleport.${BASE_DOMAIN}."
