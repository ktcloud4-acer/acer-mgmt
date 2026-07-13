#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s' 'nonprod-test-passphrase' >"$tmp/pass"
chmod 600 "$tmp/pass"
pass_file="$tmp/pass"
if command -v cygpath >/dev/null 2>&1; then
  pass_file="$(cygpath -w "$pass_file")"
fi

ROOT_CA_PASS_FILE="$pass_file" "$root/compose/scripts/create-offline-root-ca.sh" "$tmp/root"
openssl x509 -in "$tmp/root/root-ca.crt" -noout -text >"$tmp/root.txt"
grep -Fq 'Public-Key: (4096 bit)' "$tmp/root.txt"
grep -Fq 'CA:TRUE, pathlen:1' "$tmp/root.txt"
grep -Fq 'Certificate Sign' "$tmp/root.txt"
openssl pkey -in "$tmp/root/root-ca.key" -passin file:"$pass_file" -noout

MSYS2_ARG_CONV_EXCL='/CN=' openssl req -new -newkey rsa:3072 -nodes \
  -subj '/CN=Acer Lab Intermediate CA 2026' \
  -keyout "$tmp/intermediate.key" -out "$tmp/intermediate.csr" >/dev/null 2>&1
ROOT_CA_PASS_FILE="$pass_file" "$root/compose/scripts/sign-vault-intermediate.sh" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed"
openssl verify -CAfile "$tmp/root/root-ca.crt" "$tmp/signed/vault-intermediate.crt"
openssl x509 -in "$tmp/signed/vault-intermediate.crt" -noout -text >"$tmp/intermediate.txt"
grep -Fq 'Public-Key: (3072 bit)' "$tmp/intermediate.txt"
grep -Fq 'CA:TRUE, pathlen:0' "$tmp/intermediate.txt"
echo 'OFFLINE_ROOT_CA_VALIDATION=PASS'
