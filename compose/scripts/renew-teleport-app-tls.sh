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

# Vault's container has a read-only root filesystem and this Vault version's
# KV PATCH fallback is not reliable without the patch ACL capability. Preserve
# the existing OIDC secret and replace the three known fields atomically.
cert_b64="$(base64 -w0 "$cert")"
key_b64="$(base64 -w0 "$key")"
printf '%s\n%s\n' "$cert_b64" "$key_b64" | docker exec -i "$VAULT_CONTAINER" sh -c \
  "set -eu; export VAULT_TOKEN=\"\$(cat '$VAULT_TOKEN_FILE')\"; \
   IFS= read -r cert_b64; IFS= read -r key_b64; \
   oidc_client_secret=\"\$(vault kv get -mount=kv -field=oidc_client_secret mgmt/teleport)\"; \
   tls_cert_pem=\"\$(printf '%s' \"\$cert_b64\" | base64 -d)\"; \
   tls_key_pem=\"\$(printf '%s' \"\$key_b64\" | base64 -d)\"; \
   vault kv put -mount=kv mgmt/teleport \
     oidc_client_secret=\"\$oidc_client_secret\" \
     tls_cert_pem=\"\$tls_cert_pem\" \
     tls_key_pem=\"\$tls_key_pem\" >/dev/null"

docker restart vault-agent >/dev/null
echo "Teleport TLS certificate updated in Vault for *.${BASE_DOMAIN} and *.teleport.${BASE_DOMAIN}."
