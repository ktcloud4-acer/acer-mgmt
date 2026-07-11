#!/usr/bin/env bash
# Prepare pinned upstream Wazuh configuration and certificates before first run.
# Secrets must be sourced from the Vault Agent-rendered wazuh.env file; no
# password is written to this repository or printed by this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="$REPO_ROOT/stacks/security/wazuh"
DATA_ROOT="${DATA_ROOT:-/home/mgmt-data}"
WAZUH_ROOT="${DATA_ROOT}/wazuh"
SECRETS_FILE="${WAZUH_SECRETS_FILE:-/run/acer-mgmt/secrets/security/wazuh.env}"
UPSTREAM_TAG="v4.14.6"

[[ -r "$SECRETS_FILE" ]] || { echo "Missing Vault-rendered Wazuh secrets: $SECRETS_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a
: "${WAZUH_INDEXER_PASSWORD:?missing WAZUH_INDEXER_PASSWORD}"
: "${WAZUH_DASHBOARD_PASSWORD:?missing WAZUH_DASHBOARD_PASSWORD}"
: "${WAZUH_API_PASSWORD:?missing WAZUH_API_PASSWORD}"

hash_password() {
  local password="$1"
  docker run --rm \
    -e WAZUH_HASH_PASSWORD="$password" \
    wazuh/wazuh-indexer:4.14.6 \
    bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh \
      -env WAZUH_HASH_PASSWORD | tail -n1
}

if [[ -e "$WAZUH_ROOT/config/.upstream-tag" ]] && [[ "$(<"$WAZUH_ROOT/config/.upstream-tag")" != "$UPSTREAM_TAG" ]]; then
  echo "Refusing to overwrite Wazuh configuration from another upstream tag" >&2
  exit 1
fi

if [[ ! -e "$WAZUH_ROOT/config/.upstream-tag" ]]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  git clone --depth 1 --branch "$UPSTREAM_TAG" https://github.com/wazuh/wazuh-docker.git "$tmpdir/wazuh-docker"
  install -d -m 0750 "$WAZUH_ROOT/config"
  cp -a "$tmpdir/wazuh-docker/single-node/config/." "$WAZUH_ROOT/config/"
  printf '%s\n' "$UPSTREAM_TAG" >"$WAZUH_ROOT/config/.upstream-tag"
fi

# Replace upstream demonstration credentials before the first container start.
indexer_hash="$(hash_password "$WAZUH_INDEXER_PASSWORD")"
dashboard_hash="$(hash_password "$WAZUH_DASHBOARD_PASSWORD")"
users_file="$WAZUH_ROOT/config/wazuh_indexer/internal_users.yml"
sed -i "/^admin:$/,/^kibanaserver:$/ s#^  hash: .*#  hash: \"${indexer_hash}\"#" "$users_file"
sed -i "/^kibanaserver:$/,/^kibanaro:$/ s#^  hash: .*#  hash: \"${dashboard_hash}\"#" "$users_file"
sed -i "s#password: \"MyS3cr37P450r\.\*-\"#password: \"${WAZUH_API_PASSWORD}\"#" \
  "$WAZUH_ROOT/config/wazuh_dashboard/wazuh.yml"

# Generate component TLS certificates using Wazuh's pinned official utility.
docker run --rm \
  -v "$WAZUH_ROOT/config/wazuh_indexer_ssl_certs:/certificates:Z" \
  -v "$WAZUH_ROOT/config/certs.yml:/config/certs.yml:ro,Z" \
  -e CERT_TOOL_VERSION=4.14 \
  wazuh/wazuh-certs-generator:0.0.4

echo "Wazuh assets prepared. Start with: docker compose --env-file <Vault wazuh.env> -f $STACK_DIR/compose.yaml up -d"
