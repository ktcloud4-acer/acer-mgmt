#!/usr/bin/env bash
set -euo pipefail

# Reconcile only resources owned by the Dashy embed feature. The caller's
# management token remains inside the Vault container at /tmp/.vt and is never
# read to the host or written to output.
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
DASHY_ORIGIN=${DASHY_ORIGIN:-https://dash.imcherry5778.xyz}

command -v docker >/dev/null 2>&1 || {
  echo 'docker is required' >&2
  exit 1
}

docker exec -i -e DASHY_ORIGIN="$DASHY_ORIGIN" "$VAULT_CONTAINER" sh -seu <<'VAULT_SH'
  test -s /tmp/.vt
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"

  # Delete only the legacy policy created by an earlier revision of this
  # feature. Never pattern-delete policies that another team may own.
  obsolete_policy=dashy-embed-ui-headers
  if vault policy list | grep -Fxq "$obsolete_policy"; then
    vault policy delete "$obsolete_policy" >/dev/null
  fi

  # The userpass-backed mgmt administrator already owns the admin policy. Add
  # only the Vault UI-header endpoint required for this feature, preserving
  # all existing admin policy rules and making the capability effective for
  # the currently issued token.
  policy_file=/tmp/dashy-embed-admin-policy.hcl
  trap "rm -f \"$policy_file\"" EXIT
  vault policy read admin >"$policy_file"
  if ! grep -Fq "path \"sys/config/ui/headers/Content-Security-Policy\" {" "$policy_file" \
    || ! grep -Fq "capabilities = [\"read\", \"create\", \"update\", \"delete\", \"sudo\"]" "$policy_file"; then
    cat <<POLICY >>"$policy_file"
path "sys/config/ui/headers/Content-Security-Policy" {
  capabilities = ["read", "create", "update", "delete", "sudo"]
}
POLICY
    vault policy write admin "$policy_file" >/dev/null
  fi

  vault token capabilities sys/config/ui/headers/Content-Security-Policy | tr "," "\n" | grep -Fxq update
  vault token capabilities sys/config/ui/headers/Content-Security-Policy | tr "," "\n" | grep -Fxq sudo
  vault write sys/config/ui/headers/Content-Security-Policy \
    values="frame-src '\''self'\''; frame-ancestors ${DASHY_ORIGIN}; object-src '\''none'\''" >/dev/null
VAULT_SH

echo 'Vault Dashy embed resources reconciled.'
