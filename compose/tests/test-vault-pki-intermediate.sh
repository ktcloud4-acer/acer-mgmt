#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
generate="$root/compose/scripts/vault-pki-generate-intermediate-csr.sh"
install="$root/compose/scripts/vault-pki-install-intermediate.sh"
config="$root/compose/config/vault-pki/root-ca-openssl.cnf"
sign="$root/compose/scripts/sign-vault-intermediate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

for file in "$generate" "$install"; do
  [[ -x "$file" ]] || fail "missing executable: $file"
done
contains "$generate" 'vault secrets enable -path=pki_int pki'
contains "$generate" 'vault secrets tune -max-lease-ttl=26280h pki_int'
contains "$generate" 'pki_int/intermediate/generate/internal'
contains "$generate" 'key_type=rsa'
contains "$generate" 'key_bits=3072'
contains "$install" 'pki_int/intermediate/set-signed'
contains "$install" 'CA:TRUE, pathlen:0'
contains "$install" 'openssl verify'
if grep -Eq 'generate/exported|root-ca.key|set -x' "$generate" "$install"; then
  fail 'exported keys, offline Root keys, and tracing are forbidden'
fi

work="$(mktemp -d)"
created_token=0
cleanup() {
  rm -rf -- "$work"
  if [[ $created_token -eq 1 ]]; then rm -f /tmp/.vt; fi
  rm -rf -- /tmp/vault-pki-intermediate-install.lock
  rm -f -- /tmp/vault-intermediate-chain.*
}
trap cleanup EXIT

if [[ -e /tmp/.vt ]]; then
  fail '/tmp/.vt already exists; refusing to disturb it during shim tests'
fi
printf '%s\n' test-token >/tmp/.vt
chmod 600 /tmp/.vt
created_token=1

mkdir -p "$work/bin" "$work/fixtures/root" "$work/cases"
export VAULT_TEST_LOG="$work/vault.log"
export VAULT_SIGNED_FILE="$work/vault-signed"
export VAULT_READ_COUNT_FILE="$work/vault-read-count"
export VAULT_CAPTURE_FILE="$work/installed-chain.pem"
export VAULT_CSR_SOURCE="$work/fixtures/intermediate.csr"
export CHMOD_TEST_LOG="$work/chmod.log"

cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == exec ]] || exit 64
shift
if [[ ${1:-} == -i ]]; then shift; fi
[[ $# -ge 2 ]] || exit 64
shift
exec "$@"
SH

cat >"$work/bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
input="$(cat)"
[[ "$input" != NOT_JSON ]] || exit 4
case "$args" in
  *'has("pki_int/")'*)
    grep -Fq '"pki_int/"' <<<"$input"
    ;;
  *'.["pki_int/"].type'*)
    sed -n 's/.*"type":"\([^"]*\)".*/\1/p' <<<"$input"
    ;;
  *'.data.csr'*)
    [[ ${JQ_FAIL_CSR:-0} != 1 ]] || exit 5
    cat "$VAULT_CSR_SOURCE"
    ;;
  *) exit 64 ;;
esac
SH

cat >"$work/bin/vault" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
case "$cmd" in
  secrets)
    case "${2:-}" in
      list)
        printf '%s\n' list >>"$VAULT_TEST_LOG"
        case "${VAULT_MOUNT_STATE:-pki}" in
          absent) printf '{}\n' ;;
          invalid) printf 'NOT_JSON\n' ;;
          pki) printf '{"pki_int/":{"type":"pki"}}\n' ;;
          *) printf '{"pki_int/":{"type":"%s"}}\n' "$VAULT_MOUNT_STATE" ;;
        esac
        ;;
      enable)
        printf '%s\n' enable >>"$VAULT_TEST_LOG"
        ;;
      tune)
        printf '%s\n' tune >>"$VAULT_TEST_LOG"
        ;;
      *) exit 64 ;;
    esac
    ;;
  read)
    printf '%s\n' read >>"$VAULT_TEST_LOG"
    count=0
    [[ ! -f "$VAULT_READ_COUNT_FILE" ]] || count="$(cat "$VAULT_READ_COUNT_FILE")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$VAULT_READ_COUNT_FILE"
    if [[ -f "$VAULT_SIGNED_FILE" || ( ${VAULT_SIGN_ON_READ:-0} -gt 0 && $count -ge ${VAULT_SIGN_ON_READ} ) ]]; then
      printf '%s\n' '-----BEGIN CERTIFICATE-----' 'signed' '-----END CERTIFICATE-----'
      exit 0
    fi
    exit 2
    ;;
  write)
    target=${2:-}
    if [[ "$target" == -format=json ]]; then target=${3:-}; fi
    case "$target" in
      pki_int/intermediate/generate/internal)
        printf '%s\n' generate >>"$VAULT_TEST_LOG"
        [[ ${VAULT_GENERATE_FAIL:-0} != 1 ]] || exit 7
        printf '{"data":{"csr":"shim"}}\n'
        ;;
      pki_int/intermediate/set-signed)
        printf '%s\n' set-signed >>"$VAULT_TEST_LOG"
        payload=${3#certificate=@}
        cp -- "$payload" "$VAULT_CAPTURE_FILE"
        [[ ${VAULT_SET_SIGNED_FAIL:-0} != 1 ]] || exit 8
        : >"$VAULT_SIGNED_FILE"
        ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
SH
cat >"$work/bin/chmod" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${1:-}" "${2:-}" >>"$CHMOD_TEST_LOG"
exec /usr/bin/chmod "$@"
SH
for command in mv ln; do
  cat >"$work/bin/$command" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
destination=${!#}
if [[ -n ${PUBLISH_RACE_OUTPUT:-} && "$destination" == "$PUBLISH_RACE_OUTPUT" ]]; then
  printf '%s\n' "${PUBLISH_RACE_CONTENT:-competitor}" >"$destination"
fi
exec "/usr/bin/$(basename "$0")" "$@"
SH
done
chmod 755 "$work/bin/docker" "$work/bin/jq" "$work/bin/vault" "$work/bin/chmod" \
  "$work/bin/mv" "$work/bin/ln"
export PATH="$work/bin:$PATH"

export MSYS2_ARG_CONV_EXCL='/CN'
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -out "$work/fixtures/intermediate.key" >/dev/null 2>&1
openssl req -new -key "$work/fixtures/intermediate.key" \
  -subj '/CN=Acer Lab Intermediate CA 2026' -out "$VAULT_CSR_SOURCE"

reset_vault() {
  : >"$VAULT_TEST_LOG"
  rm -f -- "$VAULT_SIGNED_FILE" "$VAULT_READ_COUNT_FILE" "$VAULT_CAPTURE_FILE"
  export VAULT_MOUNT_STATE=pki
  export VAULT_GENERATE_FAIL=0
  export VAULT_SET_SIGNED_FAIL=0
  export VAULT_SIGN_ON_READ=0
  export JQ_FAIL_CSR=0
  export PUBLISH_RACE_OUTPUT=''
  export PUBLISH_RACE_CONTENT=competitor
}

expect_failure() {
  local name=$1
  shift
  if "$@" >"$work/cases/$name.stdout" 2>"$work/cases/$name.stderr"; then
    fail "$name unexpectedly succeeded"
  fi
}

assert_log() {
  local expected=$1
  local actual
  actual="$(cat "$VAULT_TEST_LOG")"
  [[ "$actual" == "$expected" ]] || fail "unexpected Vault order: expected [$expected], got [$actual]"
}

assert_no_output_or_temp() {
  local output=$1
  [[ ! -e "$output" ]] || fail "failed generation left output: $output"
  if compgen -G "$(dirname "$output")/.$(basename "$output").tmp.*" >/dev/null; then
    fail "failed generation left destination-local temp for $output"
  fi
}

reset_vault
export VAULT_MOUNT_STATE=kv
wrong_mount="$work/wrong-mount.csr"
expect_failure wrong-mount "$generate" "$wrong_mount"
assert_log $'list'
assert_no_output_or_temp "$wrong_mount"
contains "$work/cases/wrong-mount.stderr" 'must be type pki'

reset_vault
export VAULT_MOUNT_STATE=invalid
invalid_mounts="$work/invalid-mount-list.csr"
expect_failure invalid-mount-list "$generate" "$invalid_mounts"
assert_log $'list'
assert_no_output_or_temp "$invalid_mounts"

reset_vault
: >"$VAULT_SIGNED_FILE"
already_signed="$work/already-signed.csr"
expect_failure generator-already-signed "$generate" "$already_signed"
assert_log $'list\nread'
assert_no_output_or_temp "$already_signed"
contains "$work/cases/generator-already-signed.stderr" 'rotation runbook'

reset_vault
export VAULT_GENERATE_FAIL=1
failed_generate="$work/failed-generate.csr"
expect_failure failed-generate "$generate" "$failed_generate"
assert_log $'list\nread\ntune\ngenerate'
assert_no_output_or_temp "$failed_generate"

reset_vault
export JQ_FAIL_CSR=1
failed_jq="$work/failed-jq.csr"
expect_failure failed-jq "$generate" "$failed_jq"
assert_log $'list\nread\ntune\ngenerate'
assert_no_output_or_temp "$failed_jq"

reset_vault
export VAULT_MOUNT_STATE=absent
generated="$work/generated.csr"
"$generate" "$generated"
assert_log $'list\nenable\nread\ntune\ngenerate'
openssl req -in "$generated" -noout -verify >/dev/null
contains "$CHMOD_TEST_LOG" "600 $work/.generated.csr.tmp."
if compgen -G "$work/.generated.csr.tmp.*" >/dev/null; then
  fail 'successful generation left destination-local temp'
fi

reset_vault
publish_race="$work/publish-race.csr"
export PUBLISH_RACE_OUTPUT="$publish_race"
expect_failure publish-race "$generate" "$publish_race"
assert_log $'list\nread\ntune\ngenerate'
[[ "$(cat "$publish_race")" == competitor ]] || fail 'concurrent destination was overwritten'
if compgen -G "$work/.publish-race.csr.tmp.*" >/dev/null; then
  fail 'publish race left destination-local temp'
fi

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$work/fixtures/root/root-ca.key" >/dev/null 2>&1
openssl req -new -x509 -sha384 -days 3650 \
  -key "$work/fixtures/root/root-ca.key" -config "$config" \
  -extensions v3_root_ca -out "$work/fixtures/root/root-ca.crt"
"$sign" "$work/fixtures/root" "$VAULT_CSR_SOURCE" "$work/fixtures/signed"
valid_chain="$work/fixtures/signed/vault-intermediate-chain.pem"
valid_intermediate="$work/fixtures/signed/vault-intermediate.crt"

sign_variant() {
  local csr=$1 key_root=$2 cert_root=$3 days=$4 extension=$5 serial=$6 output=$7
  openssl x509 -req -sha384 -days "$days" -in "$csr" \
    -CA "$cert_root" -CAkey "$key_root" -set_serial "$serial" \
    -extfile "$config" -extensions "$extension" -out "$output" >/dev/null
}

cat "$work/fixtures/root/root-ca.crt" "$valid_intermediate" >"$work/fixtures/reversed.pem"
cat "$valid_chain" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/extra.pem"
{ printf '%s\n' garbage; cat "$valid_chain"; } >"$work/fixtures/malformed.pem"
sign_variant "$VAULT_CSR_SOURCE" "$work/fixtures/root/root-ca.key" \
  "$work/fixtures/root/root-ca.crt" 1095 v3_root_ca 3 "$work/fixtures/pathlen1.crt"
cat "$work/fixtures/pathlen1.crt" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/pathlen1.pem"
sign_variant "$VAULT_CSR_SOURCE" "$work/fixtures/root/root-ca.key" \
  "$work/fixtures/root/root-ca.crt" 800 v3_intermediate_ca 4 "$work/fixtures/short.crt"
cat "$work/fixtures/short.crt" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/short.pem"
sign_variant "$VAULT_CSR_SOURCE" "$work/fixtures/root/root-ca.key" \
  "$work/fixtures/root/root-ca.crt" 1200 v3_intermediate_ca 5 "$work/fixtures/long.crt"
cat "$work/fixtures/long.crt" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/long.pem"

mkdir "$work/fixtures/other-root"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$work/fixtures/other-root/root-ca.key" >/dev/null 2>&1
openssl req -new -x509 -sha384 -days 3650 \
  -key "$work/fixtures/other-root/root-ca.key" -config "$config" \
  -extensions v3_root_ca -out "$work/fixtures/other-root/root-ca.crt"
sign_variant "$VAULT_CSR_SOURCE" "$work/fixtures/other-root/root-ca.key" \
  "$work/fixtures/other-root/root-ca.crt" 1095 v3_intermediate_ca 6 "$work/fixtures/untrusted.crt"
cat "$work/fixtures/untrusted.crt" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/untrusted.pem"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out "$work/fixtures/rsa2048.key" >/dev/null 2>&1
openssl req -new -key "$work/fixtures/rsa2048.key" -subj '/CN=Wrong RSA Intermediate' \
  -out "$work/fixtures/rsa2048.csr"
sign_variant "$work/fixtures/rsa2048.csr" "$work/fixtures/root/root-ca.key" \
  "$work/fixtures/root/root-ca.crt" 1095 v3_intermediate_ca 7 "$work/fixtures/rsa2048.crt"
cat "$work/fixtures/rsa2048.crt" "$work/fixtures/root/root-ca.crt" >"$work/fixtures/rsa2048.pem"

for case_name in reversed extra malformed pathlen1 short long untrusted rsa2048; do
  reset_vault
  expect_failure "installer-$case_name" "$install" "$work/fixtures/$case_name.pem"
  [[ ! -s "$VAULT_TEST_LOG" ]] || fail "$case_name reached Vault mutation boundary"
  [[ ! -e "$VAULT_CAPTURE_FILE" ]] || fail "$case_name installed a payload"
done

assert_container_clean() {
  [[ ! -e /tmp/vault-pki-intermediate-install.lock ]] || fail 'container lock was not cleaned'
  if compgen -G '/tmp/vault-intermediate-chain.*' >/dev/null; then
    fail 'container chain temp was not cleaned'
  fi
}

reset_vault
: >"$VAULT_SIGNED_FILE"
expect_failure installer-already-signed "$install" "$valid_chain"
assert_log $'read'
[[ ! -e "$VAULT_CAPTURE_FILE" ]] || fail 'already signed CA was replaced'
contains "$work/cases/installer-already-signed.stderr" 'rotation runbook'
assert_container_clean

reset_vault
export VAULT_SIGN_ON_READ=2
expect_failure installer-race "$install" "$valid_chain"
assert_log $'read\nread'
[[ ! -e "$VAULT_CAPTURE_FILE" ]] || fail 'signed CA race reached set-signed'
assert_container_clean

reset_vault
mkdir /tmp/vault-pki-intermediate-install.lock
expect_failure installer-concurrent "$install" "$valid_chain"
[[ ! -s "$VAULT_TEST_LOG" ]] || fail 'concurrent installer reached Vault'
[[ -d /tmp/vault-pki-intermediate-install.lock ]] || fail 'installer removed a lock it did not own'
rmdir /tmp/vault-pki-intermediate-install.lock

reset_vault
export VAULT_SET_SIGNED_FAIL=1
expect_failure installer-write-failure "$install" "$valid_chain"
assert_log $'read\nread\nset-signed'
assert_container_clean

reset_vault
"$install" "$valid_chain"
assert_log $'read\nread\nset-signed'
assert_container_clean
openssl x509 -in "$valid_intermediate" -out "$work/expected-intermediate.crt"
openssl x509 -in "$work/fixtures/root/root-ca.crt" -out "$work/expected-root.crt"
cat "$work/expected-intermediate.crt" "$work/expected-root.crt" >"$work/expected-chain.pem"
cmp "$work/expected-chain.pem" "$VAULT_CAPTURE_FILE" || fail 'installed payload is not the validated canonical chain'

echo 'VAULT_PKI_INTERMEDIATE_CONTRACT=PASS'
