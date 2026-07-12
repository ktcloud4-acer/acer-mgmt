#!/usr/bin/env bash
set -euo pipefail

# Move Chaos Dashboard token issuance from the central project to one
# identically named Ansible task in each team's Semaphore project. The task
# always runs locally on mgmt and reaches the team's AIO via Tailnet SSH.
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest=${CHAOS_DASHBOARD_TOKEN_MANIFEST:-"$root_dir/compose/config/semaphore/chaos-dashboard-token-projects.json"}
container_manifest=${SEMAPHORE_MANIFEST_PATH:-/tmp/chaos-dashboard-token-projects.json}
repository_path=${SEMAPHORE_REPOSITORY_PATH:-/opt/acer-mgmt}
semaphore_container=${SEMAPHORE_CONTAINER:-semaphore}
task_name='Chaos Dashboard token'

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
test -r "$manifest" || { echo "manifest is unreadable: $manifest" >&2; exit 1; }
jq -e '
  type == "array" and length == 5 and
  ([.[].team] | sort == ["ggg", "khb", "ljw", "nmg", "oje"]) and
  ([.[].project] | unique | length == 5)
' "$manifest" >/dev/null || { echo 'invalid Chaos Dashboard team-project manifest' >&2; exit 1; }

if [[ "${CHAOS_DASHBOARD_TOKEN_DRY_RUN:-0}" == 1 ]]; then
  jq -r --arg task "$task_name" '.[] | "project=\(.project) team=\(.team) task=\($task)"' "$manifest"
  exit 0
fi

docker inspect "$semaphore_container" >/dev/null
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
docker cp "$manifest" "$semaphore_container:$container_manifest"

docker exec -i "$semaphore_container" sh -s -- "$container_manifest" "$repository_path" "$task_name" <<'CONTAINER_SCRIPT'
set -eu

manifest="$1"
repository_path="$2"
task_name="$3"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

api_get() { curl -fsS -b "$tmp_dir/cookies" "http://localhost:3000/api$1"; }
api_post() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X POST --data @"$2" "http://localhost:3000/api$1"; }
api_put() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X PUT --data @"$2" "http://localhost:3000/api$1"; }
api_delete() { curl -fsS -b "$tmp_dir/cookies" -X DELETE "http://localhost:3000/api$1" >/dev/null; }

json_id() { jq -r "$2" "$1" | head -n1; }
require_id() { test -n "$1" && test "$1" != null || { echo "missing $2" >&2; exit 1; }; }

jq -n --arg auth "$SEMAPHORE_ADMIN" --arg password "$SEMAPHORE_ADMIN_PASSWORD" '{auth:$auth,password:$password}' >"$tmp_dir/login.json"
curl -fsS -c "$tmp_dir/cookies" -H 'Content-Type: application/json' --data @"$tmp_dir/login.json" http://localhost:3000/api/auth/login -o /dev/null

projects="$(api_get /projects)"
mgmt_project="$(printf '%s' "$projects" | jq -r '.[] | select(.name == "acer-mgmt") | .id' | head -n1)"
require_id "$mgmt_project" 'Semaphore project acer-mgmt'

# Delete only prior Dashboard-token migration resources from the central
# project. DNS and other unrelated automation templates remain untouched.
printf '%s' "$(api_get "/project/$mgmt_project/templates")" | jq -r '
  .[] | select(.name == "chaos:issue-dashboard-token" or (.name | startswith("Chaos Dashboard token - "))) | .id
' | while read -r template_id; do
  [ -n "$template_id" ] && api_delete "/project/$mgmt_project/templates/$template_id"
done
printf '%s' "$(api_get "/project/$mgmt_project/environment")" | jq -r '
  .[] | select(.name | startswith("Dashboard token issuer - ")) | .id
' | while read -r environment_id; do
  [ -n "$environment_id" ] && api_delete "/project/$mgmt_project/environment/$environment_id"
done

jq -c '.[]' "$manifest" >"$tmp_dir/team-projects.jsonl"
while read -r entry; do
  team="$(printf '%s' "$entry" | jq -r '.team')"
  project_name="$(printf '%s' "$entry" | jq -r '.project')"
  project_id="$(printf '%s' "$projects" | jq -r --arg name "$project_name" '.[] | select(.name == $name) | .id' | head -n1)"
  require_id "$project_id" "Semaphore project $project_name"

  repositories="$(api_get "/project/$project_id/repositories")"
  repository_id="$(printf '%s' "$repositories" | jq -r '.[] | select(.name == "mgmt automation") | .id' | head -n1)"
  none_key_id="$(api_get "/project/$project_id/keys" | jq -r '.[] | select(.type == "none") | .id' | head -n1)"
  require_id "$none_key_id" "none key in $project_name"
  jq -n --argjson project "$project_id" --arg path "$repository_path" --argjson key "$none_key_id" \
    '{name:"mgmt automation",project_id:$project,git_url:$path,git_branch:"main",ssh_key_id:$key}' >"$tmp_dir/repository.json"
  if [ -z "$repository_id" ] || [ "$repository_id" = null ]; then
    repository_id="$(api_post "/project/$project_id/repositories" "$tmp_dir/repository.json" | jq -r '.id')"
  else
    jq --argjson id "$repository_id" '. + {id:$id}' "$tmp_dir/repository.json" >"$tmp_dir/repository-update.json"
    api_put "/project/$project_id/repositories/$repository_id" "$tmp_dir/repository-update.json" >/dev/null
  fi

  inventory_name='AIO Tailnet'
  inventory_id="$(api_get "/project/$project_id/inventory" | jq -r --arg name "$inventory_name" '.[] | select(.name == $name) | .id' | head -n1)"
  inventory_contents="$(cat "$repository_path/compose/ansible/aio-hosts.yml")"
  jq -n --argjson project "$project_id" --arg name "$inventory_name" --arg inventory "$inventory_contents" --argjson key "$none_key_id" \
    '{name:$name,project_id:$project,inventory:$inventory,ssh_key_id:$key,become_key_id:$key,type:"static-yaml"}' >"$tmp_dir/inventory.json"
  if [ -z "$inventory_id" ] || [ "$inventory_id" = null ]; then
    inventory_id="$(api_post "/project/$project_id/inventory" "$tmp_dir/inventory.json" | jq -r '.id')"
  else
    jq --argjson id "$inventory_id" '. + {id:$id}' "$tmp_dir/inventory.json" >"$tmp_dir/inventory-update.json"
    api_put "/project/$project_id/inventory/$inventory_id" "$tmp_dir/inventory-update.json" >/dev/null
  fi
  require_id "$inventory_id" "AIO Tailnet inventory in $project_name"

  environment_id="$(api_get "/project/$project_id/environment" | jq -r --arg name "$task_name" '.[] | select(.name == $name) | .id' | head -n1)"
  jq -n --argjson project "$project_id" --arg name "$task_name" '{name:$name,project_id:$project,json:"{}",env:"{}"}' >"$tmp_dir/environment.json"
  if [ -z "$environment_id" ] || [ "$environment_id" = null ]; then
    environment_id="$(api_post "/project/$project_id/environment" "$tmp_dir/environment.json" | jq -r '.id')"
  else
    jq --argjson id "$environment_id" '. + {id:$id}' "$tmp_dir/environment.json" >"$tmp_dir/environment-update.json"
    api_put "/project/$project_id/environment/$environment_id" "$tmp_dir/environment-update.json" >/dev/null
  fi

  view_id="$(api_get "/project/$project_id/views" | jq -r '.[] | select(.title == "All") | .id' | head -n1)"
  require_id "$view_id" "All view in $project_name"
  jq -n --arg name "$task_name" --arg team "$team" --argjson project "$project_id" --argjson inventory "$inventory_id" --argjson repository "$repository_id" --argjson environment "$environment_id" --argjson view "$view_id" \
    '{name:$name,project_id:$project,inventory_id:$inventory,repository_id:$repository,environment_ids:[$environment],view_id:$view,playbook:"compose/ansible/issue-chaos-dashboard-token.yml",arguments:("[\\\"--extra-vars\\\",\\\"chaos_dashboard_team=" + $team + "\\\"]"),description:("Issue a 10-minute token for the " + $team + " Chaos Mesh Dashboard from mgmt."),app:"ansible",type:"",allow_parallel_tasks:false,survey_vars:[]}' >"$tmp_dir/template.json"
  template_id="$(api_get "/project/$project_id/templates" | jq -r --arg name "$task_name" '.[] | select(.name == $name) | .id' | head -n1)"
  if [ -z "$template_id" ] || [ "$template_id" = null ]; then
    template_id="$(api_post "/project/$project_id/templates" "$tmp_dir/template.json" | jq -r '.id')"
  else
    jq --argjson id "$template_id" '. + {id:$id}' "$tmp_dir/template.json" >"$tmp_dir/template-update.json"
    api_put "/project/$project_id/templates/$template_id" "$tmp_dir/template-update.json" >/dev/null
  fi
  require_id "$template_id" "Chaos Dashboard token template in $project_name"
  printf 'reconciled project=%s team=%s template=%s\n' "$project_name" "$team" "$template_id"
done <"$tmp_dir/team-projects.jsonl"
CONTAINER_SCRIPT
