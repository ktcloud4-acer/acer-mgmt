#!/usr/bin/env bash
set -euo pipefail

# Imports the currently working Argo CD cluster connection Secrets into Vault.
# Values move only through stdin; tokens and CA data are never printed.
umask 077

MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-/home/user1/.kube/config}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
clusters=(ggg khb ljw nmg oje)
declare -A argocd_secret_names=(
  [ggg]=acer-kubeadm
  [khb]=cluster-khb
  [ljw]=cluster-ljw
  [nmg]=cluster-nmg
  [oje]=cluster-oje
)

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for command in kubectl jq docker; do
  require_command "$command"
done

for cluster in "${clusters[@]}"; do
  secret_name=${argocd_secret_names[$cluster]}
  secret_json="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n argocd get secret "$secret_name" -o json)"

  name="$(jq -er '.data.name | @base64d' <<<"$secret_json")"
  server="$(jq -er '.data.server | @base64d' <<<"$secret_json")"
  config="$(jq -er '.data.config | @base64d' <<<"$secret_json")"

  [[ "$name" == "$cluster" || "$cluster" == ggg ]] || {
    echo "unexpected Argo CD cluster name for $cluster" >&2
    exit 1
  }
  [[ "$server" == "https://${cluster}-operator.tailc0244b.ts.net" ]] || {
    echo "unexpected Argo CD server for $cluster" >&2
    exit 1
  }

  jq -nc --arg name "$name" --arg server "$server" --arg config "$config" \
    '{name: $name, server: $server, config: $config}' |
    docker exec -i "$VAULT_CONTAINER" sh -ceu '
      export VAULT_ADDR=https://127.0.0.1:8200
      export VAULT_CACERT=/vault/tls/ca.crt
      export VAULT_TOKEN="$(cat /tmp/.vt)"
      vault kv put -mount=kv "$1" @- >/dev/null
    ' sh "mgmt/argocd/clusters/${cluster}"

  printf 'imported Argo CD cluster credential: %s\n' "$cluster"
done
