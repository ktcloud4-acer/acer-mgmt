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

out_parent="$(dirname "$out")"
out_name="$(basename "$out")"
if [[ ! -d "$out_parent" ]]; then
  echo "Output parent directory is missing: $out_parent" >&2
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

work=""
cleanup() {
  if [[ -n "$work" && -d "$work" ]]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

work="$(mktemp -d "$out_parent/.${out_name}.tmp.XXXXXX")"
openssl genpkey -algorithm RSA -aes-256-cbc \
  -pkeyopt rsa_keygen_bits:4096 "${passout[@]}" -out "$work/root-ca.key"
openssl req -new -x509 -sha384 -days 3650 \
  -key "$work/root-ca.key" "${passin[@]}" \
  -config "$config" -extensions v3_root_ca -out "$work/root-ca.crt"
openssl x509 -in "$work/root-ca.crt" -outform DER | sha256sum | awk '{print $1}' >"$work/root-ca.sha256"

if [[ -e "$out" ]]; then
  echo "Output appeared during generation: $out" >&2
  exit 1
fi
mv -- "$work" "$out"
work=""
trap - EXIT
