#!/usr/bin/env bash
set -euo pipefail

umask 077

VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
profiles=${VAULT_PKI_TEAMS_FILE:-$root/compose/config/vault-pki/teams.tsv}
allowed_domains='chaos-mesh-controller-manager,chaos-mesh-controller-manager.chaos-mesh,chaos-mesh-controller-manager.chaos-mesh.svc,chaos-daemon.chaos-mesh.org,controller-manager.chaos-mesh.org,localhost'

# Approved one-to-one auth and signing boundaries:
# auth/kubernetes-ggg/role/cert-manager-ggg -> pki_int/sign/ggg-internal
# auth/kubernetes-nmg/role/cert-manager-nmg -> pki_int/sign/nmg-internal
# auth/kubernetes-khb/role/cert-manager-khb -> pki_int/sign/khb-internal
# auth/kubernetes-ljw/role/cert-manager-ljw -> pki_int/sign/ljw-internal
# auth/kubernetes-oje/role/cert-manager-oje -> pki_int/sign/oje-internal

for command in docker jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required command: $command" >&2
    exit 1
  }
done
[[ -r "$profiles" ]] || {
  echo "missing team profiles: $profiles" >&2
  exit 1
}

readonly -a approved_team_rows=(
  $'ggg\tkubernetes-ggg\tcert-manager-ggg\tcert-manager-ggg\tggg-internal'
  $'nmg\tkubernetes-nmg\tcert-manager-nmg\tcert-manager-nmg\tnmg-internal'
  $'khb\tkubernetes-khb\tcert-manager-khb\tcert-manager-khb\tkhb-internal'
  $'ljw\tkubernetes-ljw\tcert-manager-ljw\tcert-manager-ljw\tljw-internal'
  $'oje\tkubernetes-oje\tcert-manager-oje\tcert-manager-oje\toje-internal'
)
team_rows=()
if ! mapfile -t team_rows <"$profiles"; then
  echo "unable to read team profiles: $profiles" >&2
  exit 1
fi
if [[ ${#team_rows[@]} -ne ${#approved_team_rows[@]} ]]; then
  echo 'team profiles must contain exactly the five approved mappings' >&2
  exit 1
fi
for index in "${!approved_team_rows[@]}"; do
  if [[ "${team_rows[index]}" != "${approved_team_rows[index]}" ]]; then
    echo "team profile row $((index + 1)) does not match the approved mapping" >&2
    exit 1
  fi
done
readonly -a team_rows

vault_cmd() {
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    exec "$@"
  ' sh "$@"
}

vault_policy_write() {
  docker exec -i "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault policy write "$1" - >/dev/null
  ' sh "$1"
}

auth_mounts="$(vault_cmd vault auth list -format=json)"
for row in "${team_rows[@]}"; do
  IFS=$'\t' read -r team mount auth_role policy pki_role <<<"$row"
  if ! jq -e --arg mount "$mount/" '.[$mount].type == "kubernetes"' <<<"$auth_mounts" >/dev/null; then
    echo "required Kubernetes auth mount is missing or has the wrong type: $mount" >&2
    exit 1
  fi
done

if ! vault_cmd vault read -field=certificate pki_int/cert/ca >/dev/null; then
  echo 'pki_int signed CA is not readable' >&2
  exit 1
fi

for row in "${team_rows[@]}"; do
  IFS=$'\t' read -r team mount auth_role policy pki_role <<<"$row"
  vault_cmd vault write "pki_int/roles/$pki_role" \
    allowed_domains="$allowed_domains" allow_bare_domains=true allow_subdomains=false \
    allow_glob_domains=false allow_wildcard_certificates=false allow_any_name=false \
    enforce_hostnames=true allow_localhost=true allow_ip_sans=false require_cn=false \
    use_csr_common_name=false use_csr_sans=true key_type=rsa key_bits=2048 \
    server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false \
    ttl=2160h max_ttl=2160h >/dev/null

  cat <<POLICY | vault_policy_write "$policy"
path "pki_int/sign/$pki_role" {
  capabilities = ["update"]
}
POLICY

  vault_cmd vault write "auth/$mount/role/$auth_role" \
    bound_service_account_names=vault-issuer \
    bound_service_account_namespaces=cert-manager \
    audience=vault://vault-internal \
    token_policies="$policy" token_ttl=1m token_max_ttl=5m \
    token_no_default_policy=true token_type=batch >/dev/null
done

echo 'Vault cert-manager PKI roles and authentication boundaries are ready.'
