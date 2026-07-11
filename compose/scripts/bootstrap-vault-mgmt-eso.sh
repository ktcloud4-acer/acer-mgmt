#!/usr/bin/env bash
set -euo pipefail

# Configures Vault Kubernetes auth for the management ESO controller. The
# operator session token lives only in vault:/tmp/.vt and is never copied out.
umask 077

MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-/home/user1/.kube/config}
ARGOCD_REPO=${ARGOCD_REPO:-/home/user1/acer-argocd}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
VAULT_KUBERNETES_HOST=${VAULT_KUBERNETES_HOST:-https://k3d-mgmt-server-0:6443}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for command in kubectl jq docker; do
  require_command "$command"
done

KUBECONFIG="$MGMT_KUBECONFIG" kubectl create namespace external-secrets --dry-run=client -o yaml |
  KUBECONFIG="$MGMT_KUBECONFIG" kubectl apply -f - >/dev/null
KUBECONFIG="$MGMT_KUBECONFIG" kubectl apply -f "$ARGOCD_REPO/security/eso/mgmt/vault-auth.yaml" >/dev/null

for _ in $(seq 1 30); do
  reviewer_token_b64="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n external-secrets get secret vault-auth-token -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$reviewer_token_b64" ]] && break
  sleep 1
done
[[ -n "${reviewer_token_b64:-}" ]] || {
  echo 'Vault token-reviewer Secret was not populated' >&2
  exit 1
}

reviewer_token="$(printf '%s' "$reviewer_token_b64" | base64 -d)"
ca_data="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl config view --raw -o json | jq -er '.clusters[0].cluster["certificate-authority-data"]')"

docker exec "$VAULT_CONTAINER" sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault auth enable -path=kubernetes-mgmt kubernetes >/dev/null 2>&1 || true
' 

cat <<'POLICY' | docker exec -i "$VAULT_CONTAINER" sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault policy write argocd-cluster-reader - >/dev/null
'
path "kv/data/mgmt/argocd/clusters/*" {
  capabilities = ["read"]
}
POLICY

jq -nc \
  --arg token "$reviewer_token" \
  --arg host "$VAULT_KUBERNETES_HOST" \
  --arg ca "$ca_data" \
  '{token_reviewer_jwt: $token, kubernetes_host: $host, kubernetes_ca_cert: $ca}' |
  docker exec -i "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    export VAULT_TOKEN="$(cat /tmp/.vt)"
    vault write auth/kubernetes-mgmt/config @- >/dev/null
  '

docker exec "$VAULT_CONTAINER" sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault write auth/kubernetes-mgmt/role/argocd-cluster-reader \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=argocd-cluster-reader \
    ttl=1h >/dev/null
'

echo 'Vault Kubernetes auth is ready for management External Secrets Operator.'
