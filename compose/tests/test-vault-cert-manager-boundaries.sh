#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$root/compose/scripts/bootstrap-vault-cert-manager.sh"
profiles="$root/compose/config/vault-pki/teams.tsv"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $1"; }

[[ -x "$script" ]] || fail "missing executable: $script"
[[ -r "$profiles" ]] || fail "missing profiles: $profiles"

work="$(mktemp -d)"
created_token=0
cleanup() {
  rm -rf -- "$work"
  if [[ $created_token -eq 1 ]]; then rm -f -- /tmp/.vt; fi
}
trap cleanup EXIT

cat >"$work/expected-teams.tsv" <<'EOF'
ggg	kubernetes-ggg	cert-manager-ggg	cert-manager-ggg	ggg-internal
nmg	kubernetes-nmg	cert-manager-nmg	cert-manager-nmg	nmg-internal
khb	kubernetes-khb	cert-manager-khb	cert-manager-khb	khb-internal
ljw	kubernetes-ljw	cert-manager-ljw	cert-manager-ljw	ljw-internal
oje	kubernetes-oje	cert-manager-oje	cert-manager-oje	oje-internal
EOF
cmp "$work/expected-teams.tsv" "$profiles" || fail 'teams.tsv does not match the approved mapping'

while IFS=$'\t' read -r team mount auth_role policy pki_role; do
  contains "$script" "auth/${mount}/role/${auth_role}"
  contains "$script" 'bound_service_account_names=vault-issuer'
  contains "$script" 'bound_service_account_namespaces=cert-manager'
  contains "$script" 'audience=vault://vault-internal'
  contains "$script" "pki_int/sign/${pki_role}"
done <"$profiles"
contains "$script" 'ttl=2160h max_ttl=2160h'
contains "$script" 'allow_any_name=false'
contains "$script" 'allow_subdomains=false'
contains "$script" 'allow_ip_sans=false'
if grep -Eq 'kv/data|scalecart|allow_any_name=true|allow_subdomains=true|allow_ip_sans=true|sign-verbatim|root/generate|[*]' "$script"; then
  fail 'bootstrap contains a forbidden PKI or secret boundary'
fi
if grep -Eq 'vault auth enable|auth/[^[:space:]]+/config' "$script"; then
  fail 'bootstrap must not enable or reconfigure Kubernetes auth mounts'
fi

if [[ -e /tmp/.vt ]]; then
  fail '/tmp/.vt already exists; refusing to disturb it during shim tests'
fi
printf '%s\n' test-token >/tmp/.vt
chmod 600 /tmp/.vt
created_token=1

mkdir -p "$work/bin" "$work/cases" "$work/state/roles" "$work/state/policies" "$work/state/auth"
export VAULT_TEST_LOG="$work/vault.log"
export VAULT_STATE_DIR="$work/state"
export VAULT_AUTH_STATE=complete
export VAULT_CA_STATE=readable
export VAULT_FAIL_STAGE=''
export VAULT_FAIL_TEAM=nmg

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
[[ ${1:-} == -e && ${2:-} == --arg && ${3:-} == mount && $# -eq 5 ]] || exit 64
mount=$4
query=$5
[[ "$query" == '.[$mount].type == "kubernetes"' ]] || exit 64
input="$(cat)"
[[ "$input" == \{*\} ]] || exit 4
grep -Fq -- "\"$mount\":{\"type\":\"kubernetes\"}" <<<"$input"
SH

cat >"$work/bin/vault" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

fail() { echo "vault shim: $*" >&2; exit 65; }
log() { printf '%s\n' "$1" >>"$VAULT_TEST_LOG"; }
inject_failure() {
  local stage=$1 team=$2
  if [[ ${VAULT_FAIL_STAGE:-} == "$stage" && ${VAULT_FAIL_TEAM:-} == "$team" ]]; then
    log "failed-$stage:$team"
    exit 70
  fi
}

team_for_role() {
  case "$1" in
    ggg-internal) printf ggg ;;
    nmg-internal) printf nmg ;;
    khb-internal) printf khb ;;
    ljw-internal) printf ljw ;;
    oje-internal) printf oje ;;
    *) return 1 ;;
  esac
}

case "${1:-}/${2:-}" in
  auth/list)
    [[ ${3:-} == -format=json && $# -eq 3 ]] || fail 'unexpected auth list arguments'
    log auth-list
    case "${VAULT_AUTH_STATE:-complete}" in
      complete)
        printf '%s\n' '{"kubernetes-ggg/":{"type":"kubernetes"},"kubernetes-nmg/":{"type":"kubernetes"},"kubernetes-khb/":{"type":"kubernetes"},"kubernetes-ljw/":{"type":"kubernetes"},"kubernetes-oje/":{"type":"kubernetes"}}'
        ;;
      missing-oje)
        printf '%s\n' '{"kubernetes-ggg/":{"type":"kubernetes"},"kubernetes-nmg/":{"type":"kubernetes"},"kubernetes-khb/":{"type":"kubernetes"},"kubernetes-ljw/":{"type":"kubernetes"}}'
        ;;
      wrong-type)
        printf '%s\n' '{"kubernetes-ggg/":{"type":"kubernetes"},"kubernetes-nmg/":{"type":"kubernetes"},"kubernetes-khb/":{"type":"kubernetes"},"kubernetes-ljw/":{"type":"kubernetes"},"kubernetes-oje/":{"type":"userpass"}}'
        ;;
      malformed)
        printf '%s\n' 'NOT_JSON'
        ;;
      *) fail 'unknown auth state' ;;
    esac
    ;;
  read/-field=certificate)
    [[ ${3:-} == pki_int/cert/ca && $# -eq 3 ]] || fail 'unexpected CA read arguments'
    log ca-read
    [[ ${VAULT_CA_STATE:-readable} == readable ]] || exit 2
    printf '%s\n' '-----BEGIN CERTIFICATE-----' shim '-----END CERTIFICATE-----'
    ;;
  write/*)
    target=$2
    shift 2
    case "$target" in
      pki_int/roles/*)
        role=${target#pki_int/roles/}
        team="$(team_for_role "$role")" || fail "unexpected PKI role: $role"
        expected="allowed_domains=chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost allow_bare_domains=true allow_subdomains=false allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false ttl=2160h max_ttl=2160h"
        [[ "$*" == "$expected" ]] || fail "unexpected PKI role arguments for $team: $*"
        inject_failure role "$team"
        printf '%s\n' "$expected" >"$VAULT_STATE_DIR/roles/$role"
        log "role:$role"
        ;;
      auth/kubernetes-*/role/cert-manager-*)
        remainder=${target#auth/kubernetes-}
        team=${remainder%%/*}
        [[ "$target" == "auth/kubernetes-$team/role/cert-manager-$team" ]] || fail "cross-team auth role: $target"
        expected="bound_service_account_names=vault-issuer bound_service_account_namespaces=cert-manager audience=vault://vault-internal token_policies=cert-manager-$team token_ttl=1m token_max_ttl=5m token_no_default_policy=true token_type=batch"
        [[ "$*" == "$expected" ]] || fail "unexpected auth role arguments for $team: $*"
        inject_failure auth "$team"
        printf '%s\n' "$expected" >"$VAULT_STATE_DIR/auth/$team"
        log "auth:$team"
        ;;
      *) fail "unexpected write target: $target" ;;
    esac
    ;;
  policy/write)
    policy=${3:-}
    [[ ${4:-} == - && $# -eq 4 ]] || fail 'unexpected policy arguments'
    team=${policy#cert-manager-}
    [[ "$policy" == "cert-manager-$team" ]] || fail "unexpected policy: $policy"
    body="$(cat)"
    expected="path \"pki_int/sign/$team-internal\" {
  capabilities = [\"update\"]
}"
    [[ "$body" == "$expected" ]] || fail "unexpected policy for $team: $body"
    inject_failure policy "$team"
    printf '%s\n' "$body" >"$VAULT_STATE_DIR/policies/$team"
    log "policy:$team"
    ;;
  *) fail "unexpected command: $*" ;;
esac
SH
chmod 755 "$work/bin/docker" "$work/bin/jq" "$work/bin/vault"
export PATH="$work/bin:$PATH"

expect_failure() {
  local name=$1
  shift
  if "$@" >"$work/cases/$name.stdout" 2>"$work/cases/$name.stderr"; then
    fail "$name unexpectedly succeeded"
  fi
}

assert_no_mutation() {
  if grep -Eq '^(role|policy|auth):' "$VAULT_TEST_LOG"; then
    fail "prerequisite failure reached mutation: $(cat "$VAULT_TEST_LOG")"
  fi
}

assert_no_vault_call() {
  [[ ! -s "$VAULT_TEST_LOG" ]] || fail "invalid profile reached Vault: $(cat "$VAULT_TEST_LOG")"
}

assert_state_names() {
  local kind=$1 expected=$2 actual
  actual="$(find "$VAULT_STATE_DIR/$kind" -maxdepth 1 -type f -printf '%f\n' | sort | paste -sd, -)"
  [[ "$actual" == "$expected" ]] || fail "unexpected $kind state: expected [$expected], got [$actual]"
}

assert_final_state() {
  local role_expected auth_expected policy_expected team pki_role
  assert_state_names roles 'ggg-internal,khb-internal,ljw-internal,nmg-internal,oje-internal'
  assert_state_names policies 'ggg,khb,ljw,nmg,oje'
  assert_state_names auth 'ggg,khb,ljw,nmg,oje'
  role_expected='allowed_domains=chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost allow_bare_domains=true allow_subdomains=false allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false ttl=2160h max_ttl=2160h'
  while IFS=$'\t' read -r team mount auth_role policy pki_role; do
    [[ "$(cat "$VAULT_STATE_DIR/roles/$pki_role")" == "$role_expected" ]] || fail "role state did not converge: $pki_role"
    auth_expected="bound_service_account_names=vault-issuer bound_service_account_namespaces=cert-manager audience=vault://vault-internal token_policies=$policy token_ttl=1m token_max_ttl=5m token_no_default_policy=true token_type=batch"
    [[ "$(cat "$VAULT_STATE_DIR/auth/$team")" == "$auth_expected" ]] || fail "auth state did not converge: $team"
    policy_expected="path \"pki_int/sign/$pki_role\" {
  capabilities = [\"update\"]
}"
    [[ "$(cat "$VAULT_STATE_DIR/policies/$team")" == "$policy_expected" ]] || fail "policy state did not converge: $team"
  done <"$profiles"
}

reset_state() {
  rm -rf -- "$VAULT_STATE_DIR"
  mkdir -p "$VAULT_STATE_DIR/roles" "$VAULT_STATE_DIR/policies" "$VAULT_STATE_DIR/auth"
  : >"$VAULT_TEST_LOG"
}

mkdir -p "$work/profiles"
: >"$work/profiles/empty.tsv"
head -n 4 "$profiles" >"$work/profiles/four.tsv"
cp "$profiles" "$work/profiles/six.tsv"
printf '%s\n' $'extra\tkubernetes-extra\tcert-manager-extra\tcert-manager-extra\textra-internal' >>"$work/profiles/six.tsv"
sed '3s/\tkhb-internal$//' "$profiles" >"$work/profiles/malformed-fields.tsv"
sed '2c\ggg\tkubernetes-ggg\tcert-manager-ggg\tcert-manager-ggg\tggg-internal' "$profiles" >"$work/profiles/duplicate.tsv"
sed '1s/cert-manager-ggg/cert-manager-nmg/' "$profiles" >"$work/profiles/cross-team.tsv"

for invalid_profile in empty four six malformed-fields duplicate cross-team; do
  reset_state
  expect_failure "invalid-profile-$invalid_profile" env \
    VAULT_PKI_TEAMS_FILE="$work/profiles/$invalid_profile.tsv" "$script"
  assert_no_vault_call
done

reset_state
export VAULT_AUTH_STATE=missing-oje
expect_failure missing-auth-mount "$script"
assert_no_mutation
[[ "$(cat "$VAULT_TEST_LOG")" == auth-list ]] || fail 'unexpected missing-mount command order'

for invalid_auth in malformed wrong-type; do
  reset_state
  export VAULT_AUTH_STATE=$invalid_auth
  expect_failure "invalid-auth-$invalid_auth" "$script"
  assert_no_mutation
  [[ "$(cat "$VAULT_TEST_LOG")" == auth-list ]] || fail "unexpected $invalid_auth auth command order"
done

reset_state
export VAULT_AUTH_STATE=complete
export VAULT_CA_STATE=missing
expect_failure missing-ca "$script"
assert_no_mutation
[[ "$(cat "$VAULT_TEST_LOG")" == $'auth-list\nca-read' ]] || fail 'unexpected missing-CA command order'

reset_state
export VAULT_CA_STATE=readable
"$script"

expected_log=$'auth-list\nca-read'
while IFS=$'\t' read -r team mount auth_role policy pki_role; do
  expected_log+=$'\n'"role:$pki_role"$'\n'"policy:$team"$'\n'"auth:$team"
done <"$profiles"
actual_log="$(cat "$VAULT_TEST_LOG")"
[[ "$actual_log" == "$expected_log" ]] || fail "unexpected successful command order: [$actual_log]"
assert_final_state

for failed_stage in role policy auth; do
  reset_state
  export VAULT_FAIL_STAGE=$failed_stage
  expect_failure "injected-$failed_stage" "$script"
  case "$failed_stage" in
    role)
      assert_state_names roles 'ggg-internal'
      assert_state_names policies 'ggg'
      assert_state_names auth 'ggg'
      ;;
    policy)
      assert_state_names roles 'ggg-internal,nmg-internal'
      assert_state_names policies 'ggg'
      assert_state_names auth 'ggg'
      ;;
    auth)
      assert_state_names roles 'ggg-internal,nmg-internal'
      assert_state_names policies 'ggg,nmg'
      assert_state_names auth 'ggg'
      ;;
  esac

  export VAULT_FAIL_STAGE=''
  "$script"
  assert_final_state
  before="$(find "$VAULT_STATE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"
  "$script"
  assert_final_state
  after="$(find "$VAULT_STATE_DIR" -type f -print0 | sort -z | xargs -0 sha256sum)"
  [[ "$after" == "$before" ]] || fail "$failed_stage rerun was not idempotent"
done

echo 'VAULT_CERT_MANAGER_BOUNDARIES=PASS'
