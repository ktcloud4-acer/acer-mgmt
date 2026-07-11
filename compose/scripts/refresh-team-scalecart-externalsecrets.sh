#!/usr/bin/env bash
set -euo pipefail
umask 077

MGMT_KUBECONFIG=${MGMT_KUBECONFIG:-/home/user1/.kube/config}
refresh_stamp=${FORCE_SYNC_VALUE:-"$(date +%s)"}
teams=(ggg khb ljw nmg oje)

cluster_secret_name() {
  case "$1" in
    ggg) printf '%s' acer-kubeadm ;;
    khb|ljw|nmg|oje) printf 'cluster-%s' "$1" ;;
    *) return 1 ;;
  esac
}

for command in kubectl jq base64; do
  command -v "$command" >/dev/null 2>&1 || { echo "missing required command: $command" >&2; exit 1; }
done

for team in "${teams[@]}"; do
  secret_name="$(cluster_secret_name "$team")"
  secret_json="$(KUBECONFIG="$MGMT_KUBECONFIG" kubectl -n argocd get secret "$secret_name" -o json)"
  printf '%s' "$secret_json" | jq -e '.metadata.labels["argocd.argoproj.io/secret-type"] == "cluster"' >/dev/null

  server="$(printf '%s' "$secret_json" | jq -er '.data.server' | base64 -d)"
  config="$(printf '%s' "$secret_json" | jq -er '.data.config' | base64 -d)"
  token="$(printf '%s' "$config" | jq -er '.bearerToken')"
  ca_data="$(printf '%s' "$config" | jq -er '.tlsClientConfig.caData')"
  kubeconfig_file="$(mktemp)"
  cleanup() { rm -f "$kubeconfig_file"; }
  trap cleanup RETURN

  jq -n --arg server "$server" --arg ca "$ca_data" --arg token "$token" '
    {
      apiVersion: "v1",
      kind: "Config",
      clusters: [{name: "target", cluster: {server: $server, "certificate-authority-data": $ca}}],
      contexts: [{name: "target", context: {cluster: "target", user: "argocd"}}],
      "current-context": "target",
      users: [{name: "argocd", user: {token: $token}}]
    }
  ' >"$kubeconfig_file"

  KUBECONFIG="$kubeconfig_file" kubectl -n scalecart annotate externalsecret scalecart "force-sync=$refresh_stamp" --overwrite >/dev/null
  rm -f "$kubeconfig_file"
  trap - RETURN
  echo "ExternalSecret refresh requested: $team"
done
