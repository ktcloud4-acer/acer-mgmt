#!/usr/bin/env bash
# Create isolated Wazuh passwords in Vault only when the path does not exist.
# The deployment token stays inside the Vault container and values never print.
set -euo pipefail

VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/tmp/.vt}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

[[ $EUID -eq 0 ]] || { echo 'Run as root on acer-mgmt.' >&2; exit 1; }
docker exec "$VAULT_CONTAINER" sh -c "test -s '$VAULT_TOKEN_FILE'" || {
  echo "Missing Vault deployment token: ${VAULT_TOKEN_FILE}" >&2
  exit 1
}

if docker exec "$VAULT_CONTAINER" sh -s <<'VAULT_SCRIPT'
set -eu
export VAULT_TOKEN="$(cat /tmp/.vt)"
vault kv get -mount=kv mgmt/wazuh >/dev/null 2>&1
VAULT_SCRIPT
then
  echo 'Wazuh Vault secret already exists; leaving it unchanged.'
  exit 0
fi

for field in indexer_password dashboard_password api_password registration_password; do
  umask 077
  openssl rand -hex 32 >"$tmpdir/$field"
  docker cp "$tmpdir/$field" "$VAULT_CONTAINER:/tmp/security-bp-$field"
done

docker exec "$VAULT_CONTAINER" sh -s <<'VAULT_SCRIPT'
set -eu
export VAULT_TOKEN="$(cat /tmp/.vt)"
for field in indexer_password dashboard_password api_password registration_password; do
  vault kv patch -mount=kv mgmt/wazuh "${field}=-" <"/tmp/security-bp-${field}" >/dev/null
  rm -f "/tmp/security-bp-${field}"
done
VAULT_SCRIPT

docker restart vault-agent >/dev/null
echo 'Created isolated Wazuh credentials in Vault and restarted Vault Agent.'
