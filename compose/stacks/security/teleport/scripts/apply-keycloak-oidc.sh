#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ENV_FILE="${TELEPORT_ENV_FILE:-/run/acer-mgmt/secrets/security/teleport.env}"

if [[ -f "${ROOT_DIR}/../.env" ]]; then
  # shellcheck disable=SC1091
  set -a && . "${ROOT_DIR}/../.env" && set +a
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a && . "${ENV_FILE}" && set +a
fi

: "${BASE_DOMAIN:=imcherry5778.xyz}"
: "${KEYCLOAK_REALM:=mgmt}"
: "${TELEPORT_OIDC_CLIENT_ID:=teleport}"
: "${TELEPORT_OIDC_CLIENT_SECRET:?TELEPORT_OIDC_CLIENT_SECRET must be rendered by Vault Agent}"

docker exec -i teleport tctl create -f - <<EOF
kind: oidc
version: v3
metadata:
  name: keycloak
spec:
  issuer_url: https://keycloak.${BASE_DOMAIN}/realms/${KEYCLOAK_REALM}
  client_id: ${TELEPORT_OIDC_CLIENT_ID}
  client_secret: ${TELEPORT_OIDC_CLIENT_SECRET}
  redirect_url: https://teleport.${BASE_DOMAIN}:3080/v1/webapi/oidc/callback
  display: Keycloak
  scope:
    - openid
    - profile
    - email
    - groups
  claims_to_roles:
    - claim: groups
      value: platform-admin
      roles:
        - access
        - editor
    - claim: groups
      value: platform-editor
      roles:
        - access
    - claim: groups
      value: platform-viewer
      roles:
        - auditor
EOF
