#!/usr/bin/env bash
set -euo pipefail

umask 077

mode=full
if [[ ${1:-} == --root-only ]]; then
  mode=root
  shift
fi
root_cert=${1:-}
root_fingerprint_file=${2:-}
intermediate_cert=${3:-}
chain=${4:-}

fail() {
  echo "Vault PKI artifact verification failed: $*" >&2
  exit 1
}

if [[ "$mode" == root && $# -ne 2 ]] || [[ "$mode" == full && $# -ne 4 ]]; then
  echo "Usage: $0 [--root-only] ROOT_CERT ROOT_SHA256 [INTERMEDIATE_CERT LEAF_FIRST_CHAIN]" >&2
  exit 2
fi
files=("$root_cert" "$root_fingerprint_file")
if [[ "$mode" == full ]]; then files+=("$intermediate_cert" "$chain"); fi
for file in "${files[@]}"; do
  [[ -f "$file" ]] || fail "missing file: $file"
done
for command in openssl date sha256sum awk grep cmp; do
  command -v "$command" >/dev/null 2>&1 || fail "missing command: $command"
done

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

cert_epoch() {
  local cert="$1" field="$2" value
  value="$(openssl x509 -in "$cert" -noout -"$field" | cut -d= -f2-)"
  [[ -n "$value" ]] || fail "missing certificate $field"
  date -u -d "$value" +%s
}

assert_validity() {
  local label="$1" cert="$2" expected="$3"
  local start end actual delta tolerance=300
  start="$(cert_epoch "$cert" startdate)"
  end="$(cert_epoch "$cert" enddate)"
  actual=$((end - start))
  delta=$((actual - expected))
  (( delta < 0 )) && delta=$((-delta))
  (( delta <= tolerance )) || \
    fail "$label validity is ${actual}s; expected ${expected}s +/- ${tolerance}s"
}

assert_profile() {
  local label="$1" cert="$2" bits="$3" pathlen="$4" text
  text="$tmp/${label}.txt"
  openssl x509 -in "$cert" -noout -text >"$text"
  grep -Fq "Public-Key: (${bits} bit)" "$text" || fail "$label RSA key size is not ${bits}"
  grep -Fq 'Signature Algorithm: sha384WithRSAEncryption' "$text" || \
    fail "$label signature algorithm is not SHA-384 with RSA"
  grep -A1 -F 'X509v3 Basic Constraints: critical' "$text" |
    grep -Fq "CA:TRUE, pathlen:${pathlen}" || fail "$label critical basicConstraints/pathlen is invalid"
  grep -A1 -F 'X509v3 Key Usage: critical' "$text" |
    grep -Fq 'Certificate Sign, CRL Sign' || fail "$label critical key usage is invalid"
}

expected_fingerprint="$(tr -d '[:space:]' <"$root_fingerprint_file" | tr '[:upper:]' '[:lower:]')"
[[ "$expected_fingerprint" =~ ^[0-9a-f]{64}$ ]] || fail 'Root SHA-256 fingerprint file is invalid'
actual_fingerprint="$(openssl x509 -in "$root_cert" -outform DER | sha256sum | awk '{print $1}')"
[[ "$actual_fingerprint" == "$expected_fingerprint" ]] || fail 'Root SHA-256 fingerprint mismatch'
assert_profile root "$root_cert" 4096 1
assert_validity root "$root_cert" $((3650 * 24 * 60 * 60))
openssl verify -check_ss_sig -CAfile "$root_cert" "$root_cert" >/dev/null || \
  fail 'Root self-signature verification failed'
if [[ "$mode" == root ]]; then
  printf 'VAULT_PKI_ROOT=PASS root_sha256=%s\n' "$actual_fingerprint"
  exit 0
fi

# Parse the supplied bytes, not a permissively reserialized subset.
if ! awk -v out="$tmp" '
  BEGIN { count=0; inside=0; invalid=0 }
  $0 == "-----BEGIN CERTIFICATE-----" {
    if (inside || count >= 2) { invalid=1; next }
    count++; inside=1; file=out "/chain-" count ".pem"; print >file; next
  }
  $0 == "-----END CERTIFICATE-----" {
    if (!inside) { invalid=1; next }
    print >file; close(file); inside=0; next
  }
  {
    if (!inside || $0 !~ /^[A-Za-z0-9+\/=]+$/) { invalid=1; next }
    print >file
  }
  END { if (invalid || inside || count != 2) exit 1 }
' "$chain"; then
  fail 'chain must contain exactly two PEM certificate blocks and no other data'
fi

openssl x509 -in "$root_cert" -out "$tmp/root.expected.pem"
openssl x509 -in "$intermediate_cert" -out "$tmp/intermediate.expected.pem"
openssl x509 -in "$tmp/chain-1.pem" -out "$tmp/chain-1.canonical.pem"
openssl x509 -in "$tmp/chain-2.pem" -out "$tmp/chain-2.canonical.pem"
cmp -s "$tmp/intermediate.expected.pem" "$tmp/chain-1.canonical.pem" || \
  fail 'chain order/content mismatch: block 1 must be the supplied Intermediate'
cmp -s "$tmp/root.expected.pem" "$tmp/chain-2.canonical.pem" || \
  fail 'chain order/content mismatch: block 2 must be the supplied Root'

assert_profile intermediate "$intermediate_cert" 3072 0
assert_validity intermediate "$intermediate_cert" $((1095 * 24 * 60 * 60))
openssl verify -CAfile "$root_cert" "$intermediate_cert" >/dev/null || \
  fail 'Intermediate signature/chain verification failed'

printf 'VAULT_PKI_ARTIFACTS=PASS root_sha256=%s\n' "$actual_fingerprint"
