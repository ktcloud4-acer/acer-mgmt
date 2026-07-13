#!/usr/bin/env bash
set -euo pipefail

umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/compose/config/vault-pki/root-ca-openssl.cnf"
root_dir=${1:-}
csr=${2:-}
out=${3:-}

if [[ -z "$root_dir" || -z "$csr" || -z "$out" ]]; then
  echo "Usage: $0 ROOT_CA_DIRECTORY INTERMEDIATE_CSR OUTPUT_DIRECTORY" >&2
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
if [[ -n "${ROOT_CA_PASS_FILE:-}" ]]; then
  [[ -f "$ROOT_CA_PASS_FILE" ]] || { echo 'ROOT_CA_PASS_FILE is missing' >&2; exit 1; }
  if command -v cygpath >/dev/null 2>&1 && [[ "$ROOT_CA_PASS_FILE" == /* ]]; then
    ROOT_CA_PASS_FILE="$(cygpath -w "$ROOT_CA_PASS_FILE")"
  fi
  passin=(-passin "file:$ROOT_CA_PASS_FILE")
fi

openssl req -in "$csr" -noout -verify
csr_text="$(openssl req -in "$csr" -noout -text)"
if ! grep -Fq 'Public Key Algorithm: rsaEncryption' <<<"$csr_text"; then
  echo 'Intermediate CSR must use RSA' >&2
  exit 1
fi
if [[ "$(sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' <<<"$csr_text" | head -1)" != 3072 ]]; then
  echo 'Intermediate CSR must use RSA 3072' >&2
  exit 1
fi

work=""
cleanup() {
  if [[ -n "$work" && -d "$work" ]]; then
    rm -rf -- "$work"
  fi
}
trap cleanup EXIT

work="$(mktemp -d "$out_parent/.${out_name}.tmp.XXXXXX")"
serial="$work/ca-serial"
openssl x509 -req -sha384 -days 1095 -in "$csr" \
  -CA "$root_dir/root-ca.crt" -CAkey "$root_dir/root-ca.key" "${passin[@]}" \
  -CAserial "$serial" -CAcreateserial \
  -extfile "$config" -extensions v3_intermediate_ca \
  -out "$work/vault-intermediate.crt"
cat "$work/vault-intermediate.crt" "$root_dir/root-ca.crt" >"$work/vault-intermediate-chain.pem"
rm -f "$serial"

if [[ -e "$out" ]]; then
  echo "Output appeared during signing: $out" >&2
  exit 1
fi
mv -- "$work" "$out"
work=""
trap - EXIT
