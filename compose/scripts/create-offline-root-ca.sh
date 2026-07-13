#!/usr/bin/env bash
set -euo pipefail

umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/compose/config/vault-pki/root-ca-openssl.cnf"
out=${1:-}

if [[ -z "$out" ]]; then
  echo "Usage: $0 OUTPUT_DIRECTORY" >&2
  exit 2
fi
if [[ -e "$out" ]]; then
  echo "Output already exists: $out" >&2
  exit 1
fi

passin=()
passout=()
if [[ -n "${ROOT_CA_PASS_FILE:-}" ]]; then
  [[ -f "$ROOT_CA_PASS_FILE" ]] || { echo 'ROOT_CA_PASS_FILE is missing' >&2; exit 1; }
  if command -v cygpath >/dev/null 2>&1 && [[ "$ROOT_CA_PASS_FILE" == /* ]]; then
    ROOT_CA_PASS_FILE="$(cygpath -w "$ROOT_CA_PASS_FILE")"
  fi
  passin=(-passin "file:$ROOT_CA_PASS_FILE")
  passout=(-pass "file:$ROOT_CA_PASS_FILE")
fi

mkdir "$out"
openssl genpkey -algorithm RSA -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:4096 "${passout[@]}" -out "$out/root-ca.key"
openssl req -new -x509 -sha384 -days 3650 \
  -key "$out/root-ca.key" "${passin[@]}" \
  -config "$config" -extensions v3_root_ca -out "$out/root-ca.crt"
openssl x509 -in "$out/root-ca.crt" -outform DER | sha256sum | awk '{print $1}' >"$out/root-ca.sha256"
