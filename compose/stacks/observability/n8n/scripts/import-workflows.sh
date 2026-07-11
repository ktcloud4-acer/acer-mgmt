#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
STACK_FILE="${COMPOSE_ROOT}/stacks/observability/n8n/compose.yaml"
ROOT_ENV_FILE="${COMPOSE_ROOT}/../.env"
N8N_ENV_FILE="${N8N_ENV_FILE:-/home/mgmt-data/vault-agent/secrets/observability/n8n.env}"

[[ -r "${ROOT_ENV_FILE}" ]] || {
  echo "missing root environment file: ${ROOT_ENV_FILE}" >&2
  exit 1
}
[[ -r "${N8N_ENV_FILE}" ]] || {
  echo "missing rendered n8n secret file: ${N8N_ENV_FILE}" >&2
  exit 1
}

compose=(docker compose --env-file "${ROOT_ENV_FILE}" --env-file "${N8N_ENV_FILE}" -f "${STACK_FILE}")

for _ in $(seq 1 40); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}starting{{end}}' n8n 2>/dev/null || true)"
  if [[ "${status}" == "healthy" ]]; then
    break
  fi
  sleep 3
done

[[ "${status:-}" == "healthy" ]] || {
  echo "n8n did not become healthy" >&2
  exit 1
}

"${compose[@]}" exec -T n8n n8n import:workflow --input=/workflows/platform-digest.json
echo "Imported ACER 전체 운영 다이제스트. Create the n8n owner account, then activate the workflow in the UI."
