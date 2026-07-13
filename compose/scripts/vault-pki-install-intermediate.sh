#!/usr/bin/env bash
set -euo pipefail

umask 077

VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
chain=${1:-}

if [[ $# -ne 1 || -z "$chain" ]]; then
  echo "Usage: $0 SIGNED_LEAF_FIRST_CHAIN" >&2
  exit 2
fi
if [[ ! -f "$chain" ]]; then
  echo "Signed chain is missing: $chain" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

if ! awk -v out="$tmp" '
  BEGIN { count=0; inside=0; invalid=0 }
  $0 == "-----BEGIN CERTIFICATE-----" {
    if (inside || count >= 2) { invalid=1; next }
    count++
    inside=1
    file=out "/block-" count ".pem"
    print >file
    next
  }
  $0 == "-----END CERTIFICATE-----" {
    if (!inside) { invalid=1; next }
    print >file
    close(file)
    inside=0
    next
  }
  {
    if (!inside || $0 !~ /^[A-Za-z0-9+\/=]+$/) { invalid=1; next }
    print >file
  }
  END { if (invalid || inside || count != 2) exit 1 }
' "$chain"; then
  echo 'Signed chain must contain exactly one Intermediate followed by one Root certificate' >&2
  exit 1
fi

openssl x509 -in "$tmp/block-1.pem" -out "$tmp/intermediate.crt"
openssl x509 -in "$tmp/block-2.pem" -out "$tmp/root.crt"
intermediate_text="$(openssl x509 -in "$tmp/intermediate.crt" -noout -text)"
if ! grep -Fq 'Public Key Algorithm: rsaEncryption' <<<"$intermediate_text"; then
  echo 'Intermediate certificate must use RSA' >&2
  exit 1
fi
if [[ "$(sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' <<<"$intermediate_text" | head -1)" != 3072 ]]; then
  echo 'Intermediate certificate must use RSA 3072' >&2
  exit 1
fi
grep -Fq 'CA:TRUE, pathlen:0' <<<"$intermediate_text" || {
  echo 'First certificate must be an Intermediate CA with pathlen:0' >&2
  exit 1
}

root_text="$(openssl x509 -in "$tmp/root.crt" -noout -text)"
grep -Fq 'CA:TRUE' <<<"$root_text" || {
  echo 'Second certificate must be a Root CA' >&2
  exit 1
}
openssl verify -check_ss_sig -CAfile "$tmp/root.crt" "$tmp/root.crt" >/dev/null
openssl verify -CAfile "$tmp/root.crt" "$tmp/intermediate.crt"
if ! openssl x509 -in "$tmp/intermediate.crt" -noout -checkend $((900 * 24 * 60 * 60)); then
  echo 'Intermediate certificate has fewer than 900 remaining days' >&2
  exit 1
fi
if openssl x509 -in "$tmp/intermediate.crt" -noout -checkend $((1100 * 24 * 60 * 60)); then
  echo 'Intermediate certificate has more than 1100 remaining days' >&2
  exit 1
fi

cat "$tmp/intermediate.crt" "$tmp/root.crt" >"$tmp/canonical-chain.pem"
docker exec -i "$VAULT_CONTAINER" sh -ceu '
  lock=/tmp/vault-pki-intermediate-install.lock
  lock_owned=0
  chain_tmp=""
  cleanup() {
    if [ -n "$chain_tmp" ]; then rm -f -- "$chain_tmp"; fi
    if [ "$lock_owned" -eq 1 ]; then rmdir -- "$lock"; fi
  }
  trap cleanup EXIT
  if ! mkdir -- "$lock"; then
    echo "Another pki_int installation is in progress" >&2
    exit 1
  fi
  lock_owned=1
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"

  require_unsigned_ca() {
    ca=""
    if ca="$(vault read -field=certificate pki_int/cert/ca 2>/dev/null)"; then
      if printf "%s\n" "$ca" | grep -q "BEGIN CERTIFICATE"; then
        echo "pki_int already has a signed CA; use the rotation runbook" >&2
        return 1
      fi
      return 0
    else
      status=$?
      if [ "$status" -eq 2 ]; then return 0; fi
      echo "Unable to verify whether pki_int already has a signed CA" >&2
      return 1
    fi
  }

  require_unsigned_ca
  chain_tmp="$(mktemp /tmp/vault-intermediate-chain.XXXXXX)"
  cat >"$chain_tmp"
  require_unsigned_ca
  vault write pki_int/intermediate/set-signed certificate=@"$chain_tmp" >/dev/null
' <"$tmp/canonical-chain.pem"
