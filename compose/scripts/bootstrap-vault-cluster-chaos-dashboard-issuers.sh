#!/usr/bin/env bash
set -euo pipefail

# Converts the GitOps-managed restricted issuer ServiceAccount in each team
# cluster into a dedicated kubeconfig stored in Vault. Source cluster access is
# read from the existing Vault Argo CD cluster records; no kubeconfig is kept in
# this repository or printed by the script.
umask 077
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-/home/user1/.kube/config}
MGMT_KUBERNETES_HOST=${MGMT_KUBERNETES_HOST:-https://k3d-mgmt-server-0:6443}
namespace=chaos-mesh
issuer_service_account=chaos-dashboard-token-issuer
CHAOS_DASHBOARD_CLUSTERS=${CHAOS_DASHBOARD_CLUSTERS:-'nmg ggg khb ljw oje'}

for command in kubectl jq docker base64 mktemp; do
  command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done
docker inspect "$VAULT_CONTAINER" >/dev/null

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

vault_get_cluster() {
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault kv get -format=json -mount=kv "$1"
  ' sh "$1"
}

vault_put_issuer() {
  local path=$1 payload=$2 container_payload=/tmp/cluster-chaos-dashboard-issuer.json
  docker exec -i "$VAULT_CONTAINER" sh -ceu '
    umask 077
    trap "rm -f \"$2\"" EXIT
    cat >"$2"
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault kv put -mount=kv "$1" "@$2" >/dev/null
  ' sh "$path" "$container_payload" <"$payload"
}

for cluster in $CHAOS_DASHBOARD_CLUSTERS; do
  case "$cluster" in
    nmg|ggg|khb|ljw|oje) ;;
    *) echo "unsupported Dashboard issuer cluster: $cluster" >&2; exit 1 ;;
  esac
  source_json="$(vault_get_cluster "mgmt/argocd/clusters/$cluster")"
  server="$(jq -er '.data.data.server' <<<"$source_json")"
  config="$(jq -er '.data.data.config | fromjson' <<<"$source_json")"
  bootstrap_kubeconfig="$tmp_dir/$cluster-bootstrap.kubeconfig"
  jq -n --arg server "$server" --argjson config "$config" '
    {apiVersion:"v1",kind:"Config",clusters:[{name:"target",cluster:{server:$server,"certificate-authority-data":$config.tlsClientConfig.caData,"insecure-skip-tls-verify":($config.tlsClientConfig.insecure // false)}}],contexts:[{name:"issuer",context:{cluster:"target",namespace:"chaos-mesh",user:"bootstrap"}}],"current-context":"issuer",users:[{name:"bootstrap",user:{token:$config.bearerToken}}]}' >"$bootstrap_kubeconfig"
  token_b64="$(KUBECONFIG="$bootstrap_kubeconfig" kubectl -n "$namespace" get secret "$issuer_service_account" -o jsonpath='{.data.token}')"
  [ -n "$token_b64" ] || { echo "issuer Secret is not ready for $cluster; wait for Argo CD sync" >&2; exit 1; }
  issuer_kubeconfig="$tmp_dir/$cluster-issuer.kubeconfig"
  jq -n --arg server "$server" --argjson config "$config" --arg token "$(printf '%s' "$token_b64" | base64 -d)" --arg cluster "$cluster" '
    {apiVersion:"v1",kind:"Config",clusters:[{name:$cluster,cluster:{server:$server,"certificate-authority-data":$config.tlsClientConfig.caData,"insecure-skip-tls-verify":($config.tlsClientConfig.insecure // false)}}],contexts:[{name:($cluster+"-issuer"),context:{cluster:$cluster,namespace:"chaos-mesh",user:"issuer"}}],"current-context":($cluster+"-issuer"),users:[{name:"issuer",user:{token:$token}}]}' >"$issuer_kubeconfig"
  payload="$tmp_dir/$cluster-payload.json"
  jq -n --arg kubeconfig_b64 "$(base64 <"$issuer_kubeconfig" | tr -d '\n')" '{kubeconfig_b64:$kubeconfig_b64}' >"$payload"
  vault_put_issuer "mgmt/chaos/dashboard-token-issuers/$cluster" "$payload"
  echo "Vault issuer credential updated for $cluster."
done

# mgmt keeps its already-proven dedicated bootstrap workflow and legacy path.
"$(dirname "$0")/bootstrap-vault-chaos-dashboard-issuer.sh"
