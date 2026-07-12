#!/usr/bin/env bash
set -euo pipefail
umask 077

# Rotates a project-scoped, pull-only Harbor robot and exposes its Docker
# credential through Vault for the five team ESO roles.
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
HARBOR_URL=${HARBOR_URL:-https://harbor.imcherry5778.xyz}
HARBOR_PROJECT=${HARBOR_PROJECT:-acer}
HARBOR_ADMIN_USERNAME=${HARBOR_ADMIN_USERNAME:-admin}
HARBOR_PULL_ROBOT_PREFIX=${HARBOR_PULL_ROBOT_PREFIX:-scalecart-pull}
teams=(ggg khb ljw nmg oje)

for command in docker jq base64 curl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required command: $command" >&2
    exit 1
  }
done
docker inspect "$VAULT_CONTAINER" >/dev/null

work_dir="$(mktemp -d)"
container_payload=''
cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$container_payload" ]]; then
    docker exec "$VAULT_CONTAINER" rm -f "$container_payload" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

vault_command() {
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    export VAULT_TOKEN="$(cat /tmp/.vt)"
    "$@"
  ' sh "$@"
}

HARBOR_ADMIN_PASSWORD="$(vault_command vault kv get -field=harbor_admin_password -mount=kv mgmt/harbor)"
previous_robot_id="$(vault_command vault kv get -field=robot_id -mount=kv apps/harbor/pull 2>/dev/null || true)"
robot_name="${HARBOR_PULL_ROBOT_PREFIX}-$(date -u +%Y%m%d%H%M%S)"

jq -cn \
  --arg name "$robot_name" \
  --arg project "$HARBOR_PROJECT" \
  '{name:$name,description:"ScaleCart Kubernetes image pull",disable:false,duration:-1,level:"project",permissions:[{kind:"project",namespace:$project,access:[{resource:"repository",action:"pull"}]}]}' \
  >"$work_dir/robot-request.json"

curl --fail-with-body --silent --show-error \
  --user "$HARBOR_ADMIN_USERNAME:$HARBOR_ADMIN_PASSWORD" \
  --header 'Content-Type: application/json' \
  --request POST \
  --data @"$work_dir/robot-request.json" \
  "$HARBOR_URL/api/v2.0/robots" \
  >"$work_dir/robot-response.json"
unset HARBOR_ADMIN_PASSWORD

robot_username="$(jq -er '.name' "$work_dir/robot-response.json")"
robot_token="$(jq -er '.secret' "$work_dir/robot-response.json")"
robot_id="$(jq -er '.id' "$work_dir/robot-response.json")"
registry_auth="$(printf '%s:%s' "$robot_username" "$robot_token" | base64 | tr -d '\n')"
docker_config="$(jq -cn --arg registry "${HARBOR_URL#https://}" --arg auth "$registry_auth" '{auths:{($registry):{auth:$auth}}}')"
jq -cn --arg dockerconfigjson "$docker_config" --arg robot_id "$robot_id" '{dockerconfigjson:$dockerconfigjson,robot_id:$robot_id}' >"$work_dir/harbor-pull.json"
unset robot_token registry_auth docker_config

container_payload='/tmp/vault-harbor-pull.json'
docker exec -i "$VAULT_CONTAINER" sh -ceu '
  umask 077
  cat > "$2"
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault kv put -mount=kv "$1" "@$2" >/dev/null
  rm -f "$2"
' sh apps/harbor/pull "$container_payload" <"$work_dir/harbor-pull.json"
container_payload=''

if [[ "$previous_robot_id" =~ ^[0-9]+$ && "$previous_robot_id" != "$robot_id" ]]; then
  curl --fail-with-body --silent --show-error \
    --user "$HARBOR_ADMIN_USERNAME:$(vault_command vault kv get -field=harbor_admin_password -mount=kv mgmt/harbor)" \
    --request DELETE \
    "$HARBOR_URL/api/v2.0/robots/$previous_robot_id" >/dev/null
fi

for team in "${teams[@]}"; do
  cat <<POLICY | docker exec -i "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200
    export VAULT_CACERT=/vault/tls/ca.crt
    export VAULT_TOKEN="$(cat /tmp/.vt)"
    vault policy write "scalecart-$1" - >/dev/null
' sh "$team"
path "kv/data/apps/scalecart/${team}"      { capabilities = ["read"] }
path "kv/metadata/apps/scalecart/${team}"  { capabilities = ["read"] }
path "kv/data/apps/cloudflared/${team}"     { capabilities = ["read"] }
path "kv/metadata/apps/cloudflared/${team}" { capabilities = ["read"] }
path "kv/data/apps/velero/${team}"          { capabilities = ["read"] }
path "kv/metadata/apps/velero/${team}"      { capabilities = ["read"] }
path "kv/data/apps/harbor/pull"             { capabilities = ["read"] }
path "kv/metadata/apps/harbor/pull"         { capabilities = ["read"] }
POLICY
done

echo 'Vault Harbor pull credential and team ESO policies are ready.'
