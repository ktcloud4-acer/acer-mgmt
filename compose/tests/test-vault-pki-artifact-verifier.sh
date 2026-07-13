#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verify="$root/compose/scripts/verify-vault-pki-artifacts.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_reject() {
  local reason="$1"; shift
  if "$verify" "$@" >"$tmp/reject.out" 2>&1; then
    fail "accepted invalid artifact: $reason"
  fi
  grep -Fqi "$reason" "$tmp/reject.out" || fail "wrong rejection for $reason: $(cat "$tmp/reject.out")"
}

[[ -x "$verify" ]] || fail "missing executable verifier: $verify"
printf '%s' 'artifact-test-passphrase' >"$tmp/pass"
chmod 600 "$tmp/pass"
pass_path="$tmp/pass"
if command -v cygpath >/dev/null 2>&1; then pass_path="$(cygpath -w "$pass_path")"; fi
ROOT_CA_PASS_FILE="$tmp/pass" "$root/compose/scripts/create-offline-root-ca.sh" "$tmp/root" \
  >/dev/null 2>&1
"$verify" --root-only "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" |
  grep -Fq 'VAULT_PKI_ROOT=PASS'
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -new -newkey rsa:3072 -nodes \
  -subj '/CN=Verifier Intermediate' \
  -keyout "$tmp/intermediate.key" -out "$tmp/intermediate.csr" >/dev/null 2>&1
ROOT_CA_PASS_FILE="$tmp/pass" "$root/compose/scripts/sign-vault-intermediate.sh" \
  "$tmp/root" "$tmp/intermediate.csr" "$tmp/signed" >/dev/null 2>&1

"$verify" "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" \
  "$tmp/signed/vault-intermediate.crt" "$tmp/signed/vault-intermediate-chain.pem" |
  grep -Fq 'VAULT_PKI_ARTIFACTS=PASS'

cat "$tmp/root/root-ca.crt" "$tmp/signed/vault-intermediate.crt" >"$tmp/swapped.pem"
expect_reject 'chain order' "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" \
  "$tmp/signed/vault-intermediate.crt" "$tmp/swapped.pem"
cat "$tmp/signed/vault-intermediate-chain.pem" "$tmp/root/root-ca.crt" >"$tmp/extra.pem"
expect_reject 'exactly two' "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" \
  "$tmp/signed/vault-intermediate.crt" "$tmp/extra.pem"

openssl x509 -req -sha384 -days 100 -in "$tmp/intermediate.csr" \
  -CA "$tmp/root/root-ca.crt" -CAkey "$tmp/root/root-ca.key" \
  -passin "file:$pass_path" -CAcreateserial \
  -extfile "$root/compose/config/vault-pki/root-ca-openssl.cnf" \
  -extensions v3_intermediate_ca -out "$tmp/wrong-validity.crt" >/dev/null 2>&1
cat "$tmp/wrong-validity.crt" "$tmp/root/root-ca.crt" >"$tmp/wrong-validity-chain.pem"
expect_reject 'validity' "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" \
  "$tmp/wrong-validity.crt" "$tmp/wrong-validity-chain.pem"

cat >"$tmp/wrong-ku.cnf" <<'EOF'
[ wrong_intermediate ]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
openssl x509 -req -sha384 -days 1095 -in "$tmp/intermediate.csr" \
  -CA "$tmp/root/root-ca.crt" -CAkey "$tmp/root/root-ca.key" \
  -passin "file:$pass_path" -CAcreateserial -extfile "$tmp/wrong-ku.cnf" \
  -extensions wrong_intermediate -out "$tmp/wrong-ku.crt" >/dev/null 2>&1
cat "$tmp/wrong-ku.crt" "$tmp/root/root-ca.crt" >"$tmp/wrong-ku-chain.pem"
expect_reject 'key usage' "$tmp/root/root-ca.crt" "$tmp/root/root-ca.sha256" \
  "$tmp/wrong-ku.crt" "$tmp/wrong-ku-chain.pem"

openssl req -new -x509 -sha384 -days 100 -key "$tmp/root/root-ca.key" \
  -passin "file:$pass_path" -config "$root/compose/config/vault-pki/root-ca-openssl.cnf" \
  -extensions v3_root_ca -out "$tmp/wrong-root-validity.crt" >/dev/null 2>&1
openssl x509 -in "$tmp/wrong-root-validity.crt" -outform DER | sha256sum | awk '{print $1}' \
  >"$tmp/wrong-root-validity.sha256"
expect_reject 'validity' --root-only "$tmp/wrong-root-validity.crt" \
  "$tmp/wrong-root-validity.sha256"

echo 'VAULT_PKI_ARTIFACT_VERIFIER_TESTS=PASS'
