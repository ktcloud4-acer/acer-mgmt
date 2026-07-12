#!/usr/bin/env bash
set -euo pipefail
umask 077

vault_container=${VAULT_CONTAINER:-vault}

docker exec "$vault_container" sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  path=mgmt/cicd/semaphore-runner/aio

  if vault kv get -mount=kv "$path" >/dev/null 2>&1; then
    echo "Semaphore Runner registration material already exists."
    exit 0
  fi

  token="$(head -c 48 /dev/urandom | base64 | tr -d "\n")"
  vault kv put -mount=kv "$path" status=ready runner_registration_token="$token" >/dev/null
  unset token
  echo "Semaphore Runner registration material created."
'
