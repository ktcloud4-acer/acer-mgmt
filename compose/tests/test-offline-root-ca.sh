#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
create_root="$root/compose/scripts/create-offline-root-ca.sh"
sign_intermediate="$root/compose/scripts/sign-vault-intermediate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_no_temp_siblings() {
  local output="$1"
  local parent base leftover
  parent="$(dirname "$output")"
  base="$(basename "$output")"
  leftover="$(find "$parent" -maxdepth 1 -name ".${base}.tmp.*" -print -quit)"
  [[ -z "$leftover" ]] || fail "temporary output remains: $leftover"
}

assert_absent_and_clean() {
  local output="$1"
  [[ ! -e "$output" ]] || fail "failed operation left output: $output"
  assert_no_temp_siblings "$output"
}

assert_exact_files() {
  local dir="$1"
  shift
  local actual expected
  actual="$(find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)"
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  [[ "$actual" == "$expected" ]] || fail "unexpected files in $dir: $actual"
  [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit)" ]] || \
    fail "unexpected non-file output in $dir"
}

assert_validity_days() {
  local cert="$1" expected_days="$2"
  local not_before not_after start_epoch end_epoch
  not_before="$(openssl x509 -in "$cert" -noout -startdate | cut -d= -f2-)"
  not_after="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2-)"
  start_epoch="$(date -u -d "$not_before" +%s)"
  end_epoch="$(date -u -d "$not_after" +%s)"
  [[ $((end_epoch - start_epoch)) -eq $((expected_days * 86400)) ]] || \
    fail "unexpected validity for $cert"
}

assert_ca_extensions() {
  local cert="$1" pathlen="$2"
  local basic_constraints key_usage
  basic_constraints="$(openssl x509 -in "$cert" -noout -ext basicConstraints)"
  key_usage="$(openssl x509 -in "$cert" -noout -ext keyUsage)"
  grep -Fq 'X509v3 Basic Constraints: critical' <<<"$basic_constraints" || \
    fail "basicConstraints is not critical: $cert"
  grep -Fq "CA:TRUE, pathlen:$pathlen" <<<"$basic_constraints" || \
    fail "unexpected pathlen: $cert"
  grep -Fq 'X509v3 Key Usage: critical' <<<"$key_usage" || \
    fail "keyUsage is not critical: $cert"
  grep -Fq 'Certificate Sign, CRL Sign' <<<"$key_usage" || \
    fail "keyCertSign/cRLSign missing: $cert"
}

printf '%s' 'nonprod-test-passphrase' >"$tmp/pass"
chmod 600 "$tmp/pass"
pass_file="$tmp/pass"
if command -v cygpath >/dev/null 2>&1; then
  pass_file="$(cygpath -w "$pass_file")"
fi

ROOT_CA_PASS_FILE="$pass_file" "$create_root" "$tmp/root" >/dev/null 2>&1
assert_exact_files "$tmp/root" root-ca.crt root-ca.key root-ca.sha256

root_text="$tmp/root.txt"
openssl x509 -in "$tmp/root/root-ca.crt" -noout -text >"$root_text"
grep -Fq 'Public Key Algorithm: rsaEncryption' "$root_text" || fail 'Root key is not RSA'
grep -Fq 'Public-Key: (4096 bit)' "$root_text" || fail 'Root key is not 4096 bit'
grep -Fq 'Signature Algorithm: sha384WithRSAEncryption' "$root_text" || fail 'Root signature is not SHA-384'
assert_validity_days "$tmp/root/root-ca.crt" 3650
assert_ca_extensions "$tmp/root/root-ca.crt" 1
openssl pkey -in "$tmp/root/root-ca.key" -passin file:"$pass_file" -noout
if openssl pkey -in "$tmp/root/root-ca.key" -passin pass:incorrect-nonprod-passphrase \
  -noout >/dev/null 2>&1; then
  fail 'Root key must remain encrypted'
fi

expected_fingerprint="$(openssl x509 -in "$tmp/root/root-ca.crt" -outform DER | sha256sum | awk '{print $1}')"
actual_fingerprint="$(tr -d '\r\n' <"$tmp/root/root-ca.sha256")"
[[ "$actual_fingerprint" == "$expected_fingerprint" ]] || fail 'DER SHA-256 fingerprint mismatch'

MSYS2_ARG_CONV_EXCL='/CN=' openssl req -new -newkey rsa:3072 -nodes \
  -subj '/CN=Acer Lab Intermediate CA 2026' \
  -keyout "$tmp/intermediate.key" -out "$tmp/intermediate.csr" >/dev/null 2>&1
ROOT_CA_PASS_FILE="$pass_file" "$sign_intermediate" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed" >/dev/null 2>&1

assert_exact_files "$tmp/signed" vault-intermediate-chain.pem vault-intermediate.crt
[[ ! -e "$tmp/root/root-ca.srl" ]] || fail 'signer left root-ca.srl beside the Root CA'
openssl verify -CAfile "$tmp/root/root-ca.crt" "$tmp/signed/vault-intermediate.crt"

intermediate_text="$tmp/intermediate.txt"
openssl x509 -in "$tmp/signed/vault-intermediate.crt" -noout -text >"$intermediate_text"
grep -Fq 'Public Key Algorithm: rsaEncryption' "$intermediate_text" || fail 'Intermediate key is not RSA'
grep -Fq 'Public-Key: (3072 bit)' "$intermediate_text" || fail 'Intermediate key is not 3072 bit'
grep -Fq 'Signature Algorithm: sha384WithRSAEncryption' "$intermediate_text" || \
  fail 'Intermediate signature is not SHA-384'
assert_validity_days "$tmp/signed/vault-intermediate.crt" 1095
assert_ca_extensions "$tmp/signed/vault-intermediate.crt" 0

cat "$tmp/signed/vault-intermediate.crt" "$tmp/root/root-ca.crt" >"$tmp/expected-chain.pem"
cmp -s "$tmp/expected-chain.pem" "$tmp/signed/vault-intermediate-chain.pem" || \
  fail 'Intermediate chain is not exact leaf-first order'

mkdir "$tmp/root-existing"
printf '%s' sentinel >"$tmp/root-existing/sentinel"
if ROOT_CA_PASS_FILE="$pass_file" "$create_root" "$tmp/root-existing" >/dev/null 2>&1; then
  fail 'Root creator accepted an existing output directory'
fi
[[ "$(cat "$tmp/root-existing/sentinel")" == sentinel ]] || fail 'existing Root output was modified'
assert_no_temp_siblings "$tmp/root-existing"

if ROOT_CA_PASS_FILE="$tmp/missing-pass" "$create_root" "$tmp/root-missing-pass" >/dev/null 2>&1; then
  fail 'Root creator accepted a missing pass file'
fi
assert_absent_and_clean "$tmp/root-missing-pass"

mkdir "$tmp/signed-existing"
printf '%s' sentinel >"$tmp/signed-existing/sentinel"
if ROOT_CA_PASS_FILE="$pass_file" "$sign_intermediate" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed-existing" >/dev/null 2>&1; then
  fail 'Intermediate signer accepted an existing output directory'
fi
[[ "$(cat "$tmp/signed-existing/sentinel")" == sentinel ]] || fail 'existing signed output was modified'
assert_no_temp_siblings "$tmp/signed-existing"

if ROOT_CA_PASS_FILE="$tmp/missing-pass" "$sign_intermediate" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed-missing-pass" >/dev/null 2>&1; then
  fail 'Intermediate signer accepted a missing pass file'
fi
assert_absent_and_clean "$tmp/signed-missing-pass"

MSYS2_ARG_CONV_EXCL='/CN=' openssl req -new -newkey rsa:2048 -nodes \
  -subj '/CN=Wrong Size Intermediate CA' \
  -keyout "$tmp/rsa-2048.key" -out "$tmp/rsa-2048.csr" >/dev/null 2>&1
if ROOT_CA_PASS_FILE="$pass_file" "$sign_intermediate" \
  "$tmp/root" "$tmp/rsa-2048.csr" "$tmp/signed-rsa-2048" >/dev/null 2>&1; then
  fail 'Intermediate signer accepted RSA 2048'
fi
assert_absent_and_clean "$tmp/signed-rsa-2048"

openssl genpkey -genparam -algorithm DSA -pkeyopt dsa_paramgen_bits:3072 \
  -out "$tmp/dsa.params" >/dev/null 2>&1
openssl genpkey -paramfile "$tmp/dsa.params" -out "$tmp/dsa.key" >/dev/null 2>&1
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -new -key "$tmp/dsa.key" \
  -subj '/CN=Wrong Algorithm Intermediate CA' -out "$tmp/dsa.csr" >/dev/null 2>&1
if ROOT_CA_PASS_FILE="$pass_file" "$sign_intermediate" \
  "$tmp/root" "$tmp/dsa.csr" "$tmp/signed-dsa" >/dev/null 2>&1; then
  fail 'Intermediate signer accepted a 3072-bit non-RSA CSR'
fi
assert_absent_and_clean "$tmp/signed-dsa"

fake_sha_bin="$tmp/fake-sha-bin"
mkdir "$fake_sha_bin"
cat >"$fake_sha_bin/sha256sum" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_sha_bin/sha256sum"
if PATH="$fake_sha_bin:$PATH" ROOT_CA_PASS_FILE="$pass_file" \
  "$create_root" "$tmp/root-partial" >/dev/null 2>&1; then
  fail 'Root creator unexpectedly succeeded with a failing fingerprint command'
fi
assert_absent_and_clean "$tmp/root-partial"

printf '%s\n' '0123456789ABCDEF' >"$tmp/root/root-ca.srl"
ROOT_CA_PASS_FILE="$pass_file" "$sign_intermediate" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed-preserve-serial" >/dev/null 2>&1
[[ "$(cat "$tmp/root/root-ca.srl")" == '0123456789ABCDEF' ]] || \
  fail 'signer modified or deleted a pre-existing root-ca.srl'
assert_exact_files "$tmp/signed-preserve-serial" vault-intermediate-chain.pem vault-intermediate.crt

fake_cat_bin="$tmp/fake-cat-bin"
mkdir "$fake_cat_bin"
cat >"$fake_cat_bin/cat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_cat_bin/cat"
if PATH="$fake_cat_bin:$PATH" ROOT_CA_PASS_FILE="$pass_file" \
  "$sign_intermediate" "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed-partial" >/dev/null 2>&1; then
  fail 'Intermediate signer unexpectedly succeeded with a failing chain command'
fi
assert_absent_and_clean "$tmp/signed-partial"
[[ "$(cat "$tmp/root/root-ca.srl")" == '0123456789ABCDEF' ]] || \
  fail 'failed signer modified or deleted a pre-existing root-ca.srl'

echo 'OFFLINE_ROOT_CA_VALIDATION=PASS'
