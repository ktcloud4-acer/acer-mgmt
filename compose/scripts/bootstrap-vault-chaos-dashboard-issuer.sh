#!/usr/bin/env bash
set -euo pipefail

# Creates only the restricted central Dashboard-token issuer credential and
# stores its kubeconfig in Vault. The service account can mint a token for one
# Dashboard account; it cannot read workloads or manage any target cluster.
umask 077

MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-/home/user1/.kube/config}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
VAULT_KUBERNETES_HOST=${VAULT_KUBERNETES_HOST:-https://k3d-mgmt-server-0:6443}
namespace=chaos-mesh
service_account=chaos-dashboard-token-issuer
token_secret=chaos-dashboard-token-issuer-vault

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for command in kubectl jq docker base64; do
  require_command "$command"
done

KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n "$namespace" get serviceaccount "$service_account" >/dev/null
KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n "$namespace" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${token_secret}
  annotations:
    kubernetes.io/service-account.name: ${service_account}
type: kubernetes.io/service-account-token
EOF

for _ in $(seq 1 30); do
  token_b64="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n "$namespace" get secret "$token_secret" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_b64" ]] && break
  sleep 1
done
[[ -n "${token_b64:-}" ]] || {
  echo 'Chaos Dashboard issuer token Secret was not populated' >&2
  exit 1
}

token="$(printf '%s' "$token_b64" | base64 -d)"
ca_data_b64="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl config view --raw -o json | jq -er '.clusters[0].cluster["certificate-authority-data"]')"

payload_file="$(mktemp)"
container_payload=/tmp/chaos-dashboard-token-issuer.json
cleanup() {
  rm -f "$payload_file"
  docker exec "$VAULT_CONTAINER" rm -f "$container_payload" >/dev/null 2>&1 || true
}
trap cleanup EXIT

jq -nc \
  --arg server "$VAULT_KUBERNETES_HOST" \
  --arg ca "$ca_data_b64" \
  --arg token "$token" \
  '{
    kubeconfig_b64: (
      "apiVersion: v1\nkind: Config\nclusters:\n- name: mgmt\n  cluster:\n    server: " + $server + "\n    certificate-authority-data: " + $ca + "\ncontexts:\n- name: chaos-dashboard-token-issuer@mgmt\n  context:\n    cluster: mgmt\n    namespace: chaos-mesh\n    user: chaos-dashboard-token-issuer\ncurrent-context: chaos-dashboard-token-issuer@mgmt\nusers:\n- name: chaos-dashboard-token-issuer\n  user:\n    token: " + $token + "\n"
      | @base64
    )
  }' >"$payload_file"

docker exec -i "$VAULT_CONTAINER" sh -ceu '
  umask 077
  trap "rm -f \"$2\"" EXIT
  cat > "$2"
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault kv put -mount=kv "$1" "@$2" >/dev/null
' sh mgmt/chaos-dashboard-token-issuer "$container_payload" <"$payload_file"

echo 'Vault Chaos Dashboard issuer credential is ready.'
