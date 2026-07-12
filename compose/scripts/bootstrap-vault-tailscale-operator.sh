#!/usr/bin/env bash
set -euo pipefail
umask 077

team=${1:?team is required}
# Vault paths: mgmt/tailscale/operators/ggg mgmt/tailscale/bootstrap/ggg
# Vault paths: mgmt/tailscale/operators/khb mgmt/tailscale/bootstrap/khb
# Vault paths: mgmt/tailscale/operators/ljw mgmt/tailscale/bootstrap/ljw
# Vault paths: mgmt/tailscale/operators/nmg mgmt/tailscale/bootstrap/nmg
# Vault paths: mgmt/tailscale/operators/oje mgmt/tailscale/bootstrap/oje
case "$team" in ggg|khb|ljw|nmg|oje) ;; *) echo "unsupported team: $team" >&2; exit 1;; esac
: "${TAILSCALE_OAUTH_CLIENT_ID:?set in the one-time operator shell}"
: "${TAILSCALE_OAUTH_CLIENT_SECRET:?set in the one-time operator shell}"
: "${BOOTSTRAP_KUBECONFIG_B64:?set in the one-time operator shell}"
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
docker exec -i "$VAULT_CONTAINER" sh -s -- "$team" "$TAILSCALE_OAUTH_CLIENT_ID" "$TAILSCALE_OAUTH_CLIENT_SECRET" "$BOOTSTRAP_KUBECONFIG_B64" <<'VAULT'
set -euo pipefail
team=$1; client_id=$2; client_secret=$3; kubeconfig_b64=$4
export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
policy="semaphore-tailscale-bootstrap-$team"
role="semaphore-tailscale-bootstrap-$team"
vault kv put -mount=kv "mgmt/tailscale/operators/$team" team="$team" status=configured oauth_client_id="$client_id" oauth_client_secret="$client_secret" >/dev/null
vault kv put -mount=kv "mgmt/tailscale/bootstrap/$team" team="$team" status=configured kubeconfig_b64="$kubeconfig_b64" >/dev/null
vault write "auth/approle/role/$role" token_policies="$policy" token_ttl=30m token_max_ttl=30m secret_id_ttl=24h secret_id_num_uses=1 >/dev/null
role_id="$(vault read -field=role_id "auth/approle/role/$role/role-id")"
secret_id="$(vault write -f -field=secret_id "auth/approle/role/$role/secret-id")"
vault kv put -mount=kv "mgmt/tailscale/task-credentials/$team" team="$team" secret_id_status=ready role_id="$role_id" secret_id="$secret_id" >/dev/null
VAULT
echo "Vault Tailscale bootstrap material ready: $team"
