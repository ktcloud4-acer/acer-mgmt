#!/usr/bin/env bash
set -euo pipefail

umask 077

VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
output=${1:-}
tmp=''

cleanup() {
  if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi
}
trap cleanup EXIT

if [[ $# -ne 1 || -z "$output" ]]; then
  echo "Usage: $0 OUTPUT_CSR" >&2
  exit 2
fi
if [[ -e "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 1
fi
if [[ ! -d "$(dirname "$output")" ]]; then
  echo "Output parent directory is missing: $(dirname "$output")" >&2
  exit 1
fi

vault_exec() {
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    exec "$@"
  ' sh "$@"
}

mounts="$(vault_exec vault secrets list -format=json)"
if jq -e 'has("pki_int/")' <<<"$mounts" >/dev/null; then
  mount_type="$(jq -er '.["pki_int/"].type' <<<"$mounts")"
  if [[ "$mount_type" != pki ]]; then
    echo "pki_int must be type pki, found: $mount_type" >&2
    exit 1
  fi
else
  status=$?
  if [[ $status -ne 1 ]]; then
    echo 'Unable to parse the Vault secrets mount list' >&2
    exit 1
  fi
  vault_exec vault secrets enable -path=pki_int pki >/dev/null
fi

ca=''
if ca="$(vault_exec vault read -field=certificate pki_int/cert/ca 2>/dev/null)"; then
  if grep -q 'BEGIN CERTIFICATE' <<<"$ca"; then
    echo 'pki_int already has a signed CA; use the rotation runbook' >&2
    exit 1
  fi
else
  status=$?
  if [[ $status -ne 2 ]]; then
    echo 'Unable to verify whether pki_int already has a signed CA' >&2
    exit 1
  fi
fi
vault_exec vault secrets tune -max-lease-ttl=26280h pki_int >/dev/null

output_dir="$(dirname "$output")"
output_name="$(basename "$output")"
tmp="$(mktemp "$output_dir/.${output_name}.tmp.XXXXXX")"
vault_exec vault write -format=json pki_int/intermediate/generate/internal \
  common_name='Acer Lab Intermediate CA 2026' key_type=rsa key_bits=3072 \
  exclude_cn_from_sans=true | jq -er '.data.csr' >"$tmp"
openssl req -in "$tmp" -noout -verify >/dev/null
chmod 600 "$tmp"
if ! ln -- "$tmp" "$output"; then
  echo "Output appeared during generation: $output" >&2
  exit 1
fi
rm -f -- "$tmp"
tmp=''
trap - EXIT
