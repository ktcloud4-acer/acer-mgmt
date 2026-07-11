#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing file: $file"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "expected '${expected}' in ${file}"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "unexpected '${unexpected}' in ${file}"
  fi
}

stack="${REPO_ROOT}/compose/stacks/observability/n8n/compose.yaml"
relay_config="${REPO_ROOT}/compose/stacks/observability/n8n/config/default.conf.template"
readme="${REPO_ROOT}/compose/stacks/observability/n8n/README.md"
vault_agent_config="${REPO_ROOT}/compose/stacks/security/vault-agent/config/agent.hcl"
secrets_example="${REPO_ROOT}/compose/vault-secrets.env.example"

assert_file "$stack"
assert_file "$relay_config"
assert_file "$readme"
assert_file "$vault_agent_config"
assert_file "$secrets_example"

assert_contains "$stack" "image: docker.n8n.io/n8nio/n8n:2.26.8"
assert_contains "$stack" "image: postgres:17-alpine"
assert_contains "$stack" "container_name: n8n"
assert_contains "$stack" "container_name: n8n-db"
assert_contains "$stack" "container_name: n8n-slack-relay"
assert_contains "$stack" "image: nginx:1.27-alpine"
assert_contains "$stack" "SLACK_WEBHOOK_INFRA: \${SLACK_WEBHOOK_INFRA:?SLACK_WEBHOOK_INFRA must be set}"
assert_contains "$stack" "wget --spider -q http://127.0.0.1:8080/healthz"
assert_contains "$stack" "DB_TYPE: postgresdb"
assert_contains "$stack" "DB_POSTGRESDB_HOST: n8n-db"
assert_contains "$stack" "N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY:?N8N_ENCRYPTION_KEY must be set}"
assert_contains "$stack" "GENERIC_TIMEZONE: \${TZ:-Asia/Seoul}"
assert_contains "$stack" "WEBHOOK_URL: https://n8n.\${BASE_DOMAIN}/"
assert_contains "$stack" "EXECUTIONS_DATA_MAX_AGE: \"720\""
assert_contains "$stack" "EXECUTIONS_DATA_PRUNE_MAX_COUNT: \"500\""
assert_contains "$stack" "./workflows:/workflows:ro,Z"
assert_contains "$stack" "./config/default.conf.template:/etc/nginx/templates/default.conf.template:ro,Z"
assert_contains "$stack" 'traefik.http.routers.n8n.rule=Host(`n8n.${BASE_DOMAIN}`)'
assert_contains "$stack" "traefik.http.routers.n8n.middlewares=secure-headers@file,sso-auth@file"
assert_contains "$stack" "traefik.http.services.n8n.loadbalancer.server.port=5678"
assert_contains "$stack" "internal: true"
assert_not_contains "$stack" "ports:"
assert_not_contains "$stack" "docker.sock"
assert_not_contains "$stack" "/proc:"
assert_not_contains "$stack" "/sys:"

if sed -n '/^  n8n:/,/^networks:/p' "$stack" | grep -Fq "SLACK_WEBHOOK_INFRA"; then
  fail "n8n must not receive the Slack webhook secret"
fi

assert_contains "$relay_config" "proxy_pass \${SLACK_WEBHOOK_INFRA};"
assert_contains "$relay_config" "location = /healthz"

assert_contains "$vault_agent_config" 'kv/data/mgmt/n8n'
assert_contains "$vault_agent_config" 'destination = "/vault/secrets/observability/n8n.env"'
assert_contains "$secrets_example" "N8N_ENCRYPTION_KEY"
assert_contains "$secrets_example" "DB_POSTGRESDB_PASSWORD"

echo "n8n stack tests passed"
