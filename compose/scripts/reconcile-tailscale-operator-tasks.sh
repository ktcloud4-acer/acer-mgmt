#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest=${TAILSCALE_OPERATOR_MANIFEST:-"$root_dir/compose/config/semaphore/tailscale-operator-projects.json"}
container_manifest=${SEMAPHORE_MANIFEST_PATH:-/opt/acer-mgmt/compose/config/semaphore/tailscale-operator-projects.json}
task_name='Bootstrap Tailscale Operator and Argo CD'

command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
jq -e 'type == "array" and length == 5 and all(.[]; .team | IN("ggg", "khb", "ljw", "nmg", "oje"))' "$manifest" >/dev/null

if [[ "${TAILSCALE_RECONCILE_DRY_RUN:-0}" == 1 ]]; then
  jq -r --arg task "$task_name" '.[] | "project=\(.project) team=\(.team) task=\($task)"' "$manifest"
  exit 0
fi

docker inspect semaphore >/dev/null
credential_file="$(mktemp)"
trap 'rm -f "$credential_file"' EXIT
docker exec vault sh -ceu '
  export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
  vault kv get -format=json -mount=kv mgmt/tailscale/task-credentials
' >/dev/null 2>&1 || true
for team in ggg khb ljw nmg oje; do
  docker exec vault sh -ceu '
    export VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca.crt VAULT_TOKEN="$(cat /tmp/.vt)"
    vault kv get -format=json -mount=kv "$1"
  ' sh "mgmt/tailscale/task-credentials/$team" | jq -cer --arg team "$team" '{team:$team,role_id:.data.data.role_id,secret_id:.data.data.secret_id}' >>"$credential_file" || {
    echo "missing fresh AppRole credentials for $team; run bootstrap-vault-tailscale-operator.sh $team first" >&2; exit 1;
  }
done
credentials_b64="$(base64 -w0 "$credential_file")"
docker exec -e "TAILSCALE_CREDENTIALS_B64=$credentials_b64" -i semaphore sh -s -- "$container_manifest" "$task_name" <<'CONTAINER_SCRIPT'
set -eu
manifest="$1"; task_name="$2"; tmp="$(mktemp -d)"; credentials="$tmp/credentials.jsonl"
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$TAILSCALE_CREDENTIALS_B64" | base64 -d >"$credentials"
unset TAILSCALE_CREDENTIALS_B64
get() { curl -fsS -b "$tmp/c" "http://localhost:3000/api$1"; }
post() { curl -fsS -b "$tmp/c" -H 'Content-Type: application/json' -X POST --data @"$2" "http://localhost:3000/api$1"; }
put() { curl -fsS -b "$tmp/c" -H 'Content-Type: application/json' -X PUT --data @"$2" "http://localhost:3000/api$1"; }
jq -n --arg auth "$SEMAPHORE_ADMIN" --arg password "$SEMAPHORE_ADMIN_PASSWORD" '{auth:$auth,password:$password}' >"$tmp/login.json"
curl -fsS -c "$tmp/c" -H 'Content-Type: application/json' --data @"$tmp/login.json" http://localhost:3000/api/auth/login -o /dev/null
jq -c '.[]' "$manifest" | while read -r entry; do
  team="$(jq -r .team <<<"$entry")"; project_name="$(jq -r .project <<<"$entry")"
  role_id="$(jq -r --arg team "$team" 'select(.team==$team)|.role_id' "$credentials")"
  secret_id="$(jq -r --arg team "$team" 'select(.team==$team)|.secret_id' "$credentials")"
  test -n "$role_id"; test "$role_id" != null; test -n "$secret_id"; test "$secret_id" != null
  project="$(get /projects | jq -r --arg n "$project_name" '.[]|select(.name==$n)|.id'|head -1)"; test -n "$project"; test "$project" != null
  key="$(get "/project/$project/keys" | jq -r '.[]|select(.type=="none")|.id'|head -1)"
  repo="$(get "/project/$project/repositories" | jq -r '.[]|select(.name=="Tailscale bootstrap")|.id'|head -1)"
  if test -z "$repo" || test "$repo" = null; then jq -n --argjson p "$project" --argjson k "$key" '{name:"Tailscale bootstrap",project_id:$p,git_url:"/opt/acer-mgmt",git_branch:"main",ssh_key_id:$k}' >"$tmp/repo.json"; repo="$(post "/project/$project/repositories" "$tmp/repo.json"|jq -r .id)"; fi
  env="$(get "/project/$project/environment"|jq -r '.[]|select(.name=="Tailscale bootstrap")|.id'|head -1)"
  jq -n --arg team "$team" --arg role "$role_id" --arg secret "$secret_id" --argjson p "$project" '{name:"Tailscale bootstrap",project_id:$p,json:"{}",env:{TAILSCALE_BOOTSTRAP_TEAM:$team,VAULT_ROLE_ID:$role,VAULT_SECRET_ID:$secret}|tojson}' >"$tmp/env.json"
  if test -z "$env" || test "$env" = null; then env="$(post "/project/$project/environment" "$tmp/env.json"|jq -r .id)"; else jq --argjson id "$env" '.+{id:$id}' "$tmp/env.json" >"$tmp/env2.json"; put "/project/$project/environment/$env" "$tmp/env2.json" >/dev/null; fi
  view="$(get "/project/$project/views"|jq -r '.[]|select(.title=="All")|.id'|head -1)"
  jq -n --arg n "$task_name" --argjson p "$project" --argjson r "$repo" --argjson e "$env" --argjson v "$view" '{name:$n,project_id:$p,repository_id:$r,environment_ids:[$e],view_id:$v,playbook:"compose/scripts/tailscale/semaphore-bootstrap-operator.sh",arguments:"[]",description:"Team-scoped Tailscale Operator and Argo CD recovery.",app:"bash",type:"",allow_parallel_tasks:false,survey_vars:[]}' >"$tmp/t.json"
  id="$(get "/project/$project/templates"|jq -r --arg n "$task_name" '.[]|select(.name==$n)|.id'|head -1)"
  if test -z "$id" || test "$id" = null; then id="$(post "/project/$project/templates" "$tmp/t.json"|jq -r .id)"; else jq --argjson id "$id" '.+{id:$id}' "$tmp/t.json" >"$tmp/t2.json"; put "/project/$project/templates/$id" "$tmp/t2.json" >/dev/null; fi
  echo "reconciled project=$project_name team=$team template=$id"
done
CONTAINER_SCRIPT
