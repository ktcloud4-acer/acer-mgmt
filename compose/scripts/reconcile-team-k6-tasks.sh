#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest=${TEAM_K6_MANIFEST:-"$root_dir/compose/config/semaphore/team-k6-projects.json"}
container_manifest=${SEMAPHORE_MANIFEST_PATH:-/opt/acer-mgmt/compose/config/semaphore/team-k6-projects.json}
task_name='ScaleCart API HPA Load Test'

command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "manifest not found: $manifest" >&2; exit 1; }
jq -e 'type == "array" and length == 5' "$manifest" >/dev/null

if [[ "${TEAM_K6_DRY_RUN:-0}" == '1' ]]; then
  jq -r --arg task "$task_name" '.[] | "project=\(.project) team=\(.team) url=\(.base_url) vault=\(.vault_path) task=\($task)"' "$manifest"
  exit 0
fi

SEMAPHORE_CONTAINER=${SEMAPHORE_CONTAINER:-semaphore}
docker inspect "$SEMAPHORE_CONTAINER" >/dev/null

docker exec -i "$SEMAPHORE_CONTAINER" sh -s -- "$container_manifest" "$task_name" <<'CONTAINER_SCRIPT'
set -eu
manifest="$1"
task_name="$2"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

api_get() { curl -fsS -b "$tmp_dir/cookies" "http://localhost:3000/api$1"; }
api_post() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X POST --data @"$2" "http://localhost:3000/api$1"; }
api_put() { curl -fsS -b "$tmp_dir/cookies" -H 'Content-Type: application/json' -X PUT --data @"$2" "http://localhost:3000/api$1"; }

jq -n --arg auth "$SEMAPHORE_ADMIN" --arg password "$SEMAPHORE_ADMIN_PASSWORD" '{auth:$auth,password:$password}' >"$tmp_dir/login.json"
curl -fsS -c "$tmp_dir/cookies" -H 'Content-Type: application/json' --data @"$tmp_dir/login.json" http://localhost:3000/api/auth/login -o /dev/null

jq -c '.[]' "$manifest" | while IFS= read -r entry; do
  team="$(printf '%s' "$entry" | jq -r '.team')"
  project_name="$(printf '%s' "$entry" | jq -r '.project')"
  base_url="$(printf '%s' "$entry" | jq -r '.base_url')"
  project_id="$(api_get /projects | jq -r --arg name "$project_name" '.[] | select(.name == $name) | .id' | head -n1)"
  [ -n "$project_id" ] && [ "$project_id" != null ] || { echo "missing Semaphore project: $project_name" >&2; exit 1; }

  repository_id="$(api_get "/project/$project_id/repositories" | jq -r '.[] | select(.name == "ScaleCart k6 automation") | .id' | head -n1)"
  if [ -z "$repository_id" ] || [ "$repository_id" = null ]; then
    none_key_id="$(api_get "/project/$project_id/keys" | jq -r '.[] | select(.type == "none") | .id' | head -n1)"
    jq -n --arg name 'ScaleCart k6 automation' --arg path /opt/acer-mgmt --argjson key "$none_key_id" '{name:$name,git_url:$path,git_branch:"main",ssh_key_id:$key}' >"$tmp_dir/repository.json"
    repository_id="$(api_post "/project/$project_id/repositories" "$tmp_dir/repository.json" | jq -r '.id')"
  fi

  environment_id="$(api_get "/project/$project_id/environment" | jq -r '.[] | select(.name == "ScaleCart k6 target") | .id' | head -n1)"
  jq -n --arg team "$team" --arg url "$base_url" '{name:"ScaleCart k6 target",json:"{}",env:{K6_TEAM:$team,K6_BASE_URL:$url}|tojson}' >"$tmp_dir/environment.json"
  if [ -z "$environment_id" ] || [ "$environment_id" = null ]; then
    environment_id="$(api_post "/project/$project_id/environment" "$tmp_dir/environment.json" | jq -r '.id')"
  else
    api_put "/project/$project_id/environment/$environment_id" "$tmp_dir/environment.json" >/dev/null
  fi

  view_id="$(api_get "/project/$project_id/views" | jq -r '.[] | select(.title == "All") | .id' | head -n1)"
  jq -n --arg name "$task_name" --argjson repository "$repository_id" --argjson environment "$environment_id" --argjson view "$view_id" '{name:$name,repository_id:$repository,environment_ids:[$environment],view_id:$view,playbook:"compose/scripts/k6/semaphore-scalecart-api-hpa.sh",arguments:"[]",description:"Vault-backed k6 load test for this team\u0027s ScaleCart API HPA.",app:"bash",type:"",allow_parallel_tasks:false,survey_vars:[{name:"K6_RATE",title:"Request rate (RPS)",description:"Optional positive integer; default 150.",type:"int",required:false},{name:"K6_DURATION",title:"Hold duration",description:"Optional duration such as 4m; default 4m.",type:"",required:false}]}' >"$tmp_dir/template.json"
  template_id="$(api_get "/project/$project_id/templates" | jq -r --arg name "$task_name" '.[] | select(.name == $name) | .id' | head -n1)"
  if [ -z "$template_id" ] || [ "$template_id" = null ]; then
    template_id="$(api_post "/project/$project_id/templates" "$tmp_dir/template.json" | jq -r '.id')"
  else
    api_put "/project/$project_id/templates/$template_id" "$tmp_dir/template.json" >/dev/null
  fi
  printf 'reconciled project=%s team=%s template=%s\n' "$project_name" "$team" "$template_id"
done
CONTAINER_SCRIPT
