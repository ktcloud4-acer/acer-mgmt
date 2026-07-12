#!/usr/bin/env bash
set -euo pipefail

# Reconciles the local mgmt Dashboard-token task. The issuer kubeconfig is read
# from Vault only while the encrypted Semaphore Variable Group is updated.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
semaphore_container=${SEMAPHORE_CONTAINER:-semaphore}
vault_container=${VAULT_CONTAINER:-vault}
repository_path=${SEMAPHORE_REPOSITORY_PATH:-/opt/acer-mgmt}
task_name='Chaos Dashboard token'
issuer_environment='chaos-dashboard-token-issuer'

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
docker inspect "$semaphore_container" >/dev/null
docker inspect "$vault_container" >/dev/null

issuer_b64="$(docker exec "$vault_container" sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200
  export VAULT_CACERT=/vault/tls/ca.crt
  export VAULT_TOKEN="$(cat /tmp/.vt)"
  vault kv get -format=json -mount=kv mgmt/chaos-dashboard-token-issuer
' | jq -er '.data.data.kubeconfig_b64')"

docker exec -i "$semaphore_container" sh -s -- "$repository_path" "$task_name" "$issuer_environment" "$issuer_b64" <<'CONTAINER_SCRIPT'
set -eu

repository_path="$1"
task_name="$2"
issuer_environment="$3"
issuer_b64="$4"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

api_get() { curl -fsS -b "$tmp_dir/cookies" "http://localhost:3000/api$1"; }
api_post() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X POST --data @"$2" "http://localhost:3000/api$1"; }
api_put() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X PUT --data @"$2" "http://localhost:3000/api$1"; }
api_delete() { curl -fsS -b "$tmp_dir/cookies" -X DELETE "http://localhost:3000/api$1" >/dev/null; }
require_id() { test -n "$1" && test "$1" != null || { echo "missing $2" >&2; exit 1; }; }

jq -n --arg auth "$SEMAPHORE_ADMIN" --arg password "$SEMAPHORE_ADMIN_PASSWORD" '{auth:$auth,password:$password}' >"$tmp_dir/login.json"
curl -fsS -c "$tmp_dir/cookies" -H 'Content-Type: application/json' --data @"$tmp_dir/login.json" http://localhost:3000/api/auth/login -o /dev/null

project_id="$(api_get /projects | jq -r '.[] | select(.name == "acer-mgmt") | .id' | head -n1)"
require_id "$project_id" 'Semaphore project acer-mgmt'
none_key_id="$(api_get "/project/$project_id/keys" | jq -r '.[] | select(.type == "none") | .id' | head -n1)"
require_id "$none_key_id" 'none key in acer-mgmt'

repository_id="$(api_get "/project/$project_id/repositories" | jq -r '.[] | select(.name == "mgmt automation") | .id' | head -n1)"
jq -n --argjson project "$project_id" --arg path "$repository_path" --argjson key "$none_key_id" \
  '{name:"mgmt automation",project_id:$project,git_url:$path,git_branch:"main",ssh_key_id:$key}' >"$tmp_dir/repository.json"
if [ -z "$repository_id" ] || [ "$repository_id" = null ]; then
  repository_id="$(api_post "/project/$project_id/repositories" "$tmp_dir/repository.json" | jq -r '.id')"
else
  jq --argjson id "$repository_id" '. + {id:$id}' "$tmp_dir/repository.json" >"$tmp_dir/repository-update.json"
  api_put "/project/$project_id/repositories/$repository_id" "$tmp_dir/repository-update.json" >/dev/null
fi
require_id "$repository_id" 'mgmt automation repository'

inventory_name='Semaphore localhost'
inventory_id="$(api_get "/project/$project_id/inventory" | jq -r --arg name "$inventory_name" '.[] | select(.name == $name) | .id' | head -n1)"
inventory_contents=$'all:\n  hosts:\n    localhost:\n      ansible_connection: local\n'
jq -n --argjson project "$project_id" --arg name "$inventory_name" --arg inventory "$inventory_contents" --argjson key "$none_key_id" \
  '{name:$name,project_id:$project,inventory:$inventory,ssh_key_id:$key,become_key_id:$key,type:"static-yaml"}' >"$tmp_dir/inventory.json"
if [ -z "$inventory_id" ] || [ "$inventory_id" = null ]; then
  inventory_id="$(api_post "/project/$project_id/inventory" "$tmp_dir/inventory.json" | jq -r '.id')"
else
  jq --argjson id "$inventory_id" '. + {id:$id}' "$tmp_dir/inventory.json" >"$tmp_dir/inventory-update.json"
  api_put "/project/$project_id/inventory/$inventory_id" "$tmp_dir/inventory-update.json" >/dev/null
fi
require_id "$inventory_id" 'Semaphore localhost inventory'

environment_id="$(api_get "/project/$project_id/environment" | jq -r --arg name "$issuer_environment" '.[] | select(.name == $name) | .id' | head -n1)"
jq -n --argjson project "$project_id" --arg name "$issuer_environment" --arg issuer "$issuer_b64" \
  '{name:$name,project_id:$project,json:"{}",env:{CHAOS_TOKEN_ISSUER_KUBECONFIG_B64:$issuer}|tojson}' >"$tmp_dir/environment.json"
if [ -z "$environment_id" ] || [ "$environment_id" = null ]; then
  environment_id="$(api_post "/project/$project_id/environment" "$tmp_dir/environment.json" | jq -r '.id')"
else
  jq --argjson id "$environment_id" '. + {id:$id}' "$tmp_dir/environment.json" >"$tmp_dir/environment-update.json"
  api_put "/project/$project_id/environment/$environment_id" "$tmp_dir/environment-update.json" >/dev/null
fi
require_id "$environment_id" 'mgmt Dashboard issuer environment'

view_id="$(api_get "/project/$project_id/views" | jq -r '.[] | select(.title == "All") | .id' | head -n1)"
require_id "$view_id" 'All view in acer-mgmt'

# Remove only the obsolete shell template that this localhost Ansible task replaces.
api_get "/project/$project_id/templates" | jq -r '.[] | select(.name == "chaos:issue-dashboard-token") | .id' | while read -r template_id; do
  [ -n "$template_id" ] && api_delete "/project/$project_id/templates/$template_id"
done

jq -n --arg name "$task_name" --argjson project "$project_id" --argjson inventory "$inventory_id" --argjson repository "$repository_id" --argjson environment "$environment_id" --argjson view "$view_id" \
  '{name:$name,project_id:$project,inventory_id:$inventory,repository_id:$repository,environment_ids:[$environment],view_id:$view,playbook:"compose/ansible/issue-mgmt-chaos-dashboard-token.yml",arguments:"[]",description:"Issue a 10-minute token for the mgmt Chaos Mesh Dashboard locally.",app:"ansible",type:"",allow_parallel_tasks:false,survey_vars:[]}' >"$tmp_dir/template.json"
template_id="$(api_get "/project/$project_id/templates" | jq -r --arg name "$task_name" '.[] | select(.name == $name) | .id' | head -n1)"
if [ -z "$template_id" ] || [ "$template_id" = null ]; then
  template_id="$(api_post "/project/$project_id/templates" "$tmp_dir/template.json" | jq -r '.id')"
else
  jq --argjson id "$template_id" '. + {id:$id}' "$tmp_dir/template.json" >"$tmp_dir/template-update.json"
  api_put "/project/$project_id/templates/$template_id" "$tmp_dir/template-update.json" >/dev/null
fi
require_id "$template_id" 'mgmt Chaos Dashboard token template'
printf 'reconciled project=acer-mgmt template=%s\n' "$template_id"
CONTAINER_SCRIPT
