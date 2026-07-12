#!/usr/bin/env bash
set -euo pipefail
umask 077
TAILSCALE_OPERATOR_CHART_VERSION=1.98.4
team=${TAILSCALE_BOOTSTRAP_TEAM:?fixed Semaphore environment is required}
case "$team" in ggg|khb|ljw|nmg|oje) ;; *) echo "unsupported team: $team" >&2; exit 1;; esac
work_dir=$(mktemp -d)
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
: "${VAULT_ROLE_ID:?fixed Semaphore environment is required}"
: "${VAULT_SECRET_ID:?fixed Semaphore environment is required}"
root=/opt/acer-mgmt
manifest="$root/compose/config/semaphore/tailscale-operator-projects.json"
entry="$(jq -cer --arg team "$team" '.[] | select(.team == $team)' "$manifest")"
operator_path="$(jq -er '.operator_vault_path' <<<"$entry")"
bootstrap_path="$(jq -er '.bootstrap_vault_path' <<<"$entry")"
argocd_path="$(jq -er '.argocd_vault_path' <<<"$entry")"
proxy_hostname="$(jq -er '.proxy_hostname' <<<"$entry")"
vault_addr=${VAULT_ADDR:-https://vault:8200}
vault_cacert=/run/vault-ca/ca.crt
vault_token="$(curl -fsS --cacert "$vault_cacert" -H 'Content-Type: application/json' \
  --data "$(jq -cn --arg role "$VAULT_ROLE_ID" --arg secret "$VAULT_SECRET_ID" '{role_id:$role,secret_id:$secret}')" \
  "$vault_addr/v1/auth/approle/login" | jq -er '.auth.client_token')"
unset VAULT_ROLE_ID VAULT_SECRET_ID
vault_get() { curl -fsS --cacert "$vault_cacert" -H "X-Vault-Token: $vault_token" "$vault_addr/v1/kv/data/$1"; }
operator_json="$(vault_get "$operator_path")"
bootstrap_json="$(vault_get "$bootstrap_path")"
oauth_id="$(jq -er '.data.data.oauth_client_id' <<<"$operator_json")"
oauth_secret="$(jq -er '.data.data.oauth_client_secret' <<<"$operator_json")"
kubeconfig="$work_dir/recovery.kubeconfig"
jq -er '.data.data.kubeconfig_b64' <<<"$bootstrap_json" | base64 -d >"$kubeconfig"
chmod 600 "$kubeconfig"
api_server="$(kubectl --kubeconfig "$kubeconfig" config view --raw -o json | jq -er '.clusters[0].cluster.server')"
api_host="${api_server#https://}"; api_host="${api_host%%:*}"
ssh -i /run/secrets/acer.pem -o BatchMode=yes -o StrictHostKeyChecking=accept-new -N -L 16443:"$api_host":6443 ubuntu@172.16.1.10 &
tunnel_pid=$!
cleanup() { kill "$tunnel_pid" 2>/dev/null || true; rm -rf "$work_dir"; }
trap cleanup EXIT
sleep 1
kill -0 "$tunnel_pid" 2>/dev/null || { echo 'AIO API tunnel did not start.' >&2; exit 1; }
jq --arg server 'https://127.0.0.1:16443' --arg tls "$api_host" '(.clusters[0].cluster.server=$server) | (.clusters[0].cluster["tls-server-name"]=$tls)' "$kubeconfig" >"$work_dir/tunneled.kubeconfig"
mv "$work_dir/tunneled.kubeconfig" "$kubeconfig"
kubectl_recovery() { kubectl --kubeconfig "$kubeconfig" "$@"; }
helm repo add tailscale https://pkgs.tailscale.com/helmcharts >/dev/null
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --kubeconfig "$kubeconfig" --namespace tailscale --create-namespace \
  --version "$TAILSCALE_OPERATOR_CHART_VERSION" \
  --set-string oauth.clientId="$oauth_id" --set-string oauth.clientSecret="$oauth_secret" \
  --set-string apiServerProxyConfig.allowImpersonation="true" --wait --timeout 180s
unset oauth_id oauth_secret operator_json bootstrap_json
cat <<YAML | kubectl_recovery apply -f -
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: $proxy_hostname
spec:
  type: kube-apiserver
  replicas: 1
  tags: ["tag:k8s-$team"]
  kubeAPIServer:
    hostname: $proxy_hostname
    mode: noauth
YAML
kubectl_recovery wait proxygroup/$proxy_hostname --for=condition=ProxyGroupReady=true --timeout=240s
cat <<'YAML' | kubectl_recovery apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
YAML
argocd_token="$(kubectl_recovery -n kube-system create token argocd-manager --duration=1h)"
ca_data="$(kubectl --kubeconfig "$kubeconfig" config view --raw -o json | jq -er '.clusters[0].cluster["certificate-authority-data"]')"
server="https://$proxy_hostname.tailc0244b.ts.net"
config="$(jq -cn --arg token "$argocd_token" --arg ca "$ca_data" '{bearerToken:$token,tlsClientConfig:{caData:$ca}}')"
payload="$(jq -cn --arg name "$team" --arg server "$server" --arg config "$config" '{data:{name:$name,server:$server,config:$config}}')"
curl -fsS --cacert "$vault_cacert" -H "X-Vault-Token: $vault_token" -H 'Content-Type: application/json' \
  --data "$payload" "$vault_addr/v1/kv/data/$argocd_path" >/dev/null
unset argocd_token ca_data config payload vault_token
echo "Tailscale API proxy ready: $proxy_hostname"
