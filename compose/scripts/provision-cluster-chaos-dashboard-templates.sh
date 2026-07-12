#!/usr/bin/env bash
set -euo pipefail

# Reconciles one fixed Dashboard-token template for every team cluster in the
# existing acer-mgmt Semaphore project. Templates are created even while a
# target is offline; an unavailable issuer produces a clear task error rather
# than blocking the whole team rollout.
# Issuers are read directly from Vault only while environments are reconciled;
# they are not rendered by the always-on Vault Agent or mounted into jobs.
SEMAPHORE_CONTAINER=${SEMAPHORE_CONTAINER:-semaphore}
VAULT_CONTAINER=${VAULT_CONTAINER:-vault}
container_repo_root=${SEMAPHORE_REPOSITORY_PATH:-/opt/acer-mgmt}

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 1; }
docker inspect "$SEMAPHORE_CONTAINER" >/dev/null
docker inspect "$VAULT_CONTAINER" >/dev/null

read_issuer() {
  local cluster=$1
  docker exec "$VAULT_CONTAINER" sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault kv get -format=json -mount=kv "mgmt/chaos/dashboard-token-issuers/$1"
  ' sh "$cluster" | jq -er '.data.data.kubeconfig_b64'
}

tmp_dir="$(mktemp -d)"
container_manifest=/tmp/cluster-chaos-dashboard-issuers.json
cleanup() {
  rm -rf "$tmp_dir"
  docker exec "$SEMAPHORE_CONTAINER" rm -f "$container_manifest" >/dev/null 2>&1 || true
}
trap cleanup EXIT

jq -n '[]' >"$tmp_dir/issuers.json"
for cluster in nmg ggg khb ljw oje; do
  issuer_b64=""
  if issuer_b64="$(read_issuer "$cluster" 2>/dev/null)"; then
    :
  else
    issuer_b64=""
  fi
  jq --arg cluster "$cluster" --arg issuer "$issuer_b64" '. + [{cluster:$cluster,issuer:$issuer}]' "$tmp_dir/issuers.json" >"$tmp_dir/issuers.next.json"
  mv "$tmp_dir/issuers.next.json" "$tmp_dir/issuers.json"
done
docker cp "$tmp_dir/issuers.json" "$SEMAPHORE_CONTAINER:$container_manifest"

docker exec -i "$SEMAPHORE_CONTAINER" sh -s -- "$container_repo_root" "$container_manifest" <<'CONTAINER_SCRIPT'
set -eu
repository_path="$1"
issuer_manifest="$2"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

api_get() { curl -fsS -b "$tmp_dir/cookies" "http://localhost:3000/api$1"; }
api_post() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X POST --data @"$2" "http://localhost:3000/api$1"; }
api_put() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X PUT --data @"$2" "http://localhost:3000/api$1"; }

jq -n --arg auth "$SEMAPHORE_ADMIN" --arg password "$SEMAPHORE_ADMIN_PASSWORD" '{auth:$auth,password:$password}' >"$tmp_dir/login.json"
curl -fsS -c "$tmp_dir/cookies" -H 'Content-Type: application/json' --data @"$tmp_dir/login.json" http://localhost:3000/api/auth/login -o /dev/null

project_id="$(api_get /projects | jq -r '.[] | select(.name == "acer-mgmt") | .id' | head -n1)"
[ -n "$project_id" ] && [ "$project_id" != null ] || { echo 'missing Semaphore project: acer-mgmt' >&2; exit 1; }

repository_id="$(api_get "/project/$project_id/repositories" | jq -r '.[] | select(.name == "mgmt automation") | .id' | head -n1)"
if [ -z "$repository_id" ] || [ "$repository_id" = null ]; then
  none_key_id="$(api_get "/project/$project_id/keys" | jq -r '.[] | select(.type == "none") | .id' | head -n1)"
  jq -n --argjson project "$project_id" --arg path "$repository_path" --argjson key "$none_key_id" '{name:"mgmt automation",project_id:$project,git_url:$path,git_branch:"main",ssh_key_id:$key}' >"$tmp_dir/repository.json"
  repository_id="$(api_post "/project/$project_id/repositories" "$tmp_dir/repository.json" | jq -r '.id')"
fi

view_id="$(api_get "/project/$project_id/views" | jq -r '.[] | select(.title == "All") | .id' | head -n1)"

for entry in $(jq -c '.[]' "$issuer_manifest"); do
  cluster="$(printf '%s' "$entry" | jq -r '.cluster')"
  issuer_b64="$(printf '%s' "$entry" | jq -r '.issuer')"
  environment_name="Dashboard token issuer - $cluster"
  template_name="Chaos Dashboard token - $cluster"
  environment_id="$(api_get "/project/$project_id/environment" | jq -r --arg name "$environment_name" '.[] | select(.name == $name) | .id' | head -n1)"
  if [ -n "$issuer_b64" ] || [ -z "$environment_id" ] || [ "$environment_id" = null ]; then
    if [ -n "$issuer_b64" ]; then
      jq -n --argjson project "$project_id" --arg name "$environment_name" --arg cluster "$cluster" --arg issuer "$issuer_b64" '{name:$name,project_id:$project,json:"{}",env:{CHAOS_DASHBOARD_CLUSTER:$cluster,CHAOS_TOKEN_ISSUER_KUBECONFIG_B64:$issuer}|tojson}' >"$tmp_dir/environment.json"
    else
      jq -n --argjson project "$project_id" --arg name "$environment_name" --arg cluster "$cluster" '{name:$name,project_id:$project,json:"{}",env:{CHAOS_DASHBOARD_CLUSTER:$cluster}|tojson}' >"$tmp_dir/environment.json"
    fi
    if [ -z "$environment_id" ] || [ "$environment_id" = null ]; then
      environment_id="$(api_post "/project/$project_id/environment" "$tmp_dir/environment.json" | jq -r '.id')"
    else
      jq --argjson environment "$environment_id" '. + {id:$environment}' "$tmp_dir/environment.json" >"$tmp_dir/environment-update.json"
      api_put "/project/$project_id/environment/$environment_id" "$tmp_dir/environment-update.json" >/dev/null
    fi
  else
    printf 'issuer unavailable for %s; preserving existing encrypted environment\n' "$cluster" >&2
  fi
  jq -n --argjson project "$project_id" --argjson repository "$repository_id" --argjson environment "$environment_id" --argjson view "$view_id" --arg name "$template_name" --arg cluster "$cluster" '{name:$name,project_id:$project,repository_id:$repository,environment_ids:[$environment],view_id:$view,playbook:"compose/scripts/issue-cluster-chaos-dashboard-token.sh",arguments:"[]",description:("Issue a 10-minute token for the " + $cluster + " Chaos Mesh Dashboard."),app:"bash",type:"",allow_parallel_tasks:false,survey_vars:[]}' >"$tmp_dir/template.json"
  template_id="$(api_get "/project/$project_id/templates" | jq -r --arg name "$template_name" '.[] | select(.name == $name) | .id' | head -n1)"
  if [ -z "$template_id" ] || [ "$template_id" = null ]; then
    api_post "/project/$project_id/templates" "$tmp_dir/template.json" >/dev/null
  else
    jq --argjson template "$template_id" '. + {id:$template}' "$tmp_dir/template.json" >"$tmp_dir/template-update.json"
    api_put "/project/$project_id/templates/$template_id" "$tmp_dir/template-update.json" >/dev/null
  fi
  printf 'reconciled dashboard token template for %s\n' "$cluster"
done
CONTAINER_SCRIPT
