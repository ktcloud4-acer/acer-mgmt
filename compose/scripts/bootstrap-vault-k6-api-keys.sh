#!/usr/bin/env bash
set -euo pipefail
umask 077

VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
DATA_ROOT=${DATA_ROOT:-/home/mgmt-data}
teams=(ggg khb ljw nmg oje)

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 1; }
sudo install -d -m 0700 "${DATA_ROOT}/vault-agent/secrets/cicd/k6"

for team in "${teams[@]}"; do
  docker exec "$VAULT_CONTAINER" sh -ceu '
    team="$1"
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    export VAULT_TOKEN="$(cat /tmp/.vt)"
    key="$(vault kv get -mount=kv -field=K6_DEMO_API_KEY "apps/scalecart/${team}" 2>/dev/null || true)"
    if [ -z "$key" ]; then key="$(openssl rand -hex 32)"; fi
    app_payload="/tmp/k6-app-${team}.json"
    runner_payload="/tmp/k6-runner-${team}.json"
    trap "rm -f \"$app_payload\" \"$runner_payload\"" EXIT
    printf "{\\\"K6_DEMO_API_KEY\\\":\\\"%s\\\"}\\n" "$key" >"$app_payload"
    printf "{\\\"api_key\\\":\\\"%s\\\"}\\n" "$key" >"$runner_payload"
    vault kv patch -mount=kv "apps/scalecart/${team}" "@$app_payload" >/dev/null
    vault kv patch -mount=kv "mgmt/k6/${team}" "@$runner_payload" >/dev/null
  ' sh "$team"
  echo "Vault k6 key ready: ${team}"
done
